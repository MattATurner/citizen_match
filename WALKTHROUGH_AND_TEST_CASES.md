# NSW DCJ — End-to-End Walkthrough & Test Use-Cases Guide

This guide catalogues all interactive walkthroughs and the **8 statutory, cultural, kinship, and crisis-property test use-cases** included in this repository, along with exact search probes, Golden Entity IDs, **Gemini Platform** adjudication behavior, and BigQuery SQL/ISO GQL verification steps.

---

## 1. Walkthrough Assets Included in This Repository

| Walkthrough Asset | File(s) in Repo | Target Audience & Purpose |
| :--- | :--- | :--- |
| **1. Frontline Person & Property Search + Graph Studio** | [`dcj-frontline-search.html`](dcj-frontline-search.html) + [`backend/`](backend/) + [`sql/90_frontline_search_functions.sql`](sql/90_frontline_search_functions.sql) | Google Search-style omnibox & 9-field structured intake probe calling `fn_frontline_person_search`, `fn_frontline_property_search`, and `GRAPH_TABLE(dcj_tdm.dcj_person_graph)`. Includes D3.js v7 interactive Property Graph (`Force`, `Radial`, `Lineage L→R`), **Gemini Platform** Adjudication Audit diff viewer, field survivorship, and Simple-View Google Map. |
| **2. BigQuery Studio Interactive Notebook (`45` cells)** | [`notebooks/cdp-walkthrough.ipynb`](notebooks/cdp-walkthrough.ipynb) + [`scripts/deploy_notebook_to_bq_studio.py`](scripts/deploy_notebook_to_bq_studio.py) | Hands-on engineering & data science walkthrough executing Stages `00` through `80` step-by-step via native `%%bigquery` and `%%bigquery --graph` cells against ephemeral or live datasets. |
| **3. Plain-English Customer Walkthrough Deck** | [`novice_walkthrough.html`](novice_walkthrough.html) | Non-technical / executive walkthrough explaining cross-program identity resolution, crisis refuge hub protection, twin guards, and auditability in plain English. |
| **4. Technical Architecture & Worked Case Deck (`8` slides)** | [`index.html`](index.html) + [`dcj_person_data_model.dendrite`](dcj_person_data_model.dendrite) | Deep architectural walkthrough covering `dcj_sdm` → `dcj_match` → `dcj_tdm`, Hybrid Vector + RRF scoring, **Gemini Platform** adjudication, **BigQuery Knowledge Catalog** governance, and Slide 7's end-to-end trace of `PER-698E72DBC085`. |
| **5. Functional Hierarchy Diagram (`DCJ-00` .. `DCJ-04`)** | [`dcj_fhd.html`](dcj_fhd.html) + [`dcj_fhd_spec.json`](dcj_fhd_spec.json) | Interactive split-screen Functional Decomposition covering SDM Ingestion, Bipartite/Hybrid Matching, **Gemini Platform** Adjudication, TDM Survivorship, and Frontline Search/Graph consumption. |
| **6. Automated SQL Regression & Use-Case Suite** | [`sql/95_test_use_cases_walkthrough.sql`](sql/95_test_use_cases_walkthrough.sql) | Executable BigQuery SQL verification script testing all 8 scenarios plus `ASSERT` gates enforcing `100.00%` Precision, `100.00%` Recall (`1.0000` F1), `600` resolved entities, and `0` hairball clusters. |

---

## 2. Complete Catalog of the 8 Test Use-Cases

Every use-case below can be tested interactively in [`dcj-frontline-search.html`](dcj-frontline-search.html) (via the search bar or 1-click scenario chips) or executed in SQL via [`sql/95_test_use_cases_walkthrough.sql`](sql/95_test_use_cases_walkthrough.sql).

### Use-Case 1 — Crossover Youth Diminutive Across All 3 Programs (`CROSSOVER_YOUTH`)
- **Frontline Search Query**: `Lachie Smith` (or structured probe: `given_name='Lachie'`, `family_name='Smith'`, `dob='2009-01-01'`)
- **Expected `#1` Entity**: `PER-698E72DBC085` — **Lachlan James Smith** (DOB `2009-01-01`, `VERIFIED`)
- **Originating SDM Records (`3` Programs)**:
  - Child Protection (`ChildStory`): `CHILDSTORY:CS-10001` (*Lachlan James Smith*)
  - Family Preservation (`InfoShare`): `INFOSHARE:FP-CL-50001` (*Lachie Smith*)
  - Youth Justice (`KIMS`): `KIMS_YJ:YJ-30001` (*Lachie J Smith*)
- **What It Proves**:
  1. Bridges nickname/diminutive (`Lachie` ↔ `Lachlan`) across all three NSW DCJ divisions (`135/135` pairs, `100.0%` recall).
  2. Keeps co-resident father **Lachlan Smith** (`PER-97D8A14FED04`, DOB `1975-01-01` at `160 DARLING ST, PENRITH NSW 2750`) strictly separate via DOB contradiction & kinship guard while linking father ↔ son via `PARTY_RELATIONSHIP` (`Father` / `Son`) in `dcj_person_graph`.

---

### Use-Case 2 — Co-Resident Twins `SLK-581` Collision Guard (`TWIN_SIBLING_SLK_COLLISION`)
- **Frontline Search Query**: `Chloe Clark`
- **Expected `#1` Entity**: `PER-0EA1A1464868` — **Chloe Rose Clark** (DOB `2012-05-05`, `34 BROLGA RD, KEMPSEY NSW 2440`)
- **Kept-Separate Twin Entity**: `PER-B43AEA450C91` — **Phoebe Clark** (DOB `2012-05-05`, same address, same household)
- **What It Proves**:
  1. Naive deterministic matching merges `120` twin/sibling pairs because twins share surname, DOB, gender, address, parent phone, and often identical/near-identical AIHW `SLK-581` statistical linkage keys.
  2. Stage 40 flags `twin_or_sibling_trap = TRUE` and routes the pair to Stage 50 (**Gemini Platform** Adjudicator + Twin Guard), recording an immutable `NO_MATCH` / `UNLINK` decision with human-readable statutory rationale in `dcj_match.person_match_adjudications` (`60/60` true twin pairs resolved, `0` false twin merges).
  3. In the **Property Graph Visualisation**, toggling **✓ Showing Vetoed Pairs** renders the crimson dashed `VETO: TWIN GUARD` edge between Chloe's and Phoebe's SDM records so caseworkers can inspect why they were kept separate and pivot directly to Phoebe's dossier.

---

### Use-Case 3 — First Nations Cultural / Skin Name Bridge (`ATSI_CULTURAL_SKIN_NAME`)
- **Frontline Search Query**: `Allira Campbell`
- **Expected `#1` Entity**: `PER-96A3C7847236` — **Alice Campbell** (`Aboriginal`, Gamilaraay cultural name **Allira Campbell**)
- **What It Proves**:
  1. Preserves both `Legal Name` (*Alice Campbell*, `primary_name_flag = TRUE`) and `Tribal/Cultural Name` (*Allira Campbell*) in `dcj_tdm.person_name` (`HAS_NAME` edges in `dcj_person_graph`).
  2. Searching by cultural/community name immediately retrieves the unified Golden Person via `AI.EMBED` + `VECTOR_SEARCH` + `RRF` (`80/80` cultural alias pairs, `100.0%` recall) without overwriting cultural identity.

---

### Use-Case 4 — Pre-Adoptive to Post-Adoption Surname Change (`ADOPTIVE_FOSTER_NAME_CHANGE`)
- **Frontline Search Query**: `Oliver Peachey`
- **Expected `#1` Entity**: `PER-582C6E28FD39` — **Oliver Lee Al-Mansoor**
- **What It Proves**:
  1. Links historical `Pre-Adoptive Name` (*Oliver Peachey*) to mastered `Adopted Name` (*Oliver Lee Al-Mansoor*) when zero surname tokens overlap, using persistent identifiers, DOB, and semantic vector retrieval (`35/35` pairs, `100.0%` recall).
  2. Displays effective start/end windows across all historical name rows in the **Multi-Name, Cultural & Alias Timeline**.

---

### Use-Case 5 — Domestic Violence / Statutory Protected Person Safety (`DV_PROTECTED_PERSON_RELOCATION`)
- **Frontline Search Query**: `Aaliyah Robinson`
- **Expected `#1` Entity**: `PER-B26A1D09250D` — **Aaliyah Robinson** (`is_protected_person = TRUE`)
- **What It Proves**:
  1. Safely links relocated DV/statutory-protected client records across programs (`30/30` pairs, `100.0%` recall) while rolling up `LOGICAL_OR(is_protected)` to the Golden Person.
  2. Traverses `(p:Person)-[:HAS_PROTECTION_EVENT]->(pe:ProtectionEvent)-[:INITIATED_BY]->(org:Party)` in `dcj_person_graph` and surfaces an immediate **Statutory Confidentiality & Safety Restriction** alert banner at the top of the frontline dossier.

---

### Use-Case 6 — Estimated `01-Jan` Intake DOB vs Verified Registry DOB (`ESTIMATED_VS_VERIFIED_DOB`)
- **Frontline Search Query**: `Alexander Robinson`
- **Expected `#1` Entity**: `PER-5AC911336C97` — **Alexander Robinson**
- **What It Proves**:
  1. Youth Justice / crisis intake records frequently record an estimated `YYYY-01-01` (`dob_status = 'ESTIMATED'`) when exact birth certificates are unavailable at intake, causing exact-DOB blockers to miss matches.
  2. Hybrid RRF + **Gemini Platform** adjudication links the records (`35/35` pairs, `100.0%` recall), and `dcj_match.field_survivorship` deterministically selects the `VERIFIED` ChildStory DOB over the `ESTIMATED` DOB with full field-level provenance (`was_contested = TRUE`).

---

### Use-Case 7 — 30-Resident Crisis Refuge Hub Suppression (`CRISIS_REFUGE_HUB_HAIRBALL`)
- **Frontline Search Query**: `10 Great Western Hwy Parramatta` (Property mode or All mode)
- **Expected `#1` Property**: `GNAF-NSW-HUB-0001` — **PARRAMATTA WOMEN AND CHILDREN SAFE REFUGE** (`10 GREAT WESTERN HWY, PARRAMATTA NSW 2150`)
- **What It Proves**:
  1. Naive graph clustering collapses `75` unrelated source records sharing a crisis refuge address/landline into a catastrophic **hairball cluster** (`4,420` false-positive pairs, `12.77%` precision).
  2. Stage 20's Bipartite Identifier Graph detects `degree > 5` on `GNAF:GNAF-NSW-HUB-0001` (`is_promiscuous = TRUE`, `idf_weight = 0.000`), completely preventing false merges (`0` hairballs) while **preserving every `LIVES_AT` edge in `dcj_person_graph`** so frontline safety workers searching the refuge address see all `30` current/historical residents, protected-resident flags, and intra-refuge kinship links.

---

### Use-Case 8 — Multi-Generational Household & Extended Kinship Network (`EXTENDED_KINSHIP_AND_YJ_RELATIVES`)
- **Frontline Search Query**: `160 Darling St Penrith` (Property `GNAF-NSW-00003`) or Person `PER-698E72DBC085`
- **What It Proves**:
  1. Harmonises all `78` raw SDM relationship strings into `5` canonical categories (`IMMEDIATE_FAMILY`, `EXTENDED_OR_KINSHIP_FAMILY`, `CARE_AND_GUARDIANSHIP`, `HOUSEHOLD_OR_DOMESTIC`, `SERVICE_OR_GROUP`) across `593` `PARTY_RELATIONSHIP` edges.
  2. Enables 1-hop and 2-hop ISO GQL traversal across parents, siblings, grandparents, kinship carers, Family Preservation household groups (`GRP-*`), and NGOs (`ORG-*`), with interactive click-to-pivot in the D3 Property Graph Studio (`210/210` kinship-context pairs, `100.0%` recall).

---

## 3. Running the Full Pipeline & Test Suite from CLI

```bash
# 1. Run full idempotent SDM -> Hybrid Match -> Gemini Platform -> TDM -> Property Graph -> TVFs -> Verification
./run.sh --all

# 2. Run only the 3-method benchmark, 8-scenario scorecard, and 9-test SQL regression suite
./run.sh --verify

# 3. Deploy/refresh the 45-cell walkthrough notebook in BigQuery Studio
python3 scripts/deploy_notebook_to_bq_studio.py \
  --project all-things-cdp \
  --location us-central1 \
  --notebook-id cdp-walkthrough \
  --display-name cdp-walkthrough \
  --file notebooks/cdp-walkthrough.ipynb

# 4. Deploy/update the Cloud Run Frontline Search & Graph API
./backend/deploy_api.sh
```
