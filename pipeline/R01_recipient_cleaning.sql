/*
================================================================================
R01_RECIPIENT_CLEANING.sql
================================================================================
STEP 1 OF 6 IN THE RECIPIENT ENTITY RESOLUTION PIPELINE

PURPOSE:
  Loads raw patient/recipient data from MDM.RAW.RAW_PATIENTS, applies cleaning
  transformations, and assigns a stable ROW_ID for downstream matching.

RUN ON: COMPUTE_WH
INPUT:  MDM.RAW.RAW_PATIENTS
OUTPUT: MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN (with ROW_ID)

RAW_PATIENTS COLUMNS:
  ID, BIRTHDATE, DEATHDATE, SSN, DRIVERS, PASSPORT, PREFIX, FIRST, LAST,
  SUFFIX, MAIDEN, MARITAL, RACE, ETHNICITY, GENDER, BIRTHPLACE, ADDRESS,
  CITY, STATE, COUNTY, ZIP, LAT, LON, HEALTHCARE_EXPENSES, HEALTHCARE_COVERAGE

CLEANING RULES:
  - Names: UPPER, TRIM, strip non-alpha except spaces/hyphens
  - DOB: Parse YYYY-MM-DD text to DATE
  - SSN: Validate 9 digits (no dashes), extract LAST4
  - Address: UPPER + TRIM, build ADDRESS_CLEAN = STREET + CITY + STATE + ZIP
  - Gender: Normalize M/F/U
  - Deceased: Y/N based on DEATHDATE presence
  - Marital: Standardize codes

NEXT STEP: R02_RECIPIENT_DETERMINISTIC_MATCHING.sql
================================================================================
*/

USE WAREHOUSE COMPUTE_WH;
USE DATABASE MDM;
USE SCHEMA TRANSFORMED;

CREATE OR REPLACE TABLE MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN AS
SELECT
    ROW_NUMBER() OVER (ORDER BY _SOURCE_SYSTEM, RECIPIENT_ID, FIRST_NAME_CLEAN, LAST_NAME_CLEAN) AS ROW_ID,
    *
FROM (
    SELECT
        -- Identifiers
        ID AS RECIPIENT_ID,
        FIRST AS FIRST_NAME,
        LAST AS LAST_NAME,

        -- Name cleaning: UPPER, strip non-alpha (keep space/hyphen), collapse whitespace
        TRIM(REGEXP_REPLACE(UPPER(FIRST), '[^A-Z \\-]', '')) AS FIRST_NAME_CLEAN,
        TRIM(REGEXP_REPLACE(UPPER(LAST), '[^A-Z \\-]', '')) AS LAST_NAME_CLEAN,

        -- DOB
        BIRTHDATE AS DATE_OF_BIRTH,
        TRY_TO_DATE(BIRTHDATE, 'YYYY-MM-DD') AS DOB_CLEAN,

        -- Gender normalization
        GENDER AS GENDER_RAW,
        CASE
            WHEN UPPER(GENDER) IN ('M', 'MALE') THEN 'M'
            WHEN UPPER(GENDER) IN ('F', 'FEMALE') THEN 'F'
            ELSE 'U'
        END AS GENDER_CLEAN,

        -- SSN cleaning: strip dashes, validate 9 digits
        REGEXP_REPLACE(SSN, '[^0-9]', '') AS SSN,
        CASE
            WHEN LENGTH(REGEXP_REPLACE(SSN, '[^0-9]', '')) = 9
            THEN RIGHT(REGEXP_REPLACE(SSN, '[^0-9]', ''), 4)
            ELSE NULL
        END AS SSN_LAST4,

        -- Address fields
        ADDRESS AS ADDRESS_STREET,
        TRIM(REGEXP_REPLACE(UPPER(ADDRESS), '[^A-Z0-9 ]', ' ')) AS ADDRESS_STREET_CLEAN,
        CITY AS ADDRESS_CITY,
        STATE AS ADDRESS_STATE,
        ZIP AS ADDRESS_ZIP,
        LAT AS ADDRESS_LAT,
        LON AS ADDRESS_LON,

        -- Build composite ADDRESS_CLEAN for matching
        TRIM(
            COALESCE(TRIM(REGEXP_REPLACE(UPPER(ADDRESS), '[^A-Z0-9 ]', ' ')), '') || ' ' ||
            COALESCE(UPPER(CITY), '') || ' ' ||
            COALESCE(UPPER(STATE), '') || ' ' ||
            COALESCE(ZIP, '')
        ) AS ADDRESS_CLEAN,

        -- Marital status
        CASE
            WHEN UPPER(MARITAL) IN ('M', 'MARRIED') THEN 'M'
            WHEN UPPER(MARITAL) IN ('S', 'SINGLE', 'NEVER MARRIED') THEN 'S'
            WHEN UPPER(MARITAL) IN ('D', 'DIVORCED') THEN 'D'
            WHEN UPPER(MARITAL) IN ('W', 'WIDOWED') THEN 'W'
            ELSE UPPER(MARITAL)
        END AS MARITAL_STATUS,

        -- Race/ethnicity
        RACE,
        ETHNICITY,

        -- Deceased
        CASE WHEN DEATHDATE IS NOT NULL AND DEATHDATE != '' THEN 'Y' ELSE 'N' END AS DECEASED_INDICATOR,
        TRY_TO_DATE(DEATHDATE, 'YYYY-MM-DD') AS DECEASED_DATE,

        -- Additional IDs
        CASE
            WHEN LENGTH(REGEXP_REPLACE(DRIVERS, '[^A-Z0-9]', '')) BETWEEN 6 AND 17
            THEN UPPER(REGEXP_REPLACE(DRIVERS, '[^A-Z0-9]', ''))
            ELSE NULL
        END AS DRIVERS_LICENSE_NUMBER,

        CASE
            WHEN REGEXP_LIKE(PASSPORT, '^[A-Z][0-9]{8}$')
            THEN UPPER(PASSPORT)
            ELSE NULL
        END AS PASSPORT_NUMBER,

        -- County
        COUNTY AS COUNTY_ID,

        -- Maiden name (useful for matching)
        TRIM(REGEXP_REPLACE(UPPER(MAIDEN), '[^A-Z \\-]', '')) AS MAIDEN_NAME_CLEAN,

        -- Source tracking
        'SYNTHEA_PATIENTS' AS _SOURCE_SYSTEM,
        CURRENT_TIMESTAMP() AS _LOAD_TS

    FROM MDM.RAW.RAW_PATIENTS
    WHERE FIRST IS NOT NULL AND LAST IS NOT NULL
);


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT COUNT(*) AS total, COUNT(DISTINCT ROW_ID) AS unique_ids, MAX(ROW_ID) AS max_id
FROM MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN;

SELECT _SOURCE_SYSTEM, COUNT(*) AS records
FROM MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN
GROUP BY _SOURCE_SYSTEM;
