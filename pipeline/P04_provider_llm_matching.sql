/*
================================================================================
P04_PROVIDER_LLM_MATCHING.sql
================================================================================
STEP 4 OF 5 IN THE PROVIDER ENTITY RESOLUTION PIPELINE

PURPOSE:
  Handles the genuinely ambiguous pairs that ML (Tier 2) could not resolve with
  high confidence (merge probability between 0.20 and 0.80). These pairs have
  mixed signals that the gradient boosting model cannot confidently interpret.

  For each pair, sends both records to SNOWFLAKE.CORTEX.COMPLETE (LLM) with a
  structured prompt asking for MATCH/NO_MATCH + confidence + reasoning.

RUN ON: ADOPTIVE_WH
INPUT:  MDM.MATCHING.PROVIDER_ML_SCORES (pairs with 0.20 < prob < 0.80)
OUTPUT: Inserts AUTO_MERGE pairs into PROVIDER_MATCH_RESULTS
        Creates LLM_AUDIT_LOG with reasoning for all decisions

PREREQUISITE: P03_provider_ml_matching.sql must have run.

WHEN THIS STEP IS NEEDED:
  Only runs if Tier 2 produces MANUAL_REVIEW pairs. If all ML predictions are
  >= 0.80 or <= 0.20, this step finds 0 pairs and does nothing — which is fine.

WHY LLM IS NEEDED:
  Example pair the ML model scored at 0.45 (uncertain):
    Provider A: "VALLEY FAMILY MEDICINE" at 200 Medical Plaza, ZIP 91702
    Provider B: "VALLEY FAMILY MEDICAL GROUP" at 200 Medical Plaza, ZIP 91702
  ML sees: name_jw=0.78, address_exact=1, zip_exact=1, type_exact=0 → uncertain.
  LLM reasons: "Both are family medicine at the same address. One is individual,
  the other is group practice billing. Same entity." → MATCH, HIGH confidence.

ROUTING AFTER LLM:
  HIGH/MEDIUM confidence MATCH  → AUTO_MERGE (insert into results)
  HIGH/MEDIUM confidence NO_MATCH → AUTO_REJECT (not stored)
  LOW confidence (any)          → MANUAL_REVIEW (human decides)

COST: ~$0.30-0.50 in LLM tokens (418 pairs × ~400 tokens each)

NEXT STEP: P05_PROVIDER_GOLDEN_RECORDS.sql
================================================================================
*/

USE WAREHOUSE ADOPTIVE_WH;
USE DATABASE MDM;
USE SCHEMA MATCHING;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1: Identify MANUAL_REVIEW pairs from ML
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.PROVIDER_LLM_REVIEW_QUEUE AS
SELECT
    ROW_ID_A, ROW_ID_B,
    NPI_A, NPI_B,
    NAME_A, NAME_B, ADDR_A, ADDR_B,
    ZIP_A, ZIP_B, TYPE_A, TYPE_B,
    PHONE_A, PHONE_B,
    SOURCE_A, SOURCE_B,
    NAME_PRIMARY_JW,
    prediction:"probability":"MATCH"::FLOAT AS ML_MERGE_PROB,
    ROW_NUMBER() OVER (ORDER BY prediction:"probability":"MATCH"::FLOAT DESC) AS PAIR_NUM
FROM MDM.MATCHING.PROVIDER_ML_SCORES
WHERE prediction:"probability":"MATCH"::FLOAT > 0.20
  AND prediction:"probability":"MATCH"::FLOAT < 0.80;

SELECT COUNT(*) AS pairs_for_llm FROM MDM.MATCHING.PROVIDER_LLM_REVIEW_QUEUE;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2: Run LLM on each pair
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.PROVIDER_LLM_RAW_DECISIONS AS
SELECT
    q.*,
    SNOWFLAKE.CORTEX.COMPLETE(
        'llama4-maverick',
        CONCAT(
            'You are a healthcare data steward performing entity resolution on California provider records. ',
            'Determine if these two records represent the SAME real-world healthcare provider or two DIFFERENT providers.\n\n',
            'PROVIDER A:\n',
            '  Name: ', NVL(q.NAME_A, '(missing)'), '\n',
            '  Address: ', NVL(q.ADDR_A, '(missing)'), '\n',
            '  ZIP: ', NVL(q.ZIP_A, '(missing)'), '\n',
            '  Provider Type: ', NVL(q.TYPE_A, '(missing)'), '\n',
            '  Phone: ', NVL(q.PHONE_A, '(missing)'), '\n',
            '  NPI: ', NVL(q.NPI_A, '(missing)'), '\n',
            '  Source: ', NVL(q.SOURCE_A, '(missing)'), '\n\n',
            'PROVIDER B:\n',
            '  Name: ', NVL(q.NAME_B, '(missing)'), '\n',
            '  Address: ', NVL(q.ADDR_B, '(missing)'), '\n',
            '  ZIP: ', NVL(q.ZIP_B, '(missing)'), '\n',
            '  Provider Type: ', NVL(q.TYPE_B, '(missing)'), '\n',
            '  Phone: ', NVL(q.PHONE_B, '(missing)'), '\n',
            '  NPI: ', NVL(q.NPI_B, '(missing)'), '\n',
            '  Source: ', NVL(q.SOURCE_B, '(missing)'), '\n\n',
            'Name similarity (Jaro-Winkler): ', ROUND(q.NAME_PRIMARY_JW * 100, 1)::VARCHAR, '%\n',
            'ML model merge probability: ', ROUND(q.ML_MERGE_PROB * 100, 1)::VARCHAR, '%\n\n',
            'Respond with ONLY a JSON object (no other text):\n',
            '{"decision": "MATCH" or "NO_MATCH", "confidence": "HIGH" or "MEDIUM" or "LOW", "reasoning": "1-3 sentences explaining why"}'
        )
    ) AS LLM_RAW_RESPONSE
FROM MDM.MATCHING.PROVIDER_LLM_REVIEW_QUEUE q;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 3: Parse LLM responses and route
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.PROVIDER_LLM_DECISIONS AS
SELECT
    d.*,
    TRY_PARSE_JSON(d.LLM_RAW_RESPONSE):"decision"::VARCHAR AS LLM_DECISION,
    TRY_PARSE_JSON(d.LLM_RAW_RESPONSE):"confidence"::VARCHAR AS LLM_CONFIDENCE,
    TRY_PARSE_JSON(d.LLM_RAW_RESPONSE):"reasoning"::VARCHAR AS LLM_REASONING,
    CASE
        WHEN TRY_PARSE_JSON(d.LLM_RAW_RESPONSE):"decision"::VARCHAR = 'MATCH'
         AND TRY_PARSE_JSON(d.LLM_RAW_RESPONSE):"confidence"::VARCHAR IN ('HIGH', 'MEDIUM')
            THEN 'AUTO_MERGE'
        WHEN TRY_PARSE_JSON(d.LLM_RAW_RESPONSE):"decision"::VARCHAR = 'NO_MATCH'
         AND TRY_PARSE_JSON(d.LLM_RAW_RESPONSE):"confidence"::VARCHAR IN ('HIGH', 'MEDIUM')
            THEN 'AUTO_REJECT'
        ELSE 'MANUAL_REVIEW'
    END AS ROUTING
FROM MDM.MATCHING.PROVIDER_LLM_RAW_DECISIONS d;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 4: Insert LLM matches into PROVIDER_MATCH_RESULTS
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO MDM.MATCHING.PROVIDER_MATCH_RESULTS (
    ROW_A, ROW_B, NPI_A, NPI_B, NAME_A, NAME_B, ADDR_A, ADDR_B,
    ZIP_A, ZIP_B, TYPE_A, TYPE_B, PHONE_A, PHONE_B, SOURCE_A, SOURCE_B,
    MATCH_TYPE, HYBRID_SCORE, ROUTING
)
SELECT
    ROW_ID_A, ROW_ID_B, NPI_A, NPI_B, NAME_A, NAME_B, ADDR_A, ADDR_B,
    ZIP_A, ZIP_B, TYPE_A, TYPE_B, PHONE_A, PHONE_B, SOURCE_A, SOURCE_B,
    'PROV_LLM_CORTEX' AS MATCH_TYPE,
    ML_MERGE_PROB AS HYBRID_SCORE,
    ROUTING
FROM MDM.MATCHING.PROVIDER_LLM_DECISIONS
WHERE ROUTING = 'AUTO_MERGE';


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 5: Audit log
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.PROVIDER_LLM_AUDIT_LOG AS
SELECT
    UUID_STRING() AS AUDIT_ID,
    ROW_ID_A, ROW_ID_B,
    NAME_A, NAME_B, ADDR_A, ADDR_B, TYPE_A, TYPE_B,
    NAME_PRIMARY_JW, ML_MERGE_PROB,
    LLM_DECISION, LLM_CONFIDENCE, LLM_REASONING,
    ROUTING AS FINAL_ROUTING,
    LLM_RAW_RESPONSE,
    CURRENT_TIMESTAMP() AS DECIDED_AT
FROM MDM.MATCHING.PROVIDER_LLM_DECISIONS;


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ROUTING, LLM_DECISION, LLM_CONFIDENCE, COUNT(*) AS cnt
FROM MDM.MATCHING.PROVIDER_LLM_DECISIONS
GROUP BY ROUTING, LLM_DECISION, LLM_CONFIDENCE
ORDER BY cnt DESC;

SELECT MATCH_TYPE, ROUTING, COUNT(*) AS pairs
FROM MDM.MATCHING.PROVIDER_MATCH_RESULTS
GROUP BY MATCH_TYPE, ROUTING ORDER BY pairs DESC;
