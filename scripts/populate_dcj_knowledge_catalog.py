#!/usr/bin/env python3
"""
Populates the BigQuery Knowledge Catalog Business Glossary (`dcj_person_cdm_glossary`)
for the NSW Department of Communities and Justice (DCJ) Target Data Model (TDM),
attaches every term directly to its physical BigQuery table column (`Schema.<Column>`)
across all 9 TDM tables + the GenAI Adjudicator Audit Ledger via `definition` EntryLinks,
and syncs enriched descriptions to BigQuery.
"""

from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request

PROJECT_ID = os.environ.get("DCJ_PROJECT", "all-things-cdp")
DATASET_ID = os.environ.get("DCJ_TDM_DS", "dcj_tdm")
MATCH_DATASET_ID = os.environ.get("DCJ_MATCH_DS", "dcj_match")
BQ_LOCATION = os.environ.get("DCJ_LOCATION", "us-central1").lower()
GLOSSARY_ID = "dcj_person_cdm_glossary"
GLOSSARY_LOC = "global"

DATAPLEX_TYPES_PROJECT = "655216118709"
DEFINITION_LINK_TYPE = (
    f"projects/{DATAPLEX_TYPES_PROJECT}/locations/global/entryLinkTypes/definition"
)


def get_adc_token() -> str:
    res = subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    return res.stdout.strip()


def get_project_number(project_id: str) -> str:
    res = subprocess.run(
        ["gcloud", "projects", "describe", project_id, "--format=value(projectNumber)"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    return res.stdout.strip()


def api_request(
    method: str, url: str, token: str, project_id: str, payload: dict | None = None
) -> dict:
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "x-goog-user-project": project_id,
    }
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8")
        raise RuntimeError(f"HTTP {e.code} on {method} {url}: {err_body}") from e


def sanitize_hyphen_id(raw: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    if not s or not s[0].isalpha():
        s = "link-" + s
    if len(s) > 63:
        h = hashlib.md5(s.encode("utf-8")).hexdigest()[:6]
        return f"{s[:56].rstrip('-')}-{h}"
    return s.rstrip("-")


def sanitize_snake_id(raw: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", raw.lower()).strip("_")
    if not s or not s[0].isalpha():
        s = "term_" + s
    if len(s) > 63:
        h = hashlib.md5(s.encode("utf-8")).hexdigest()[:6]
        return f"{s[:56].rstrip('_')}_{h}"
    return s.rstrip("_")


CATEGORIES = [
    {
        "id": "core_party_and_person",
        "displayName": "1. Core Party & Golden Person Entities",
        "description": "Root party entities (person, group, organisation) and survivored human individual demographics in the DCJ Target Data Model (`party`, `person`).",
    },
    {
        "id": "names_and_identity_instruments",
        "displayName": "2. Person Names & Identity Instruments",
        "description": "Current and historical person names across all 16 DCJ usage contexts (Legal, Preferred, Adopted, Pre-Adoptive, Tribal/Cultural, Alias) and official/statistical identity instruments (CNI, NDIS, ChildStory ID, SLK-581).",
    },
    {
        "id": "geospatial_and_address",
        "displayName": "3. Geospatial GNAF Locations & Address Relations",
        "description": "De-duplicated physical locations validated against GNAF across 6 centroid/locality record types and temporal person-to-address associations (`address_location`, `address_relation`).",
    },
    {
        "id": "kinship_care_and_relationships",
        "displayName": "4. Kinship, Care & Party Relationships",
        "description": "Directed party-to-party relationships covering all 78 DCJ familial, kinship, Aboriginal community, foster/carer, and service group relationship types (`party_relationship`).",
    },
    {
        "id": "source_linkage_and_protection",
        "displayName": "5. Cross-Program Source Linkage & Statutory Protection",
        "description": "Lineage mapping between Golden Person IDs and originating SDM records (ChildStory, InfoShare, KIMS) plus Domestic & Family Violence / statutory confidentiality protection events (`person_source_linkage`, `person_protection_event`).",
    },
    {
        "id": "hybrid_match_and_ai_audit",
        "displayName": "6. Hybrid Entity Resolution, RRF & GenAI Adjudication Audit",
        "description": "Bipartite Identifier IDF rarity, Reciprocal Rank Fusion (RRF), and immutable Gemini Platform adjudication verdicts (`person_match_adjudications`, `resolution_edges`, and CDM KPIs).",
    },
]

# Full table and column glossary specifications across all 9 TDM tables + Audit Ledger
TABLE_SPECS = {
    "party": {
        "category": "core_party_and_person",
        "table_description": "Root entity table in the NSW DCJ Target Data Model (`dcj_tdm.party`) governing all persons, Family Preservation groups, and statutory/NGO organisations.",
        "columns": {
            "party_id": ("Root Party Identifier (party_id)", "Canonical STRING primary key (`PER-...`, `GRP-...`, `ORG-...`) identifying a resolved person, family group, or organisation across the DCJ relational TDM and `dcj_person_graph` Property Graph."),
            "party_id_int64": ("Numeric Party ID (party_id_int64)", "Deterministic 64-bit integer fingerprint of `party_id` maintained for backward compatibility with legacy INT64 foreign-key schemas."),
            "party_type_code": ("Party Type Code (party_type_code)", "Low-cardinality classification of the party entity. Valid values: `'person'` (resolved human individual), `'group'` (Family Preservation client group), or `'organisation'` (service provider or statutory issuing authority)."),
            "party_display_name": ("Party Display Name (party_display_name)", "Human-readable label for the party (primary full name for a person, group label for a Family Preservation group, or official agency name for an organisation)."),
            "created_timestamp": ("Party Creation Timestamp (created_timestamp)", "Earliest UTC audit timestamp when the party was first ingested or mastered in the DCJ Target Data Model."),
        },
    },
    "person": {
        "category": "core_party_and_person",
        "table_description": "Mastered Golden Person table (`dcj_tdm.person`) containing one survivored row per resolved human individual across Child Protection (ChildStory), Family Preservation (InfoShare), and Youth Justice (KIMS).",
        "columns": {
            "person_id": ("Golden Person Identifier (person_id)", "Unique mastered identifier (`PER-...`, 1:1 with `party.party_id`) derived via MD5 hashing of the cluster's anchor source person ID after Two-Pass Connected Components and Contradiction Pruning."),
            "gender": ("Survivored Person Gender (gender)", "Survivored biological/reported gender of the individual (`'Male'`, `'Female'`, `'Unknown'`), selected using source-trust and recency survivorship rules."),
            "date_of_birth": ("Survivored Date of Birth (date_of_birth)", "Known or believed Date of Birth (`DATE`). Prioritises `VERIFIED` ChildStory/KIMS dates over `ESTIMATED` (`01-01-YYYY`) intake dates during field-level survivorship."),
            "dob_certainty_code": ("DOB Certainty Code (dob_certainty_code)", "Indicates accuracy of `date_of_birth`: `'VERIFIED'` (confirmed against birth certificate or statutory record) or `'ESTIMATED'` (approximate intake date such as 1st of January)."),
            "date_of_death": ("Date of Death (date_of_death)", "Recorded Date of Death (`DATE`) where `VITAL_STATUS` indicates deceased; `NULL` for living individuals."),
            "dod_certainty_code": ("DOD Certainty Code (dod_certainty_code)", "Accuracy indicator for `date_of_death` (`'VERIFIED'`, `'ESTIMATED'`, or `NULL`)."),
            "is_protected_person": ("Protected Person Flag (is_protected_person)", "Boolean security flag (`TRUE`/`FALSE`) set to `TRUE` if ANY contributing source record marks `PROTECTED_INDIVIDUAL = 'Y'` or active Domestic & Family Violence restriction. Mandatory predicate for Row-Level Security (RLS)."),
            "is_cald": ("CALD Indicator (is_cald)", "Boolean indicator (`TRUE`/`FALSE`) denoting whether the person is Culturally and Linguistically Diverse (derived from primary spoken language other than English or interpreter need)."),
            "indigenous_status": ("Indigenous Status (indigenous_status)", "Aboriginal and/or Torres Strait Islander origin status (`'Aboriginal'`, `'Torres Strait Islander'`, `'Aboriginal and Torres Strait Islander'`, or `'No'`)."),
            "source_program": ("Authoritative Source Program (source_program)", "Primary authoritative DCJ program domain (`'Child Protection'`, `'InfoShare- Family Preservation'`, or `'Youth Justice'`) that governed the golden record's primary survivorship."),
        },
    },
    "person_name": {
        "category": "names_and_identity_instruments",
        "table_description": "Tracks all current and historical names (`dcj_tdm.person_name`) across the 16 DCJ `name_usage_code` contexts (Legal, Preferred, Adopted, Pre-Adoptive, Tribal/Cultural, Alias, Married, etc.) for every Golden Person.",
        "columns": {
            "person_name_id": ("Person Name Record ID (person_name_id)", "Unique MD5-derived primary key (`PNM-...`) hashed over `(person_id, given_name, middle_name, family_name, name_usage_code, primary_name_flag)`."),
            "person_id": ("Linked Golden Person ID (person_id)", "Foreign key referencing `dcj_tdm.person.person_id`."),
            "name_usage_code": ("Name Usage Code (name_usage_code)", "Business context of the name across the 16 DCJ usage codes: `'Legal Name'`, `'Preferred Name'`, `'Adopted Name'`, `'Pre-Adoptive Name'`, `'Name at Birth'`, `'Tribal/Cultural Name'`, `'Alias Name'`, `'Married Name'`, `'Previous Name'`, `'New Born Identification Name'`, `'Nick Name'`, `'Professional Name'`, `'Trading Name'`, `'Business Entity Name'`, `'Unspecified'`, or `NULL`."),
            "primary_name_flag": ("Primary Name Flag (primary_name_flag)", "Boolean flag (`TRUE`/`FALSE`) indicating the single active preferred display name for this `person_id`."),
            "name_title": ("Honorific Title (name_title)", "Honorific prefix (`Mr`, `Ms`, `Mx`, `Dr`) if captured."),
            "given_name": ("Given Name (given_name)", "First or given name as asserted in the source record (retaining cultural, diminutive, or birth spelling)."),
            "middle_name": ("Middle Name (middle_name)", "Middle name or initial(s) as asserted in the source system."),
            "family_name": ("Family Name / Surname (family_name)", "Surname or family name (capturing pre-adoptive, adopted, maiden, or married surname history)."),
            "name_suffix": ("Name Suffix (name_suffix)", "Generational or professional suffix (`Jr`, `Sr`, `III`)."),
            "full_name": ("Concatenated Full Name (full_name)", "Formatted full name (`given_name middle_name family_name`) indexed for search and graph display."),
            "start_date": ("Name Effective Start Date (start_date)", "Timestamp when this name usage was first observed or became effective."),
            "end_date": ("Name Effective End Date (end_date)", "Timestamp when this name usage ended (populated for superseded `'Pre-Adoptive Name'`, `'Name at Birth'`, and `'Previous Name'` rows; `NULL` for currently active names)."),
            "source_program": ("Asserting Source Program (source_program)", "DCJ program domain (`'Child Protection'`, `'InfoShare- Family Preservation'`, `'Youth Justice'`) that contributed this name record."),
        },
    },
    "person_identity_instrument": {
        "category": "names_and_identity_instruments",
        "table_description": "Official government and statistical identity instruments (`dcj_tdm.person_identity_instrument`) linked to each Golden Person, including NSW Police CNI, NDIS Number, ChildStory ID, and AIHW SLK-581.",
        "columns": {
            "instrument_id": ("Identity Instrument ID (instrument_id)", "Unique primary key (`INST-...`) for the identity instrument record."),
            "instrument_id_int64": ("Numeric Instrument ID (instrument_id_int64)", "Deterministic 64-bit integer instrument key for Data Dictionary compatibility."),
            "person_id": ("Instrument Holder Person ID (person_id)", "Foreign key referencing `dcj_tdm.person.person_id`."),
            "instrument_type_code": ("Instrument Type Code (instrument_type_code)", "Category of identity instrument: `'CNI'` (NSW Police Central Names Index), `'NDIS'` (National Disability Insurance Scheme number), `'CHILDSTORY_ID'` (Child Protection identifier), or `'SLK_581'` (AIHW Statistical Linkage Key 581)."),
            "designation_number": ("Instrument Designation Number (designation_number)", "Exact alphanumeric reference or identifier value printed/recorded on the instrument."),
            "issuer_party_id": ("Issuing Authority Party ID (issuer_party_id)", "Foreign key referencing `dcj_tdm.party.party_id` for the issuing organisation (`ORG-NSW-POLICE`, `ORG-NDIA`, `ORG-DCJ-CP`, `ORG-AIHW`)."),
            "issuer_party_id_int64": ("Numeric Issuer Party ID (issuer_party_id_int64)", "Numeric party ID of the issuing organisation."),
            "issue_date": ("Instrument Issue Date (issue_date)", "Date the instrument or identifier was issued or verified."),
            "expiry_date": ("Instrument Expiry Date (expiry_date)", "Date the instrument or package expires."),
            "status_code": ("Instrument Status Code (status_code)", "Operational validity status: `'Verified'`, `'Active'`, or `'Statistical'` (for `SLK_581`, which is a statistical linkage key and NOT a unique identifier)."),
            "is_primary": ("Primary Instrument Flag (is_primary)", "Boolean flag indicating whether this instrument is a primary deterministic anchor (`TRUE` for `CNI` and `CHILDSTORY_ID`; `FALSE` for `SLK_581`)."),
            "source_program": ("Instrument Source Program (source_program)", "DCJ program domain that recorded this identity instrument."),
        },
    },
    "address_location": {
        "category": "geospatial_and_address",
        "table_description": "De-duplicated physical locations (`dcj_tdm.address_location`) across NSW standardised against the Geocoded National Address File (GNAF).",
        "columns": {
            "id": ("GNAF Location Identifier (id)", "Unique primary key (`GNAF-NSW-...`) identifying a de-duplicated physical address in NSW."),
            "building_name": ("Building or Facility Name (building_name)", "Property or facility name (e.g. Women's Crisis Refuge or Youth Residential Care Hub)."),
            "lot_number_prefix": ("Lot Number Prefix (lot_number_prefix)", "Prefix preceding the cadastral lot number."),
            "lot_number": ("Cadastral Lot Number (lot_number)", "Cadastral lot number for the property."),
            "lot_number_suffix": ("Lot Number Suffix (lot_number_suffix)", "Suffix following the cadastral lot number."),
            "flat_type": ("Sub-Dwelling Flat Type (flat_type)", "Sub-dwelling descriptor (`UNIT`, `FLAT`, `APT`, `VILLA`)."),
            "flat_number_prefix": ("Flat Number Prefix (flat_number_prefix)", "Prefix before the unit/flat number."),
            "flat_number": ("Flat / Unit Number (flat_number)", "Unit or apartment number within a multi-dwelling building."),
            "flat_number_suffix": ("Flat Number Suffix (flat_number_suffix)", "Suffix after the unit/flat number."),
            "number_first_prefix": ("Street Number First Prefix (number_first_prefix)", "Prefix before the primary street number."),
            "number_first": ("Street Number First (number_first)", "Primary street number on the thoroughfare."),
            "number_first_suffix": ("Street Number First Suffix (number_first_suffix)", "Suffix after the primary street number."),
            "number_last_prefix": ("Street Number Last Prefix (number_last_prefix)", "Prefix before the upper street number in a ranged address."),
            "number_last": ("Street Number Last (number_last)", "Upper street number for ranged properties (e.g., `10-14`)."),
            "number_last_suffix": ("Street Number Last Suffix (number_last_suffix)", "Suffix after the upper street number."),
            "street_name": ("Thoroughfare Street Name (street_name)", "Official uppercase street name (`MACQUARIE`, `GEORGE`, `GREAT WESTERN`)."),
            "street_type": ("Street Type Code (street_type)", "Standardised thoroughfare type (`ST`, `RD`, `AV`, `PD`, `DR`, `PL`, `HWY`)."),
            "street_type_suffix": ("Street Directional Suffix (street_type_suffix)", "Directional suffix (`NORTH`, `SOUTH`, `EAST`, `WEST`)."),
            "suburb": ("Locality / Suburb Name (suburb)", "Official gazetted NSW suburb or town (`PARRAMATTA`, `BLACKTOWN`, `DUBBO`, `KEMPSEY`, etc.)."),
            "postcode": ("Australian Postcode (postcode)", "4-digit NSW postal code (`2000`–`2999`)."),
            "state": ("State Territory Code (state)", "Australian state abbreviation (`NSW`)."),
            "latitude": ("Geocode Latitude (latitude)", "GDA2020 / WGS84 decimal latitude of the address centroid."),
            "longitude": ("Geocode Longitude (longitude)", "GDA2020 / WGS84 decimal longitude of the address centroid."),
            "full_address": ("Formatted Full Address (full_address)", "Complete standardised street address string used for display and BM25/vector indexing."),
            "record_type": ("GNAF Geocode Record Type (record_type)", "Official GNAF precision category across the 6 DCJ codes: `'BUILDING CENTROID'`, `'PROPERTY CENTROID'`, `'GAP GEOCODE'`, `'LOCALITY'`, `'STREET LOCALITY'`, or `'PROPERTY CENTROID MANUAL'`."),
        },
    },
    "address_relation": {
        "category": "geospatial_and_address",
        "table_description": "Temporal association table (`dcj_tdm.address_relation`) linking each Golden Person to their current and historical GNAF address locations.",
        "columns": {
            "address_relation_id": ("Address Relation ID (address_relation_id)", "Unique MD5-derived primary key (`AREL-...`) for the person-to-address association."),
            "person_id": ("Resident Golden Person ID (person_id)", "Foreign key referencing `dcj_tdm.person.person_id`."),
            "address_location_id": ("Linked GNAF Location ID (address_location_id)", "Foreign key referencing `dcj_tdm.address_location.id`."),
            "primary_address_flag": ("Primary Address Flag (primary_address_flag)", "Boolean flag (`TRUE`/`FALSE`) indicating the person's current primary residential address."),
            "address_relation_start_date": ("Address Effective Start Date (address_relation_start_date)", "Timestamp when the person began residing at or using this address."),
            "address_relation_end_date": ("Address Effective End Date (address_relation_end_date)", "Timestamp when usage of this address ended (`NULL` for current primary address; populated for prior addresses after DV relocation or house move)."),
            "address_purpose": ("Address Usage Purpose (address_purpose)", "Operational purpose of the address: `'Residential'` or `'Crisis / Short-Term Accommodation'`."),
            "source_program": ("Address Source Program (source_program)", "DCJ program domain that recorded this address association."),
        },
    },
    "person_source_linkage": {
        "category": "source_linkage_and_protection",
        "table_description": "Cross-program lineage crosswalk (`dcj_tdm.person_source_linkage`) mapping every SDM source record in ChildStory, InfoShare, and Youth Justice KIMS to its mastered Golden Person ID.",
        "columns": {
            "linkage_id": ("Source Linkage ID (linkage_id)", "Unique primary key (`LNK-...`) for the golden-to-source linkage row."),
            "person_id": ("Mastered Golden Person ID (person_id)", "Foreign key referencing `dcj_tdm.person.person_id`."),
            "source_record_id": ("Staged Source Record Key (source_record_id)", "Prefixed staging record identifier (`CP:CP-REC-...`, `FP:FP-CL-...`, `YJ:YJ-...`) used as the `SourceRecord` node key in `dcj_person_graph`."),
            "source_app_id": ("Originating Agency Application ID (source_app_id)", "Code identifying the source system application: `'CHILDSTORY'`, `'INFOSHARE'`, or `'KIMS_YJ'`."),
            "source_person_id": ("Native Source Person ID (source_person_id)", "Native alphanumeric person identifier in the originating system (`CS-10001`, `FP-CL-50001`, `YJ-30001`)."),
            "source_program": ("Source Program Domain (source_program)", "DCJ business domain (`'Child Protection'`, `'InfoShare- Family Preservation'`, `'Youth Justice'`), used for Row-Level Security segmentation."),
            "is_mastered": ("Mastered Record Status (is_mastered)", "Boolean indicator (`TRUE` = linked into a verified Golden Person record; `FALSE` = unmastered raw record)."),
            "last_updated_ts": ("Linkage Verification Timestamp (last_updated_ts)", "UTC timestamp when the entity resolution pipeline last verified this linkage."),
        },
    },
    "party_relationship": {
        "category": "kinship_care_and_relationships",
        "table_description": "Directed party-to-party relationship graph table (`dcj_tdm.party_relationship`) capturing all 78 DCJ familial, kinship, Aboriginal community, carer, and group relationships.",
        "columns": {
            "relationship_id": ("Party Relationship ID (relationship_id)", "Unique MD5-derived primary key (`REL-...`) for the directed relationship edge."),
            "subject_party_id": ("Subject 'From' Party ID (subject_party_id)", "Foreign key referencing `dcj_tdm.party.party_id` for the subject ('From') side of the relationship."),
            "related_party_id": ("Related 'To' Party ID (related_party_id)", "Foreign key referencing `dcj_tdm.party.party_id` for the related ('To') side of the relationship."),
            "relationship_type": ("Raw DCJ Relationship Type (relationship_type)", "Exact relationship code asserted by the source system across all 78 DCJ values (e.g., `'Mother'`, `'Father'`, `'Sibling'`, `'ATSI Community Relationship'`, `'Carer (Family)'`, `'Legal Guardian'`, `'Step Child'`, `'Group Member'`)."),
            "canonical_relationship_type": ("Canonical Relationship Type (canonical_relationship_type)", "Harmonised relationship label resolving raw spelling/hyphenation variants (`'Step child'` -> `'Step Child'`, `'Step Parent'` -> `'Step-Parent'`, `'Grand Parent'` -> `'Grandparent'`)."),
            "relationship_category": ("High-Level Relationship Category (relationship_category)", "Roll-up analytical grouping: `'IMMEDIATE_FAMILY'`, `'STEP_OR_BLENDED_FAMILY'`, `'EXTENDED_OR_KINSHIP_FAMILY'`, `'CARER_OR_GUARDIANSHIP'`, `'PRENATAL_OR_UNBORN'`, `'FORMER_PARTNER'`, `'SERVICE_OR_GROUP'`, or `'OTHER_SOCIAL'`."),
            "start_date": ("Relationship Start Date (start_date)", "Timestamp when the relationship became effective or was first recorded."),
            "end_date": ("Relationship End Date (end_date)", "Timestamp when the relationship ended (`NULL` for active relationships)."),
            "comment": ("Relationship Provenance Note (comment)", "Audit note recording the originating source relation ID or Youth Justice KIMS relative extraction context."),
            "source_program": ("Relationship Source Program (source_program)", "DCJ program domain that asserted this party relationship."),
        },
    },
    "person_protection_event": {
        "category": "source_linkage_and_protection",
        "table_description": "Statutory confidentiality and Domestic & Family Violence (DV) restriction log (`dcj_tdm.person_protection_event`) governing restricted access windows for protected individuals.",
        "columns": {
            "protection_event_id": ("Protection Event ID (protection_event_id)", "Unique primary key (`PROT-...`) for the statutory restriction event."),
            "person_id": ("Protected Golden Person ID (person_id)", "Foreign key referencing `dcj_tdm.person.person_id`."),
            "protect_start_date": ("Protection Start Timestamp (protect_start_date)", "UTC timestamp when the confidentiality or DV safety restriction took effect."),
            "protect_end_date": ("Protection End Timestamp (protect_end_date)", "UTC timestamp when the restriction expired (`NULL` indicates an active restriction requiring Row-Level Security enforcement)."),
            "reason": ("Protection Restriction Reason (reason)", "Statutory or safety justification (e.g., `'Domestic & Family Violence Safety / Statutory Confidentiality Restriction'`)."),
            "initiator_party_id": ("Initiating Authority Party ID (initiator_party_id)", "Foreign key referencing `dcj_tdm.party.party_id` for the authority that requested the restriction (`ORG-DCJ-CP`)."),
            "initiator_party_id_int64": ("Numeric Initiator Party ID (initiator_party_id_int64)", "Numeric party ID of the initiating authority for legacy DDL compatibility."),
            "source_program": ("Protection Source Program (source_program)", "DCJ program domain enforcing the protection event."),
        },
    },
    "person_match_adjudications": {
        "dataset": "dcj_match",
        "category": "hybrid_match_and_ai_audit",
        "table_description": "Immutable append-only audit ledger (`dcj_match.person_match_adjudications`) storing every Gemini Platform (`AI.GENERATE`) entity resolution verdict, confidence score, and statutory rationale.",
        "columns": {
            "record_id_a": ("Candidate Pair Record A (record_id_a)", "First staged source record ID (`CP:...`, `FP:...`, `YJ:...`) in the grey-zone comparison pair."),
            "record_id_b": ("Candidate Pair Record B (record_id_b)", "Second staged source record ID (`CP:...`, `FP:...`, `YJ:...`) in the grey-zone comparison pair."),
            "verdict": ("Gemini Adjudicator Verdict (verdict)", "Canonical decision returned by Gemini Platform: `'MATCH'`, `'NO_MATCH'`, or `'UNCERTAIN'`."),
            "confidence": ("Adjudicator Confidence Score (confidence)", "Calibrated confidence score (`0.0` to `1.0`). Verdicts with `verdict = 'MATCH'` and `confidence >= 0.85` (and zero structural contradictions) auto-link; `0.60–0.85` route to the Data Steward queue."),
            "rationale": ("Statutory Audit Rationale (rationale)", "Plain-English explanation written by the Gemini Adjudicator justifying why the two records were linked or kept separate."),
            "decisive_evidence": ("Decisive Evidence Signal (decisive_evidence)", "Primary corroborating or refuting signal cited by the adjudicator (e.g. shared CNI/NDIS, adoptive surname alias, or twin SLK-581 collision)."),
            "contradiction": ("Explicit Contradiction Cited (contradiction)", "Specific conflicting attribute noted by the adjudicator (e.g. twin/sibling distinct forenames born on the same date at the same address)."),
            "scenario_classified": ("Classified Domain Archetype (scenario_classified)", "DCJ entity resolution archetype identified by the adjudicator (`CROSSOVER_YOUTH`, `TWIN_SIBLING_SLK_COLLISION`, `ADOPTIVE_FOSTER_NAME_CHANGE`, `ATSI_CULTURAL_SKIN_NAME`, `ESTIMATED_VS_VERIFIED_DOB`)."),
            "injection_detected": ("Prompt Injection Safety Flag (injection_detected)", "Boolean safety veto (`TRUE`/`FALSE`) triggered if any untrusted text field attempted to manipulate adjudication instructions."),
            "model": ("Pinned Gemini Model ID (model)", "Exact Gemini Platform model endpoint (`gemini-2.5-flash`) used to produce the verdict."),
            "prompt_version": ("Adjudicator Prompt Version (prompt_version)", "Source-controlled prompt version (`dcj-adjudicator-v1.0`) for deterministic audit reproducibility."),
            "adjudicated_at": ("Adjudication UTC Timestamp (adjudicated_at)", "Partition timestamp recording when the verdict was appended to the immutable ledger."),
            "raw_status": ("Model Execution Status (raw_status)", "Status returned by `AI.GENERATE` (empty string indicates healthy completion)."),
            "input_tokens": ("Prompt Input Tokens (input_tokens)", "Number of prompt tokens billed for this pairwise adjudication."),
            "output_tokens": ("Completion & Reasoning Tokens (output_tokens)", "Number of completion and thinking tokens billed for this pairwise adjudication."),
        },
    },
}

KPI_TERMS = [
    {
        "term_id": "kpi_cross_program_client_overlap_rate",
        "category": "hybrid_match_and_ai_audit",
        "table": "person_source_linkage",
        "displayName": "Cross-Program Client Overlap Rate (KPI)",
        "description": "Percentage of mastered Golden Persons in `dcj_tdm.person` who are linked to 2 or more distinct DCJ source programs (`Child Protection`, `InfoShare- Family Preservation`, `Youth Justice`). Canonical SQL: `ROUND(100.0 * COUNTIF(prog_cnt > 1) / COUNT(*), 2)` over `(SELECT person_id, COUNT(DISTINCT source_program) AS prog_cnt FROM dcj_tdm.person_source_linkage GROUP BY person_id)`.",
    },
    {
        "term_id": "kpi_hybrid_match_pairwise_f1",
        "category": "hybrid_match_and_ai_audit",
        "table": "person_match_adjudications",
        "displayName": "Hybrid Person Match Pairwise Precision & F1 Score (KPI)",
        "description": "End-to-end pairwise entity resolution accuracy combining Bipartite Identifier IDF Rarity, `VECTOR_SEARCH` + Reciprocal Rank Fusion (RRF), Gemini Platform Adjudication, and Pass-2 Contradiction Pruning (`v_dcj_method_comparison`).",
    },
    {
        "term_id": "kpi_protected_person_rls_coverage",
        "category": "source_linkage_and_protection",
        "table": "person",
        "displayName": "Protected Person Confidentiality Coverage (KPI)",
        "description": "Proportion of Golden Persons flagged with `is_protected_person = TRUE` who have an active statutory confidentiality restriction in `dcj_tdm.person_protection_event` (`protect_end_date IS NULL`). Must equal 100%.",
    },
    {
        "term_id": "kpi_gnaf_geocoded_address_rate",
        "category": "geospatial_and_address",
        "table": "address_location",
        "displayName": "GNAF Parcel-Level Geocode Precision Rate (KPI)",
        "description": "Percentage of physical locations in `dcj_tdm.address_location` resolved to parcel-level GNAF precision (`record_type IN ('BUILDING CENTROID', 'PROPERTY CENTROID', 'PROPERTY CENTROID MANUAL')`) vs locality fallback.",
    },
]


def main():
    token = get_adc_token()
    project_number = get_project_number(PROJECT_ID)

    glossary_parent = f"projects/{PROJECT_ID}/locations/{GLOSSARY_LOC}"
    glossary_name = f"{glossary_parent}/glossaries/{GLOSSARY_ID}"

    print(f"==> [1/4] Ensuring Business Glossary '{GLOSSARY_ID}' in {glossary_parent} ...")
    try:
        api_request("GET", f"https://dataplex.googleapis.com/v1/{glossary_name}", token, PROJECT_ID)
        print(f"    ✔ Glossary exists: {glossary_name}")
    except RuntimeError as e:
        if "404" not in str(e):
            raise
        api_request(
            "POST",
            f"https://dataplex.googleapis.com/v1/{glossary_parent}/glossaries?glossaryId={GLOSSARY_ID}",
            token,
            PROJECT_ID,
            {
                "displayName": "NSW DCJ Person Data Model (SDM -> TDM) & Hybrid Match Business Glossary",
                "description": (
                    "Authoritative BigQuery Knowledge Catalog Business Glossary governing the NSW Department of "
                    "Communities and Justice (DCJ) Person Target Data Model (`dcj_tdm`), Native Property Graph "
                    "(`dcj_person_graph`), and Hybrid Search + Gemini Platform Adjudicator pipeline."
                ),
            },
        )
        for _ in range(15):
            try:
                api_request("GET", f"https://dataplex.googleapis.com/v1/{glossary_name}", token, PROJECT_ID)
                break
            except RuntimeError:
                time.sleep(2)
        print(f"    ✔ Created Glossary: {glossary_name}")

    print("\n==> [2/4] Ensuring 6 Logical Glossary Categories ...")
    for cat in CATEGORIES:
        cat_name = f"{glossary_name}/categories/{cat['id']}"
        try:
            api_request("GET", f"https://dataplex.googleapis.com/v1/{cat_name}", token, PROJECT_ID)
            print(f"    ✔ Category exists: {cat['id']}")
        except RuntimeError as e:
            if "404" not in str(e):
                raise
            api_request(
                "POST",
                f"https://dataplex.googleapis.com/v1/{glossary_name}/categories?categoryId={cat['id']}",
                token,
                PROJECT_ID,
                {
                    "displayName": cat["displayName"],
                    "description": cat["description"],
                    "parent": glossary_name,
                },
            )
            print(f"    ✔ Created Category: {cat['id']}")
    time.sleep(2)

    # Build flat work list of all column terms + KPI terms
    work_items = []
    for table_id, t_spec in TABLE_SPECS.items():
        cat_id = t_spec["category"]
        t_ds = t_spec.get("dataset", DATASET_ID)
        for col_name, (disp_name, desc) in t_spec["columns"].items():
            term_id = sanitize_snake_id(f"dcj_{table_id}_{col_name}")
            work_items.append({
                "term_id": term_id,
                "category": cat_id,
                "dataset": t_ds,
                "table": table_id,
                "column": col_name,
                "displayName": disp_name,
                "description": desc,
            })
    for kpi in KPI_TERMS:
        kpi_copy = dict(kpi)
        kpi_copy["dataset"] = TABLE_SPECS[kpi["table"]].get("dataset", DATASET_ID)
        work_items.append(kpi_copy)

    print(f"\n==> [3/4] Creating {len(work_items)} Glossary Terms, HTML Overviews & Attaching Column EntryLinks ...")

    def process_item(item: dict) -> str:
        term_id = item["term_id"]
        cat_id = item["category"]
        table_ds = item.get("dataset", DATASET_ID)
        table_id = item["table"]
        col_name = item.get("column")
        parent_path = f"{glossary_name}/categories/{cat_id}"
        term_name = f"{glossary_name}/terms/{term_id}"
        payload = {
            "displayName": item["displayName"],
            "description": item["description"],
            "parent": parent_path,
        }
        try:
            api_request("GET", f"https://dataplex.googleapis.com/v1/{term_name}", token, PROJECT_ID)
            api_request(
                "PATCH",
                f"https://dataplex.googleapis.com/v1/{term_name}?updateMask=displayName,description",
                token,
                PROJECT_ID,
                payload,
            )
        except RuntimeError as e:
            if "404" in str(e):
                api_request(
                    "POST",
                    f"https://dataplex.googleapis.com/v1/{glossary_name}/terms?termId={term_id}",
                    token,
                    PROJECT_ID,
                    payload,
                )
            else:
                raise

        # Enrich @dataplex Term Entry Overview aspect (using numeric PROJECT_NUMBER)
        term_entry_name = (
            f"projects/{project_number}/locations/{GLOSSARY_LOC}/entryGroups/@dataplex/entries/"
            f"projects/{project_number}/locations/{GLOSSARY_LOC}/glossaries/{GLOSSARY_ID}/terms/{term_id}"
        )
        overview_key = f"{DATAPLEX_TYPES_PROJECT}.global.overview"
        target_label = f"{PROJECT_ID}.{table_ds}.{table_id}.{col_name or 'KPI'}"
        html_doc = (
            f"<h3>{item['displayName']}</h3>"
            f"<p><strong>Physical Mapping:</strong> <code>{target_label}</code></p>"
            f"<p><strong>Domain Category:</strong> <code>{cat_id}</code></p>"
            f"<p>{item['description']}</p>"
        )
        try:
            api_request(
                "PATCH",
                f"https://dataplex.googleapis.com/v1/{term_entry_name}?updateMask=aspects&aspectKeys={overview_key}",
                token,
                PROJECT_ID,
                {
                    "name": term_entry_name,
                    "aspects": {
                        overview_key: {
                            "aspectType": f"projects/{DATAPLEX_TYPES_PROJECT}/locations/global/aspectTypes/overview",
                            "data": {"content": html_doc},
                        }
                    },
                },
            )
        except Exception:
            pass

        # Attach EntryLink in @bigquery regional entry group
        table_entry_name = (
            f"projects/{PROJECT_ID}/locations/{BQ_LOCATION}/entryGroups/@bigquery/entries/"
            f"bigquery.googleapis.com/projects/{PROJECT_ID}/datasets/{table_ds}/tables/{table_id}"
        )
        entry_links_parent = f"projects/{PROJECT_ID}/locations/{BQ_LOCATION}/entryGroups/@bigquery"
        if col_name:
            link_id = sanitize_hyphen_id(f"link-dcj-{table_id}-{col_name}")
            src_ref = {
                "name": table_entry_name,
                "path": f"Schema.{col_name}",
                "type": "SOURCE",
            }
            label = f"{table_ds}.{table_id}.Schema.{col_name} -> {term_id}"
        else:
            link_id = sanitize_hyphen_id(f"link-dcj-{table_id}-{term_id}")
            src_ref = {
                "name": table_entry_name,
                "type": "SOURCE",
            }
            label = f"{table_ds}.{table_id} (Table KPI) -> {term_id}"

        link_name = f"{entry_links_parent}/entryLinks/{link_id}"
        try:
            existing_link = api_request("GET", f"https://dataplex.googleapis.com/v1/{link_name}", token, PROJECT_ID)
            existing_refs = existing_link.get("entryReferences", [])
            if any(r.get("name") == table_entry_name for r in existing_refs):
                return f"✔ Verified Link: {label}"
            # Dataset changed (e.g. migrated from dcj_tdm to dcj_match): delete stale link and recreate
            api_request("DELETE", f"https://dataplex.googleapis.com/v1/{link_name}", token, PROJECT_ID)
        except RuntimeError as e:
            if "404" not in str(e):
                raise

        try:
            api_request(
                "POST",
                f"https://dataplex.googleapis.com/v1/{entry_links_parent}/entryLinks?entryLinkId={link_id}",
                token,
                PROJECT_ID,
                {
                    "entryLinkType": DEFINITION_LINK_TYPE,
                    "entryReferences": [
                        src_ref,
                        {"name": term_entry_name, "type": "TARGET"},
                    ],
                },
            )
            return f"✔ Attached Glossary Term: {label}"
        except RuntimeError as e:
            if "409" in str(e) or "ALREADY_EXISTS" in str(e):
                return f"✔ Verified Link: {label}"
            raise

    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(process_item, item): item["term_id"] for item in work_items}
        for fut in as_completed(futures):
            print(f"    {fut.result()}")

    print("\n==> [4/4] Syncing Enriched Glossary Definitions to BigQuery Table & Column Descriptions ...")
    for table_id, t_spec in TABLE_SPECS.items():
        t_ds = t_spec.get("dataset", DATASET_ID)
        bq_url = (
            f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT_ID}"
            f"/datasets/{t_ds}/tables/{table_id}"
        )
        table_meta = api_request("GET", bq_url, token, PROJECT_ID)
        fields = table_meta.get("schema", {}).get("fields", [])
        col_map = t_spec["columns"]
        for f in fields:
            c_name = f.get("name")
            if c_name in col_map:
                disp, desc = col_map[c_name]
                f["description"] = f"[{disp}] {desc}"[:1024]
        patch_body = {
            "description": t_spec["table_description"],
            "schema": {"fields": fields},
        }
        api_request("PATCH", bq_url, token, PROJECT_ID, patch_body)
        print(f"    ✔ Synced {len(col_map):2d} column descriptions -> `{PROJECT_ID}.{t_ds}.{table_id}`")

    print("\n🎉 NSW DCJ Knowledge Catalog Business Glossary & Column Attachment Complete!")


if __name__ == "__main__":
    main()
