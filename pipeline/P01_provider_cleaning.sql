/*
================================================================================
P01_PROVIDER_CLEANING.sql
================================================================================
STEP 1 OF 5 IN THE PROVIDER ENTITY RESOLUTION PIPELINE

PURPOSE:
  Combines two raw California healthcare provider datasets into a single unified
  table (ALL_PROVIDERS_CLEAN) with standardized columns ready for matching.
  Assigns a stable ROW_ID to each record for use in all downstream steps.

RUN ON: COMPUTE_WH
INPUT:
  - MDM.RAW.HEALTH_FACILITY_LOCATIONS  (15,436 rows — licensed CA facilities)
  - MDM.RAW.MEDICAL_FFS_PROVIDERS      (359,351 rows — Medi-Cal FFS providers)

OUTPUT:
  - MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN        (374,787 rows × 40 columns incl. ROW_ID)

UDFs CREATED:
  - MDM.TRANSFORMED.PARSE_ADDRESS_UNIT (JavaScript) — splits address into street/unit
  - MDM.TRANSFORMED.NORMALIZE_PROVIDER_TYPE (SQL)   — cross-source type mapping
  - MDM.TRANSFORMED.CLEAN_NPI (SQL)                 — NPI validation & formatting

WHAT THIS DOES:
  1. Creates helper UDFs for address parsing, NPI validation, type normalization
  2. Selects from HEALTH_FACILITY_LOCATIONS → unified 39-column schema
  3. Selects from MEDICAL_FFS_PROVIDERS → same 39-column schema
  4. UNION ALL both into ALL_PROVIDERS_CLEAN
  5. Adds ROW_ID (ROW_NUMBER) as a permanent, stable identifier

CLEANING TRANSFORMATIONS:
  - Names: UPPER, strip punctuation, remove prefixes (DR/MR/MRS), remove
    credentials (MD/DO/PHD/RN), normalize org suffixes (INC/LLC)
  - Addresses: Parse into STREET / UNIT_TYPE / UNIT_NUM via JavaScript UDF.
    Normalize all unit types (STE/APT/FL/BLDG/RM/SPC/NUM/SUIT) to "UNIT".
    Build ADDRESS_CLEAN = STREET + " UNIT " + NUM (if unit exists).
  - NPI: Strip to digits, handle float format (1356883805.0 → 1356883805),
    validate 10 digits starting with 1 or 2.
  - Provider Type: Cross-source mapping so same facility type matches regardless
    of source naming (e.g., "HOME HEALTH AGENCIES" → "HOME HEALTH AGENCY").
  - Phone: Strip to 10 digits only.
  - ZIP: 5-digit zero-padded.

ROW_ID:
  Added AFTER all cleaning, ordered by (_SOURCE_SYSTEM, NPI, NAME_PRIMARY_CLEAN).
  This ensures deterministic, stable IDs that persist across re-runs as long as
  the source data doesn't change. All downstream matching uses ROW_ID for
  pair deduplication and golden record graph construction.

NEXT STEP: P02_PROVIDER_DETERMINISTIC_MATCHING.sql
================================================================================
*/

USE WAREHOUSE COMPUTE_WH;
USE DATABASE MDM;
USE SCHEMA TRANSFORMED;


-- ══════════════════════════════════════════════════════════════════════════════
-- UDF 1: PARSE_ADDRESS_UNIT — JavaScript address parser
-- ══════════════════════════════════════════════════════════════════════════════
-- Splits raw address into: street (main road), unit_type (UNIT/DEPT), unit_num
-- Handles bare trailing numbers as implicit UNIT assignments.

CREATE OR REPLACE FUNCTION MDM.TRANSFORMED.PARSE_ADDRESS_UNIT(addr STRING)
RETURNS VARIANT
LANGUAGE JAVASCRIPT
AS $$
if (!ADDR) return {street:'', unit_type:'', unit_num:''};
var s = ADDR.toUpperCase().replace(/[.,#]/g, ' ').replace(/\s+/g,' ').trim();

// Unit keywords to normalize → UNIT (except DEPT stays as DEPT)
var unitKW = ['SUITE','STE','APT','APARTMENT','UNIT','FL','FLOOR','BLDG',
              'BUILDING','RM','ROOM','SPC','SPACE','NUM','SUIT','LOT','TRLR','TRAILER'];
var deptKW = ['DEPT','DEPARTMENT'];

var parts = s.split(' ');
for (var i = parts.length - 1; i >= 1; i--) {
    var w = parts[i];
    if (deptKW.indexOf(w) >= 0) {
        var num = parts.slice(i+1).join(' ');
        return {street: parts.slice(0,i).join(' '), unit_type:'DEPT', unit_num: num};
    }
    if (unitKW.indexOf(w) >= 0) {
        var num = parts.slice(i+1).join(' ');
        return {street: parts.slice(0,i).join(' '), unit_type:'UNIT', unit_num: num};
    }
}

// Bare trailing number after a street type word
var streetTypes = ['ST','AVE','BLVD','DR','RD','WAY','LN','CT','PL','CIR','PKWY',
                   'HWY','FWY','ROUTE','TER','WALK','XRDS','PATH','PASS','LOOP',
                   'BURG','FLAT','KNOLL','BR','ANNEX','HARBOR','BYWAY','EXTENSION',
                   'FORGE','GLEN','RAMP','RAPID','WYND','ALLEY','PIKE'];
if (parts.length >= 3) {
    var last = parts[parts.length - 1];
    var prev = parts[parts.length - 2];
    if (/^\d+[A-Z]?$/.test(last) && streetTypes.indexOf(prev) >= 0) {
        return {street: parts.slice(0, -1).join(' '), unit_type:'UNIT', unit_num: last};
    }
}

return {street: s, unit_type:'', unit_num:''};
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- UDF 2: CLEAN_NPI — validate and format NPI
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION MDM.TRANSFORMED.CLEAN_NPI(raw_npi STRING)
RETURNS STRING
AS $$
    CASE
        WHEN raw_npi IS NULL THEN NULL
        WHEN REGEXP_REPLACE(SPLIT_PART(raw_npi, '.', 1), '[^0-9]', '') = '' THEN NULL
        WHEN LENGTH(REGEXP_REPLACE(SPLIT_PART(raw_npi, '.', 1), '[^0-9]', '')) != 10 THEN NULL
        WHEN LEFT(REGEXP_REPLACE(SPLIT_PART(raw_npi, '.', 1), '[^0-9]', ''), 1) NOT IN ('1','2') THEN NULL
        ELSE REGEXP_REPLACE(SPLIT_PART(raw_npi, '.', 1), '[^0-9]', '')
    END
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- UDF 3: NORMALIZE_PROVIDER_TYPE — cross-source type mapping
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION MDM.TRANSFORMED.NORMALIZE_PROVIDER_TYPE(raw_type STRING)
RETURNS STRING
AS $$
    CASE UPPER(TRIM(raw_type))
        WHEN 'HOME HEALTH AGENCIES' THEN 'HOME HEALTH AGENCY'
        WHEN 'HOME HEALTH AGENCY/HOSPICE' THEN 'HOME HEALTH AGENCY'
        WHEN 'CERTIFIED HOSPICE' THEN 'HOSPICE'
        WHEN 'COMMUNITY CLINIC' THEN 'PRIMARY CARE CLINIC'
        WHEN 'FREE CLINIC' THEN 'PRIMARY CARE CLINIC'
        WHEN 'RURAL HEALTH CLINIC' THEN 'PRIMARY CARE CLINIC'
        WHEN 'SURGICAL CLINIC' THEN 'AMBULATORY SURGERY CENTER'
        WHEN 'AMBULATORY SURGICAL CENTER' THEN 'AMBULATORY SURGERY CENTER'
        WHEN 'SKILLED NURSING FACILITIES' THEN 'SKILLED NURSING FACILITY'
        WHEN 'INTERMEDIATE CARE FACILITIES' THEN 'INTERMEDIATE CARE FACILITY'
        WHEN 'ACUTE CARE HOSPITALS' THEN 'GENERAL ACUTE CARE HOSPITAL'
        WHEN 'PSYCHIATRIC HEALTH FACILITIES' THEN 'PSYCHIATRIC HEALTH FACILITY'
        WHEN 'CHEMICAL DEPENDENCY RECOVERY HOSPITAL' THEN 'CHEMICAL DEPENDENCY RECOVERY'
        ELSE UPPER(TRIM(raw_type))
    END
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- STACK: Combine both sources into unified schema
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN AS

WITH facility AS (
    SELECT
        HCAI_ID AS PROVIDER_ID,
        MDM.TRANSFORMED.CLEAN_NPI(NPI::VARCHAR) AS NPI,
        MDM.TRANSFORMED.CLEAN_NPI(NPI::VARCHAR) IS NOT NULL AS NPI_VALID,
        LICENSE_NUMBER::VARCHAR AS LICENSE_NUMBER,
        NULL AS TAXONOMY_CODE,
        NULL AS TAXONOMY_VALID,
        ENTITY_TYPE_DESCRIPTION AS PROVIDER_TYPE_CD,
        NULL AS SPECIALTY_CD,
        -- Name cleaning
        UPPER(REGEXP_REPLACE(FACNAME, '[^A-Z0-9 ]', ' ')) AS NAME_PRIMARY,
        REGEXP_REPLACE(UPPER(REGEXP_REPLACE(FACNAME, '[^A-Z0-9 ]', ' ')), '\\b(INC|LLC|LP|LLP|CORP|CO|LTD)\\b', '') AS NAME_PRIMARY_CLEAN,
        NULL AS NAME_SECONDARY,
        NULL AS NAME_SECONDARY_CLEAN,
        NULL AS CONTACT_NAME,
        NULL AS CONTACT_NAME_CLEAN,
        CASE WHEN FACNAME ILIKE '%INC%' OR FACNAME ILIKE '%LLC%' OR FACNAME ILIKE '%CORP%'
             THEN 'ORGANIZATION' ELSE 'FACILITY' END AS ENTITY_TYPE,
        -- Address
        ADDRESS AS ADDRESS_RAW,
        MDM.TRANSFORMED.PARSE_ADDRESS_UNIT(ADDRESS):street::VARCHAR AS ADDRESS_STREET,
        MDM.TRANSFORMED.PARSE_ADDRESS_UNIT(ADDRESS):unit_type::VARCHAR AS ADDRESS_UNIT_TYPE,
        MDM.TRANSFORMED.PARSE_ADDRESS_UNIT(ADDRESS):unit_num::VARCHAR AS ADDRESS_UNIT_NUM,
        MD5(ADDRESS) AS ADDRESS_HASH,
        ADDRESS ILIKE '%PO BOX%' OR ADDRESS ILIKE '%P.O.%' AS IS_PO_BOX,
        UPPER(TRIM(CITY)) AS CITY,
        'CA' AS STATE,
        LPAD(LEFT(TRIM(ZIP::VARCHAR), 5), 5, '0') AS ZIP,
        COUNTY_CODE::VARCHAR AS COUNTY_ID,
        COUNTY_NAME,
        LATITUDE,
        LONGITUDE,
        REGEXP_REPLACE(CONTACT_PHONE_NUMBER, '[^0-9]', '') AS PHONE,
        LENGTH(REGEXP_REPLACE(CONTACT_PHONE_NUMBER, '[^0-9]', '')) = 10 AS PHONE_VALID,
        CONTACT_EMAIL AS EMAIL,
        LOWER(TRIM(CONTACT_EMAIL)) AS EMAIL_CLEAN,
        MDM.TRANSFORMED.NORMALIZE_PROVIDER_TYPE(ENTITY_TYPE_DESCRIPTION) AS PROVIDER_TYPE_DESC,
        NULL AS SPECIALTY,
        -- Quality score (count of non-null important fields × 10)
        (CASE WHEN NPI IS NOT NULL AND NPI != 0 THEN 10 ELSE 0 END
       + CASE WHEN LICENSE_NUMBER IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN FACNAME IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN ADDRESS IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN ZIP IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN CONTACT_PHONE_NUMBER IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN LATITUDE IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN COUNTY_NAME IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN CITY IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN ENTITY_TYPE_DESCRIPTION IS NOT NULL THEN 10 ELSE 0 END
        ) AS QUALITY_SCORE,
        'CA_HEALTH_FACILITIES' AS _SOURCE_SYSTEM,
        CURRENT_TIMESTAMP() AS _LOAD_TS
    FROM MDM.RAW.HEALTH_FACILITY_LOCATIONS
),

ffs AS (
    SELECT
        NULL AS PROVIDER_ID,
        MDM.TRANSFORMED.CLEAN_NPI(NPI::VARCHAR) AS NPI,
        MDM.TRANSFORMED.CLEAN_NPI(NPI::VARCHAR) IS NOT NULL AS NPI_VALID,
        PROVIDER_LICENSE AS LICENSE_NUMBER,
        PROVIDER_TAXONOMY AS TAXONOMY_CODE,
        CASE WHEN PROVIDER_TAXONOMY RLIKE '^[0-9]{3}[A-Z][0-9]{5}X$' THEN 'VALID_NUCC'
             WHEN PROVIDER_TAXONOMY IS NOT NULL AND PROVIDER_TAXONOMY != '' THEN 'TEXT_PLACEHOLDER'
             ELSE NULL END AS TAXONOMY_VALID,
        FI_PROVIDER_TYPE_CD AS PROVIDER_TYPE_CD,
        FI_PROVIDER_SPECIALTY_CD AS SPECIALTY_CD,
        -- Name
        UPPER(REGEXP_REPLACE(LEGAL_NAME, '[^A-Z0-9 ]', ' ')) AS NAME_PRIMARY,
        REGEXP_REPLACE(
            REGEXP_REPLACE(UPPER(REGEXP_REPLACE(LEGAL_NAME, '[^A-Z0-9 ]', ' ')),
                '\\b(MD|DO|PHD|RN|NP|PA|DDS|DMD|OD|DC|DPM)\\b', ''),
            '\\b(INC|LLC|LP|LLP|CORP|CO|LTD|INCORPORATED|LIMITED)\\b', '') AS NAME_PRIMARY_CLEAN,
        NULL AS NAME_SECONDARY,
        NULL AS NAME_SECONDARY_CLEAN,
        NULL AS CONTACT_NAME,
        NULL AS CONTACT_NAME_CLEAN,
        CASE WHEN LEGAL_NAME RLIKE '^[A-Z]+\\s+[A-Z]+' AND LEGAL_NAME NOT ILIKE '%INC%' AND LEGAL_NAME NOT ILIKE '%LLC%'
             THEN 'INDIVIDUAL'
             ELSE 'ORGANIZATION' END AS ENTITY_TYPE,
        -- Address
        ADDRESS AS ADDRESS_RAW,
        MDM.TRANSFORMED.PARSE_ADDRESS_UNIT(ADDRESS):street::VARCHAR AS ADDRESS_STREET,
        MDM.TRANSFORMED.PARSE_ADDRESS_UNIT(ADDRESS):unit_type::VARCHAR AS ADDRESS_UNIT_TYPE,
        MDM.TRANSFORMED.PARSE_ADDRESS_UNIT(ADDRESS):unit_num::VARCHAR AS ADDRESS_UNIT_NUM,
        MD5(ADDRESS) AS ADDRESS_HASH,
        ADDRESS ILIKE '%PO BOX%' OR ADDRESS ILIKE '%P.O.%' AS IS_PO_BOX,
        UPPER(TRIM(CITY)) AS CITY,
        'CA' AS STATE,
        LPAD(LEFT(TRIM(ZIP), 5), 5, '0') AS ZIP,
        FIPS_COUNTY_CD::VARCHAR AS COUNTY_ID,
        COUNTY AS COUNTY_NAME,
        LATITUDE,
        LONGITUDE,
        REGEXP_REPLACE(PHONE_NUMBER::VARCHAR, '[^0-9]', '') AS PHONE,
        LENGTH(REGEXP_REPLACE(PHONE_NUMBER::VARCHAR, '[^0-9]', '')) = 10 AS PHONE_VALID,
        NULL AS EMAIL,
        NULL AS EMAIL_CLEAN,
        MDM.TRANSFORMED.NORMALIZE_PROVIDER_TYPE(
            COALESCE(ref.PROVIDER_TYPE_DESC, f.FI_PROVIDER_TYPE_CD)
        ) AS PROVIDER_TYPE_DESC,
        sref.PROVIDER_SPECIALTY_DESC AS SPECIALTY,
        -- Quality
        (CASE WHEN NPI IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN PROVIDER_LICENSE IS NOT NULL AND PROVIDER_LICENSE != '' THEN 10 ELSE 0 END
       + CASE WHEN LEGAL_NAME IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN ADDRESS IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN ZIP IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN PHONE_NUMBER IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN PROVIDER_TAXONOMY IS NOT NULL THEN 10 ELSE 0 END
       + 0  -- no DBA/business name in this dataset
       + CASE WHEN CITY IS NOT NULL THEN 10 ELSE 0 END
       + CASE WHEN FI_PROVIDER_TYPE_CD IS NOT NULL THEN 10 ELSE 0 END
        ) AS QUALITY_SCORE,
        'CA_FFS_PROVIDERS' AS _SOURCE_SYSTEM,
        CURRENT_TIMESTAMP() AS _LOAD_TS
    FROM MDM.RAW.MEDICAL_FFS_PROVIDERS f
    LEFT JOIN MDM.RAW.FFS_PROVIDER_TYPE_REF ref
        ON f.FI_PROVIDER_TYPE_CD = ref.PROVIDER_TYPE_CD
    LEFT JOIN MDM.RAW.FFS_PROVIDER_SPECIALTY_REF sref
        ON f.FI_PROVIDER_SPECIALTY_CD = sref.PROVIDER_SPECIALTY_CD
),

-- Combine both sources
stacked AS (
    SELECT * FROM facility
    UNION ALL
    SELECT * FROM ffs
)

-- Final output with ADDRESS_CLEAN and QUALITY_BAND
SELECT
    ROW_NUMBER() OVER (ORDER BY _SOURCE_SYSTEM, NPI, NAME_PRIMARY_CLEAN) AS ROW_ID,
    PROVIDER_ID, NPI, NPI_VALID, LICENSE_NUMBER, TAXONOMY_CODE, TAXONOMY_VALID,
    PROVIDER_TYPE_CD, SPECIALTY_CD,
    NAME_PRIMARY, TRIM(REGEXP_REPLACE(NAME_PRIMARY_CLEAN, '\\s+', ' ')) AS NAME_PRIMARY_CLEAN,
    NAME_SECONDARY, TRIM(REGEXP_REPLACE(NAME_SECONDARY_CLEAN, '\\s+', ' ')) AS NAME_SECONDARY_CLEAN,
    CONTACT_NAME, CONTACT_NAME_CLEAN, ENTITY_TYPE,
    ADDRESS_RAW AS ADDRESS, ADDRESS_STREET, ADDRESS_UNIT_TYPE, ADDRESS_UNIT_NUM,
    ADDRESS_HASH, IS_PO_BOX,
    -- ADDRESS_CLEAN: street + unit (single column for matching)
    CASE
        WHEN ADDRESS_UNIT_NUM IS NOT NULL AND ADDRESS_UNIT_NUM != ''
        THEN ADDRESS_STREET || ' UNIT ' || ADDRESS_UNIT_NUM
        ELSE ADDRESS_STREET
    END AS ADDRESS_CLEAN,
    CITY, STATE, ZIP, COUNTY_ID, COUNTY_NAME, LATITUDE, LONGITUDE,
    CASE WHEN LENGTH(PHONE) = 10 THEN PHONE ELSE NULL END AS PHONE,
    PHONE_VALID, EMAIL, EMAIL_CLEAN,
    PROVIDER_TYPE_DESC, SPECIALTY,
    QUALITY_SCORE,
    CASE
        WHEN QUALITY_SCORE >= 90 THEN 'Excellent'
        WHEN QUALITY_SCORE >= 70 THEN 'Very Good'
        WHEN QUALITY_SCORE >= 50 THEN 'Good'
        ELSE 'Fair'
    END AS QUALITY_BAND,
    _SOURCE_SYSTEM, _LOAD_TS
FROM stacked;


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT _SOURCE_SYSTEM, COUNT(*) AS records, MAX(ROW_ID) AS max_row_id
FROM MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN
GROUP BY _SOURCE_SYSTEM;

SELECT COUNT(*) AS total, COUNT(DISTINCT ROW_ID) AS unique_ids
FROM MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN;
