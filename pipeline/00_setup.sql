/*
================================================================================
00_SETUP.sql — Database Setup for MDM Entity Resolution
================================================================================

Run this ONCE in a new Snowflake account to set up the database, schemas,
warehouses, and stages needed for the MDM pipeline.

PREREQUISITES:
  - ACCOUNTADMIN or SYSADMIN role
  - A warehouse (COMPUTE_WH will be used)

WHAT THIS CREATES:
  - Database: MDM
  - Schemas:
      RAW         — Raw loaded data (providers, recipients, reference tables)
      TRANSFORMED — Cleaned/standardized records
      MATCHING    — All matching results (deterministic, ML, LLM, combined)
      MASTER      — Golden records and readiness stats
  - Warehouses: ADOPTIVE_WH (adaptive, for ML/LLM workloads)
  - Internal stage: @MDM.RAW.DATA_STAGE (for uploading CSVs)

AFTER RUNNING THIS:
  1. Upload CSV files from data/ folder to @MDM.RAW.DATA_STAGE
  2. Run 01_LOAD_DATA.sql to load CSVs into tables
  3. Run the pipeline: P01 → P02 → P03 → P04 → P05 → P06
                        R01 → R02 → R03 → R04 → R05 → R06
================================================================================
*/

-- Create database and schemas
CREATE DATABASE IF NOT EXISTS MDM;
CREATE SCHEMA IF NOT EXISTS MDM.RAW;
CREATE SCHEMA IF NOT EXISTS MDM.TRANSFORMED;
CREATE SCHEMA IF NOT EXISTS MDM.MATCHING;
CREATE SCHEMA IF NOT EXISTS MDM.MASTER;

-- Create warehouses (COMPUTE_WH assumed to exist)
CREATE WAREHOUSE IF NOT EXISTS ADOPTIVE_WH
  WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- Create internal stage for CSV uploads
CREATE STAGE IF NOT EXISTS MDM.RAW.DATA_STAGE
  FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' SKIP_HEADER = 1);

-- Create file formats
CREATE FILE FORMAT IF NOT EXISTS MDM.RAW.CSV_FORMAT
  TYPE = CSV
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  SKIP_HEADER = 1
  NULL_IF = ('', 'NULL', 'null', 'None');

-- Grant usage (adjust role as needed)
GRANT USAGE ON DATABASE MDM TO ROLE SYSADMIN;
GRANT USAGE ON ALL SCHEMAS IN DATABASE MDM TO ROLE SYSADMIN;
GRANT ALL ON ALL SCHEMAS IN DATABASE MDM TO ROLE SYSADMIN;

-- Steward decisions audit table (persists across pipeline reruns)
CREATE TABLE IF NOT EXISTS MDM.MATCHING.STEWARD_DECISIONS (
    ROW_A NUMBER,
    ROW_B NUMBER,
    ENTITY_TYPE VARCHAR(20),
    MATCH_TYPE VARCHAR(40),
    HYBRID_SCORE FLOAT,
    DECISION VARCHAR(10),
    DECIDED_BY VARCHAR(100),
    DECIDED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    NOTES VARCHAR(500)
);

-- Match rules configuration (display names, tiers, descriptions)
CREATE TABLE IF NOT EXISTS MDM.MATCHING.MATCH_RULES_CONFIG (
    ENTITY_TYPE VARCHAR(20),
    MATCH_TYPE VARCHAR(40),
    TIER VARCHAR(20),
    DISPLAY_NAME VARCHAR(100),
    CONFIDENCE FLOAT,
    DESCRIPTION VARCHAR(500),
    SORT_ORDER INT
);

-- Threshold configuration
CREATE TABLE IF NOT EXISTS MDM.MATCHING.THRESHOLDS_CONFIG (
    ENTITY_TYPE VARCHAR(20),
    TIER VARCHAR(20),
    AUTO_MERGE_MIN FLOAT,
    MANUAL_REVIEW_MIN FLOAT,
    DESCRIPTION VARCHAR(200)
);
