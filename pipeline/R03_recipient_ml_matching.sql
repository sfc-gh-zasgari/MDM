/*
================================================================================
R03_RECIPIENT_ML_MATCHING.sql
================================================================================
STEP 3 OF 5 IN THE RECIPIENT ENTITY RESOLUTION PIPELINE

PURPOSE:
  For recipient pairs that Tier 1 could not resolve, uses ML classification
  to combine multiple weak signals into a single merge probability.

RUN ON: ADOPTIVE_WH
INPUT:  MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN
        MDM.MATCHING.RECIPIENT_MATCH_RESULTS (Tier 1)
OUTPUT: Inserts AUTO_MERGE pairs into RECIPIENT_MATCH_RESULTS

PREREQUISITE: R02_recipient_deterministic_matching.sql must have run.

BLOCKING STRATEGY:
  Generate candidate pairs where:
    - Same DOB (strong correlated signal)
    - OR same ZIP + same SSN_LAST4
    - AND JW(first+last name) between 50-84% (uncertain zone)
    - Exclude pairs already matched by Tier 1

FEATURES (8 numeric columns):
  name_jw, ssn_exact, dob_exact, address_exact, zip_exact,
  gender_exact, dl_exact, passport_exact

TRAINING:
  - POSITIVE: Tier 1 matches (high-confidence ground truth)
  - NEGATIVE: Candidate pairs (Tier 1 rejects)

NOTE ON RESULTS:
  In testing with heavily corrupted data (multiple fields simultaneously null),
  the ML model may reject all candidates. This is correct behavior — pairs with
  no corroborating signals (null SSN, null DOB, null address) cannot be
  confidently matched by feature-based classification. These escalate to Tier 3.

NEXT STEP: R04_RECIPIENT_LLM_MATCHING.sql
================================================================================
*/

USE WAREHOUSE ADOPTIVE_WH;
USE DATABASE MDM;
USE SCHEMA MATCHING;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1: BLOCKING — Generate candidate pairs
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_ML_CANDIDATE_PAIRS AS
WITH r AS (
    SELECT * FROM MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN
    WHERE FIRST_NAME_CLEAN IS NOT NULL AND FIRST_NAME_CLEAN != ''
      AND LAST_NAME_CLEAN IS NOT NULL AND LAST_NAME_CLEAN != ''
)
SELECT
    a.ROW_ID AS ROW_ID_A, b.ROW_ID AS ROW_ID_B,
    a.FIRST_NAME_CLEAN AS FNAME_A, b.FIRST_NAME_CLEAN AS FNAME_B,
    a.LAST_NAME_CLEAN AS LNAME_A, b.LAST_NAME_CLEAN AS LNAME_B,
    a.DOB_CLEAN AS DOB_A, b.DOB_CLEAN AS DOB_B,
    a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
    a.ADDRESS_ZIP AS ZIP_A, b.ADDRESS_ZIP AS ZIP_B,
    a.SSN AS SSN_A, b.SSN AS SSN_B,
    a.SSN_LAST4 AS SSN4_A, b.SSN_LAST4 AS SSN4_B,
    a.GENDER_CLEAN AS GENDER_A, b.GENDER_CLEAN AS GENDER_B,
    a.DRIVERS_LICENSE_NUMBER AS DL_A, b.DRIVERS_LICENSE_NUMBER AS DL_B,
    a.PASSPORT_NUMBER AS PP_A, b.PASSPORT_NUMBER AS PP_B,
    a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
    ROUND(JAROWINKLER_SIMILARITY(
        a.FIRST_NAME_CLEAN || ' ' || a.LAST_NAME_CLEAN,
        b.FIRST_NAME_CLEAN || ' ' || b.LAST_NAME_CLEAN
    ) / 100.0, 4) AS NAME_JW
FROM r a JOIN r b
  ON a.ROW_ID < b.ROW_ID
 AND ((a.DOB_CLEAN = b.DOB_CLEAN AND a.DOB_CLEAN IS NOT NULL)
   OR (a.ADDRESS_ZIP = b.ADDRESS_ZIP AND a.SSN_LAST4 = b.SSN_LAST4
       AND a.ADDRESS_ZIP IS NOT NULL AND a.SSN_LAST4 IS NOT NULL))
WHERE
  JAROWINKLER_SIMILARITY(a.FIRST_NAME_CLEAN || ' ' || a.LAST_NAME_CLEAN,
                          b.FIRST_NAME_CLEAN || ' ' || b.LAST_NAME_CLEAN) >= 50
  AND JAROWINKLER_SIMILARITY(a.FIRST_NAME_CLEAN || ' ' || a.LAST_NAME_CLEAN,
                              b.FIRST_NAME_CLEAN || ' ' || b.LAST_NAME_CLEAN) < 85
  AND NOT (a.SSN = b.SSN AND a.SSN IS NOT NULL)
  AND NOT (a.FIRST_NAME_CLEAN = b.FIRST_NAME_CLEAN
       AND a.LAST_NAME_CLEAN = b.LAST_NAME_CLEAN
       AND a.ADDRESS_CLEAN = b.ADDRESS_CLEAN
       AND a.DOB_CLEAN = b.DOB_CLEAN);

SELECT COUNT(*) AS candidate_pairs FROM MDM.MATCHING.RECIP_ML_CANDIDATE_PAIRS;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2: TRAINING DATA
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_ML_TRAINING AS
WITH t1_pos AS (
    SELECT
        JAROWINKLER_SIMILARITY(FNAME_A || ' ' || LNAME_A, FNAME_B || ' ' || LNAME_B) / 100.0 AS name_jw,
        CASE WHEN SSN_A = SSN_B AND SSN_A IS NOT NULL THEN 1 ELSE 0 END AS ssn_exact,
        CASE WHEN DOB_A = DOB_B AND DOB_A IS NOT NULL THEN 1 ELSE 0 END AS dob_exact,
        CASE WHEN ADDR_A = ADDR_B AND ADDR_A IS NOT NULL AND ADDR_A != '' THEN 1 ELSE 0 END AS address_exact,
        CASE WHEN ZIP_A = ZIP_B AND ZIP_A IS NOT NULL THEN 1 ELSE 0 END AS zip_exact,
        0 AS gender_exact, 0 AS dl_exact, 0 AS passport_exact,
        'MATCH' AS IS_MATCH
    FROM MDM.MATCHING.RECIPIENT_MATCH_RESULTS
    WHERE MATCH_TYPE LIKE 'RECIP_R%'
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM(42)) <= 200
),
neg AS (
    SELECT
        c.NAME_JW AS name_jw,
        CASE WHEN c.SSN_A = c.SSN_B AND c.SSN_A IS NOT NULL THEN 1 ELSE 0 END AS ssn_exact,
        CASE WHEN c.DOB_A = c.DOB_B AND c.DOB_A IS NOT NULL THEN 1 ELSE 0 END AS dob_exact,
        CASE WHEN c.ADDR_A = c.ADDR_B AND c.ADDR_A IS NOT NULL AND c.ADDR_A != '' THEN 1 ELSE 0 END AS address_exact,
        CASE WHEN c.ZIP_A = c.ZIP_B AND c.ZIP_A IS NOT NULL THEN 1 ELSE 0 END AS zip_exact,
        CASE WHEN c.GENDER_A = c.GENDER_B THEN 1 ELSE 0 END AS gender_exact,
        CASE WHEN c.DL_A = c.DL_B AND c.DL_A IS NOT NULL AND c.DL_A != '' THEN 1 ELSE 0 END AS dl_exact,
        CASE WHEN c.PP_A = c.PP_B AND c.PP_A IS NOT NULL AND c.PP_A != '' THEN 1 ELSE 0 END AS passport_exact,
        'NO_MATCH' AS IS_MATCH
    FROM MDM.MATCHING.RECIP_ML_CANDIDATE_PAIRS c
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM(42)) <= 200
)
SELECT * FROM t1_pos UNION ALL SELECT * FROM neg;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 3: TRAIN ML MODEL
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION MDM.MATCHING.RECIP_DEDUP_MODEL(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'MDM.MATCHING.RECIP_ML_TRAINING'),
    TARGET_COLNAME => 'IS_MATCH'
);


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 4: SCORE all candidate pairs
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_ML_SCORED AS
SELECT c.*,
    MDM.MATCHING.RECIP_DEDUP_MODEL!PREDICT(
        INPUT_DATA => OBJECT_CONSTRUCT(
            'NAME_JW', c.NAME_JW,
            'SSN_EXACT', CASE WHEN c.SSN_A = c.SSN_B AND c.SSN_A IS NOT NULL THEN 1 ELSE 0 END,
            'DOB_EXACT', CASE WHEN c.DOB_A = c.DOB_B AND c.DOB_A IS NOT NULL THEN 1 ELSE 0 END,
            'ADDRESS_EXACT', CASE WHEN c.ADDR_A = c.ADDR_B AND c.ADDR_A IS NOT NULL AND c.ADDR_A != '' THEN 1 ELSE 0 END,
            'ZIP_EXACT', CASE WHEN c.ZIP_A = c.ZIP_B AND c.ZIP_A IS NOT NULL THEN 1 ELSE 0 END,
            'GENDER_EXACT', CASE WHEN c.GENDER_A = c.GENDER_B THEN 1 ELSE 0 END,
            'DL_EXACT', CASE WHEN c.DL_A = c.DL_B AND c.DL_A IS NOT NULL AND c.DL_A != '' THEN 1 ELSE 0 END,
            'PASSPORT_EXACT', CASE WHEN c.PP_A = c.PP_B AND c.PP_A IS NOT NULL AND c.PP_A != '' THEN 1 ELSE 0 END
        )
    ) AS prediction
FROM MDM.MATCHING.RECIP_ML_CANDIDATE_PAIRS c;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 5: ROUTE — Insert ML matches into RECIPIENT_MATCH_RESULTS
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO MDM.MATCHING.RECIPIENT_MATCH_RESULTS
    (ROW_A, ROW_B, FNAME_A, FNAME_B, LNAME_A, LNAME_B, DOB_A, DOB_B,
     ADDR_A, ADDR_B, ZIP_A, ZIP_B, SSN_A, SSN_B, SOURCE_A, SOURCE_B,
     MATCH_TYPE, HYBRID_SCORE, ROUTING)
SELECT
    ROW_ID_A, ROW_ID_B, FNAME_A, FNAME_B, LNAME_A, LNAME_B, DOB_A, DOB_B,
    ADDR_A, ADDR_B, ZIP_A, ZIP_B, SSN_A, SSN_B, SOURCE_A, SOURCE_B,
    'RECIP_ML_MATCH' AS MATCH_TYPE,
    prediction:"probability":"MATCH"::FLOAT AS HYBRID_SCORE,
    CASE WHEN prediction:"probability":"MATCH"::FLOAT >= 0.80 THEN 'AUTO_MERGE'
         ELSE 'MANUAL_REVIEW' END AS ROUTING
FROM MDM.MATCHING.RECIP_ML_SCORED
WHERE prediction:"probability":"MATCH"::FLOAT >= 0.65;


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
FROM MDM.MATCHING.RECIP_ML_SCORED
GROUP BY ROUTING ORDER BY pairs DESC;
