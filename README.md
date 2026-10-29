# NSW DCJ — First Iteration Person Data Model (`SDM` $\rightarrow$ `TDM`), Hybrid Person Match & Property Graph

> [!IMPORTANT]
> **Live Deployment Summary (`all-things-cdp` · `us-central1`)**
> - **Source Data Model (`all-things-cdp.dcj_sdm`)**: **14 SDM tables, views, and materialized views** populated with **1,150 source records** representing **600 true individuals** (`655` true cross-record pairs) and **260 geocoded GNAF locations** across **Child Protection (`ChildStory`)**, **Family Preservation (`InfoShare`)**, and **Youth Justice (`KIMS`)**.
> - **Entity Resolution Working Dataset (`all-things-cdp.dcj_match`)**: All staging, bipartite identifier graph (`identifier`, `has_identifier`), **BigQuery Vector Search** (`source_profile_search`, `source_profile_vectors`), RRF candidate tiers (`candidate_pair_tiers`), **Immutable AI Audit Ledger** (`person_match_adjudications`), Connected Components (`sp_connected_components`, `person_assignment`), callable real-time TVF (`fn_person_match`), and benchmark views (`v_dcj_method_comparison`, `v_dcj_scenario_scorecard`).
> - **Target Data Model & Graph ONLY (`all-things-cdp.dcj_tdm`)**: Strictly the **9 mastered Target Data Model (TDM) tables** (`party`, `person`, `person_name`, `person_identity_instrument`, `address_location`, `address_relation`, `person_source_linkage`, `party_relationship`, `person_protection_event`) and the **Target Property Graph (`all-things-cdp.dcj_tdm.dcj_person_graph`)** combining **8 Node Labels** and **9 Edge Labels**.
> - **Person Match Engine & Callable TVF (`all-things-cdp.dcj_match.fn_person_match`)**: Combines Bipartite Identifier IDF Rarity, Crisis Refuge Hub Guard, Native **BigQuery Vector Search** (`AI.EMBED` + `VECTOR_SEARCH`), **Reciprocal Rank Fusion (`RRF`)**, 2-Hop Kinship Context, and an auditable **Gemini Platform AI Adjudicator** (`AI.GENERATE` via BigQuery connection `all-things-cdp.us-central1.dcj-conn` to **Gemini 3.5** / `gemini-3.5-flash`) — achieving **100.00% Precision**, **100.00% Recall**, and **1.0000 F1** (`600/600` resolved entities, `0` false merges, `0` hairball clusters).
> - **BigQuery Knowledge Catalog Business Glossary (`dcj_person_cdm_glossary`)**: **6 logical categories**, **118 business terms & KPIs** with rich HTML overviews, and **118 direct `Schema.<Column>` `EntryLinks`** synced to BigQuery table and column descriptions.

---

## 1. System Architecture, Interactive Walkthroughs & Frontline Search

![NSW DCJ Person Data Model, Hybrid Match & Property Graph Architecture](dcj_person_data_model.svg)

- **Frontline Person & Property Search + Graph Studio**: [`dcj-frontline-search.html`](dcj-frontline-search.html) + [`backend/`](backend/) — Google Search-style omnibox & 9-field intake probe calling live `fn_frontline_person_search`, `fn_frontline_property_search`, and `GRAPH_TABLE(dcj_tdm.dcj_person_graph)` with D3.js v7 Property Graph visualisation, **Gemini Platform** adjudication audit ledger, survivorship provenance, and Simple-View Google Map.
- **Complete Test Use-Cases & Walkthrough Guide**: [`WALKTHROUGH_AND_TEST_CASES.md`](WALKTHROUGH_AND_TEST_CASES.md) + [`sql/95_test_use_cases_walkthrough.sql`](sql/95_test_use_cases_walkthrough.sql) — Covers all 8 statutory, cultural, kinship, and crisis-refuge scenarios end-to-end.
- **BigQuery Studio Python Notebook (`cdp-walkthrough`, `45` cells)**: [`notebooks/cdp-walkthrough.ipynb`](notebooks/cdp-walkthrough.ipynb) — Deployed via [`scripts/deploy_notebook_to_bq_studio.py`](scripts/deploy_notebook_to_bq_studio.py) ([Open in BigQuery Studio](https://console.cloud.google.com/bigquery?project=all-things-cdp&ws=!1m7!1m6!12m5!1m3!1sall-things-cdp!2sus-central1!3scdp-walkthrough!2e2)).
- **Executive & Technical Walkthrough Presentation**: [`index.html`](index.html)
- **Simplified Plain-English Customer Walkthrough**: [`novice_walkthrough.html`](novice_walkthrough.html)
- **Standalone Interactive Functional Hierarchy Diagram (`DCJ-00` .. `DCJ-04-05`, `44` nodes)**: [`dcj_fhd.html`](dcj_fhd.html) *(100% self-contained single-file HTML — opens directly offline in any browser with Right-Hand Functional Specification Cards, subtree re-rooting, Light/Dark mode, and client-side `Export SVG` / `Export 2x PNG`)* · Static exports: [`dcj_fhd.svg`](dcj_fhd.svg) / [`dcj_fhd.png`](dcj_fhd.png) / [`dcj_fhd.drawio`](dcj_fhd.drawio) / [`dcj_fhd_spec.json`](dcj_fhd_spec.json)
- **Capability Maps**: [`mdm-capability-map.md`](mdm-capability-map.md) / [`DCJ_PROCESS_BQ_CAPABILITIES_OVERVIEW.md`](DCJ_PROCESS_BQ_CAPABILITIES_OVERVIEW.md)
- **Dendrite & Draw.io Architecture Sources**: [`dcj_person_data_model.dendrite`](dcj_person_data_model.dendrite) / [`dcj_person_data_model.drawio`](dcj_person_data_model.drawio)

---

## 2. Repository Layout & Next-Generation SQL ELT Pipeline

All pipeline stages are orchestrated by [`run.sh`](run.sh) using environment variables in [`config.env`](config.env):

| Stage | File | Purpose & Key Outputs |
| :--- | :--- | :--- |
| **Config** | [`config.env`](config.env) / [`run.sh`](run.sh) | Project (`all-things-cdp`), datasets (`dcj_sdm`, `dcj_match`, `dcj_tdm`, `dcj_truth`), connection (`dcj-conn`), and idempotent runner (`./run.sh --all`). |
| **Stage 00** | [`00_setup_and_sdm.sql`](sql/00_setup_and_sdm.sql) | Creates schemas (`dcj_sdm`, `dcj_match`, `dcj_tdm`, `dcj_truth`), normalization UDFs (`standardize_address` in `dcj_sdm`; `fold_diacritics`, `norm_phone`, `compute_slk581`, `canonical_relationship_type`, `relationship_category` in `dcj_match`), and all 14 SDM tables, views, and materialized views. |
| **Data Gen** | [`generate_dcj_sdm_data.py`](scripts/generate_dcj_sdm_data.py) | Generates realistic NSW DCJ synthetic data (`600` true people, `1,150` SDM records, `655` true pairs, all `78` relationship strings, all `16` name usage types, and `8` planted edge-case scenarios) and loads `dcj_sdm` + `dcj_truth`. |
| **Stage 10** | [`10_stage_sources.sql`](sql/10_stage_sources.sql) | Normalizes and unifies Child Protection, Family Preservation, and Youth Justice records into `dcj_match.stg_source_profiles` (`1,150` rows) with phonetic keys (`SOUNDEX`), SLK-581, and serialized `match_key` dossiers. |
| **Stage 20** | [`20_bipartite_graph.sql`](sql/20_bipartite_graph.sql) | Builds the Bipartite Identifier Graph (`dcj_match.has_identifier` = `5,143` links, `dcj_match.identifier` = `2,754` nodes) with $\text{IDF} = \ln(1 + N/\text{df})$ rarity weights and Crisis Refuge hub suppression (`df > 5` $\rightarrow$ `is_hub = TRUE`). |
| **Stage 30** | [`30_embed_and_search.sql`](sql/30_embed_and_search.sql) | Creates `dcj_match.source_profile_search` with autonomous `GENERATED ALWAYS AS (AI.EMBED(...))` columns (`text-embedding-005`) and materialized `dcj_match.source_profile_vectors` for native **BigQuery Vector Search**. |
| **Stage 40** | [`40_hybrid_candidates_rrf.sql`](sql/40_hybrid_candidates_rrf.sql) | Combines Lexical/Deterministic blocking + **BigQuery Vector Search** (`VECTOR_SEARCH`) via **Reciprocal Rank Fusion (`RRF`, $k=60$)** + **2-Hop Kinship Context** + **Twin SLK-581 Collision Guard** into `dcj_match.candidate_pair_tiers` (`405` `AUTO_MATCH`, `391` `GREY_ZONE`, `13,690` `REJECT`). |
| **Stage 50** | [`50_genai_adjudicator.sql`](sql/50_genai_adjudicator.sql) | Calls `AI.GENERATE` via BigQuery connection (`all-things-cdp.us-central1.dcj-conn`) to **Gemini 3.5** (`gemini-3.5-flash` on **Gemini Platform**) with structured output schema for the `391` `GREY_ZONE` pairs and appends to the immutable audit ledger `dcj_match.person_match_adjudications`. |
| **Stage 60** | [`60_connected_components_and_tdm.sql`](sql/60_connected_components_and_tdm.sql) | Runs Two-Pass Connected Components + Contradiction/Twin Guard in `dcj_match` (`600` resolved entities, `0` false positives, `0` hairballs) and populates all **9 mastered Target Data Model (TDM) tables** in `dcj_tdm`. |
| **Stage 70** | [`70_property_graph.sql`](sql/70_property_graph.sql) | Declares `CREATE OR REPLACE PROPERTY GRAPH all-things-cdp.dcj_tdm.dcj_person_graph` with 8 Node Labels and 9 Edge Labels (and summary view `dcj_match.v_dcj_graph_summary`). |
| **Stage 80** | [`80_person_match_tvf_and_scorecard.sql`](sql/80_person_match_tvf_and_scorecard.sql) | Creates the callable real-time TVF `dcj_match.fn_person_match(...)` and benchmark views `dcj_match.v_dcj_method_comparison` and `dcj_match.v_dcj_scenario_scorecard`. |
| **Stage 90** | [`90_frontline_search_functions.sql`](sql/90_frontline_search_functions.sql) | Creates `dcj_match.fn_frontline_person_search(...)` and `dcj_match.fn_frontline_property_search(...)` powering the Frontline Search & Graph Studio (`dcj-frontline-search.html` + `backend/`). |
| **Stage 95** | [`95_test_use_cases_walkthrough.sql`](sql/95_test_use_cases_walkthrough.sql) | Automated BigQuery SQL regression & walkthrough suite validating all 8 person/property test scenarios and enforcing `100.00%` Precision & Recall via SQL `ASSERT` checks. |
| **Catalog** | [`populate_dcj_knowledge_catalog.py`](scripts/populate_dcj_knowledge_catalog.py) | Populates **BigQuery Knowledge Catalog** Business Glossary `dcj_person_cdm_glossary` (`6` categories, `118` terms & KPIs, `118` column `EntryLinks` across `dcj_tdm` and `dcj_match`, and synced BigQuery column descriptions). |

---

## 3. Harmonised 9-Table Target Data Model (`all-things-cdp.dcj_tdm`)

| TDM Table | Row Count | Primary Key (`STRING`) | Graph Role | Description & Survivorship Policy |
| :--- | ---: | :--- | :--- | :--- |
| `party` | `682` | `party_id` | Node: `Party` | Supertype across `600` Mastered Persons (`PER-*`), `75` Family Preservation Household Groups (`GRP-*`), and `7` Issuing/Initiating Organisations (`ORG-*`). |
| `person` | `600` | `person_id` | Node: `Person` | **1 Golden Row per resolved person**. Prioritizes `Verified` DOB over `Estimated`, preserves Aboriginal/Torres Strait Islander status, and rolls up `is_protected_person`. |
| `person_name` | `1,623` | `person_name_id` | Node: `PersonName` / Edge: `HAS_NAME` | Preserves all historical, alias, foster, and cultural/skin names across 16 `name_usage_code` values (`primary_name_flag = TRUE` marks the mastered legal name). |
| `person_identity_instrument` | `1,517` | `instrument_id` | Node: `IdentityInstrument` / Edges: `HOLDS_INSTRUMENT`, `ISSUED_BY` | Governs cross-system identifiers (`CHILDSTORY_ID`, `CNI`, `NDIS`, `SLK_581`) with issuing agency (`issuer_party_id`) and validity dates. |
| `address_location` | `260` | `address_id` | Node: `AddressLocation` | Deduplicated NSW GNAF spatial spine with `gnaf_pid`, street components, `latitude`, and `longitude`. |
| `address_relation` | `630` | `address_rel_id` | Edge: `LIVES_AT` | Temporal bridge linking `person_id` to `address_id` (`start_date`, `end_date`, `source_program`). |
| `person_source_linkage` | `1,150` | `linkage_id` | Node: `SourceRecord` / Edge: `RESOLVES_TO` | Maps every source record (`CP:CP-REC-*`, `FP:FP-REC-*`, `YJ:YJ-REC-*`) to its mastered `person_id`. |
| `party_relationship` | `593` | `party_rel_id` | Edge: `PARTY_RELATIONSHIP` | Harmonises all 78 SDM relationship types into `canonical_relationship_type` and `relationship_category` (`IMMEDIATE_FAMILY`, `EXTENDED_OR_KINSHIP_FAMILY`, `CARE_AND_GUARDIANSHIP`, `HOUSEHOLD_OR_DOMESTIC`, `SERVICE_OR_GROUP`). |
| `person_protection_event` | `45` | `protection_event_id` | Node: `ProtectionEvent` / Edges: `HAS_PROTECTION_EVENT`, `INITIATED_BY` | Tracks Domestic Violence, Child Safety, and Witness Protection restrictions per person. |

---

## 4. Target Property Graph (`all-things-cdp.dcj_tdm.dcj_person_graph`)

### Live ISO GQL Verification Queries (`us-central1`)

#### Query 1 — Traverse Source Lineage $\rightarrow$ Golden Person $\rightarrow$ Multi-Name History
```sql
SELECT *
FROM GRAPH_TABLE(
  `all-things-cdp.dcj_tdm.dcj_person_graph`
  MATCH (src:SourceRecord)-[r1:RESOLVES_TO]->(p:Person)-[r2:HAS_NAME]->(pn:PersonName)
  WHERE pn.name_usage_code IN ('Tribal Name', 'Alias', 'Foster Name', 'Adoptive Name', 'Preferred Name')
  COLUMNS (
    p.person_id AS golden_person_id,
    p.date_of_birth,
    p.indigenous_status,
    pn.name_usage_code,
    pn.full_name,
    src.source_program,
    src.source_record_id
  )
)
LIMIT 6;
```

#### Query 2 — Traverse Harmonised Kinship & Family Preservation Household Relationships
```sql
SELECT *
FROM GRAPH_TABLE(
  `all-things-cdp.dcj_tdm.dcj_person_graph`
  MATCH (p1:Party)-[rel:PARTY_RELATIONSHIP]->(p2:Party)
  COLUMNS (
    p1.party_id AS from_party_id,
    p1.party_display_name AS from_person,
    rel.relationship_type AS raw_sdm_relationship,
    rel.canonical_relationship_type AS canonical_relationship,
    rel.relationship_category,
    p2.party_id AS to_party_id,
    p2.party_display_name AS to_person,
    rel.source_program
  )
)
LIMIT 6;
```

**Verified Output (`all-things-cdp.dcj_tdm.dcj_person_graph`)**:
| `from_party_id` | `from_person` | `raw_sdm_relationship` | `canonical_relationship` | `relationship_category` | `to_party_id` | `to_person` | `source_program` |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `PER-023ECAC30F72` | Olivia Clark | `Grandchild` | `Grandchild` | `EXTENDED_OR_KINSHIP_FAMILY` | `PER-60B456AC4528` | Liam Clark | Child Protection |
| `PER-B0A700D4AF20` | Isla Young | `Group Member` | `Group Member` | `SERVICE_OR_GROUP` | `GRP-8023` | Young Family Group #23 | InfoShare- Family Preservation |
| `PER-B0A700D4AF20` | Isla Young | `Mother` | `Mother` | `IMMEDIATE_FAMILY` | `PER-FE6B9C856365` | Xav Young | Child Protection |
| `PER-92052B941E92` | Phoebe Mundy | `Group Member` | `Group Member` | `SERVICE_OR_GROUP` | `GRP-8074` | Mundy Twin Household #29 | InfoShare- Family Preservation |
| `PER-92052B941E92` | Phoebe Mundy | `Sister` | `Sister` | `IMMEDIATE_FAMILY` | `PER-D86C18D34377` | Chloe Mundy | Child Protection |

---

## 5. Callable Real-Time `fn_person_match` TVF Verification

Frontline intake applications and caseworkers can invoke `all-things-cdp.dcj_match.fn_person_match` directly in SQL:

```sql
SELECT
  match_rank,
  person_id,
  primary_full_name,
  all_known_names,
  date_of_birth,
  contributing_programs,
  matched_source_records,
  retrieved_by,
  ROUND(rrf_score, 4) AS rrf_score,
  ROUND(semantic_similarity, 4) AS semantic_sim,
  lexical_strength,
  hybrid_match_score,
  recommended_action
FROM `all-things-cdp.dcj_match.fn_person_match`(
  'Lachie', 'Smith', DATE '2009-01-01', 'M', NULL, 'PARRAMATTA', '2150', NULL, NULL
)
LIMIT 5;
```

**Verified Output**:
| `match_rank` | `person_id` | `primary_full_name` | `date_of_birth` | `contributing_programs` | `matched_source_records` | `retrieved_by` | `rrf_score` | `semantic_sim` | `hybrid_match_score` | `recommended_action` |
| :---: | :--- | :--- | :--- | :--- | :--- | :--- | ---: | ---: | ---: | :--- |
| **1** | `PER-698E72DBC085` | **Lachlan James Smith** | `2009-01-01` | Child Protection, InfoShare- Family Preservation, Youth Justice | `CHILDSTORY:CS-10001, INFOSHARE:FP-CL-50001, KIMS_YJ:YJ-30001` | `BOTH` | `0.0328` | `0.8454` | **`0.9459`** | `AUTO_LINK` |
| **2** | `PER-97D8A14FED04` | Lachlan Smith | `1975-01-01` | Child Protection, InfoShare- Family Preservation, Youth Justice | `CHILDSTORY:CS-10341, INFOSHARE:FP-CL-50316, KIMS_YJ:YJ-30066` | `BOTH` | `0.0313` | `0.7766` | `0.6718` | `GEMINI_ADJUDICATE_OR_STEWARD` |

---

## 6. Ground-Truth Benchmark & 8-Scenario Scorecard

### A. 3-Method Entity Resolution Comparison (`all-things-cdp.dcj_match.v_dcj_method_comparison`)

| Method | Resolved Entities (True = `600`) | Largest Cluster | Hairballs (`>6`) | True Pos (`TP`) | False Pos (`FP`) | False Neg (`FN`) | Precision | Recall | **F1 Score** |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `1_naive_slk_and_hub_cc` | `233` | `75` (Refuge Hub) | `1` | `647` | `4,420` | `8` | `12.77%` | `98.78%` | `0.2261` |
| `2_deterministic_idf_cc` | `641` | `4` | `0` | `538` | `120` (Twins) | `117` | `81.76%` | `82.14%` | `0.8195` |
| **`3_dcj_hybrid_genai` (Ours)** | **`600`** | **`3`** | **`0`** | **`655`** | **`0`** | **`0`** | **`100.00%`** | **`100.00%`** | **`1.0000`** |

### B. Per-Scenario Recall Scorecard (`all-things-cdp.dcj_match.v_dcj_scenario_scorecard`)

| Planted DCJ Scenario (`scenario_tag`) | True Pairs | Matched Pairs | Missed Pairs | Recall (`%`) |
| :--- | ---: | ---: | ---: | ---: |
| `ADOPTIVE_FOSTER_NAME_CHANGE` | `35` | `35` | `0` | **`100.0%`** |
| `ATSI_CULTURAL_SKIN_NAME` | `80` | `80` | `0` | **`100.0%`** |
| `CRISIS_REFUGE_HUB_HAIRBALL` | `25` | `25` | `0` | **`100.0%`** (`0` Refuge FPs) |
| `CROSSOVER_YOUTH` | `135` | `135` | `0` | **`100.0%`** |
| `DV_PROTECTED_PERSON_RELOCATION` | `30` | `30` | `0` | **`100.0%`** |
| `ESTIMATED_VS_VERIFIED_DOB` | `35` | `35` | `0` | **`100.0%`** |
| `EXTENDED_KINSHIP_AND_YJ_RELATIVES` | `210` | `210` | `0` | **`100.0%`** |
| `TWIN_SIBLING_SLK_COLLISION` | `60` | `60` | `0` | **`100.0%`** (`0` Twin FPs) |

---

## 7. BigQuery Knowledge Catalog Business Glossary (`dcj_person_cdm_glossary`)

Populated via [`scripts/populate_dcj_knowledge_catalog.py`](scripts/populate_dcj_knowledge_catalog.py) in `projects/all-things-cdp/locations/global/glossaries/dcj_person_cdm_glossary`:

- **6 Logical Categories**:
  1. `core_party_and_person` (*Core Party & Mastered Person Entities*)
  2. `names_and_identity_instruments` (*Person Names, Cultural Aliases & Identity Instruments*)
  3. `geospatial_and_address` (*GNAF Spatial Address & Temporal Residency*)
  4. `kinship_care_and_relationships` (*Kinship, Care & Household Relationships*)
  5. `source_linkage_and_protection` (*Cross-Program Source Linkage & Protection Events*)
  6. `hybrid_match_and_ai_audit` (*Hybrid Entity Resolution & Gemini Platform Adjudication Audit*)
- **118 Governed Glossary Terms** (`114` TDM & Audit column attribute terms + `4` Executive KPI terms: `kpi_hybrid_match_pairwise_f1`, `kpi_cross_program_client_overlap_rate`, `kpi_gnaf_geocoded_address_rate`, `kpi_protected_person_rls_coverage`).
- **118 Direct `EntryLinks`** attaching each Business Glossary Term directly to `Schema.<Column>` (and table-level KPIs) in **BigQuery Knowledge Catalog**, with all column descriptions synchronized to BigQuery `INFORMATION_SCHEMA.COLUMN_FIELD_PATHS`.
