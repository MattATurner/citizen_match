-- =====================================================================
-- 60 · Two-Pass Connected Components, Contradiction Guard, Survivorship
--      (`dcj_match`) & Population of All 9 Target Data Model Tables (`dcj_tdm`)
-- =====================================================================

-- 60a · Iterative Label-Propagation Connected Components Stored Procedure
CREATE OR REPLACE PROCEDURE `all-things-cdp.dcj_match.sp_connected_components`(
  nodes_table STRING,
  edges_table STRING,
  out_table   STRING,
  max_iter    INT64
)
BEGIN
  DECLARE iter INT64 DEFAULT 0;
  DECLARE changed INT64 DEFAULT 1;
  DECLARE next_table STRING DEFAULT CONCAT(out_table, '_next');

  EXECUTE IMMEDIATE FORMAT(
    'CREATE OR REPLACE TABLE `%s` AS SELECT node, node AS comp FROM `%s`',
    out_table, nodes_table
  );

  WHILE iter < max_iter AND changed > 0 DO
    SET iter = iter + 1;

    EXECUTE IMMEDIATE FORMAT('''
      CREATE OR REPLACE TABLE `%s` AS
      WITH prop AS (
        SELECT c.node, c.comp AS candidate_comp
        FROM `%s` AS c
        UNION ALL
        SELECT e.src AS node, c.comp AS candidate_comp
        FROM `%s` AS e
        JOIN `%s` AS c ON c.node = e.dst
      )
      SELECT node, MIN(candidate_comp) AS comp
      FROM prop
      GROUP BY node
    ''', next_table, out_table, edges_table, out_table);

    EXECUTE IMMEDIATE FORMAT('''
      SELECT COUNTIF(a.comp != b.comp)
      FROM `%s` AS a
      JOIN `%s` AS b USING (node)
    ''', out_table, next_table) INTO changed;

    EXECUTE IMMEDIATE FORMAT(
      'CREATE OR REPLACE TABLE `%s` AS SELECT * FROM `%s`',
      out_table, next_table
    );
  END WHILE;

  EXECUTE IMMEDIATE FORMAT('DROP TABLE IF EXISTS `%s`', next_table);
END;

-- 60b · Pass-1 Connected Components over Accepted LINK Decisions
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.graph_nodes`
AS
SELECT DISTINCT record_id AS node
FROM `all-things-cdp.dcj_match.stg_source_profiles`;

CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.edges_pass1`
AS
SELECT record_id_a AS src, record_id_b AS dst
FROM `all-things-cdp.dcj_match.person_match_decisions`
WHERE decision = 'LINK'
UNION ALL
SELECT record_id_b AS src, record_id_a AS dst
FROM `all-things-cdp.dcj_match.person_match_decisions`
WHERE decision = 'LINK';

CALL `all-things-cdp.dcj_match.sp_connected_components`(
  'all-things-cdp.dcj_match.graph_nodes',
  'all-things-cdp.dcj_match.edges_pass1',
  'all-things-cdp.dcj_match.cc_pass1',
  15
);

-- 60c · Pass-2 Transitive Contradiction Guard (Detects Twin/Sibling or Verified DOB Conflicts inside a Cluster)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.component_contradictions`
AS
SELECT
  c.comp,
  COUNT(DISTINCT c.node) AS cluster_size,
  COUNT(DISTINCT IF(p.dob_status = 'VERIFIED', p.dob, NULL)) > 1 AS has_verified_dob_conflict,
  COUNT(DISTINCT p.cni_number) > 1 AS has_cni_conflict,
  COUNT(DISTINCT p.ndis_number) > 1 AS has_ndis_conflict,
  COUNT(DISTINCT p.childstory_id_ref) > 1 AS has_cs_id_conflict
FROM `all-things-cdp.dcj_match.cc_pass1` AS c
JOIN `all-things-cdp.dcj_match.stg_source_profiles` AS p
  ON p.record_id = c.node
GROUP BY c.comp
HAVING has_verified_dob_conflict OR has_cni_conflict OR has_ndis_conflict OR has_cs_id_conflict;

-- Drop Property Graph temporarily if present so underlying TDM/edge tables can be replaced cleanly (recreated in Stage 70)
DROP PROPERTY GRAPH IF EXISTS `all-things-cdp.dcj_tdm.dcj_person_graph`;

-- 60d · Prune Contradicted Bridge Edges & Re-Run Pass-2 Connected Components
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.resolution_edges`
CLUSTER BY record_id_a, record_id_b
AS
WITH suspect_nodes AS (
  SELECT c.node
  FROM `all-things-cdp.dcj_match.cc_pass1` AS c
  JOIN `all-things-cdp.dcj_match.component_contradictions` AS x USING (comp)
)
SELECT
  d.record_id_a,
  d.record_id_b,
  d.decision,
  d.decided_by,
  d.confidence,
  d.rationale,
  d.decisive_evidence,
  d.contradiction,
  d.retrieved_by,
  d.combined_score,
  d.rrf_score,
  d.semantic_similarity,
  (d.decision = 'LINK'
   AND (d.record_id_a IN (SELECT node FROM suspect_nodes) OR d.record_id_b IN (SELECT node FROM suspect_nodes))
   AND (t.verified_dob_conflict OR t.cni_conflict OR t.ndis_conflict OR t.cs_id_conflict OR t.twin_or_sibling_trap OR d.confidence < 0.92 OR (t.non_hub_idf_sum = 0.0 AND NOT t.surname_or_alias_match))
  ) AS suppressed_by_contradiction
FROM `all-things-cdp.dcj_match.person_match_decisions` AS d
JOIN `all-things-cdp.dcj_match.candidate_pair_tiers` AS t
  ON t.record_id_a = d.record_id_a AND t.record_id_b = d.record_id_b;

CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.edges_pass2`
AS
SELECT record_id_a AS src, record_id_b AS dst
FROM `all-things-cdp.dcj_match.resolution_edges`
WHERE decision = 'LINK' AND NOT suppressed_by_contradiction
UNION ALL
SELECT record_id_b AS src, record_id_a AS dst
FROM `all-things-cdp.dcj_match.resolution_edges`
WHERE decision = 'LINK' AND NOT suppressed_by_contradiction;

CALL `all-things-cdp.dcj_match.sp_connected_components`(
  'all-things-cdp.dcj_match.graph_nodes',
  'all-things-cdp.dcj_match.edges_pass2',
  'all-things-cdp.dcj_match.cc_final',
  15
);

-- 60e · Durable Golden `person_id` Assignment (`person_assignment` & `person_crosswalk`)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.person_assignment`
CLUSTER BY person_id, record_id
AS
SELECT
  c.node AS record_id,
  c.comp AS anchor_record_id,
  -- MD5 hash of anchor source person ID + cluster key, matching TDM spec
  CONCAT('PER-', UPPER(SUBSTR(TO_HEX(MD5(c.comp)), 1, 12))) AS person_id,
  ABS(FARM_FINGERPRINT(CONCAT('PER-', UPPER(SUBSTR(TO_HEX(MD5(c.comp)), 1, 12))))) AS party_id_int64,
  COUNT(*) OVER (PARTITION BY c.comp) AS cluster_size,
  CURRENT_TIMESTAMP() AS assigned_at
FROM `all-things-cdp.dcj_match.cc_final` AS c;

-- 60f · Field-Level Survivorship & Provenance (`field_survivorship`)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.field_assertions`
CLUSTER BY person_id, field_name
AS
SELECT
  a.person_id,
  p.record_id,
  p.source_system,
  p.source_program,
  p.source_trust,
  p.record_ts,
  f.field_name,
  f.field_value
FROM `all-things-cdp.dcj_match.stg_source_profiles` AS p
JOIN `all-things-cdp.dcj_match.person_assignment` AS a USING (record_id),
UNNEST([
  STRUCT('given_name'        AS field_name, p.given_name_raw AS field_value),
  STRUCT('middle_name'       AS field_name, p.middle_name_raw AS field_value),
  STRUCT('family_name'       AS field_name, p.family_name_raw AS field_value),
  STRUCT('gender'            AS field_name, p.gender_norm AS field_value),
  STRUCT('date_of_birth'     AS field_name, IF(p.dob_status = 'VERIFIED', CAST(p.dob AS STRING), NULL) AS field_value),
  STRUCT('date_of_birth_any' AS field_name, CAST(p.dob AS STRING) AS field_value),
  STRUCT('dob_certainty'     AS field_name, p.dob_status AS field_value),
  STRUCT('indigenous_status' AS field_name, NULLIF(p.indigenous_status, 'No') AS field_value),
  STRUCT('gnaf_address_id'   AS field_name, p.gnaf_address_id AS field_value),
  STRUCT('phone_e164'        AS field_name, p.phone_e164 AS field_value),
  STRUCT('email_norm'        AS field_name, p.email_norm AS field_value)
]) AS f
WHERE f.field_value IS NOT NULL AND f.field_value != '';

CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.field_survivorship`
CLUSTER BY person_id, field_name
AS
WITH ranked AS (
  SELECT
    fa.*,
    COUNT(DISTINCT source_program) OVER (PARTITION BY person_id, field_name, field_value) AS corroborating_programs,
    COUNT(DISTINCT field_value) OVER (PARTITION BY person_id, field_name) AS distinct_values,
    ROW_NUMBER() OVER (
      PARTITION BY person_id, field_name
      ORDER BY
        source_trust DESC,
        record_ts DESC NULLS LAST,
        record_id ASC
    ) AS rn
  FROM `all-things-cdp.dcj_match.field_assertions` AS fa
)
SELECT
  person_id,
  field_name,
  field_value AS surviving_value,
  record_id AS won_from_record_id,
  source_program AS won_from_program,
  source_trust,
  corroborating_programs,
  distinct_values > 1 AS was_contested
FROM ranked
WHERE rn = 1;

-- =====================================================================
-- 60g · Populate the 9 Target Data Model (TDM) Tables
-- =====================================================================

-- 1. TDM Table: `dcj_tdm.party` (Root table for all entities: person, group, organisation)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.party`
(
  party_id          STRING    NOT NULL OPTIONS(description="Unique internal identifier for the party (harmonised STRING key for Property Graph)"),
  party_id_int64    INT64     NOT NULL OPTIONS(description="Deterministic INT64 party identifier for legacy DDL compatibility"),
  party_type_code   STRING    NOT NULL OPTIONS(description="Categorises the party: person, organisation, or group"),
  party_display_name STRING            OPTIONS(description="Human-readable display label for the party"),
  created_timestamp TIMESTAMP          OPTIONS(description="Audit timestamp when record was created")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Root table for all entities across NSW DCJ (person, organisation, group)."
);

INSERT INTO `all-things-cdp.dcj_tdm.party`
-- (a) Mastered Golden Persons
SELECT
  a.person_id AS party_id,
  ANY_VALUE(a.party_id_int64) AS party_id_int64,
  'person' AS party_type_code,
  ANY_VALUE(CONCAT(p.given_name_raw, ' ', p.family_name_raw)) AS party_display_name,
  MIN(p.record_ts) AS created_timestamp
FROM `all-things-cdp.dcj_match.person_assignment` AS a
JOIN `all-things-cdp.dcj_match.stg_source_profiles` AS p USING (record_id)
GROUP BY a.person_id

UNION ALL

-- (b) Family Preservation Groups
SELECT
  CONCAT('GRP-', CAST(g.AutoID AS STRING)) AS party_id,
  g.AutoID AS party_id_int64,
  'group' AS party_type_code,
  g.GroupLabel AS party_display_name,
  g.CreatedOn AS created_timestamp
FROM `all-things-cdp.dcj_sdm.infoshare_fp_groupsTBL` AS g

UNION ALL

-- (c) Service Provider & Statutory Issuing Organisations
SELECT
  org_id AS party_id,
  org_int64 AS party_id_int64,
  'organisation' AS party_type_code,
  org_name AS party_display_name,
  TIMESTAMP('2025-01-01T00:00:00Z') AS created_timestamp
FROM UNNEST([
  STRUCT('ORG-DCJ-CP'     AS org_id, 1001 AS org_int64, 'NSW DCJ Child Protection Authority' AS org_name),
  STRUCT('ORG-NSW-POLICE' AS org_id, 1002 AS org_int64, 'NSW Police Force (CNI Registry)' AS org_name),
  STRUCT('ORG-NDIA'       AS org_id, 1003 AS org_int64, 'National Disability Insurance Agency (NDIA)' AS org_name),
  STRUCT('ORG-AIHW'       AS org_id, 1004 AS org_int64, 'Australian Institute of Health and Welfare (SLK-581)' AS org_name),
  STRUCT('ORG-401'        AS org_id, 401  AS org_int64, 'Western Sydney Family Preservation Service' AS org_name),
  STRUCT('ORG-402'        AS org_id, 402  AS org_int64, 'Hunter & Central Coast Family Support NGO' AS org_name),
  STRUCT('ORG-403'        AS org_id, 403  AS org_int64, 'Regional NSW Aboriginal Family Preservation Alliance' AS org_name)
]);

-- 2. TDM Table: `dcj_tdm.person` (Core Attributes specific to human individuals — 1 Golden Row per Person)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.person`
(
  person_id           STRING NOT NULL OPTIONS(description="Unique identifier (Same as Party ID). MD5 hash of anchor source_person_id"),
  gender              STRING          OPTIONS(description="Defines gender of the person (Male, Female, Unknown)"),
  date_of_birth       DATE            OPTIONS(description="Survivored known or believed date of birth"),
  dob_certainty_code  STRING          OPTIONS(description="Code indicating accuracy of DOB (VERIFIED or ESTIMATED)"),
  date_of_death       DATE            OPTIONS(description="Known date of death"),
  dod_certainty_code  STRING          OPTIONS(description="Code indicating accuracy of DOD"),
  is_protected_person BOOL            OPTIONS(description="Flag if record is confidential/restricted (Critical for Row Level Security)"),
  is_cald             BOOL            OPTIONS(description="Culturally and Linguistically Diverse indicator"),
  indigenous_status   STRING          OPTIONS(description="Aboriginal and/or Torres Strait Islander origin indicator"),
  source_program      STRING NOT NULL OPTIONS(description="Primary authoritative source program for this mastered person")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Core attributes specific to human individuals (1 mastered Golden record per resolved person)."
);

INSERT INTO `all-things-cdp.dcj_tdm.person`
WITH piv AS (
  SELECT
    person_id,
    MAX(IF(field_name = 'gender', surviving_value, NULL)) AS gender,
    MAX(IF(field_name = 'date_of_birth', surviving_value, NULL)) AS dob_verified,
    MAX(IF(field_name = 'date_of_birth_any', surviving_value, NULL)) AS dob_any,
    MAX(IF(field_name = 'dob_certainty', surviving_value, NULL)) AS dob_cert,
    MAX(IF(field_name = 'indigenous_status', surviving_value, NULL)) AS indig_val
  FROM `all-things-cdp.dcj_match.field_survivorship`
  GROUP BY person_id
),
flags AS (
  SELECT
    a.person_id,
    LOGICAL_OR(p.is_protected) AS is_protected_person,
    LOGICAL_OR(p.is_cald) AS is_cald,
    ARRAY_AGG(p.source_program ORDER BY p.source_trust DESC, p.record_ts DESC LIMIT 1)[OFFSET(0)] AS winning_program
  FROM `all-things-cdp.dcj_match.person_assignment` AS a
  JOIN `all-things-cdp.dcj_match.stg_source_profiles` AS p USING (record_id)
  GROUP BY a.person_id
)
SELECT
  f.person_id,
  COALESCE(piv.gender, 'Unknown') AS gender,
  SAFE_CAST(COALESCE(piv.dob_verified, piv.dob_any) AS DATE) AS date_of_birth,
  IF(piv.dob_verified IS NOT NULL, 'VERIFIED', COALESCE(piv.dob_cert, 'ESTIMATED')) AS dob_certainty_code,
  CAST(NULL AS DATE) AS date_of_death,
  CAST(NULL AS STRING) AS dod_certainty_code,
  f.is_protected_person,
  f.is_cald,
  COALESCE(piv.indig_val, 'No') AS indigenous_status,
  f.winning_program AS source_program
FROM flags AS f
LEFT JOIN piv USING (person_id);

-- 3. TDM Table: `dcj_tdm.person_name` (Tracks all current and past names across all 16 name_usage_codes)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.person_name`
(
  person_name_id    STRING NOT NULL OPTIONS(description="Unique ID for this specific name record (MD5 hash of person_id, name, usage and primary flag)"),
  person_id         STRING NOT NULL OPTIONS(description="Link to the Golden Person"),
  name_usage_code   STRING          OPTIONS(description="Context of name (Legal Name, Preferred Name, Adopted Name, Pre-Adoptive Name, Tribal/Cultural Name, Alias Name, etc.)"),
  primary_name_flag BOOL            OPTIONS(description="Flag to indicate for this person_id this is the primary name"),
  name_title        STRING          OPTIONS(description="Honorific (Mr, Ms, Mx)"),
  given_name        STRING          OPTIONS(description="First name"),
  middle_name       STRING          OPTIONS(description="Middle name(s)"),
  family_name       STRING          OPTIONS(description="Last name / Surname"),
  name_suffix       STRING          OPTIONS(description="Suffix (Jr, Sr, III)"),
  full_name         STRING          OPTIONS(description="Concatenation for search purposes"),
  start_date        TIMESTAMP       OPTIONS(description="Date this name became effective"),
  end_date          TIMESTAMP       OPTIONS(description="Date this name usage ended (NULL = Active)"),
  source_program    STRING NOT NULL OPTIONS(description="ID to determine which source program/domain the row comes from")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Tracks all current, historical, cultural, pre-adoptive, adopted, and alias names per Golden Person."
);

INSERT INTO `all-things-cdp.dcj_tdm.person_name`
WITH raw_names AS (
  SELECT
    a.person_id,
    p.source_program,
    p.source_trust,
    p.record_ts,
    nm.given_name,
    nm.middle_name,
    nm.family_name,
    nm.name_usage_code,
    nm.is_primary
  FROM `all-things-cdp.dcj_match.stg_source_profiles` AS p
  JOIN `all-things-cdp.dcj_match.person_assignment` AS a USING (record_id),
  UNNEST(p.all_names_arr) AS nm
  WHERE nm.given_name IS NOT NULL OR nm.family_name IS NOT NULL
),
dedup AS (
  SELECT
    person_id,
    given_name,
    middle_name,
    family_name,
    name_usage_code,
    LOGICAL_OR(is_primary) AS was_source_primary,
    MAX(source_trust) AS max_trust,
    MIN(record_ts) AS start_date,
    ARRAY_AGG(source_program ORDER BY source_trust DESC LIMIT 1)[OFFSET(0)] AS source_program
  FROM raw_names
  GROUP BY person_id, given_name, middle_name, family_name, name_usage_code
),
ranked AS (
  SELECT
    d.*,
    ROW_NUMBER() OVER (
      PARTITION BY d.person_id
      ORDER BY
        d.was_source_primary DESC,
        d.name_usage_code = 'Legal Name' DESC,
        d.max_trust DESC,
        d.given_name ASC
    ) = 1 AS primary_name_flag
  FROM dedup AS d
)
SELECT
  CONCAT('PNM-', UPPER(SUBSTR(TO_HEX(MD5(CONCAT(
    person_id, '|', IFNULL(given_name, ''), '|', IFNULL(middle_name, ''), '|',
    IFNULL(family_name, ''), '|', IFNULL(name_usage_code, 'NULL'), '|', CAST(primary_name_flag AS STRING)
  ))), 1, 16))) AS person_name_id,
  person_id,
  name_usage_code,
  primary_name_flag,
  CAST(NULL AS STRING) AS name_title,
  given_name,
  middle_name,
  family_name,
  CAST(NULL AS STRING) AS name_suffix,
  TRIM(CONCAT(IFNULL(given_name, ''), ' ', IFNULL( initcap(middle_name), ''), ' ', IFNULL(family_name, ''))) AS full_name,
  start_date,
  IF(name_usage_code IN ('Pre-Adoptive Name', 'Name at Birth', 'Previous Name'),
     TIMESTAMP('2025-12-31T00:00:00Z'),
     CAST(NULL AS TIMESTAMP)) AS end_date,
  source_program
FROM ranked;

-- 4. TDM Table: `dcj_tdm.address_location` (Unique physical locations — de-duplicated GNAF)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.address_location`
(
  id                  STRING  NOT NULL OPTIONS(description="ID of each address/location (GNAF PID)"),
  building_name       STRING           OPTIONS(description="Name of the address/building if applicable"),
  lot_number_prefix   STRING           OPTIONS(description="Anything before the lot number"),
  lot_number          STRING           OPTIONS(description="Where applicable the lot number for an address"),
  lot_number_suffix   STRING           OPTIONS(description="Anything after the lot number"),
  flat_type           STRING           OPTIONS(description="Description of the flat e.g. Unit, House"),
  flat_number_prefix  STRING           OPTIONS(description="Anything before the flat number"),
  flat_number         STRING           OPTIONS(description="Where applicable the flat number for an address"),
  flat_number_suffix  STRING           OPTIONS(description="Anything after the flat number"),
  number_first_prefix STRING           OPTIONS(description="Anything before the first number in an address"),
  number_first        STRING           OPTIONS(description="The street number portion of an address"),
  number_first_suffix STRING           OPTIONS(description="Anything after the first number in an address"),
  number_last_prefix  STRING           OPTIONS(description="Anything before the last number in an address"),
  number_last         STRING           OPTIONS(description="The last street number portion of an address"),
  number_last_suffix  STRING           OPTIONS(description="Anything after the last number in an address"),
  street_name         STRING           OPTIONS(description="Name of street"),
  street_type         STRING           OPTIONS(description="Type of street such as AV, ST, PD, RD"),
  street_type_suffix  STRING           OPTIONS(description="Anything after the street type e.g NORTH, SOUTH"),
  suburb              STRING           OPTIONS(description="Listed Suburb of the address"),
  postcode            STRING           OPTIONS(description="Listed postcode of the address"),
  state               STRING           OPTIONS(description="Listed state of the address"),
  latitude            FLOAT64          OPTIONS(description="Latitude of the address"),
  longitude           FLOAT64          OPTIONS(description="Longitude of the address"),
  full_address        STRING           OPTIONS(description="Concatenation of number, name and type for searching purposes"),
  record_type         STRING           OPTIONS(description="GNAF record type: BUILDING CENTROID, PROPERTY CENTROID, GAP GEOCODE, LOCALITY, STREET LOCALITY, PROPERTY CENTROID MANUAL")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Unique de-duplicated physical locations standardised against GNAF."
);

INSERT INTO `all-things-cdp.dcj_tdm.address_location`
SELECT
  id, building_name, lot_number_prefix, lot_number, lot_number_suffix,
  flat_type, flat_number_prefix, flat_number, flat_number_suffix,
  number_first_prefix, number_first, number_first_suffix,
  number_last_prefix, number_last, number_last_suffix,
  street_name, street_type, street_type_suffix,
  suburb, postcode, state, latitude, longitude, full_address, record_type
FROM `all-things-cdp.dcj_sdm.GNAF_address_view`;

-- 5. TDM Table: `dcj_tdm.address_relation` (Associates a person with an address for a specific period and purpose)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.address_relation`
(
  address_relation_id         STRING    NOT NULL OPTIONS(description="Unique ID for this specific link of person to address record"),
  person_id                   STRING    NOT NULL OPTIONS(description="Link to the Golden Person"),
  address_location_id         STRING    NOT NULL OPTIONS(description="Link to address_location.id"),
  primary_address_flag        BOOL               OPTIONS(description="Flag to indicate if this address is the current primary address for this person_id"),
  address_relation_start_date TIMESTAMP          OPTIONS(description="Date this address became effective"),
  address_relation_end_date   TIMESTAMP          OPTIONS(description="Date this address usage ended (NULL = current)"),
  address_purpose             STRING             OPTIONS(description="Purpose of this address (Residential, Crisis Accommodation, Postal)"),
  source_program              STRING    NOT NULL OPTIONS(description="ID to determine which source program/domain the row comes from")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Associates a mastered person with a physical GNAF address location over time."
);

INSERT INTO `all-things-cdp.dcj_tdm.address_relation`
WITH person_addrs AS (
  SELECT
    a.person_id,
    p.gnaf_address_id AS address_location_id,
    MAX(p.source_trust) AS max_trust,
    MIN(p.record_ts) AS start_dt,
    MAX(p.record_ts) AS last_seen_dt,
    ARRAY_AGG(p.source_program ORDER BY p.source_trust DESC LIMIT 1)[OFFSET(0)] AS source_program
  FROM `all-things-cdp.dcj_match.stg_source_profiles` AS p
  JOIN `all-things-cdp.dcj_match.person_assignment` AS a USING (record_id)
  WHERE p.gnaf_address_id IS NOT NULL
  GROUP BY a.person_id, p.gnaf_address_id
),
ranked AS (
  SELECT
    pa.*,
    ROW_NUMBER() OVER (
      PARTITION BY pa.person_id
      ORDER BY pa.last_seen_dt DESC, pa.max_trust DESC, pa.address_location_id ASC
    ) = 1 AS primary_address_flag
  FROM person_addrs AS pa
)
SELECT
  CONCAT('AREL-', UPPER(SUBSTR(TO_HEX(MD5(CONCAT(person_id, '|', address_location_id))), 1, 16))) AS address_relation_id,
  person_id,
  address_location_id,
  primary_address_flag,
  start_dt AS address_relation_start_date,
  IF(primary_address_flag, CAST(NULL AS TIMESTAMP), TIMESTAMP('2026-09-01T00:00:00Z')) AS address_relation_end_date,
  IF(STARTS_WITH(address_location_id, 'GNAF-NSW-HUB'), 'Crisis / Short-Term Accommodation', 'Residential') AS address_purpose,
  source_program
FROM ranked;

-- 6. TDM Table: `dcj_tdm.person_source_linkage` (Maps Golden Person to SDM records & domains)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.person_source_linkage`
(
  linkage_id        STRING    NOT NULL OPTIONS(description="Unique primary key for this person-to-source linkage row"),
  person_id         STRING    NOT NULL OPTIONS(description="The 'Golden' internal Person ID"),
  source_record_id  STRING    NOT NULL OPTIONS(description="Internal staging record ID (CP:..., FP:..., YJ:...)"),
  source_app_id     STRING    NOT NULL OPTIONS(description="ID of the originating agency system (CHILDSTORY, INFOSHARE, KIMS_YJ)"),
  source_person_id  STRING    NOT NULL OPTIONS(description="The ID used in the source system (e.g. CS-10001, FP-CL-50001, YJ-30001)"),
  source_program    STRING    NOT NULL OPTIONS(description="ID to determine which source program/domain the row comes from"),
  is_mastered       BOOL               OPTIONS(description="TRUE = Mastered into Golden Record"),
  last_updated_ts   TIMESTAMP          OPTIONS(description="When this link was last verified")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Maps mastered Golden Person IDs back to originating source systems and domains."
);

INSERT INTO `all-things-cdp.dcj_tdm.person_source_linkage`
SELECT
  CONCAT('LNK-', UPPER(SUBSTR(TO_HEX(MD5(CONCAT(a.person_id, '|', p.record_id))), 1, 16))) AS linkage_id,
  a.person_id,
  p.record_id AS source_record_id,
  p.source_system AS source_app_id,
  p.source_person_id,
  p.source_program,
  TRUE AS is_mastered,
  a.assigned_at AS last_updated_ts
FROM `all-things-cdp.dcj_match.person_assignment` AS a
JOIN `all-things-cdp.dcj_match.stg_source_profiles` AS p USING (record_id);

-- 7. TDM Table: `dcj_tdm.party_relationship` (Links parties: person-person across 78 types, person-group, group-org)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.party_relationship`
(
  relationship_id             STRING    NOT NULL OPTIONS(description="Unique identifier for the party relationship edge"),
  subject_party_id            STRING    NOT NULL OPTIONS(description="The 'From' side of the relationship (FK to party.party_id)"),
  related_party_id            STRING    NOT NULL OPTIONS(description="The 'To' side of the relationship (FK to party.party_id)"),
  relationship_type           STRING    NOT NULL OPTIONS(description="Raw DCJ relationship type code (all 78 familial, kinship, carer & group types)"),
  canonical_relationship_type STRING    NOT NULL OPTIONS(description="Standardised relationship type (resolves case/hyphen variants like Step Child/Step child)"),
  relationship_category       STRING    NOT NULL OPTIONS(description="High-level relationship domain (IMMEDIATE_FAMILY, STEP_OR_BLENDED_FAMILY, EXTENDED_OR_KINSHIP_FAMILY, CARER_OR_GUARDIANSHIP, etc.)"),
  start_date                  TIMESTAMP          OPTIONS(description="Relationship effective date"),
  end_date                    TIMESTAMP          OPTIONS(description="Relationship end date"),
  comment                     STRING             OPTIONS(description="Free text notes / provenance on the relationship"),
  source_program              STRING    NOT NULL OPTIONS(description="ID to determine which source program/domain the row comes from")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Links parties (person-to-person across 78 kinship/carer types, person-to-group, group-to-organisation)."
);

INSERT INTO `all-things-cdp.dcj_tdm.party_relationship`
WITH
-- Map ChildStory IDs to Golden person_id
cs_to_person AS (
  SELECT DISTINCT source_person_id AS cs_id, person_id
  FROM `all-things-cdp.dcj_tdm.person_source_linkage`
  WHERE source_app_id = 'CHILDSTORY'
),
-- (a) Child Protection person_relation_file_4_ciw (all 78 relationship types)
cp_rels AS (
  SELECT
    s.person_id AS subject_party_id,
    o.person_id AS related_party_id,
    r.REL_TYPE AS relationship_type,
    r.W_INSERT_DT AS start_date,
    CAST(NULL AS TIMESTAMP) AS end_date,
    CONCAT('Asserted in ChildStory relation ID ', r.ID) AS comment,
    r.source_program
  FROM `all-things-cdp.dcj_sdm.cp_person_relation_file_4_ciw` AS r
  JOIN cs_to_person AS s ON s.cs_id = r.SUBJECT_PERSON_NUMBER
  JOIN cs_to_person AS o ON o.cs_id = r.RELATED_PERSON_NUMBER
  WHERE s.person_id != o.person_id
),
-- (b) Youth Justice Relative Relationships (matching YO_Relation_First_Name + Last_Name to resolved person)
yj_rels AS (
  SELECT
    l_yo.person_id AS subject_party_id,
    p_rel.person_id AS related_party_id,
    COALESCE(y.Relationship_To_YO, 'Relative') AS relationship_type,
    TIMESTAMP('2026-01-01T00:00:00Z') AS start_date,
    CAST(NULL AS TIMESTAMP) AS end_date,
    CONCAT('Extracted from Youth Justice KIMS relative field: ', y.Desc) AS comment,
    y.source_program
  FROM `all-things-cdp.dcj_sdm.yj_new_clients_kims` AS y
  JOIN `all-things-cdp.dcj_tdm.person_source_linkage` AS l_yo
    ON l_yo.source_app_id = 'KIMS_YJ' AND l_yo.source_person_id = y.Young_Offender_Id
  JOIN (
    SELECT person_id, UPPER(given_name) AS gn, UPPER(family_name) AS fn
    FROM `all-things-cdp.dcj_tdm.person_name`
    WHERE primary_name_flag
  ) AS p_rel
    ON p_rel.gn = UPPER(y.YO_Relation_First_Name)
   AND p_rel.fn = UPPER(y.YO_Relation_Last_Name)
  WHERE l_yo.person_id != p_rel.person_id
),
-- (c) Family Preservation Client -> Group Membership
fp_group_rels AS (
  SELECT
    l.person_id AS subject_party_id,
    CONCAT('GRP-', CAST(gc.GroupAutoID AS STRING)) AS related_party_id,
    'Group Member' AS relationship_type,
    TIMESTAMP('2026-01-15T00:00:00Z') AS start_date,
    CAST(NULL AS TIMESTAMP) AS end_date,
    CONCAT('Family Preservation Group AutoID ', CAST(gc.GroupAutoID AS STRING)) AS comment,
    gc.source_program
  FROM `all-things-cdp.dcj_sdm.infoshare_fp_groupclientsTBL` AS gc
  JOIN `all-things-cdp.dcj_sdm.infoshare_fp_clientsTBL` AS c
    ON c.AutoID = gc.ClientAutoID
  JOIN `all-things-cdp.dcj_tdm.person_source_linkage` AS l
    ON l.source_app_id = 'INFOSHARE' AND l.source_person_id = c.ClientID
),
-- (d) Family Preservation Group -> Service Provider Organisation
fp_org_rels AS (
  SELECT
    CONCAT('GRP-', CAST(g.AutoID AS STRING)) AS subject_party_id,
    CONCAT('ORG-', CAST(g.OrganisationAutoID AS STRING)) AS related_party_id,
    'Service Provider' AS relationship_type,
    g.CreatedOn AS start_date,
    CAST(NULL AS TIMESTAMP) AS end_date,
    CONCAT('Managed by OrganisationAutoID ', CAST(g.OrganisationAutoID AS STRING)) AS comment,
    g.source_program
  FROM `all-things-cdp.dcj_sdm.infoshare_fp_groupsTBL` AS g
),
all_rels AS (
  SELECT * FROM cp_rels
  UNION ALL
  SELECT * FROM yj_rels
  UNION ALL
  SELECT * FROM fp_group_rels
  UNION ALL
  SELECT * FROM fp_org_rels
),
dedup_rels AS (
  SELECT
    subject_party_id,
    related_party_id,
    relationship_type,
    MIN(start_date) AS start_date,
    ANY_VALUE(end_date) AS end_date,
    ANY_VALUE(comment) AS comment,
    ANY_VALUE(source_program) AS source_program
  FROM all_rels
  GROUP BY subject_party_id, related_party_id, relationship_type
)
SELECT
  CONCAT('REL-', UPPER(SUBSTR(TO_HEX(MD5(CONCAT(subject_party_id, '|', related_party_id, '|', relationship_type))), 1, 16))) AS relationship_id,
  subject_party_id,
  related_party_id,
  relationship_type,
  `all-things-cdp.dcj_match.canonical_relationship_type`(relationship_type) AS canonical_relationship_type,
  `all-things-cdp.dcj_match.relationship_category`(relationship_type) AS relationship_category,
  start_date,
  end_date,
  comment,
  source_program
FROM dedup_rels;

-- 8. TDM Table: `dcj_tdm.person_protection_event` (Logs periods where a person's data is restricted)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.person_protection_event`
(
  protection_event_id      STRING    NOT NULL OPTIONS(description="Unique ID for this protection restriction event"),
  person_id                STRING    NOT NULL OPTIONS(description="Link to Golden Person"),
  protect_start_date       TIMESTAMP          OPTIONS(description="Date protection started"),
  protect_end_date         TIMESTAMP          OPTIONS(description="Date protection ended (NULL = Currently Active Restriction)"),
  reason                   STRING             OPTIONS(description="Reason for protection (Domestic & Family Violence Safety, Statutory Child Protection Order, Witness/Confidential)"),
  initiator_party_id       STRING             OPTIONS(description="Party ID of the authority that requested the protection (FK to party.party_id)"),
  initiator_party_id_int64 INT64              OPTIONS(description="Numeric Party ID of the authority for legacy DDL compatibility"),
  source_program           STRING    NOT NULL OPTIONS(description="ID to determine which source program/domain the row comes from")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Logs statutory periods where a person's identity and location data is restricted."
);

INSERT INTO `all-things-cdp.dcj_tdm.person_protection_event`
SELECT
  CONCAT('PROT-', UPPER(SUBSTR(TO_HEX(MD5(p.person_id)), 1, 14))) AS protection_event_id,
  p.person_id,
  TIMESTAMP('2025-06-01T00:00:00Z') AS protect_start_date,
  CAST(NULL AS TIMESTAMP) AS protect_end_date,
  'Domestic & Family Violence Safety / Statutory Confidentiality Restriction' AS reason,
  'ORG-DCJ-CP' AS initiator_party_id,
  1001 AS initiator_party_id_int64,
  p.source_program
FROM `all-things-cdp.dcj_tdm.person` AS p
WHERE p.is_protected_person = TRUE;

-- 9. TDM Table: `dcj_tdm.person_identity_instrument` (Official & Statistical Identity Documents)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.person_identity_instrument`
(
  instrument_id         STRING NOT NULL OPTIONS(description="Unique ID for this document/instrument record (STRING PK for Property Graph)"),
  instrument_id_int64   INT64  NOT NULL OPTIONS(description="Numeric instrument ID for Data Dictionary compatibility"),
  person_id             STRING NOT NULL OPTIONS(description="Link to Golden Person (FK to person.person_id)"),
  instrument_type_code  STRING NOT NULL OPTIONS(description="Type of identity instrument: CNI, NDIS, CHILDSTORY_ID, or SLK_581"),
  designation_number    STRING NOT NULL OPTIONS(description="The identifier/reference value on the instrument"),
  issuer_party_id       STRING NOT NULL OPTIONS(description="The Party ID of the issuing authority (FK to party.party_id)"),
  issuer_party_id_int64 INT64  NOT NULL OPTIONS(description="Numeric Party ID of the issuing authority"),
  issue_date            DATE            OPTIONS(description="Date instrument was issued or first recorded"),
  expiry_date           DATE            OPTIONS(description="Date instrument expires"),
  status_code           STRING          OPTIONS(description="Validity status (Active, Verified, Statistical)"),
  is_primary            BOOL            OPTIONS(description="Indicates if this is the primary government instrument for this person"),
  source_program        STRING NOT NULL OPTIONS(description="ID to determine which source program/domain the row comes from")
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  description="Tracks government and statistical identity instruments (CNI, NDIS, ChildStory ID, SLK-581) linked to each Golden Person."
);

INSERT INTO `all-things-cdp.dcj_tdm.person_identity_instrument`
WITH raw_inst AS (
  SELECT
    a.person_id,
    'CNI' AS instrument_type_code,
    s.cni_number AS designation_number,
    'ORG-NSW-POLICE' AS issuer_party_id,
    1002 AS issuer_party_id_int64,
    'Verified' AS status_code,
    TRUE AS is_primary,
    s.source_program
  FROM `all-things-cdp.dcj_match.stg_source_profiles` AS s
  JOIN `all-things-cdp.dcj_match.person_assignment` AS a USING (record_id)
  WHERE s.cni_number IS NOT NULL

  UNION ALL

  SELECT
    a.person_id,
    'NDIS' AS instrument_type_code,
    s.ndis_number AS designation_number,
    'ORG-NDIA' AS issuer_party_id,
    1003 AS issuer_party_id_int64,
    'Active' AS status_code,
    FALSE AS is_primary,
    s.source_program
  FROM `all-things-cdp.dcj_match.stg_source_profiles` AS s
  JOIN `all-things-cdp.dcj_match.person_assignment` AS a USING (record_id)
  WHERE s.ndis_number IS NOT NULL

  UNION ALL

  SELECT
    a.person_id,
    'CHILDSTORY_ID' AS instrument_type_code,
    s.childstory_id_ref AS designation_number,
    'ORG-DCJ-CP' AS issuer_party_id,
    1001 AS issuer_party_id_int64,
    'Active' AS status_code,
     TRUE AS is_primary,
    s.source_program
  FROM `all-things-cdp.dcj_match.stg_source_profiles` AS s
  JOIN `all-things-cdp.dcj_match.person_assignment` AS a USING (record_id)
  WHERE s.childstory_id_ref IS NOT NULL

  UNION ALL

  SELECT
    a.person_id,
    'SLK_581' AS instrument_type_code,
    s.slk_code AS designation_number,
    'ORG-AIHW' AS issuer_party_id,
    1004 AS issuer_party_id_int64,
    'Statistical' AS status_code,
    FALSE AS is_primary,
    s.source_program
  FROM `all-things-cdp.dcj_match.stg_source_profiles` AS s
  JOIN `all-things-cdp.dcj_match.person_assignment` AS a USING (record_id)
  WHERE s.slk_code IS NOT NULL
),
dedup_inst AS (
  SELECT
    person_id,
    instrument_type_code,
    designation_number,
    ANY_VALUE(issuer_party_id) AS issuer_party_id,
    ANY_VALUE(issuer_party_id_int64) AS issuer_party_id_int64,
    ANY_VALUE(status_code) AS status_code,
    LOGICAL_OR(is_primary) AS is_primary,
    ANY_VALUE(source_program) AS source_program
  FROM raw_inst
  GROUP BY person_id, instrument_type_code, designation_number
)
SELECT
  CONCAT('INST-', UPPER(SUBSTR(TO_HEX(MD5(CONCAT(person_id, '|', instrument_type_code, '|', designation_number))), 1, 14))) AS instrument_id,
  ABS(FARM_FINGERPRINT(CONCAT(person_id, '|', instrument_type_code, '|', designation_number))) AS instrument_id_int64,
  person_id,
  instrument_type_code,
  designation_number,
  issuer_party_id,
  issuer_party_id_int64,
  DATE('2025-01-01') AS issue_date,
  DATE('2030-12-31') AS expiry_date,
  status_code,
  is_primary,
  source_program
FROM dedup_inst;
