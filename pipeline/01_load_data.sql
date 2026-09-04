/*
================================================================================
01_LOAD_DATA.sql — Load Raw Source Data into MDM.RAW Schema
================================================================================

Run this AFTER 00_setup.sql to populate the raw source tables.

DATA SOURCES:
  1. HEALTH_FACILITY_LOCATIONS (15,436 rows)
     - Licensed healthcare facilities (hospitals, SNFs, clinics, hospices)
     - Source: Health & Human Services Open Data Portal

  2. MEDICAL_FFS_PROVIDERS (359,351 rows)
     - Fee-for-Service enrolled providers
     - Source: Department of Health Care Services Open Data

  3. patients.csv (1,163 rows)
     - Synthetic patient data for recipient matching demo
     - Included in data/ folder

  4. Reference tables (provider type codes, specialty codes)
     - Included in data/ folder

HOW TO LOAD:
  Option A (if you have the open data CSVs downloaded):
    1. PUT file://path/to/health_facility_locations.csv @MDM.RAW.DATA_STAGE;
    2. PUT file://path/to/medi_cal_ffs_providers.csv @MDM.RAW.DATA_STAGE;
    3. Run the COPY INTO statements below.

  Option B (if tables already exist in another schema):
    Run the CREATE TABLE AS SELECT statements at the bottom.
================================================================================
*/

USE WAREHOUSE COMPUTE_WH;
USE DATABASE MDM;

-- ══════════════════════════════════════════════════════════════════════════════
-- REFERENCE TABLES (from data/ folder CSVs)
-- ══════════════════════════════════════════════════════════════════════════════

-- Upload reference CSVs first:
-- PUT file://data/FFS_Provider_Type_Reference_Table.csv @MDM.RAW.DATA_STAGE AUTO_COMPRESS=FALSE;
-- PUT file://data/FFS_Provider_Specialty_Reference_Table.csv @MDM.RAW.DATA_STAGE AUTO_COMPRESS=FALSE;

CREATE TABLE IF NOT EXISTS MDM.RAW.FFS_PROVIDER_TYPE_REF (
    PROVIDER_TYPE_CD VARCHAR(10),
    PROVIDER_TYPE_DESC VARCHAR(100)
);

COPY INTO MDM.RAW.FFS_PROVIDER_TYPE_REF
FROM @MDM.RAW.DATA_STAGE/FFS_Provider_Type_Reference_Table.csv
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=1)
ON_ERROR = 'CONTINUE';

CREATE TABLE IF NOT EXISTS MDM.RAW.FFS_PROVIDER_SPECIALTY_REF (
    PROVIDER_SPECIALTY_CD VARCHAR(10),
    PROVIDER_SPECIALTY_DESC VARCHAR(200)
);

COPY INTO MDM.RAW.FFS_PROVIDER_SPECIALTY_REF
FROM @MDM.RAW.DATA_STAGE/FFS_Provider_Specialty_Reference_Table.csv
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=1)
ON_ERROR = 'CONTINUE';


-- ══════════════════════════════════════════════════════════════════════════════
-- PATIENTS DATA (from data/patients.csv)
-- ══════════════════════════════════════════════════════════════════════════════

-- PUT file://data/patients.csv @MDM.RAW.DATA_STAGE AUTO_COMPRESS=FALSE;

CREATE TABLE IF NOT EXISTS MDM.RAW.RAW_PATIENTS (
    Id VARCHAR,
    BIRTHDATE DATE,
    DEATHDATE DATE,
    SSN VARCHAR(11),
    DRIVERS VARCHAR(20),
    PASSPORT VARCHAR(20),
    PREFIX VARCHAR(10),
    FIRST VARCHAR(50),
    LAST VARCHAR(50),
    SUFFIX VARCHAR(10),
    MAIDEN VARCHAR(50),
    MARITAL VARCHAR(5),
    RACE VARCHAR(20),
    ETHNICITY VARCHAR(20),
    GENDER VARCHAR(5),
    BIRTHPLACE VARCHAR(100),
    ADDRESS VARCHAR(200),
    CITY VARCHAR(50),
    STATE VARCHAR(5),
    COUNTY VARCHAR(50),
    FIPS VARCHAR(10),
    ZIP VARCHAR(10),
    LAT FLOAT,
    LON FLOAT,
    HEALTHCARE_EXPENSES FLOAT,
    HEALTHCARE_COVERAGE FLOAT,
    INCOME NUMBER
);

COPY INTO MDM.RAW.RAW_PATIENTS
FROM @MDM.RAW.DATA_STAGE/patients.csv
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=1)
ON_ERROR = 'CONTINUE';


-- ══════════════════════════════════════════════════════════════════════════════
-- PROVIDER SOURCE TABLES (from data/ folder CSVs)
-- ══════════════════════════════════════════════════════════════════════════════

-- Upload provider CSVs first:
-- PUT file://data/health_facility_locations.csv @MDM.RAW.DATA_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
-- PUT file://data/medical_ffs_providers.csv @MDM.RAW.DATA_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Use INFER_SCHEMA to auto-detect columns from the CSVs
CREATE TABLE IF NOT EXISTS MDM.RAW.HEALTH_FACILITY_LOCATIONS
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(INFER_SCHEMA(
      LOCATION => '@MDM.RAW.DATA_STAGE/health_facility_locations.csv',
      FILE_FORMAT => 'MDM.RAW.CSV_FORMAT'
    ))
  );

COPY INTO MDM.RAW.HEALTH_FACILITY_LOCATIONS
FROM @MDM.RAW.DATA_STAGE/health_facility_locations.csv
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=1)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'CONTINUE';

CREATE TABLE IF NOT EXISTS MDM.RAW.MEDICAL_FFS_PROVIDERS
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(INFER_SCHEMA(
      LOCATION => '@MDM.RAW.DATA_STAGE/medical_ffs_providers.csv',
      FILE_FORMAT => 'MDM.RAW.CSV_FORMAT'
    ))
  );

COPY INTO MDM.RAW.MEDICAL_FFS_PROVIDERS
FROM @MDM.RAW.DATA_STAGE/medical_ffs_providers.csv
FILE_FORMAT = (TYPE=CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=1)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'CONTINUE';


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT 'HEALTH_FACILITY_LOCATIONS' AS tbl, COUNT(*) AS rows FROM MDM.RAW.HEALTH_FACILITY_LOCATIONS
UNION ALL SELECT 'MEDICAL_FFS_PROVIDERS', COUNT(*) FROM MDM.RAW.MEDICAL_FFS_PROVIDERS
UNION ALL SELECT 'RAW_PATIENTS', COUNT(*) FROM MDM.RAW.RAW_PATIENTS
UNION ALL SELECT 'FFS_PROVIDER_TYPE_REF', COUNT(*) FROM MDM.RAW.FFS_PROVIDER_TYPE_REF
UNION ALL SELECT 'FFS_PROVIDER_SPECIALTY_REF', COUNT(*) FROM MDM.RAW.FFS_PROVIDER_SPECIALTY_REF;
