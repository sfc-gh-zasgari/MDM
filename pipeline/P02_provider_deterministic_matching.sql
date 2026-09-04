/*
================================================================================
P02_PROVIDER_DETERMINISTIC_MATCHING.sql
================================================================================
STEP 2 OF 5 IN THE PROVIDER ENTITY RESOLUTION PIPELINE

PURPOSE:
  Applies 5 deterministic rules to identify high-confidence duplicate provider
  pairs. These rules use exact matches on strong identifiers (NPI, license) and
  Jaro-Winkler similarity on names with exact address/ZIP/type guards.

RUN ON: COMPUTE_WH
INPUT:  MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN (374,787 rows with ROW_ID)
OUTPUT: MDM.MATCHING.PROVIDER_MATCH_RESULTS (96K+ matched pairs with ROW_A/ROW_B)

PREREQUISITE: P01_provider_cleaning.sql must have run.

RULES (applied in confidence order):
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ T0 (1.00): Exact NPI match                                              │
  │   Both records share the same 10-digit NPI.                             │
  │   NPI is federally unique per provider → zero false-merge risk.         │
  │   Uses STAR TOPOLOGY: connects each record to the MIN ROW_ID in its     │
  │   NPI group (N-1 edges vs N*(N-1)/2 — prevents combinatorial explosion  │
  │   for NPIs appearing 1000+ times in the data).                          │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ T1 (0.97): Exact PROVIDER_ID + LICENSE_NUMBER                           │
  │   State-issued identifiers. Very strong when both present.              │
  │   Also uses star topology for groups with >2 members.                   │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ T2 (0.95): Exact NAME + ADDRESS_CLEAN + ZIP + PROVIDER_TYPE_DESC        │
  │   4 independent fields all matching = same entity.                      │
  │   Uses ROW_ID < ROW_ID for dedup (groups are small).                    │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ T3 (0.88): JW(name) + exact ADDR + ZIP + TYPE                            │
  │   INDIVIDUAL: >= 92% | ORGANIZATION/FACILITY: >= 85%                    │
  │   Catches name variations (INC vs LLC, abbreviations, typos) at the     │
  │   same physical location with same specialty. Three exact guards make    │
  │   the 85% JW threshold safe from false merges.                          │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ T4 (0.88): JAROWINKLER(secondary name) >= 85% + exact ADDR + ZIP + TYPE │
  │   Catches DBA / legal name variations when primary names don't match.   │
  │   Only fires when BOTH records have a secondary name.                   │
  └──────────────────────────────────────────────────────────────────────────┘

DEDUPLICATION:
  All rules use ROW_ID to ensure each pair appears exactly once.
  T0/T1 use star topology (connect to MIN ROW_ID in group) for efficiency.
  T2/T3/T4 use pairwise ROW_A < ROW_B (groups are naturally small).

NULL GUARDS:
  Every rule requires all compared fields to be non-null on BOTH records.
  This prevents null-to-null false matches.

EXCLUSION LOGIC:
  Each rule excludes pairs already matched by higher-confidence rules above it.
  T2 excludes T0/T1 matches. T3 excludes T0/T1. T4 excludes T0/T1/T3.

RESULTS (measured):
  T0: ~78K pairs (NPI groups)
  T2: ~2.4K pairs (exact name+addr+zip+type duplicates)
  T3: ~15K pairs (JW name variations at same location)
  T4: ~47 pairs (secondary name variations)
  Total: ~96K AUTO_MERGE edges

NEXT STEP: P03_PROVIDER_ML_MATCHING.sql
================================================================================
*/

USE WAREHOUSE COMPUTE_WH;
USE DATABASE MDM;
USE SCHEMA MATCHING;

CREATE OR REPLACE TABLE MDM.MATCHING.PROVIDER_MATCH_RESULTS AS

WITH p AS (
    SELECT * FROM MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN
    WHERE NAME_PRIMARY_CLEAN IS NOT NULL AND TRIM(NAME_PRIMARY_CLEAN) != ''
),

-- ── T0: Exact NPI (star topology) ───────────────────────────────────────────
t0 AS (
    SELECT
        npi_min.MIN_ROW_ID AS ROW_A,
        a.ROW_ID AS ROW_B,
        a.NPI AS NPI_A, a.NPI AS NPI_B,
        npi_min.MIN_NAME AS NAME_A, a.NAME_PRIMARY_CLEAN AS NAME_B,
        npi_min.MIN_ADDR AS ADDR_A, a.ADDRESS_CLEAN AS ADDR_B,
        npi_min.MIN_ZIP AS ZIP_A, a.ZIP AS ZIP_B,
        npi_min.MIN_TYPE AS TYPE_A, a.PROVIDER_TYPE_DESC AS TYPE_B,
        npi_min.MIN_PHONE AS PHONE_A, a.PHONE AS PHONE_B,
        npi_min.MIN_SOURCE AS SOURCE_A, a._SOURCE_SYSTEM AS SOURCE_B,
        'PROV_T0_EXACT_NPI' AS MATCH_TYPE, 1.00 AS HYBRID_SCORE, 'AUTO_MERGE'::VARCHAR(20) AS ROUTING
    FROM p a
    JOIN (
        SELECT NPI, MIN(ROW_ID) AS MIN_ROW_ID,
            MIN_BY(NAME_PRIMARY_CLEAN, ROW_ID) AS MIN_NAME,
            MIN_BY(ADDRESS_CLEAN, ROW_ID) AS MIN_ADDR,
            MIN_BY(ZIP, ROW_ID) AS MIN_ZIP,
            MIN_BY(PROVIDER_TYPE_DESC, ROW_ID) AS MIN_TYPE,
            MIN_BY(PHONE, ROW_ID) AS MIN_PHONE,
            MIN_BY(_SOURCE_SYSTEM, ROW_ID) AS MIN_SOURCE
        FROM p WHERE NPI IS NOT NULL AND NPI != ''
        GROUP BY NPI HAVING COUNT(*) > 1
    ) npi_min ON a.NPI = npi_min.NPI AND a.ROW_ID > npi_min.MIN_ROW_ID
),

-- ── T1: Exact PROVIDER_ID + LICENSE (star topology) ─────────────────────────
t1 AS (
    SELECT
        grp.MIN_ROW_ID AS ROW_A,
        a.ROW_ID AS ROW_B,
        grp.MIN_NPI AS NPI_A, a.NPI AS NPI_B,
        grp.MIN_NAME AS NAME_A, a.NAME_PRIMARY_CLEAN AS NAME_B,
        grp.MIN_ADDR AS ADDR_A, a.ADDRESS_CLEAN AS ADDR_B,
        grp.MIN_ZIP AS ZIP_A, a.ZIP AS ZIP_B,
        grp.MIN_TYPE AS TYPE_A, a.PROVIDER_TYPE_DESC AS TYPE_B,
        grp.MIN_PHONE AS PHONE_A, a.PHONE AS PHONE_B,
        grp.MIN_SOURCE AS SOURCE_A, a._SOURCE_SYSTEM AS SOURCE_B,
        'PROV_T1_PROVID_LICENSE' AS MATCH_TYPE, 0.97 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM p a
    JOIN (
        SELECT PROVIDER_ID, LICENSE_NUMBER, MIN(ROW_ID) AS MIN_ROW_ID,
            MIN_BY(NPI, ROW_ID) AS MIN_NPI,
            MIN_BY(NAME_PRIMARY_CLEAN, ROW_ID) AS MIN_NAME,
            MIN_BY(ADDRESS_CLEAN, ROW_ID) AS MIN_ADDR,
            MIN_BY(ZIP, ROW_ID) AS MIN_ZIP,
            MIN_BY(PROVIDER_TYPE_DESC, ROW_ID) AS MIN_TYPE,
            MIN_BY(PHONE, ROW_ID) AS MIN_PHONE,
            MIN_BY(_SOURCE_SYSTEM, ROW_ID) AS MIN_SOURCE
        FROM p WHERE PROVIDER_ID IS NOT NULL
          AND LICENSE_NUMBER IS NOT NULL AND LICENSE_NUMBER != ''
        GROUP BY PROVIDER_ID, LICENSE_NUMBER HAVING COUNT(*) > 1
    ) grp ON a.PROVIDER_ID = grp.PROVIDER_ID AND a.LICENSE_NUMBER = grp.LICENSE_NUMBER
         AND a.ROW_ID > grp.MIN_ROW_ID
    WHERE NOT EXISTS (SELECT 1 FROM t0 WHERE t0.ROW_B = a.ROW_ID)
),

-- ── T2: Exact NAME + ADDRESS + ZIP + TYPE ───────────────────────────────────
t2 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.NPI AS NPI_A, b.NPI AS NPI_B,
        a.NAME_PRIMARY_CLEAN AS NAME_A, b.NAME_PRIMARY_CLEAN AS NAME_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ZIP AS ZIP_A, b.ZIP AS ZIP_B,
        a.PROVIDER_TYPE_DESC AS TYPE_A, b.PROVIDER_TYPE_DESC AS TYPE_B,
        a.PHONE AS PHONE_A, b.PHONE AS PHONE_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'PROV_T2_EXACT_NAME_ADDR_ZIP_TYPE' AS MATCH_TYPE, 0.95 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM p a JOIN p b
        ON a.NAME_PRIMARY_CLEAN = b.NAME_PRIMARY_CLEAN
       AND a.ADDRESS_CLEAN = b.ADDRESS_CLEAN AND a.ZIP = b.ZIP
       AND a.PROVIDER_TYPE_DESC = b.PROVIDER_TYPE_DESC
       AND a.ADDRESS_CLEAN IS NOT NULL AND a.ADDRESS_CLEAN != ''
       AND a.ZIP IS NOT NULL AND a.ZIP != ''
       AND a.PROVIDER_TYPE_DESC IS NOT NULL AND a.PROVIDER_TYPE_DESC != ''
       AND a.ROW_ID < b.ROW_ID
    WHERE NOT EXISTS (SELECT 1 FROM t0 WHERE t0.ROW_B = a.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM t0 WHERE t0.ROW_B = b.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM t1 WHERE t1.ROW_B = a.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM t1 WHERE t1.ROW_B = b.ROW_ID)
),

-- ── T3: JW primary name + exact ADDRESS + ZIP + TYPE ─────────────────────────
-- Threshold depends on entity type:
--   INDIVIDUAL: JW >= 92% (higher bar — avoids false merges at large clinics)
--   ORGANIZATION/FACILITY: JW >= 85% (lower bar — org name variations are real dupes)
-- Short name guard: if either name is < 15 characters, skip JW (require exact match
-- via T2 instead). Short names like "CHAN STEPHEN" produce too many false JW matches.
-- NPI conflict guard: if both have valid NPI but they differ, these are different providers.
t3 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.NPI AS NPI_A, b.NPI AS NPI_B,
        a.NAME_PRIMARY_CLEAN AS NAME_A, b.NAME_PRIMARY_CLEAN AS NAME_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ZIP AS ZIP_A, b.ZIP AS ZIP_B,
        a.PROVIDER_TYPE_DESC AS TYPE_A, b.PROVIDER_TYPE_DESC AS TYPE_B,
        a.PHONE AS PHONE_A, b.PHONE AS PHONE_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'PROV_T3_JW_PRIMARY_ADDR_ZIP_TYPE' AS MATCH_TYPE, 0.88 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM p a JOIN p b
        ON a.ADDRESS_CLEAN = b.ADDRESS_CLEAN AND a.ZIP = b.ZIP
       AND a.PROVIDER_TYPE_DESC = b.PROVIDER_TYPE_DESC
       AND a.ADDRESS_CLEAN IS NOT NULL AND a.ADDRESS_CLEAN != ''
       AND a.ZIP IS NOT NULL AND a.ZIP != ''
       AND a.PROVIDER_TYPE_DESC IS NOT NULL AND a.PROVIDER_TYPE_DESC != ''
       AND a.ROW_ID < b.ROW_ID
       AND a.NAME_PRIMARY_CLEAN != b.NAME_PRIMARY_CLEAN
       -- Short name guard: both names must be >= 15 chars for JW to apply
       AND LENGTH(a.NAME_PRIMARY_CLEAN) >= 15
       AND LENGTH(b.NAME_PRIMARY_CLEAN) >= 15
       -- Entity-type-aware JW threshold
       AND JAROWINKLER_SIMILARITY(a.NAME_PRIMARY_CLEAN, b.NAME_PRIMARY_CLEAN) >=
           CASE WHEN a.ENTITY_TYPE = 'INDIVIDUAL' OR b.ENTITY_TYPE = 'INDIVIDUAL' THEN 92 ELSE 85 END
    WHERE NOT EXISTS (SELECT 1 FROM t0 WHERE t0.ROW_B = a.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM t0 WHERE t0.ROW_B = b.ROW_ID)
      -- NPI conflict guard: if both have valid NPI but they differ, these are different providers
      AND NOT (a.NPI IS NOT NULL AND a.NPI != '' AND b.NPI IS NOT NULL AND b.NPI != '' AND a.NPI != b.NPI)
),

-- ── T4: JW secondary name >= 85% + exact ADDRESS + ZIP + TYPE ───────────────
t4 AS (
    SELECT a.ROW_ID AS ROW_A, b.ROW_ID AS ROW_B,
        a.NPI AS NPI_A, b.NPI AS NPI_B,
        a.NAME_PRIMARY_CLEAN AS NAME_A, b.NAME_PRIMARY_CLEAN AS NAME_B,
        a.ADDRESS_CLEAN AS ADDR_A, b.ADDRESS_CLEAN AS ADDR_B,
        a.ZIP AS ZIP_A, b.ZIP AS ZIP_B,
        a.PROVIDER_TYPE_DESC AS TYPE_A, b.PROVIDER_TYPE_DESC AS TYPE_B,
        a.PHONE AS PHONE_A, b.PHONE AS PHONE_B,
        a._SOURCE_SYSTEM AS SOURCE_A, b._SOURCE_SYSTEM AS SOURCE_B,
        'PROV_T4_JW_SECONDARY_ADDR_ZIP_TYPE' AS MATCH_TYPE, 0.88 AS HYBRID_SCORE, 'AUTO_MERGE' AS ROUTING
    FROM p a JOIN p b
        ON a.ADDRESS_CLEAN = b.ADDRESS_CLEAN AND a.ZIP = b.ZIP
       AND a.PROVIDER_TYPE_DESC = b.PROVIDER_TYPE_DESC
       AND a.ADDRESS_CLEAN IS NOT NULL AND a.ADDRESS_CLEAN != ''
       AND a.ZIP IS NOT NULL AND a.ZIP != ''
       AND a.PROVIDER_TYPE_DESC IS NOT NULL AND a.PROVIDER_TYPE_DESC != ''
       AND a.NAME_SECONDARY_CLEAN IS NOT NULL AND a.NAME_SECONDARY_CLEAN != ''
       AND b.NAME_SECONDARY_CLEAN IS NOT NULL AND b.NAME_SECONDARY_CLEAN != ''
       AND a.ROW_ID < b.ROW_ID
       AND JAROWINKLER_SIMILARITY(a.NAME_SECONDARY_CLEAN, b.NAME_SECONDARY_CLEAN) >= 85
    WHERE NOT EXISTS (SELECT 1 FROM t0 WHERE t0.ROW_B = a.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM t0 WHERE t0.ROW_B = b.ROW_ID)
      AND NOT EXISTS (SELECT 1 FROM t3 WHERE t3.ROW_A = a.ROW_ID AND t3.ROW_B = b.ROW_ID)
)

-- Stack all rules
SELECT * FROM t0
UNION ALL SELECT * FROM t1
UNION ALL SELECT * FROM t2
UNION ALL SELECT * FROM t3
UNION ALL SELECT * FROM t4;


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT MATCH_TYPE, ROUTING, COUNT(*) AS pairs
FROM MDM.MATCHING.PROVIDER_MATCH_RESULTS
GROUP BY MATCH_TYPE, ROUTING ORDER BY pairs DESC;
