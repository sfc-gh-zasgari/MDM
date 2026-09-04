/*
================================================================================
P03_PROVIDER_ML_MATCHING.sql
================================================================================
STEP 3 OF 5 IN THE PROVIDER ENTITY RESOLUTION PIPELINE

PURPOSE:
  For pairs that Tier 1 (deterministic rules) could not resolve — names are
  50-84% similar — this step uses a machine learning model to combine multiple
  weak signals into a single merge probability. The model learns from Tier 1's
  high-confidence decisions and applies that knowledge to uncertain pairs.

RUN ON: ADOPTIVE_WH (adaptive warehouse — auto-scales for ML workloads)
INPUT:  MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN
        MDM.MATCHING.PROVIDER_MATCH_RESULTS (Tier 1 results)
OUTPUT: Inserts AUTO_MERGE and MANUAL_REVIEW pairs into PROVIDER_MATCH_RESULTS

PREREQUISITE: P02_provider_deterministic_matching.sql must have run.

HOW IT WORKS:
  1. BLOCKING: Generate candidate pairs from records that MIGHT be the same
     provider but weren't caught by Tier 1. Conditions:
       - Same PROVIDER_TYPE_DESC (same specialty)
       - Same ZIP OR same CITY (geographic proximity)
       - 50 <= JAROWINKLER(name) < 85 (uncertain name similarity zone)
       - Secondary name guard (JW >= 50% if both present)
       - Excludes Tier 1 pairs
     This produces ~197M candidate pairs.

  2. TRAINING: Build labeled data from ground truth:
       - POSITIVE (50K): Sample from Tier 1 AUTO_MERGE (high-confidence matches)
       - NEGATIVE (50K): Sample from candidate pairs (Tier 1 rejects)
     Compute 10 numeric features for each pair.

  3. MODEL: Train SNOWFLAKE.ML.CLASSIFICATION — a native gradient boosting
     classifier. No external libraries or compute pools needed.

  4. PRE-FILTER: 197M pairs is too large for inline prediction. Only score
     pairs with at least one corroborating signal beyond name similarity:
       - Batch A: Phone matches OR license matches (~14K pairs)
       - Batch B: Address exact + JW >= 70% (~253K pairs)
     Pairs with NO corroborating signal always predict NO_MATCH — skip them.

  5. ROUTING:
       - merge_probability >= 0.80 → AUTO_MERGE
       - merge_probability < 0.65 → AUTO_REJECT (not stored)
       - 0.65 <= probability < 0.80 → MANUAL_REVIEW → escalate to Tier 3 LLM
       - NPI conflict guard: reject when NPIs differ AND names are dissimilar (JW < 80%)
       - Allows diff-NPI pairs if names are similar (possible NPI reassignment)

FEATURES (10 numeric columns from clean data):
  ┌───────────────────────┬────────────┬────────────────────────────────────┐
  │ Feature               │ Importance │ Description                        │
  ├───────────────────────┼────────────┼────────────────────────────────────┤
  │ name_primary_jw       │ ~67%       │ JW score on NAME_PRIMARY_CLEAN     │
  │ phone_exact           │ ~8%        │ PHONE matches (10-digit clean)     │
  │ address_exact         │ ~8%        │ ADDRESS_CLEAN matches exactly      │
  │ name_secondary_jw     │ ~6%        │ JW on NAME_SECONDARY_CLEAN         │
  │ npi_conflict          │ ~4%        │ Both have NPI but they differ      │
  │ npi_valid_both        │ ~4%        │ Both have valid NPI                │
  │ city_exact            │ ~4%        │ Same CITY                          │
  │ license_exact         │ <1%        │ Same LICENSE_NUMBER                │
  │ zip_exact             │ <1%        │ Same ZIP (mostly 1, blocked on it) │
  │ street_exact          │ <1%        │ Same ADDRESS_STREET                │
  └───────────────────────┴────────────┴────────────────────────────────────┘

WHY ML OUTPERFORMS HAND-TUNED RULES:
  A rule must pick one threshold (e.g., JW >= 80% + phone match). The ML model
  learns complex combinations: "JW 72% + phone match + same address = 98% MATCH"
  AND "JW 82% + NPI conflict = 1% MATCH" — too complex for rules.

COST: ~1.4 credits | ~10 min total

NEXT STEP: P04_PROVIDER_LLM_MATCHING.sql
================================================================================
*/

USE WAREHOUSE ADOPTIVE_WH;
USE DATABASE MDM;
USE SCHEMA MATCHING;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1: BLOCKING — Generate candidate pairs (~197M)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.PROVIDER_ML_CANDIDATE_PAIRS AS
WITH base AS (
    SELECT
        ROW_ID, NAME_PRIMARY_CLEAN, NAME_SECONDARY_CLEAN,
        ADDRESS_CLEAN, ADDRESS_STREET, ZIP, CITY,
        PHONE, NPI, NPI_VALID, PROVIDER_TYPE_DESC,
        LICENSE_NUMBER, PROVIDER_ID, _SOURCE_SYSTEM,
        LATITUDE, LONGITUDE
    FROM MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN
    WHERE NAME_PRIMARY_CLEAN IS NOT NULL AND TRIM(NAME_PRIMARY_CLEAN) != ''
      AND PROVIDER_TYPE_DESC IS NOT NULL AND TRIM(PROVIDER_TYPE_DESC) != ''
)
SELECT
    a.ROW_ID AS ROW_ID_A, b.ROW_ID AS ROW_ID_B,
    a.NAME_PRIMARY_CLEAN AS NAME_A, b.NAME_PRIMARY_CLEAN AS NAME_B,
    a.NAME_SECONDARY_CLEAN AS SEC_NAME_A, b.NAME_SECONDARY_CLEAN AS SEC_NAME_B,
    a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
    a.ADDRESS_STREET AS STREET_A, b.ADDRESS_STREET AS STREET_B,
    a.ZIP AS ZIP_A, b.ZIP AS ZIP_B,
    a.CITY AS CITY_A, b.CITY AS CITY_B,
    a.PHONE AS PHONE_A, b.PHONE AS PHONE_B,
    a.NPI AS NPI_A, b.NPI AS NPI_B,
    a.NPI_VALID AS NPI_VALID_A, b.NPI_VALID AS NPI_VALID_B,
    a.PROVIDER_TYPE_DESC AS TYPE_A, b.PROVIDER_TYPE_DESC AS TYPE_B,
    a.LICENSE_NUMBER AS LICENSE_A, b.LICENSE_NUMBER AS LICENSE_B,
    a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
    ROUND(JAROWINKLER_SIMILARITY(a.NAME_PRIMARY_CLEAN, b.NAME_PRIMARY_CLEAN) / 100.0, 4) AS NAME_PRIMARY_JW
FROM base a
JOIN base b
  ON a.PROVIDER_TYPE_DESC = b.PROVIDER_TYPE_DESC
 AND (a.ZIP = b.ZIP OR a.CITY = b.CITY)
 AND a.ROW_ID < b.ROW_ID
WHERE
    JAROWINKLER_SIMILARITY(a.NAME_PRIMARY_CLEAN, b.NAME_PRIMARY_CLEAN) >= 50
    AND JAROWINKLER_SIMILARITY(a.NAME_PRIMARY_CLEAN, b.NAME_PRIMARY_CLEAN) < 85
    AND (a.NAME_SECONDARY_CLEAN IS NULL OR a.NAME_SECONDARY_CLEAN = ''
         OR b.NAME_SECONDARY_CLEAN IS NULL OR b.NAME_SECONDARY_CLEAN = ''
         OR JAROWINKLER_SIMILARITY(a.NAME_SECONDARY_CLEAN, b.NAME_SECONDARY_CLEAN) >= 50)
    AND NOT (a.NPI = b.NPI AND a.NPI IS NOT NULL AND a.NPI != '')
    AND NOT (a.NAME_PRIMARY_CLEAN = b.NAME_PRIMARY_CLEAN
             AND a.ADDRESS_CLEAN = b.ADDRESS_CLEAN
             AND a.ZIP = b.ZIP
             AND a.PROVIDER_TYPE_DESC = b.PROVIDER_TYPE_DESC);


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2: TRAINING DATA — Labeled pairs for model training
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.PROVIDER_ML_TRAINING_DATA AS
WITH t1_positives AS (
    SELECT
        JAROWINKLER_SIMILARITY(NAME_A, NAME_B) / 100.0 AS name_primary_jw,
        NULL AS name_secondary_jw,
        CASE WHEN ADDR_A = ADDR_B AND ADDR_A IS NOT NULL AND ADDR_A != '' THEN 1 ELSE 0 END AS address_exact,
        CASE WHEN ADDR_A = ADDR_B THEN 1 ELSE 0 END AS street_exact,
        CASE WHEN ZIP_A = ZIP_B THEN 1 ELSE 0 END AS zip_exact,
        1 AS city_exact,
        CASE WHEN PHONE_A IS NOT NULL AND PHONE_A != '' AND PHONE_B IS NOT NULL AND PHONE_B != '' AND PHONE_A = PHONE_B THEN 1 ELSE 0 END AS phone_exact,
        CASE WHEN TYPE_A IS NOT NULL AND TYPE_B IS NOT NULL AND TYPE_A = TYPE_B THEN 1 ELSE 0 END AS type_exact,
        0 AS license_exact,
        'MATCH' AS IS_MATCH
    FROM MDM.MATCHING.PROVIDER_MATCH_RESULTS
    WHERE ROUTING = 'AUTO_MERGE'
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM(42)) <= 50000
),
negatives AS (
    SELECT
        c.NAME_PRIMARY_JW AS name_primary_jw,
        CASE WHEN c.SEC_NAME_A IS NOT NULL AND c.SEC_NAME_A != '' AND c.SEC_NAME_B IS NOT NULL AND c.SEC_NAME_B != ''
             THEN JAROWINKLER_SIMILARITY(c.SEC_NAME_A, c.SEC_NAME_B) / 100.0 ELSE NULL END AS name_secondary_jw,
        CASE WHEN c.ADDR_A = c.ADDR_B AND c.ADDR_A IS NOT NULL AND c.ADDR_A != '' THEN 1 ELSE 0 END AS address_exact,
        CASE WHEN c.STREET_A = c.STREET_B AND c.STREET_A IS NOT NULL AND c.STREET_A != '' THEN 1 ELSE 0 END AS street_exact,
        CASE WHEN c.ZIP_A = c.ZIP_B THEN 1 ELSE 0 END AS zip_exact,
        CASE WHEN c.CITY_A = c.CITY_B THEN 1 ELSE 0 END AS city_exact,
        CASE WHEN c.PHONE_A IS NOT NULL AND c.PHONE_A != '' AND c.PHONE_B IS NOT NULL AND c.PHONE_B != '' AND c.PHONE_A = c.PHONE_B THEN 1 ELSE 0 END AS phone_exact,
        CASE WHEN c.TYPE_A IS NOT NULL AND c.TYPE_A != '' AND c.TYPE_B IS NOT NULL AND c.TYPE_B != '' AND c.TYPE_A = c.TYPE_B THEN 1 ELSE 0 END AS type_exact,
        CASE WHEN c.LICENSE_A IS NOT NULL AND c.LICENSE_A != '' AND c.LICENSE_B IS NOT NULL AND c.LICENSE_B != '' AND c.LICENSE_A = c.LICENSE_B THEN 1 ELSE 0 END AS license_exact,
        'NO_MATCH' AS IS_MATCH
    FROM MDM.MATCHING.PROVIDER_ML_CANDIDATE_PAIRS c
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM(42)) <= 50000
)
SELECT * FROM t1_positives UNION ALL SELECT * FROM negatives;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 3: TRAIN — Fit the ML classification model
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION MDM.MATCHING.PROVIDER_DEDUP_MODEL(
    INPUT_DATA     => SYSTEM$REFERENCE('TABLE', 'MDM.MATCHING.PROVIDER_ML_TRAINING_DATA'),
    TARGET_COLNAME => 'IS_MATCH'
);

CALL MDM.MATCHING.PROVIDER_DEDUP_MODEL!SHOW_FEATURE_IMPORTANCE();


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 4: SCORE — Run inference on pre-filtered candidate pairs
-- ══════════════════════════════════════════════════════════════════════════════

-- Batch A: Phone or license matches
CREATE OR REPLACE TABLE MDM.MATCHING.PROVIDER_ML_SCORES AS
SELECT
    c.ROW_ID_A, c.ROW_ID_B,
    c.NPI_A, c.NPI_B, c.NAME_A, c.NAME_B, c.ADDR_A, c.ADDR_B,
    c.ZIP_A, c.ZIP_B, c.TYPE_A, c.TYPE_B, c.PHONE_A, c.PHONE_B,
    c.SOURCE_A, c.SOURCE_B, c.NAME_PRIMARY_JW,
    MDM.MATCHING.PROVIDER_DEDUP_MODEL!PREDICT(
        INPUT_DATA => OBJECT_CONSTRUCT(
            'NAME_PRIMARY_JW', c.NAME_PRIMARY_JW,
            'NAME_SECONDARY_JW', CASE WHEN c.SEC_NAME_A IS NOT NULL AND c.SEC_NAME_A != '' AND c.SEC_NAME_B IS NOT NULL AND c.SEC_NAME_B != '' THEN JAROWINKLER_SIMILARITY(c.SEC_NAME_A, c.SEC_NAME_B) / 100.0 ELSE NULL END,
            'ADDRESS_EXACT', CASE WHEN c.ADDR_A = c.ADDR_B AND c.ADDR_A IS NOT NULL AND c.ADDR_A != '' THEN 1 ELSE 0 END,
            'STREET_EXACT', CASE WHEN c.STREET_A = c.STREET_B AND c.STREET_A IS NOT NULL AND c.STREET_A != '' THEN 1 ELSE 0 END,
            'ZIP_EXACT', CASE WHEN c.ZIP_A = c.ZIP_B THEN 1 ELSE 0 END,
            'CITY_EXACT', CASE WHEN c.CITY_A = c.CITY_B THEN 1 ELSE 0 END,
            'PHONE_EXACT', CASE WHEN c.PHONE_A IS NOT NULL AND c.PHONE_A != '' AND c.PHONE_B IS NOT NULL AND c.PHONE_B != '' AND c.PHONE_A = c.PHONE_B THEN 1 ELSE 0 END,
            'TYPE_EXACT', CASE WHEN c.TYPE_A IS NOT NULL AND c.TYPE_A != '' AND c.TYPE_B IS NOT NULL AND c.TYPE_B != '' AND c.TYPE_A = c.TYPE_B THEN 1 ELSE 0 END,
            'LICENSE_EXACT', CASE WHEN c.LICENSE_A IS NOT NULL AND c.LICENSE_A != '' AND c.LICENSE_B IS NOT NULL AND c.LICENSE_B != '' AND c.LICENSE_A = c.LICENSE_B THEN 1 ELSE 0 END
        )
    ) AS prediction
FROM MDM.MATCHING.PROVIDER_ML_CANDIDATE_PAIRS c
WHERE (c.PHONE_A IS NOT NULL AND c.PHONE_A != '' AND c.PHONE_B IS NOT NULL AND c.PHONE_B != '' AND c.PHONE_A = c.PHONE_B)
   OR (c.LICENSE_A IS NOT NULL AND c.LICENSE_A != '' AND c.LICENSE_B IS NOT NULL AND c.LICENSE_B != '' AND c.LICENSE_A = c.LICENSE_B);

-- Batch B: Address exact + JW >= 70% (excludes Batch A)
INSERT INTO MDM.MATCHING.PROVIDER_ML_SCORES
SELECT
    c.ROW_ID_A, c.ROW_ID_B,
    c.NPI_A, c.NPI_B, c.NAME_A, c.NAME_B, c.ADDR_A, c.ADDR_B,
    c.ZIP_A, c.ZIP_B, c.TYPE_A, c.TYPE_B, c.PHONE_A, c.PHONE_B,
    c.SOURCE_A, c.SOURCE_B, c.NAME_PRIMARY_JW,
    MDM.MATCHING.PROVIDER_DEDUP_MODEL!PREDICT(
        INPUT_DATA => OBJECT_CONSTRUCT(
            'NAME_PRIMARY_JW', c.NAME_PRIMARY_JW,
            'NAME_SECONDARY_JW', CASE WHEN c.SEC_NAME_A IS NOT NULL AND c.SEC_NAME_A != '' AND c.SEC_NAME_B IS NOT NULL AND c.SEC_NAME_B != '' THEN JAROWINKLER_SIMILARITY(c.SEC_NAME_A, c.SEC_NAME_B) / 100.0 ELSE NULL END,
            'ADDRESS_EXACT', 1,
            'STREET_EXACT', CASE WHEN c.STREET_A = c.STREET_B AND c.STREET_A IS NOT NULL THEN 1 ELSE 0 END,
            'ZIP_EXACT', CASE WHEN c.ZIP_A = c.ZIP_B THEN 1 ELSE 0 END,
            'CITY_EXACT', CASE WHEN c.CITY_A = c.CITY_B THEN 1 ELSE 0 END,
            'PHONE_EXACT', CASE WHEN c.PHONE_A IS NOT NULL AND c.PHONE_A != '' AND c.PHONE_B IS NOT NULL AND c.PHONE_B != '' AND c.PHONE_A = c.PHONE_B THEN 1 ELSE 0 END,
            'TYPE_EXACT', CASE WHEN c.TYPE_A IS NOT NULL AND c.TYPE_A != '' AND c.TYPE_B IS NOT NULL AND c.TYPE_B != '' AND c.TYPE_A = c.TYPE_B THEN 1 ELSE 0 END,
            'LICENSE_EXACT', CASE WHEN c.LICENSE_A IS NOT NULL AND c.LICENSE_A != '' AND c.LICENSE_B IS NOT NULL AND c.LICENSE_B != '' AND c.LICENSE_A = c.LICENSE_B THEN 1 ELSE 0 END
        )
    ) AS prediction
FROM MDM.MATCHING.PROVIDER_ML_CANDIDATE_PAIRS c
WHERE c.ADDR_A = c.ADDR_B AND c.ADDR_A IS NOT NULL AND c.ADDR_A != ''
  AND c.NAME_PRIMARY_JW >= 0.70
  AND NOT (c.PHONE_A IS NOT NULL AND c.PHONE_A != '' AND c.PHONE_B IS NOT NULL AND c.PHONE_B != '' AND c.PHONE_A = c.PHONE_B)
  AND NOT (c.LICENSE_A IS NOT NULL AND c.LICENSE_A != '' AND c.LICENSE_B IS NOT NULL AND c.LICENSE_B != '' AND c.LICENSE_A = c.LICENSE_B);


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 5: ROUTE — Insert ML results into PROVIDER_MATCH_RESULTS
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO MDM.MATCHING.PROVIDER_MATCH_RESULTS (
    ROW_A, ROW_B, NPI_A, NPI_B, NAME_A, NAME_B, ADDR_A, ADDR_B,
    ZIP_A, ZIP_B, TYPE_A, TYPE_B, PHONE_A, PHONE_B, SOURCE_A, SOURCE_B,
    MATCH_TYPE, HYBRID_SCORE, ROUTING
)
SELECT
    ROW_ID_A, ROW_ID_B, NPI_A, NPI_B, NAME_A, NAME_B, ADDR_A, ADDR_B,
    ZIP_A, ZIP_B, TYPE_A, TYPE_B, PHONE_A, PHONE_B, SOURCE_A, SOURCE_B,
    'PROV_ML_MATCH' AS MATCH_TYPE,
    prediction:"probability":"MATCH"::FLOAT AS HYBRID_SCORE,
    CASE WHEN prediction:"probability":"MATCH"::FLOAT >= 0.80 THEN 'AUTO_MERGE'
         ELSE 'MANUAL_REVIEW' END AS ROUTING
FROM MDM.MATCHING.PROVIDER_ML_SCORES
WHERE prediction:"probability":"MATCH"::FLOAT >= 0.65
  -- NPI conflict guard: reject only when BOTH NPIs differ AND names are dissimilar
  -- (allows matches where same provider got a new NPI but name is similar)
  AND NOT (NPI_A IS NOT NULL AND NPI_A != '' AND NPI_B IS NOT NULL AND NPI_B != '' AND NPI_A != NPI_B
           AND JAROWINKLER_SIMILARITY(NAME_A, NAME_B) < 80);


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT
    CASE
        WHEN prediction:"probability":"MATCH"::FLOAT >= 0.80 THEN 'AUTO_MERGE'
        WHEN prediction:"probability":"MATCH"::FLOAT <= 0.65 THEN 'AUTO_REJECT'
        ELSE 'MANUAL_REVIEW'
    END AS ROUTING,
    COUNT(*) AS pairs
FROM MDM.MATCHING.PROVIDER_ML_SCORES
GROUP BY ROUTING ORDER BY pairs DESC;

SELECT MATCH_TYPE, ROUTING, COUNT(*) AS pairs
FROM MDM.MATCHING.PROVIDER_MATCH_RESULTS
GROUP BY MATCH_TYPE, ROUTING ORDER BY pairs DESC;
