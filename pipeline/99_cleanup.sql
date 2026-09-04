/*
================================================================================
99_CLEANUP.sql — Teardown all MDM pipeline objects
================================================================================

Run this to drop all objects created by the pipeline.
WARNING: This is IRREVERSIBLE. All data will be lost.

Also includes SAR Application Service teardown commands (commented).
================================================================================
*/

-- ============================================================
-- 1. Drop MASTER tables (golden records, readiness)
-- ============================================================
DROP TABLE IF EXISTS MDM.MASTER.PROVIDER_GOLDEN_RECORDS;
DROP TABLE IF EXISTS MDM.MASTER.RECIPIENT_GOLDEN_RECORDS;
DROP TABLE IF EXISTS MDM.MASTER.DATA_READINESS_STATS;

-- ============================================================
-- 2. Drop MATCHING tables (all tiers)
-- ============================================================
DROP TABLE IF EXISTS MDM.MATCHING.PROVIDER_MATCH_RESULTS;
DROP TABLE IF EXISTS MDM.MATCHING.RECIPIENT_MATCH_RESULTS;

-- Deterministic intermediates
DROP TABLE IF EXISTS MDM.MATCHING.PROV_EDGES_BIDIR;
DROP TABLE IF EXISTS MDM.MATCHING.PROV_LABELS;
DROP TABLE IF EXISTS MDM.MATCHING.RECIP_EDGES_BIDIR;
DROP TABLE IF EXISTS MDM.MATCHING.RECIP_LABELS;

-- ML tables
DROP TABLE IF EXISTS MDM.MATCHING.PROVIDER_ML_CANDIDATE_PAIRS;
DROP TABLE IF EXISTS MDM.MATCHING.PROVIDER_ML_TRAINING_DATA;
DROP TABLE IF EXISTS MDM.MATCHING.PROVIDER_ML_SCORES;
DROP TABLE IF EXISTS MDM.MATCHING.RECIPIENT_ML_CANDIDATE_PAIRS;
DROP TABLE IF EXISTS MDM.MATCHING.RECIPIENT_ML_TRAINING_DATA;
DROP TABLE IF EXISTS MDM.MATCHING.RECIPIENT_ML_SCORES;

-- LLM tables
DROP TABLE IF EXISTS MDM.MATCHING.PROVIDER_LLM_REVIEW_QUEUE;
DROP TABLE IF EXISTS MDM.MATCHING.PROVIDER_LLM_RAW_DECISIONS;
DROP TABLE IF EXISTS MDM.MATCHING.PROVIDER_LLM_DECISIONS;
DROP TABLE IF EXISTS MDM.MATCHING.PROVIDER_LLM_AUDIT_LOG;
DROP TABLE IF EXISTS MDM.MATCHING.RECIPIENT_LLM_REVIEW_QUEUE;
DROP TABLE IF EXISTS MDM.MATCHING.RECIPIENT_LLM_RAW_DECISIONS;
DROP TABLE IF EXISTS MDM.MATCHING.RECIPIENT_LLM_DECISIONS;
DROP TABLE IF EXISTS MDM.MATCHING.RECIPIENT_LLM_AUDIT_LOG;

-- ML models
DROP SNOWFLAKE.ML.CLASSIFICATION IF EXISTS MDM.MATCHING.PROVIDER_DEDUP_MODEL;
DROP SNOWFLAKE.ML.CLASSIFICATION IF EXISTS MDM.MATCHING.RECIPIENT_DEDUP_MODEL;

-- ============================================================
-- 3. Drop TRANSFORMED tables
-- ============================================================
DROP TABLE IF EXISTS MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN;
DROP TABLE IF EXISTS MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN;

-- ============================================================
-- 4. Drop RAW tables
-- ============================================================
DROP TABLE IF EXISTS MDM.RAW.MEDICAL_FFS_PROVIDERS;
DROP TABLE IF EXISTS MDM.RAW.HEALTH_FACILITY_LOCATIONS;
DROP TABLE IF EXISTS MDM.RAW.RAW_PATIENTS;
DROP TABLE IF EXISTS MDM.RAW.FFS_PROVIDER_TYPE_REF;
DROP TABLE IF EXISTS MDM.RAW.FFS_PROVIDER_SPECIALTY_REF;

-- ============================================================
-- 5. Drop stages and file formats
-- ============================================================
DROP STAGE IF EXISTS MDM.RAW.DATA_STAGE;
DROP FILE FORMAT IF EXISTS MDM.RAW.CSV_FORMAT;

-- ============================================================
-- 6. Drop warehouses
-- ============================================================
DROP WAREHOUSE IF EXISTS ADOPTIVE_WH;
-- Note: COMPUTE_WH is shared — only drop if not used elsewhere
-- DROP WAREHOUSE IF EXISTS COMPUTE_WH;

-- ============================================================
-- 7. Drop schemas
-- ============================================================
DROP SCHEMA IF EXISTS MDM.MASTER;
DROP SCHEMA IF EXISTS MDM.MATCHING;
DROP SCHEMA IF EXISTS MDM.TRANSFORMED;
DROP SCHEMA IF EXISTS MDM.RAW;

-- ============================================================
-- 8. Drop database (uncomment if you want full teardown)
-- ============================================================
-- DROP DATABASE IF EXISTS MDM;

-- ============================================================
-- 9. SAR Application Service Teardown
-- ============================================================
-- Run from CLI:
--   cd app-mdm && snow app teardown --force
--   cd app-readiness && snow app teardown --force
--
-- Or via SQL:
--   DROP APPLICATION SERVICE IF EXISTS MDM.PUBLIC.MDM_CA_AUG24_MDM;
--   DROP APPLICATION SERVICE IF EXISTS MDM.PUBLIC.MDM_CA_AUG24_READINESS;
