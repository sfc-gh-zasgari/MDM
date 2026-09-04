# Master Data Management — Entity Resolution Platform

End-to-end Master Data Management (MDM) system that resolves duplicate and overlapping records across multiple healthcare data sources. Identifies when the same real-world entity (provider or recipient) appears under different records in different source systems and merges them into a single **Golden Record**.

The platform implements a three-tier matching strategy — deterministic rules, ML classification, and LLM adjudication — to maximize recall while maintaining precision. All computation runs natively on Snowflake with no external dependencies.

---

## What It Does

Healthcare administrative data contains pervasive identity fragmentation: the same provider appears in multiple registries with variant name spellings, address changes, and different identifiers. The same recipient may re-enroll under a new ID with altered name or address. This platform resolves that fragmentation:

| Duplicate Pattern | Resolution Approach |
|---|---|
| Same provider in two registries with matching NPI | Tier 1: Exact NPI deterministic match |
| Same provider, different name spelling at same address | Tier 1: Jaro-Winkler fuzzy name + exact address/ZIP/type |
| Ambiguous pairs that pass blocking but aren't obvious matches | Tier 2: ML Classification (SNOWFLAKE.ML.CLASSIFICATION) |
| Edge cases requiring semantic understanding | Tier 3: LLM adjudication (SNOWFLAKE.CORTEX.COMPLETE) |
| Recipient re-enrolled under new ID with altered name/DOB | Tier 1: SSN exact match, or SSN-last4 + DOB + name |
| Recipient with address change but same identity signals | Tier 1: Name + DOB + ZIP, or fuzzy name + address + DOB |

**Output:** A single Golden Record per resolved entity with full audit trail of every merge decision.

---

## Data Sources

| File | Table | Rows | Description |
|------|-------|------|-------------|
| `health_facility_locations.csv` | `MDM.RAW.HEALTH_FACILITY_LOCATIONS` | 15,436 | Licensed healthcare facilities — hospitals, SNFs, home health agencies, clinics, hospices |
| `medical_ffs_providers.csv` | `MDM.RAW.MEDICAL_FFS_PROVIDERS` | 359,351 | Enrolled Medi-Cal Fee-for-Service providers — individual practitioners and organizations |
| `patients.csv` | `MDM.RAW.RAW_PATIENTS` | 1,513 | Synthea-generated patient records for recipient entity resolution |
| `FFS_Provider_Type_Reference_Table.csv` | `MDM.RAW.FFS_PROVIDER_TYPE_REF` | 87 | Provider type code → description lookup |
| `FFS_Provider_Specialty_Reference_Table.csv` | `MDM.RAW.FFS_PROVIDER_SPECIALTY_REF` | 72 | Provider specialty code → description lookup |

---

## Architecture

```
MDM_CA_Aug24/
├── pipeline/           SQL pipeline (16 scripts — runs entirely on Snowflake)
├── data/               Source CSV files (5 files)
├── app-mdm/            Next.js SAR app — MDM matching & golden records dashboard
└── app-readiness/      Next.js SAR app — Data quality & readiness dashboard
```

### Database Schema Layout

```
MDM (Database)
├── RAW              Source tables (loaded from CSV via stage)
├── TRANSFORMED      Cleaned & standardized records (ALL_PROVIDERS_CLEAN, ALL_RECIPIENTS_CLEAN)
├── MATCHING         Match results, ML scores, LLM decisions, connected-component labels
└── MASTER           Golden records, data readiness statistics
```

### Compute

| Warehouse | Type | Purpose |
|-----------|------|---------|
| `COMPUTE_WH` | Standard XS | Deterministic matching, golden records, readiness stats |
| `ADOPTIVE_WH` | Snowpark-Optimized Medium | ML training/inference, LLM calls, heavy blocking joins |

### Application Layer

Two standalone Next.js apps deployed as Snowflake Application Services (SAR):

| App | Purpose |
|-----|---------|
| **MDM Dashboard** | View golden records, drill into matched clusters, see match distribution by tier, review alerts |
| **Data Readiness** | Assess data quality before/after cleaning — completeness, uniqueness, validity metrics per column |

---

## Pipeline Overview

The pipeline has two parallel tracks (Providers and Recipients), each with 6 steps:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  00_setup.sql          Create database, schemas, warehouses, stage          │
│  00_reference_data.sql Create reference lookup tables                       │
│  01_load_data.sql      Load CSVs → RAW tables                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROVIDER TRACK                    RECIPIENT TRACK                          │
│  ─────────────────                 ───────────────────                      │
│  P01 → Clean & standardize        R01 → Clean & standardize                │
│  P02 → Deterministic matching      R02 → Deterministic matching             │
│  P03 → ML classification           R03 → ML classification                  │
│  P04 → LLM adjudication           R04 → LLM adjudication                   │
│  P05 → Golden records              R05 → Golden records                     │
│  P06 → Readiness stats             R06 → Readiness stats                    │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  99_cleanup.sql        Drop all objects (full teardown)                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Pipeline Steps — Providers

### P01: Cleaning & Standardization

**Input:** `MDM.RAW.HEALTH_FACILITY_LOCATIONS` + `MDM.RAW.MEDICAL_FFS_PROVIDERS`  
**Output:** `MDM.TRANSFORMED.ALL_PROVIDERS_CLEAN` (374,787 rows × 22 columns)

Transforms two source tables into a unified schema:

- **Name cleaning:** UPPER, strip punctuation, remove credentials (MD, DO, PHD), normalize org suffixes (INC, LLC)
- **Address parsing:** JavaScript UDF splits raw addresses into STREET / UNIT components, builds ADDRESS_CLEAN
- **NPI validation:** Strip to digits, validate 10-digit format starting with 1 or 2
- **Provider type normalization:** Cross-source mapping ensures same facility type matches regardless of naming convention (e.g., "CERTIFIED HOSPICE" → "HOSPICE", "COMMUNITY CLINIC" → "PRIMARY CARE CLINIC")
- **Phone/ZIP standardization:** Strip to digits, validate length
- **Entity type assignment:** INDIVIDUAL vs ORGANIZATION based on source and provider type

### P02: Deterministic Matching (Tier 1)

**Output:** `MDM.MATCHING.PROVIDER_MATCH_RESULTS` (80,272 match pairs)

Five deterministic rules with decreasing confidence:

| Rule | Confidence | Condition | Pairs Found |
|------|-----------|-----------|-------------|
| Exact NPI Match | 1.00 | Same NPI across any records | 78,203 |
| Same Provider ID + License | 0.97 | Provider ID + license number match | — |
| Same Name + Address + ZIP + Type | 0.95 | Exact match on all four fields | 1,969 |
| Similar Name + Address + ZIP + Type | 0.88 | Jaro-Winkler ≥ 85-92% + exact address/ZIP/type | 100 |
| Similar Secondary Name + Address + ZIP + Type | 0.88 | JW on secondary name ≥ 85% + exact address/ZIP/type | — |

**Safeguards:**
- Every rule requires all compared fields to be non-null on BOTH records (prevents null-to-null false matches)
- Short name guard: names < 15 characters skip fuzzy matching (too many false positives)
- NPI conflict guard: if both records have valid NPIs that differ, they are NOT the same provider
- Entity-type-aware thresholds: individuals require JW ≥ 92%, organizations ≥ 85%

### P03: ML Classification (Tier 2)

**Output:** `MDM.MATCHING.PROVIDER_ML_CANDIDATE_PAIRS` (202.9M pairs), `MDM.MATCHING.PROVIDER_ML_SCORES` (11.5M scored)

For pairs not caught by deterministic rules:

1. **Blocking:** Generate candidate pairs via same-ZIP + same-type + JW name ≥ 70% (produces ~203M candidates)
2. **Feature engineering:** Compute similarity features (name JW, address match, ZIP match, phone match, type match, NPI match)
3. **Training:** Build labeled training set from deterministic matches (positive) and random non-matches (negative)
4. **Model:** Train `SNOWFLAKE.ML.CLASSIFICATION` on the labeled pairs
5. **Scoring:** Score all 11.5M filtered candidates; route ≥ 0.80 to AUTO_MERGE, ≤ 0.20 to AUTO_REJECT, middle to MANUAL_REVIEW

### P04: LLM Adjudication (Tier 3)

**Output:** `MDM.MATCHING.PROVIDER_LLM_DECISIONS`, `MDM.MATCHING.PROVIDER_LLM_AUDIT_LOG`

For MANUAL_REVIEW pairs from ML:

1. **Prompt construction:** Format both records side-by-side with all relevant fields
2. **LLM call:** `SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', prompt)` — asks for MATCH/NO_MATCH/UNCERTAIN with confidence and reasoning
3. **Decision routing:** MATCH → insert into PROVIDER_MATCH_RESULTS; NO_MATCH → reject; UNCERTAIN → stays in review queue
4. **Audit trail:** Every LLM decision is logged with full prompt, response, confidence, and reasoning

### P05: Golden Records

**Output:** `MDM.MASTER.PROVIDER_GOLDEN_RECORDS` (295,446 golden records), `MDM.MATCHING.PROV_LABELS` (cluster assignments)

Connected-component clustering via min-label propagation:

1. **Bidirectional edges:** All match pairs are made symmetric
2. **Label propagation:** 15 iterations of min-label propagation to find connected components (handles transitive matches: if A=B and B=C, then A=B=C form one cluster)
3. **Representative selection:** Within each cluster, pick the record with the highest completeness score as the golden representative
4. **Quality scoring:** Sum of non-null key fields (NPI, name, address, phone, type, ZIP, license)

### P06: Data Readiness

**Output:** `MDM.MASTER.DATA_READINESS_STATS` (provider metrics)

Computes per-column quality metrics on the cleaned provider data:
- **Completeness:** % of rows with non-null/non-empty values
- **Uniqueness:** % of distinct values among populated rows
- **Validity:** % passing domain-specific validation (e.g., NPI Luhn check)
- **Consistency:** Cross-field consistency checks

---

## Pipeline Steps — Recipients

### R01: Cleaning & Standardization

**Input:** `MDM.RAW.RAW_PATIENTS`  
**Output:** `MDM.TRANSFORMED.ALL_RECIPIENTS_CLEAN` (1,499 rows × 31 columns)

- **Name cleaning:** UPPER, strip non-alpha (keep spaces/hyphens)
- **DOB parsing:** Validate YYYY-MM-DD format, produce DOB_CLEAN date
- **SSN cleaning:** Strip dashes, validate 9 digits, extract LAST4
- **Address:** UPPER + TRIM, build ADDRESS_CLEAN composite (street + city + state + ZIP)
- **Gender normalization:** M/F/U
- **Deceased indicator:** Y/N based on DEATHDATE presence
- **Driver's license / Passport validation:** Format checks

### R02: Deterministic Matching (Tier 1)

**Output:** `MDM.MATCHING.RECIPIENT_MATCH_RESULTS` (308 match pairs)

| Rule | Confidence | Condition | Pairs Found |
|------|-----------|-----------|-------------|
| Exact SSN Match | 1.00 | Full 9-digit SSN exact match | 257 |
| SSN Last-4 + DOB + Name | 0.97 | SSN_LAST4 + DOB + first + last name | — |
| SSN Last-4 + Name + ZIP | 0.95 | SSN_LAST4 + first + last + ZIP | — |
| Same Name + Address + DOB | 0.93 | First + last + ADDRESS_CLEAN + DOB | 42 |
| Name + DOB + ZIP | 0.90 | First + last + DOB + ZIP | — |
| Similar Name + Address + DOB | 0.88 | JW full name ≥ 88% + address + DOB | 8 |

### R03: ML Classification (Tier 2)

Same approach as providers: blocking → feature engineering → train → score.

### R04: LLM Adjudication (Tier 3)

Same approach: prompt construction → Cortex Complete → decision routing.  
**Result:** 1 LLM-confirmed match for recipients.

### R05: Golden Records

**Output:** `MDM.MASTER.RECIPIENT_GOLDEN_RECORDS` (1,194 golden records)

Connected-component clustering (3 propagation passes — sufficient for the smaller dataset):
- 293 merged entities (clusters of 2-6 records)
- 901 singletons
- Largest cluster: 6 records

### R06: Data Readiness

Computes the same quality metrics for recipient data.

---

## Matching Strategy Summary

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MATCHING TIERS                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  TIER 1: Deterministic Rules                                         │
│  ────────────────────────────                                        │
│  • Exact identifier matches (NPI, SSN, Provider ID + License)        │
│  • Exact multi-field matches (name + address + ZIP + type)           │
│  • Fuzzy name (Jaro-Winkler) + exact structural fields              │
│  • Result: AUTO_MERGE with confidence 0.88 – 1.00                    │
│                                                                       │
│  TIER 2: ML Classification                                           │
│  ─────────────────────────                                           │
│  • Blocking: same ZIP + type + JW name ≥ 70% (generates candidates) │
│  • Model: SNOWFLAKE.ML.CLASSIFICATION trained on Tier 1 labels       │
│  • Features: name_jw, address_match, zip_match, phone_match, etc.   │
│  • Routing: ≥ 0.80 → AUTO_MERGE, ≤ 0.20 → REJECT, else → REVIEW   │
│                                                                       │
│  TIER 3: LLM Adjudication                                           │
│  ─────────────────────────                                           │
│  • Input: MANUAL_REVIEW pairs from Tier 2                            │
│  • Model: SNOWFLAKE.CORTEX.COMPLETE (mistral-large2)                 │
│  • Output: MATCH / NO_MATCH / UNCERTAIN + confidence + reasoning     │
│  • Full audit trail of every LLM decision                            │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Golden Record Construction

After all three tiers produce match pairs, connected-component clustering merges transitive matches:

1. **Edge construction:** All match pairs → bidirectional edge graph
2. **Min-label propagation:** Iteratively assign each node the minimum label reachable through edges (converges in ≤ 15 iterations for providers, ≤ 3 for recipients)
3. **Cluster formation:** Nodes sharing the same label form a cluster
4. **Representative selection:** The record with the highest completeness score becomes the golden record
5. **Metadata:** Each golden record carries CLUSTER_SIZE and SOURCE_SYSTEMS

---

## Data Governance

### SSN Masking Policy

A Snowflake masking policy (`MDM.TRANSFORMED.SSN_MASK`) is applied to SSN columns in both `ALL_RECIPIENTS_CLEAN` and `RECIPIENT_GOLDEN_RECORDS`. SSN values display as `XXX-XX-####` (only last 4 digits visible).

---

## Snowflake Objects

### Tables

| Schema | Table | Rows | Purpose |
|--------|-------|------|---------|
| RAW | HEALTH_FACILITY_LOCATIONS | 15,436 | Raw facility registry |
| RAW | MEDICAL_FFS_PROVIDERS | 359,351 | Raw FFS provider registry |
| RAW | RAW_PATIENTS | 1,513 | Raw patient/recipient data |
| RAW | FFS_PROVIDER_TYPE_REF | 87 | Provider type code lookup |
| RAW | FFS_PROVIDER_SPECIALTY_REF | 72 | Provider specialty code lookup |
| TRANSFORMED | ALL_PROVIDERS_CLEAN | 374,787 | Unified cleaned providers |
| TRANSFORMED | ALL_RECIPIENTS_CLEAN | 1,499 | Cleaned recipients |
| MATCHING | PROVIDER_MATCH_RESULTS | 80,272 | All provider match pairs |
| MATCHING | PROVIDER_ML_CANDIDATE_PAIRS | 202,956,938 | ML blocking candidates |
| MATCHING | PROVIDER_ML_SCORES | 11,520,392 | ML-scored pairs |
| MATCHING | PROVIDER_ML_TRAINING_DATA | 100,000 | ML training labels |
| MATCHING | PROV_LABELS | 121,374 | Provider cluster assignments |
| MATCHING | PROV_EDGES_BIDIR | 160,544 | Provider match graph edges |
| MATCHING | RECIPIENT_MATCH_RESULTS | 308 | All recipient match pairs |
| MATCHING | RECIP_ML_CANDIDATE_PAIRS | 286 | Recipient ML candidates |
| MATCHING | RECIP_ML_SCORED | 286 | Recipient ML scores |
| MATCHING | RECIP_LABELS | 598 | Recipient cluster assignments |
| MATCHING | RECIP_LLM_DECISIONS | 3 | LLM adjudication results |
| MASTER | PROVIDER_GOLDEN_RECORDS | 295,446 | One row per resolved provider |
| MASTER | RECIPIENT_GOLDEN_RECORDS | 1,194 | One row per resolved recipient |
| MASTER | DATA_READINESS_STATS | 18 | Quality metrics for both entities |

### Other Objects

| Object | Type | Purpose |
|--------|------|---------|
| `MDM.TRANSFORMED.SSN_MASK` | Masking Policy | Hides first 5 digits of SSN |
| `MDM.TRANSFORMED.PARSE_ADDRESS_UNIT` | UDF (JavaScript) | Address → street/unit parsing |
| `MDM.TRANSFORMED.NORMALIZE_PROVIDER_TYPE` | UDF (SQL) | Cross-source type normalization |
| `MDM.TRANSFORMED.CLEAN_NPI` | UDF (SQL) | NPI validation & cleaning |
| `MDM.MATCHING.PROVIDER_MATCH_MODEL` | ML Model | Trained classification model |
| `ADOPTIVE_WH` | Warehouse | Snowpark-Optimized Medium for ML/LLM |

---

## Cleaning Process Detail

### Address Standardization

The address pipeline splits raw addresses into structured components using a JavaScript UDF:

```
"300 N 3RD ST STE 302"  → street="300 N 3RD ST", unit_type="UNIT", unit_num="302"
"620 W ROUTE 66 219"    → street="620 W ROUTE 66", unit_type="UNIT", unit_num="219"
"100 MAIN ST DEPT 4B"   → street="100 MAIN ST",    unit_type="DEPT", unit_num="4B"
"4647 ZION AVE"         → street="4647 ZION AVE",  unit_type="",     unit_num=""
```

- **Unit type normalization:** SUITE/STE/APT/FL/BLDG/RM/SPC/NUM → `UNIT`
- **Bare number detection:** Numbers after a street type with no unit keyword are assigned UNIT
- **ADDRESS_CLEAN:** `STREET + " UNIT " + NUM` (if unit exists), otherwise just STREET

### Name Standardization

- Uppercase, strip punctuation
- Remove name prefixes (DR, MR, MRS) and credentials (MD, DO, PHD, RN)
- Normalize org suffixes (INCORPORATED → INC, LIMITED LIABILITY COMPANY → LLC)
- NAME_PRIMARY_CLEAN = main entity name; NAME_SECONDARY_CLEAN = DBA/alternate name

### Provider Type Normalization

Cross-source mapping ensures matching regardless of source naming:
- "HOME HEALTH AGENCIES" (FFS) → "HOME HEALTH AGENCY" (Facilities)
- "CERTIFIED HOSPICE" (FFS) → "HOSPICE"
- "COMMUNITY CLINIC" → "PRIMARY CARE CLINIC"

---

## Prerequisites

- Snowflake account with `ACCOUNTADMIN` or equivalent role
- Snowflake CLI (`snow`) v3.25.0+ installed and configured
- Node.js 20+ (for local app development only)
- Two warehouses: `COMPUTE_WH` (XS) and `ADOPTIVE_WH` (Snowpark-Optimized Medium)

---

## Execution Order

### 1. Setup & Load

```bash
snow sql -f pipeline/00_setup.sql
snow sql -f pipeline/00_reference_data.sql
snow stage copy data/*.csv @MDM.RAW.DATA_STAGE
snow sql -f pipeline/01_load_data.sql
```

### 2. Provider Pipeline

```bash
snow sql -f pipeline/P01_provider_cleaning.sql         # ~2 min
snow sql -f pipeline/P02_provider_deterministic_matching.sql  # ~1 min
snow sql -f pipeline/P03_provider_ml_matching.sql      # ~20 min (heavy ML)
snow sql -f pipeline/P04_provider_llm_matching.sql     # ~2 min
snow sql -f pipeline/P05_provider_golden_records.sql   # ~5 min
snow sql -f pipeline/P06_provider_readiness.sql        # ~1 min
```

### 3. Recipient Pipeline (can run in parallel with providers)

```bash
snow sql -f pipeline/R01_recipient_cleaning.sql
snow sql -f pipeline/R02_recipient_deterministic_matching.sql
snow sql -f pipeline/R03_recipient_ml_matching.sql     # ~5 min
snow sql -f pipeline/R04_recipient_llm_matching.sql
snow sql -f pipeline/R05_recipient_golden_records.sql
snow sql -f pipeline/R06_recipient_readiness.sql
```

### 4. Deploy Apps

```bash
cd app-mdm
snow app setup
snow app deploy --verbose

cd ../app-readiness
snow app setup
snow app deploy --verbose
```

---

## App Deployment (SAR — Snowflake App Runtime)

Each app is a standalone Next.js project deployed as an Application Service. The apps are **visualization-only** — they read from the MATCHING and MASTER tables and display results. They do NOT execute the matching pipeline.

### Local Development

```bash
cd app-mdm && npm install && npm run dev
cd app-readiness && npm install && npm run dev
```

Apps read Snowflake credentials from `~/.snowflake/config.toml` (default connection) or set `SNOWFLAKE_CONNECTION_NAME=<name>`.

### What the Apps Show

**MDM Dashboard:**
- Summary KPIs: total source records, golden records, merged entities, pending review
- Match distribution by tier (deterministic, ML, LLM) with human-readable labels
- Golden records table with search/filter by cluster size
- Click-to-expand: view all source records that rolled up into a golden record
- Matching logic reference with rule definitions and pair counts
- Alerts/review queue for manual adjudication

**Data Readiness Dashboard:**
- Per-column quality metrics (completeness, uniqueness, validity, consistency)
- Before/after comparison showing cleaning effectiveness
- Separate views for providers and recipients

---

## Cleanup

Full teardown of all Snowflake objects:

```sql
-- Run pipeline/99_cleanup.sql to drop all tables, models, schemas
```

Teardown Application Services:

```bash
cd app-mdm && snow app teardown --force
cd ../app-readiness && snow app teardown --force
```

---

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Database | Snowflake (MDM database, 4 schemas) |
| ML | SNOWFLAKE.ML.CLASSIFICATION (native ML) |
| LLM | SNOWFLAKE.CORTEX.COMPLETE (mistral-large2) |
| Matching | Pure SQL — Jaro-Winkler, min-label propagation, connected components |
| Frontend | Next.js 16, TypeScript, Tailwind CSS, Recharts, shadcn/ui |
| Deployment | Snowflake App Runtime (SAR) — Application Services |
| CLI | Snowflake CLI (`snow`) v3.25.0+ |

---

## Folder Structure

```
MDM_CA_Aug24/
├── README.md                              ← This file
├── pipeline/                              ← Data pipeline (runs entirely on Snowflake)
│   ├── 00_setup.sql                       ← Create database, schemas, warehouses, stage
│   ├── 00_reference_data.sql              ← Reference lookup tables (type codes, specialties)
│   ├── 01_load_data.sql                   ← Load CSVs from stage → RAW tables
│   ├── P01_provider_cleaning.sql          ← Clean + standardize → ALL_PROVIDERS_CLEAN
│   ├── P02_provider_deterministic_matching.sql  ← 5 deterministic rules
│   ├── P03_provider_ml_matching.sql       ← ML blocking + training + scoring
│   ├── P04_provider_llm_matching.sql      ← LLM adjudication of review pairs
│   ├── P05_provider_golden_records.sql    ← Connected components → golden records
│   ├── P06_provider_readiness.sql         ← Data quality metrics
│   ├── R01_recipient_cleaning.sql         ← Clean patients → ALL_RECIPIENTS_CLEAN
│   ├── R02_recipient_deterministic_matching.sql  ← 6 deterministic rules
│   ├── R03_recipient_ml_matching.sql      ← ML classification
│   ├── R04_recipient_llm_matching.sql     ← LLM adjudication
│   ├── R05_recipient_golden_records.sql   ← Connected components → golden records
│   ├── R06_recipient_readiness.sql        ← Data quality metrics
│   └── 99_cleanup.sql                     ← Drop all objects
├── data/                                  ← Source CSV files
│   ├── health_facility_locations.csv      ← Licensed healthcare facilities
│   ├── medical_ffs_providers.csv          ← Medi-Cal FFS providers
│   ├── patients.csv                       ← Synthea patient records
│   ├── FFS_Provider_Type_Reference_Table.csv
│   └── FFS_Provider_Specialty_Reference_Table.csv
├── app-mdm/                               ← Next.js SAR app (MDM dashboard)
│   ├── snowflake.yml                      ← SAR deployment config
│   ├── app.yml                            ← Install/run commands + profile
│   ├── app/                               ← Next.js App Router pages
│   │   ├── providers/matching/page.tsx    ← Provider golden records + match drill-down
│   │   ├── providers/logic/page.tsx       ← Provider matching rule reference
│   │   ├── providers/alerts/page.tsx      ← Provider manual review queue
│   │   ├── recipients/matching/page.tsx   ← Recipient golden records + match drill-down
│   │   ├── recipients/logic/page.tsx      ← Recipient matching rule reference
│   │   ├── recipients/alerts/page.tsx     ← Recipient manual review queue
│   │   └── api/v1/mdm/                   ← API routes (query Snowflake)
│   ├── lib/snowflake.ts                   ← Snowflake query helper (SPCS OAuth + local dev)
│   └── lib/match-labels.ts               ← Human-readable match type labels
└── app-readiness/                         ← Next.js SAR app (data quality dashboard)
    ├── snowflake.yml
    ├── app.yml
    └── app/
        ├── providers/page.tsx             ← Provider data quality assessment
        ├── recipients/page.tsx            ← Recipient data quality assessment
        └── api/v1/mdm/                    ← API routes
```
