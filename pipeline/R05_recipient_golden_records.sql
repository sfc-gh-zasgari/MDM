/*
================================================================================
R05_RECIPIENT_GOLDEN_RECORDS.sql
================================================================================
STEP 5 OF 5 IN THE RECIPIENT ENTITY RESOLUTION PIPELINE

PURPOSE:
  Resolves all matched recipient pairs into clusters and selects one "golden"
  record per cluster. Unmatched records become singletons.

RUN ON: COMPUTE_WH
INPUT:  MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN (with ROW_ID)
        MDM.MATCHING.RECIPIENT_MATCH_RESULTS (all AUTO_MERGE pairs)
OUTPUT: MDM.MASTER.RECIPIENT_GOLDEN_RECORDS (one row per resolved person)

PREREQUISITE: All matching steps (R02/R03/R04) must have run.

HOW IT WORKS:
  Same approach as providers (P05):
  1. Build bidirectional edge graph from match pairs
  2. Iterative min-label propagation (converges in 2-3 passes for pairwise data)
  3. Survivorship: most complete record wins (most non-null fields)

SURVIVORSHIP PRIORITY:
  a) Most non-null critical fields (SSN, DOB, address, name, DL, passport)
  b) Most recent _LOAD_TS (tiebreaker)

RESULTS (measured on 1,513 test records):
  1,513 input → 1,192 golden records
  - 321 merged entities (all size-2 clusters)
  - 871 singletons

NEXT STEP: Pipeline complete for recipients.
================================================================================
*/

USE WAREHOUSE COMPUTE_WH;
USE DATABASE MDM;
USE SCHEMA MASTER;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1: Bidirectional edges + label propagation (3 passes)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_EDGES_BIDIR AS
SELECT ROW_A AS src, ROW_B AS dst FROM MDM.MATCHING.RECIPIENT_MATCH_RESULTS
UNION
SELECT ROW_B AS src, ROW_A AS dst FROM MDM.MATCHING.RECIPIENT_MATCH_RESULTS;

CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_LABELS AS
SELECT DISTINCT src AS node, src AS label FROM MDM.MATCHING.RECIP_EDGES_BIDIR;

-- 3 propagation passes (sufficient for pairwise clusters)
CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.RECIP_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.RECIP_EDGES_BIDIR e JOIN MDM.MATCHING.RECIP_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.RECIP_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.RECIP_EDGES_BIDIR e JOIN MDM.MATCHING.RECIP_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.RECIP_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.RECIP_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.RECIP_EDGES_BIDIR e JOIN MDM.MATCHING.RECIP_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2: Build golden records
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MASTER.RECIPIENT_GOLDEN_RECORDS AS
WITH all_labels AS (
    SELECT node, label AS cluster_id FROM MDM.MATCHING.RECIP_LABELS
    UNION ALL
    SELECT ROW_ID AS node, ROW_ID AS cluster_id
    FROM MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN
    WHERE ROW_ID NOT IN (SELECT node FROM MDM.MATCHING.RECIP_LABELS)
),
ranked AS (
    SELECT
        cl.cluster_id, p.*,
        ROW_NUMBER() OVER (
            PARTITION BY cl.cluster_id
            ORDER BY
                (CASE WHEN p.SSN IS NOT NULL AND p.SSN != '' THEN 1 ELSE 0 END
               + CASE WHEN p.DOB_CLEAN IS NOT NULL THEN 1 ELSE 0 END
               + CASE WHEN p.ADDRESS_CLEAN IS NOT NULL AND p.ADDRESS_CLEAN != '' THEN 1 ELSE 0 END
               + CASE WHEN p.ADDRESS_ZIP IS NOT NULL AND p.ADDRESS_ZIP != '' THEN 1 ELSE 0 END
               + CASE WHEN p.FIRST_NAME_CLEAN IS NOT NULL AND p.FIRST_NAME_CLEAN != '' THEN 1 ELSE 0 END
               + CASE WHEN p.LAST_NAME_CLEAN IS NOT NULL AND p.LAST_NAME_CLEAN != '' THEN 1 ELSE 0 END
               + CASE WHEN p.DRIVERS_LICENSE_NUMBER IS NOT NULL AND p.DRIVERS_LICENSE_NUMBER != '' THEN 1 ELSE 0 END
               + CASE WHEN p.PASSPORT_NUMBER IS NOT NULL AND p.PASSPORT_NUMBER != '' THEN 1 ELSE 0 END
                ) DESC,
                p._LOAD_TS DESC NULLS LAST
        ) AS rank_in_cluster
    FROM all_labels cl
    JOIN MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN p ON p.ROW_ID = cl.node
),
cluster_meta AS (
    SELECT cluster_id, COUNT(*) AS CLUSTER_SIZE,
        LISTAGG(DISTINCT _SOURCE_SYSTEM, ', ') AS SOURCE_SYSTEMS
    FROM ranked GROUP BY cluster_id
)
SELECT
    r.cluster_id AS GOLDEN_ID,
    r.ROW_ID, r.RECIPIENT_ID,
    r.FIRST_NAME, r.FIRST_NAME_CLEAN, r.LAST_NAME, r.LAST_NAME_CLEAN,
    r.DATE_OF_BIRTH, r.DOB_CLEAN, r.GENDER_RAW, r.GENDER_CLEAN,
    r.SSN, r.SSN_LAST4,
    r.ADDRESS_STREET, r.ADDRESS_STREET_CLEAN, r.ADDRESS_CITY, r.ADDRESS_STATE, r.ADDRESS_ZIP,
    r.ADDRESS_CLEAN,
    r.DRIVERS_LICENSE_NUMBER, r.PASSPORT_NUMBER,
    r.MARITAL_STATUS, r.RACE, r.ETHNICITY,
    r.DECEASED_INDICATOR, r.DECEASED_DATE,
    r.MAIDEN_NAME_CLEAN, r.COUNTY_ID,
    r._SOURCE_SYSTEM, r._LOAD_TS,
    cm.CLUSTER_SIZE, cm.SOURCE_SYSTEMS
FROM ranked r
JOIN cluster_meta cm ON cm.cluster_id = r.cluster_id
WHERE r.rank_in_cluster = 1;


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT
    COUNT(*) AS total_golden,
    SUM(CASE WHEN CLUSTER_SIZE > 1 THEN 1 ELSE 0 END) AS merged,
    SUM(CASE WHEN CLUSTER_SIZE = 1 THEN 1 ELSE 0 END) AS singletons,
    MAX(CLUSTER_SIZE) AS largest_cluster
FROM MDM.MASTER.RECIPIENT_GOLDEN_RECORDS;
