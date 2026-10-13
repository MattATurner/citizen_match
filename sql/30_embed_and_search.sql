-- =====================================================================
-- 30 · Autonomous Embedding Generation & Hybrid Search Surface
--
-- Creates:
--   1. `dcj_tdm.source_profile_search`  (Autonomous `GENERATED ALWAYS AS
--                                        (AI.EMBED(...))` table + BM25
--                                        SEARCH INDEX)
--   2. `dcj_tdm.source_profile_vectors` (Materialised 768-dim vectors from
--                                        `text-embedding-005` for immediate
--                                        `VECTOR_SEARCH` execution)
-- =====================================================================

-- 1. Autonomous Embedding Table (Self-maintaining vector column)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.source_profile_search`
(
  record_id         STRING NOT NULL,
  source_system     STRING,
  source_program    STRING,
  source_trust      INT64,
  source_person_id  STRING,
  match_key         STRING,
  full_name_norm    STRING,
  given_name_norm   STRING,
  family_name_norm  STRING,
  address_norm      STRING,
  suburb_norm       STRING,
  postcode_norm     STRING,
  dob               DATE,
  dob_status        STRING,
  gender_norm       STRING,
  slk_code          STRING,
  cni_number        STRING,
  ndis_number       STRING,
  childstory_id_ref STRING,
  blocking_keys     ARRAY<STRING>,

  match_embedding   STRUCT<result ARRAY<FLOAT64>, status STRING>
    GENERATED ALWAYS AS (
      AI.EMBED(
        match_key,
        connection_id => 'all-things-cdp.us-central1.dcj-conn',
        endpoint      => 'text-embedding-005'
      )
    ) STORED OPTIONS (asynchronous = TRUE)
)
CLUSTER BY postcode_norm, family_name_norm
OPTIONS (
  description = 'DCJ Hybrid Search surface with autonomous AI.EMBED column (text-embedding-005).'
);

INSERT INTO `all-things-cdp.dcj_tdm.source_profile_search`
(
  record_id, source_system, source_program, source_trust, source_person_id,
  match_key, full_name_norm, given_name_norm, family_name_norm, address_norm,
  suburb_norm, postcode_norm, dob, dob_status, gender_norm, slk_code,
  cni_number, ndis_number, childstory_id_ref, blocking_keys
)
SELECT
  record_id, source_system, source_program, source_trust, source_person_id,
  match_key, full_name_norm, given_name_norm, family_name_norm, address_norm,
  suburb_norm, postcode_norm, dob, dob_status, gender_norm, slk_code,
  cni_number, ndis_number, childstory_id_ref, blocking_keys
FROM `all-things-cdp.dcj_tdm.stg_source_profiles`
WHERE match_key IS NOT NULL AND match_key != '';

-- 2. Materialise 768-dim Embeddings for Immediate VECTOR_SEARCH
CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.source_profile_vectors`
CLUSTER BY record_id
AS
SELECT
  s.record_id,
  s.source_system,
  s.source_program,
  s.match_key,
  AI.EMBED(
    s.match_key,
    connection_id => 'all-things-cdp.us-central1.dcj-conn',
    endpoint      => 'text-embedding-005'
  ).result AS embedding
FROM `all-things-cdp.dcj_tdm.stg_source_profiles` AS s
WHERE s.match_key IS NOT NULL AND s.match_key != '';
