/*
================================================================================
R04_RECIPIENT_LLM_MATCHING.sql
================================================================================
STEP 4 OF 5 IN THE RECIPIENT ENTITY RESOLUTION PIPELINE

PURPOSE:
  Handles recipient pairs that ML could not resolve — typically because multiple
  fields are simultaneously null/corrupted, leaving no numeric features for the
  model to use. The LLM reads the actual record text and reasons about identity.

RUN ON: ADOPTIVE_WH
INPUT:  MDM.MATCHING.RECIP_ML_CANDIDATE_PAIRS (pairs ML scored)
OUTPUT: Inserts AUTO_MERGE pairs into RECIPIENT_MATCH_RESULTS

PREREQUISITE: R03_recipient_ml_matching.sql must have run.

ESCALATION CRITERIA:
  Send to LLM when the pair has at least one corroborating signal:
    - JW name >= 70% (names are fairly similar)
    - OR same driver's license number
    - OR same address
  These are pairs where SOMETHING suggests a match but ML couldn't confirm it.

EXAMPLE (real case from testing):
  Patient A: "GLE HETTINGER", DOB 2003-06-04, DL S99979223, addr 345 KERLUKE BURG
  Patient B: "GLENDORA HETTINGER", DOB 2003-06-04, DL S99979223, addr 345 KERLUKE BURG
  ML scored this at 0.0 (SSN was null, only feature that worked was name_jw=0.84)
  LLM correctly identified: same DL + same DOB + same address → MATCH, HIGH confidence

COST: Minimal — typically only 1-5 pairs reach this tier for patient data.

NEXT STEP: R05_RECIPIENT_GOLDEN_RECORDS.sql
================================================================================
*/

USE WAREHOUSE ADOPTIVE_WH;
USE DATABASE MDM;
USE SCHEMA MATCHING;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1: Identify pairs with corroborating signals for LLM
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_LLM_DECISIONS AS
SELECT
    c.*,
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama4-maverick',
        CONCAT(
            'You are a healthcare data steward. Determine if these two patient records ',
            'represent the SAME person or DIFFERENT people.\n\n',
            'PATIENT A:\n  Name: ', NVL(c.FNAME_A,'?'), ' ', NVL(c.LNAME_A,'?'),
            '\n  DOB: ', NVL(c.DOB_A::VARCHAR,'(missing)'),
            '\n  Address: ', NVL(c.ADDR_A,'(missing)'),
            '\n  ZIP: ', NVL(c.ZIP_A,'(missing)'),
            '\n  SSN: ', NVL(c.SSN_A,'(missing)'),
            '\n  DL: ', NVL(c.DL_A,'(missing)'),
            '\n  Passport: ', NVL(c.PP_A,'(missing)'),
            '\n\nPATIENT B:\n  Name: ', NVL(c.FNAME_B,'?'), ' ', NVL(c.LNAME_B,'?'),
            '\n  DOB: ', NVL(c.DOB_B::VARCHAR,'(missing)'),
            '\n  Address: ', NVL(c.ADDR_B,'(missing)'),
            '\n  ZIP: ', NVL(c.ZIP_B,'(missing)'),
            '\n  SSN: ', NVL(c.SSN_B,'(missing)'),
            '\n  DL: ', NVL(c.DL_B,'(missing)'),
            '\n  Passport: ', NVL(c.PP_B,'(missing)'),
            '\n\nName similarity: ', ROUND(c.NAME_JW*100,1)::VARCHAR, '%',
            '\n\nRespond with ONLY JSON: {"decision":"MATCH" or "NO_MATCH",',
            '"confidence":"HIGH" or "MEDIUM" or "LOW",',
            '"reasoning":"1-2 sentences"}'
        )
    ) AS LLM_RAW
FROM MDM.MATCHING.RECIP_ML_CANDIDATE_PAIRS c
WHERE c.NAME_JW >= 0.70
   OR (c.DL_A = c.DL_B AND c.DL_A IS NOT NULL AND c.DL_A != '')
   OR (c.ADDR_A = c.ADDR_B AND c.ADDR_A IS NOT NULL AND c.ADDR_A != '');


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2: Insert LLM matches into RECIPIENT_MATCH_RESULTS
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO MDM.MATCHING.RECIPIENT_MATCH_RESULTS
    (ROW_A, ROW_B, FNAME_A, FNAME_B, LNAME_A, LNAME_B, DOB_A, DOB_B,
     ADDR_A, ADDR_B, ZIP_A, ZIP_B, SSN_A, SSN_B, SOURCE_A, SOURCE_B,
     MATCH_TYPE, HYBRID_SCORE, ROUTING)
SELECT
    d.ROW_ID_A, d.ROW_ID_B, d.FNAME_A, d.FNAME_B, d.LNAME_A, d.LNAME_B,
    d.DOB_A, d.DOB_B, d.ADDR_A, d.ADDR_B, d.ZIP_A, d.ZIP_B, d.SSN_A, d.SSN_B,
    d.SOURCE_A, d.SOURCE_B,
    'RECIP_LLM_TIER3' AS MATCH_TYPE,
    0.92 AS HYBRID_SCORE,
    'AUTO_MERGE' AS ROUTING
FROM MDM.MATCHING.RECIP_LLM_DECISIONS d
WHERE TRY_PARSE_JSON(d.LLM_RAW):"decision"::VARCHAR = 'MATCH'
  AND TRY_PARSE_JSON(d.LLM_RAW):"confidence"::VARCHAR IN ('HIGH','MEDIUM');


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT
    TRY_PARSE_JSON(LLM_RAW):"decision"::VARCHAR AS decision,
    TRY_PARSE_JSON(LLM_RAW):"confidence"::VARCHAR AS confidence,
    TRY_PARSE_JSON(LLM_RAW):"reasoning"::VARCHAR AS reasoning,
    FNAME_A || ' ' || LNAME_A AS name_a,
    FNAME_B || ' ' || LNAME_B AS name_b
FROM MDM.MATCHING.RECIP_LLM_DECISIONS;

SELECT MATCH_TYPE, ROUTING, COUNT(*) AS pairs
FROM MDM.MATCHING.RECIPIENT_MATCH_RESULTS
GROUP BY MATCH_TYPE, ROUTING ORDER BY pairs DESC;
