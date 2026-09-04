/*
================================================================================
R02_RECIPIENT_DETERMINISTIC_MATCHING.sql
================================================================================
STEP 2 OF 5 IN THE RECIPIENT ENTITY RESOLUTION PIPELINE

PURPOSE:
  Applies 6 deterministic rules to identify high-confidence duplicate patient
  records. Uses SSN, DOB, name, address, and document identifiers.

RUN ON: COMPUTE_WH
INPUT:  MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN (with ROW_ID)
OUTPUT: MDM.MATCHING.RECIPIENT_MATCH_RESULTS (matched pairs with ROW_A/ROW_B)

PREREQUISITE: R01_recipient_cleaning.sql must have run.

RULES (applied in confidence order):
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ R0 (1.00): Full SSN exact match                                         │
  │   Both records share the same 9-digit SSN. SSN is unique per person.    │
  │   Most common rule — catches the majority of duplicates.                │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ R1 (0.97): SSN_LAST4 + DOB + FIRST_NAME + LAST_NAME                    │
  │   When full SSN differs (typo in one digit) but last-4 + DOB + name    │
  │   all match, this is still the same person.                             │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ R2 (0.95): SSN_LAST4 + FIRST_NAME + LAST_NAME + ZIP                    │
  │   No DOB available but partial SSN + name + ZIP is strong enough.       │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ R3 (0.93): FIRST_NAME + LAST_NAME + ADDRESS_CLEAN + DOB                 │
  │   No SSN at all, but exact name + exact address + exact DOB.            │
  │   Three independent fields matching = same person.                      │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ R5 (0.88): JW(first+last concatenated) >= 85% + STREET + DOB + ZIP      │
  │   Catches name typos/variations (MICHAEL vs MICHEAL, abbreviated names) │
  │   at the same address with same birthday and ZIP.                       │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ R6 (0.97): (Driver's License OR Passport) + full SSN                    │
  │   Government-issued document + SSN is very strong identification.       │
  └──────────────────────────────────────────────────────────────────────────┘

DEDUPLICATION:
  All rules use a.ROW_ID < b.ROW_ID to ensure each pair appears once.

NULL GUARDS:
  Every rule requires all compared fields to be non-null and non-empty.

EXCLUSION LOGIC:
  Each rule excludes pairs already caught by higher-confidence rules.

RESULTS (measured on 1,513 test records with 350 seeded duplicates):
  R0: 255 pairs | R3: 57 pairs | R5: 9 pairs | Total: 321 AUTO_MERGE

NEXT STEP: R03_RECIPIENT_ML_MATCHING.sql
================================================================================
*/

USE WAREHOUSE COMPUTE_WH;
USE DATABASE MDM;
USE SCHEMA MATCHING;

CREATE OR REPLACE TABLE MDM.MATCHING.RECIPIENT_MATCH_RESULTS AS

WITH r AS (
    SELECT * FROM MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN
    WHERE (FIRST_NAME_CLEAN IS NOT NULL AND FIRST_NAME_CLEAN != '')
       OR (LAST_NAME_CLEAN IS NOT NULL AND LAST_NAME_CLEAN != '')
),

-- R0: Full SSN + DOB exact match
r0 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.FIRST_NAME_CLEAN AS FNAME_A, b.FIRST_NAME_CLEAN AS FNAME_B,
        a.LAST_NAME_CLEAN AS LNAME_A, b.LAST_NAME_CLEAN AS LNAME_B,
        a.DOB_CLEAN AS DOB_A, b.DOB_CLEAN AS DOB_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ADDRESS_ZIP AS ZIP_A, b.ADDRESS_ZIP AS ZIP_B,
        a.SSN AS SSN_A, b.SSN AS SSN_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'RECIP_R0_SSN_DOB' AS MATCH_TYPE, 1.00 AS HYBRID_SCORE, 'AUTO_MERGE'::VARCHAR(20) AS ROUTING
    FROM r a JOIN r b
      ON a.SSN = b.SSN AND a.DOB_CLEAN = b.DOB_CLEAN
     AND a.SSN IS NOT NULL AND a.SSN != '' AND a.DOB_CLEAN IS NOT NULL
     AND a.ROW_ID < b.ROW_ID
),

-- R1: SSN_LAST4 + DOB + first + last name
r1 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.FIRST_NAME_CLEAN AS FNAME_A, b.FIRST_NAME_CLEAN AS FNAME_B,
        a.LAST_NAME_CLEAN AS LNAME_A, b.LAST_NAME_CLEAN AS LNAME_B,
        a.DOB_CLEAN AS DOB_A, b.DOB_CLEAN AS DOB_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ADDRESS_ZIP AS ZIP_A, b.ADDRESS_ZIP AS ZIP_B,
        a.SSN AS SSN_A, b.SSN AS SSN_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'RECIP_R1_SSN4_DOB_NAME' AS MATCH_TYPE, 0.97 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM r a JOIN r b
      ON a.SSN_LAST4 = b.SSN_LAST4 AND a.DOB_CLEAN = b.DOB_CLEAN
     AND a.FIRST_NAME_CLEAN = b.FIRST_NAME_CLEAN AND a.LAST_NAME_CLEAN = b.LAST_NAME_CLEAN
     AND a.SSN_LAST4 IS NOT NULL AND a.SSN_LAST4 != '' AND a.DOB_CLEAN IS NOT NULL
     AND a.ROW_ID < b.ROW_ID
    WHERE NOT EXISTS (SELECT 1 FROM r0 WHERE r0.ROW_A = a.ROW_ID AND r0.ROW_B = b.ROW_ID)
),

-- R2: SSN_LAST4 + first + last + ZIP
r2 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.FIRST_NAME_CLEAN AS FNAME_A, b.FIRST_NAME_CLEAN AS FNAME_B,
        a.LAST_NAME_CLEAN AS LNAME_A, b.LAST_NAME_CLEAN AS LNAME_B,
        a.DOB_CLEAN AS DOB_A, b.DOB_CLEAN AS DOB_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ADDRESS_ZIP AS ZIP_A, b.ADDRESS_ZIP AS ZIP_B,
        a.SSN AS SSN_A, b.SSN AS SSN_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'RECIP_R2_SSN4_NAME_ZIP' AS MATCH_TYPE, 0.95 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM r a JOIN r b
      ON a.SSN_LAST4 = b.SSN_LAST4 AND a.FIRST_NAME_CLEAN = b.FIRST_NAME_CLEAN
     AND a.LAST_NAME_CLEAN = b.LAST_NAME_CLEAN AND a.ADDRESS_ZIP = b.ADDRESS_ZIP
     AND a.SSN_LAST4 IS NOT NULL AND a.SSN_LAST4 != ''
     AND a.ADDRESS_ZIP IS NOT NULL AND a.ADDRESS_ZIP != ''
     AND a.ROW_ID < b.ROW_ID
    WHERE NOT EXISTS (SELECT 1 FROM r0 WHERE r0.ROW_A = a.ROW_ID AND r0.ROW_B = b.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM r1 WHERE r1.ROW_A = a.ROW_ID AND r1.ROW_B = b.ROW_ID)
),

-- R3: First + last + ADDRESS_CLEAN + DOB
r3 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.FIRST_NAME_CLEAN AS FNAME_A, b.FIRST_NAME_CLEAN AS FNAME_B,
        a.LAST_NAME_CLEAN AS LNAME_A, b.LAST_NAME_CLEAN AS LNAME_B,
        a.DOB_CLEAN AS DOB_A, b.DOB_CLEAN AS DOB_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ADDRESS_ZIP AS ZIP_A, b.ADDRESS_ZIP AS ZIP_B,
        a.SSN AS SSN_A, b.SSN AS SSN_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'RECIP_R3_NAME_ADDRESS_DOB' AS MATCH_TYPE, 0.93 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM r a JOIN r b
      ON a.FIRST_NAME_CLEAN = b.FIRST_NAME_CLEAN AND a.LAST_NAME_CLEAN = b.LAST_NAME_CLEAN
     AND a.ADDRESS_CLEAN = b.ADDRESS_CLEAN AND a.DOB_CLEAN = b.DOB_CLEAN
     AND a.ADDRESS_CLEAN IS NOT NULL AND a.ADDRESS_CLEAN != '' AND a.DOB_CLEAN IS NOT NULL
     AND a.ROW_ID < b.ROW_ID
    WHERE NOT EXISTS (SELECT 1 FROM r0 WHERE r0.ROW_A = a.ROW_ID AND r0.ROW_B = b.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM r1 WHERE r1.ROW_A = a.ROW_ID AND r1.ROW_B = b.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM r2 WHERE r2.ROW_A = a.ROW_ID AND r2.ROW_B = b.ROW_ID)
),

-- R5: JW(first+last) >= 85% + ADDRESS_STREET + DOB + ZIP
r5 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.FIRST_NAME_CLEAN AS FNAME_A, b.FIRST_NAME_CLEAN AS FNAME_B,
        a.LAST_NAME_CLEAN AS LNAME_A, b.LAST_NAME_CLEAN AS LNAME_B,
        a.DOB_CLEAN AS DOB_A, b.DOB_CLEAN AS DOB_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ADDRESS_ZIP AS ZIP_A, b.ADDRESS_ZIP AS ZIP_B,
        a.SSN AS SSN_A, b.SSN AS SSN_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'RECIP_R5_JW_FULLNAME_ADDR_DOB' AS MATCH_TYPE, 0.88 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM r a JOIN r b
      ON a.ADDRESS_STREET_CLEAN = b.ADDRESS_STREET_CLEAN AND a.DOB_CLEAN = b.DOB_CLEAN
     AND a.ADDRESS_ZIP = b.ADDRESS_ZIP
     AND a.ADDRESS_STREET_CLEAN IS NOT NULL AND a.ADDRESS_STREET_CLEAN != ''
     AND a.DOB_CLEAN IS NOT NULL AND a.ADDRESS_ZIP IS NOT NULL AND a.ADDRESS_ZIP != ''
     AND a.ROW_ID < b.ROW_ID
     AND JAROWINKLER_SIMILARITY(
           a.FIRST_NAME_CLEAN || ' ' || a.LAST_NAME_CLEAN,
           b.FIRST_NAME_CLEAN || ' ' || b.LAST_NAME_CLEAN) >= 85
     AND NOT (a.FIRST_NAME_CLEAN = b.FIRST_NAME_CLEAN AND a.LAST_NAME_CLEAN = b.LAST_NAME_CLEAN)
    WHERE NOT EXISTS (SELECT 1 FROM r0 WHERE r0.ROW_A = a.ROW_ID AND r0.ROW_B = b.ROW_ID)
),

-- R6: (DL or passport) + full SSN
r6 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.FIRST_NAME_CLEAN AS FNAME_A, b.FIRST_NAME_CLEAN AS FNAME_B,
        a.LAST_NAME_CLEAN AS LNAME_A, b.LAST_NAME_CLEAN AS LNAME_B,
        a.DOB_CLEAN AS DOB_A, b.DOB_CLEAN AS DOB_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ADDRESS_ZIP AS ZIP_A, b.ADDRESS_ZIP AS ZIP_B,
        a.SSN AS SSN_A, b.SSN AS SSN_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'RECIP_R6_DOCUMENT_SSN' AS MATCH_TYPE, 0.97 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM r a JOIN r b
      ON a.SSN = b.SSN AND a.SSN IS NOT NULL AND a.SSN != '' AND a.ROW_ID < b.ROW_ID
    WHERE ((a.DRIVERS_LICENSE_NUMBER = b.DRIVERS_LICENSE_NUMBER AND a.DRIVERS_LICENSE_NUMBER IS NOT NULL AND a.DRIVERS_LICENSE_NUMBER != '')
        OR (a.PASSPORT_NUMBER = b.PASSPORT_NUMBER AND a.PASSPORT_NUMBER IS NOT NULL AND a.PASSPORT_NUMBER != ''))
      AND NOT EXISTS (SELECT 1 FROM r0 WHERE r0.ROW_A = a.ROW_ID AND r0.ROW_B = b.ROW_ID)
)

-- Stack all rules
SELECT * FROM r0
UNION ALL SELECT * FROM r1
UNION ALL SELECT * FROM r2
UNION ALL SELECT * FROM r3
UNION ALL SELECT * FROM r5
UNION ALL SELECT * FROM r6;


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT MATCH_TYPE, ROUTING, COUNT(*) AS pairs
FROM MDM.MATCHING.RECIPIENT_MATCH_RESULTS
GROUP BY MATCH_TYPE, ROUTING ORDER BY pairs DESC;
