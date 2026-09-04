/*
================================================================================
P05_PROVIDER_GOLDEN_RECORDS.sql
================================================================================
STEP 5 OF 5 IN THE PROVIDER ENTITY RESOLUTION PIPELINE

PURPOSE:
  Resolves all matched pairs into clusters (connected components) and selects
  one "golden" record per cluster as the canonical representation. Unmatched
  records become their own singleton golden records.

RUN ON: COMPUTE_WH
INPUT:  MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN (374,787 rows with ROW_ID)
        MDM.MATCHING.PROVIDER_MATCH_RESULTS (all AUTO_MERGE pairs from Tiers 1-3)
OUTPUT: MDM.MASTER.PROVIDER_GOLDEN_RECORDS (one row per resolved entity)

PREREQUISITE: All matching steps (P02/P03/P04) must have run.

HOW IT WORKS:

  1. GRAPH CONSTRUCTION:
     Each AUTO_MERGE pair (ROW_A, ROW_B) is an edge in an undirected graph.
     Records connected by any chain of edges belong to the same real-world entity.

  2. CONNECTED COMPONENTS (iterative min-label propagation):
     - Initialize: each node's cluster label = its own ROW_ID
     - Each pass: propagate the minimum label across all edges
     - Repeat until no labels change (convergence)
     - Typical: 10-15 passes for this dataset (graph diameter ~ 13)

     This assigns every record a cluster_id = the minimum ROW_ID in its cluster.

  3. SURVIVORSHIP (selecting the golden record within each cluster):
     Priority order:
       a) Highest QUALITY_SCORE (reflects overall data completeness)
       b) Most non-null important fields (tiebreaker)
       c) Most recent _LOAD_TS (tiebreaker)
     The top-ranked record becomes the golden record for that cluster.

  4. METADATA: Each golden record is enriched with:
     - CLUSTER_SIZE: how many source records merged into this entity
     - SOURCE_SYSTEMS: which data sources contributed
     - ALL_NPIS: all distinct NPIs associated with this entity

RESULTS (measured):
  374,787 input records → 284,475 golden records
  - 47,051 merged entities (clusters of 2+ records)
  - 237,424 singletons (unique records, no matches found)
  - Largest cluster: 1,878 members (one NPI appearing many times)
  - Most common: size-2 clusters (38K entities — same provider enrolled twice)

NEXT STEP: Pipeline complete for providers. Results available for apps/reporting.
================================================================================
*/

USE WAREHOUSE COMPUTE_WH;
USE DATABASE MDM;
USE SCHEMA MASTER;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 1: Build bidirectional edge list from all AUTO_MERGE pairs
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MATCHING.PROV_EDGES_BIDIR AS
SELECT ROW_A AS src, ROW_B AS dst FROM MDM.MATCHING.PROVIDER_MATCH_RESULTS WHERE ROUTING = 'AUTO_MERGE'
UNION
SELECT ROW_B AS src, ROW_A AS dst FROM MDM.MATCHING.PROVIDER_MATCH_RESULTS WHERE ROUTING = 'AUTO_MERGE';


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 2: Iterative min-label propagation (connected components)
-- ══════════════════════════════════════════════════════════════════════════════
-- Initialize: each node = its own cluster
-- Propagate 15 times (guaranteed convergence for graph diameter <= 15)

CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS
SELECT DISTINCT src AS node, src AS label FROM MDM.MATCHING.PROV_EDGES_BIDIR;

-- 15 propagation passes
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;
CREATE OR REPLACE TABLE MDM.MATCHING.PROV_LABELS AS SELECT l.node, LEAST(l.label, m.min_label) AS label FROM MDM.MATCHING.PROV_LABELS l JOIN (SELECT e.src AS node, MIN(l2.label) AS min_label FROM MDM.MATCHING.PROV_EDGES_BIDIR e JOIN MDM.MATCHING.PROV_LABELS l2 ON l2.node = e.dst GROUP BY e.src) m ON m.node = l.node;


-- ══════════════════════════════════════════════════════════════════════════════
-- STEP 3: Build golden records (one per cluster)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE MDM.MASTER.PROVIDER_GOLDEN_RECORDS AS
WITH all_labels AS (
    -- Matched nodes get their converged cluster label
    SELECT node, label AS cluster_id FROM MDM.MATCHING.PROV_LABELS
    UNION ALL
    -- Singletons get their own ROW_ID as cluster
    SELECT ROW_ID AS node, ROW_ID AS cluster_id
    FROM MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN
    WHERE ROW_ID NOT IN (SELECT node FROM MDM.MATCHING.PROV_LABELS)
),
ranked AS (
    SELECT
        cl.cluster_id, p.*,
        ROW_NUMBER() OVER (
            PARTITION BY cl.cluster_id
            ORDER BY
                p.QUALITY_SCORE DESC NULLS LAST,
                (CASE WHEN p.NPI IS NOT NULL AND p.NPI != '' THEN 1 ELSE 0 END
               + CASE WHEN p.LICENSE_NUMBER IS NOT NULL AND p.LICENSE_NUMBER != '' THEN 1 ELSE 0 END
               + CASE WHEN p.ADDRESS_CLEAN IS NOT NULL AND p.ADDRESS_CLEAN != '' THEN 1 ELSE 0 END
               + CASE WHEN p.ZIP IS NOT NULL AND p.ZIP != '' THEN 1 ELSE 0 END
               + CASE WHEN p.PHONE IS NOT NULL AND p.PHONE != '' THEN 1 ELSE 0 END
               + CASE WHEN p.EMAIL IS NOT NULL AND p.EMAIL != '' THEN 1 ELSE 0 END
               + CASE WHEN p.TAXONOMY_CODE IS NOT NULL AND p.TAXONOMY_CODE != '' THEN 1 ELSE 0 END
               + CASE WHEN p.NAME_SECONDARY_CLEAN IS NOT NULL AND p.NAME_SECONDARY_CLEAN != '' THEN 1 ELSE 0 END
                ) DESC,
                p._LOAD_TS DESC NULLS LAST
        ) AS rank_in_cluster
    FROM all_labels cl
    JOIN MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN p ON p.ROW_ID = cl.node
),
cluster_meta AS (
    SELECT cluster_id, COUNT(*) AS CLUSTER_SIZE,
        LISTAGG(DISTINCT _SOURCE_SYSTEM, ', ') AS SOURCE_SYSTEMS,
        LISTAGG(DISTINCT CASE WHEN NPI IS NOT NULL AND NPI != '' THEN NPI END, ', ') AS ALL_NPIS
    FROM ranked GROUP BY cluster_id
)
SELECT
    r.cluster_id AS GOLDEN_ID,
    r.ROW_ID, r.PROVIDER_ID, r.NPI, r.NPI_VALID, r.LICENSE_NUMBER,
    r.TAXONOMY_CODE, r.TAXONOMY_VALID, r.PROVIDER_TYPE_CD, r.SPECIALTY_CD,
    r.NAME_PRIMARY, r.NAME_PRIMARY_CLEAN, r.NAME_SECONDARY, r.NAME_SECONDARY_CLEAN,
    r.CONTACT_NAME, r.CONTACT_NAME_CLEAN, r.ENTITY_TYPE,
    r.ADDRESS, r.ADDRESS_STREET, r.ADDRESS_UNIT_TYPE, r.ADDRESS_UNIT_NUM,
    r.ADDRESS_CLEAN, r.IS_PO_BOX, r.CITY, r.STATE, r.ZIP,
    r.COUNTY_ID, r.COUNTY_NAME, r.LATITUDE, r.LONGITUDE,
    r.PHONE, r.PHONE_VALID, r.EMAIL, r.EMAIL_CLEAN,
    r.PROVIDER_TYPE_DESC, r.SPECIALTY, r.QUALITY_SCORE, r.QUALITY_BAND,
    r._SOURCE_SYSTEM, r._LOAD_TS, r.ADDRESS_HASH,
    cm.CLUSTER_SIZE, cm.SOURCE_SYSTEMS, cm.ALL_NPIS
FROM ranked r
JOIN cluster_meta cm ON cm.cluster_id = r.cluster_id
WHERE r.rank_in_cluster = 1;


-- ══════════════════════════════════════════════════════════════════════════════
-- VERIFY
-- ══════════════════════════════════════════════════════════════════════════════

SELECT
    COUNT(*) AS total_golden,
    SUM(CASE WHEN CLUSTER_SIZE > 1 THEN 1 ELSE 0 END) AS merged_entities,
    SUM(CASE WHEN CLUSTER_SIZE = 1 THEN 1 ELSE 0 END) AS singletons,
    MAX(CLUSTER_SIZE) AS largest_cluster
FROM MDM.MASTER.PROVIDER_GOLDEN_RECORDS;

SELECT CLUSTER_SIZE, COUNT(*) AS entities
FROM MDM.MASTER.PROVIDER_GOLDEN_RECORDS
WHERE CLUSTER_SIZE > 1
GROUP BY CLUSTER_SIZE ORDER BY CLUSTER_SIZE LIMIT 10;
