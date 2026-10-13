-- =====================================================================
-- 40 · Hybrid Search Candidate Generation, Reciprocal Rank Fusion (RRF)
--      & 2-Hop Kinship/Household Tiered Scoring
--
-- Implements:
--   40a · Block size statistics & oversized block pruning (`block_stats`)
--   40b · Lexical / Deterministic blocking leg (`candidate_pairs_lexical`)
--   40c · Semantic vector search leg (`candidate_pairs_semantic` via `VECTOR_SEARCH`)
--   40d · Reciprocal Rank Fusion (`RRF`, k=60) (`candidate_pairs_fused`)
--   40e · 1-Hop Rarity + 2-Hop Kinship/Twin/Hub Features & Tiering (`candidate_pair_tiers`)
-- =====================================================================

-- 40a · Block size telemetry
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.block_stats`
AS
WITH exploded AS (
  SELECT record_id, key
  FROM `all-things-cdp.dcj_match.stg_source_profiles`, UNNEST(blocking_keys) AS key
)
SELECT
  key,
  SPLIT(key, ':')[OFFSET(0)] AS key_type,
  COUNT(*) AS members,
  COUNT(*) * (COUNT(*) - 1) / 2 AS pairs_implied,
  COUNT(*) > 250 AS oversized
FROM exploded
GROUP BY key
HAVING COUNT(*) > 1;

-- 40b · Lexical / Deterministic Candidate Leg
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.candidate_pairs_lexical`
CLUSTER BY record_id_a, record_id_b
AS
WITH exploded AS (
  SELECT p.record_id, key
  FROM `all-things-cdp.dcj_match.stg_source_profiles` AS p, UNNEST(p.blocking_keys) AS key
),
usable AS (
  SELECT e.record_id, e.key
  FROM exploded AS e
  JOIN `all-things-cdp.dcj_match.block_stats` AS b USING (key)
  WHERE NOT b.oversized
),
paired AS (
  SELECT
    a.record_id AS record_id_a,
    b.record_id AS record_id_b,
    a.key
  FROM usable AS a
  JOIN usable AS b
    ON a.key = b.key
   AND a.record_id < b.record_id
)
SELECT
  record_id_a,
  record_id_b,
  ARRAY_AGG(DISTINCT SPLIT(key, ':')[OFFSET(0)] ORDER BY SPLIT(key, ':')[OFFSET(0)]) AS key_types,
  ARRAY_AGG(DISTINCT key ORDER BY key) AS matched_keys,
  MAX(CASE SPLIT(key, ':')[OFFSET(0)]
        WHEN 'CS'   THEN 100
        WHEN 'CNI'  THEN 100
        WHEN 'NDIS' THEN 95
        WHEN 'PH'   THEN 80
        WHEN 'EM'   THEN 80
        WHEN 'SLK'  THEN 75
        WHEN 'ND'   THEN 75
        WHEN 'FD'   THEN 70
        WHEN 'GNAF' THEN 55
        WHEN 'AD'   THEN 55
        WHEN 'NY'   THEN 45
        WHEN 'SX'   THEN 25
        ELSE 10
      END) AS block_strength,
  COUNT(DISTINCT key) AS keys_shared
FROM paired
GROUP BY record_id_a, record_id_b;

-- 40c · Semantic Vector Search Leg (COSINE top_k = 15)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.candidate_pairs_semantic`
CLUSTER BY record_id_a, record_id_b
AS
WITH knn AS (
  SELECT
    query.record_id AS probe_id,
    base.record_id  AS match_id,
    distance
  FROM VECTOR_SEARCH(
    TABLE `all-things-cdp.dcj_match.source_profile_vectors`, 'embedding',
    (SELECT record_id, embedding FROM `all-things-cdp.dcj_match.source_profile_vectors`),
    'embedding',
    top_k         => 15,
    distance_type => 'COSINE'
  )
  WHERE query.record_id != base.record_id
)
SELECT
  LEAST(probe_id, match_id)    AS record_id_a,
  GREATEST(probe_id, match_id) AS record_id_b,
  MIN(distance)                AS cosine_distance,
  ROUND(1 - MIN(distance), 4)  AS semantic_similarity,
  COUNT(*) = 2                 AS is_mutual_nn
FROM knn
GROUP BY record_id_a, record_id_b;

-- 40d · Reciprocal Rank Fusion (RRF, k = 60)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.candidate_pairs_fused`
CLUSTER BY record_id_a, record_id_b
AS
WITH all_pairs AS (
  SELECT record_id_a, record_id_b FROM `all-things-cdp.dcj_match.candidate_pairs_lexical`
  UNION DISTINCT
  SELECT record_id_a, record_id_b FROM `all-things-cdp.dcj_match.candidate_pairs_semantic`
),
joined AS (
  SELECT
    p.record_id_a,
    p.record_id_b,
    l.block_strength,
    l.key_types,
    l.matched_keys,
    l.keys_shared,
    s.semantic_similarity,
    s.is_mutual_nn,
    l.block_strength IS NOT NULL      AS found_lexical,
    s.semantic_similarity IS NOT NULL AS found_semantic
  FROM all_pairs AS p
  LEFT JOIN `all-things-cdp.dcj_match.candidate_pairs_lexical` AS l
    ON l.record_id_a = p.record_id_a AND l.record_id_b = p.record_id_b
  LEFT JOIN `all-things-cdp.dcj_match.candidate_pairs_semantic` AS s
    ON s.record_id_a = p.record_id_a AND s.record_id_b = p.record_id_b
),
directed_ranks AS (
  SELECT
    record_id_a,
    record_id_b,
    IF(found_lexical,
       RANK() OVER (PARTITION BY probe ORDER BY block_strength DESC, keys_shared DESC),
       NULL) AS dir_rank_lexical,
    IF(found_semantic,
       RANK() OVER (PARTITION BY probe ORDER BY semantic_similarity DESC),
       NULL) AS dir_rank_semantic
  FROM (
    SELECT record_id_a AS probe, * FROM joined
    UNION ALL
    SELECT record_id_b AS probe, * FROM joined
  )
),
pair_ranks AS (
  SELECT
    record_id_a,
    record_id_b,
    MIN(dir_rank_lexical)  AS rank_lexical,
    MIN(dir_rank_semantic) AS rank_semantic
  FROM directed_ranks
  GROUP BY record_id_a, record_id_b
)
SELECT
  j.*,
  pr.rank_lexical,
  pr.rank_semantic,
  ROUND(
    IFNULL(SAFE_DIVIDE(1.0, 60 + pr.rank_lexical), 0.0)
    + IFNULL(SAFE_DIVIDE(1.0, 60 + pr.rank_semantic), 0.0),
    6
  ) AS rrf_score,
  CASE
    WHEN j.found_lexical AND j.found_semantic THEN 'BOTH'
    WHEN j.found_lexical                      THEN 'LEXICAL_ONLY'
    ELSE                                           'SEMANTIC_ONLY'
  END AS retrieved_by
FROM joined AS j
JOIN pair_ranks AS pr USING (record_id_a, record_id_b);

-- 40e · Enrich with 1-Hop Bipartite Rarity, 2-Hop Kinship/Household Features & Tiering
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.candidate_pair_tiers`
CLUSTER BY tier, record_id_a
AS
WITH
-- Known kinship links in Child Protection (two people related to each other are distinct individuals!)
known_cp_kin AS (
  SELECT DISTINCT
    LEAST(SUBJECT_PERSON_NUMBER, RELATED_PERSON_NUMBER) AS cs_a,
    GREATEST(SUBJECT_PERSON_NUMBER, RELATED_PERSON_NUMBER) AS cs_b,
    ANY_VALUE(REL_TYPE) AS cp_rel_type
  FROM `all-things-cdp.dcj_sdm.cp_person_relation_file_4_ciw`
  WHERE SUBJECT_PERSON_NUMBER != RELATED_PERSON_NUMBER
  GROUP BY 1, 2
),
features AS (
  SELECT
    f.record_id_a,
    f.record_id_b,
    f.retrieved_by,
    f.rank_lexical,
    f.rank_semantic,
    f.rrf_score,
    IFNULL(f.block_strength, 0) AS block_strength,
    IFNULL(f.keys_shared, 0) AS keys_shared,
    IFNULL(f.semantic_similarity, 0.0) AS semantic_similarity,
    IFNULL(f.is_mutual_nn, FALSE) AS is_mutual_nn,
    -- Profile A attributes
    a.source_system AS a_source,
    a.source_program AS a_program,
    a.source_person_id AS a_source_id,
    a.full_name_norm AS a_name,
    a.given_name_norm AS a_forename,
    a.family_name_norm AS a_surname,
    a.alias_names_concat AS a_aliases,
    a.dob AS a_dob,
    a.dob_status AS a_dob_status,
    a.gender_norm AS a_gender,
    a.indigenous_status AS a_atsi,
    a.address_norm AS a_address,
    a.suburb_norm AS a_suburb,
    a.postcode_norm AS a_postcode,
    a.phone_e164 AS a_phone,
    a.email_norm AS a_email,
    a.childstory_id_ref AS a_cs_id,
    a.cni_number AS a_cni,
    a.ndis_number AS a_ndis,
    a.slk_code AS a_slk,
    a.kin_context AS a_kin,
    a.is_protected AS a_protected,
    -- Profile B attributes
    b.source_system AS b_source,
    b.source_program AS b_program,
    b.source_person_id AS b_source_id,
    b.full_name_norm AS b_name,
    b.given_name_norm AS b_forename,
    b.family_name_norm AS b_surname,
    b.alias_names_concat AS b_aliases,
    b.dob AS b_dob,
    b.dob_status AS b_dob_status,
    b.gender_norm AS b_gender,
    b.indigenous_status AS b_atsi,
    b.address_norm AS b_address,
    b.suburb_norm AS b_suburb,
    b.postcode_norm AS b_postcode,
    b.phone_e164 AS b_phone,
    b.email_norm AS b_email,
    b.childstory_id_ref AS b_cs_id,
    b.cni_number AS b_cni,
    b.ndis_number AS b_ndis,
    b.slk_code AS b_slk,
    b.kin_context AS b_kin,
    b.is_protected AS b_protected,
    -- 1-Hop Bipartite Identifier Rarity features
    IFNULL(pp.non_hub_idf_sum, 0.0) AS non_hub_idf_sum,
    IFNULL(pp.min_shared_degree, 999) AS min_shared_degree,
    IFNULL(pp.via_hub, FALSE) AS via_hub,
    IFNULL(pp.hub_only, FALSE) AS hub_only,
    pp.shared_identifiers,
    -- Exact identifier matches
    (a.childstory_id_ref IS NOT NULL AND a.childstory_id_ref = b.childstory_id_ref) AS cs_id_match,
    (a.cni_number IS NOT NULL AND a.cni_number = b.cni_number) AS cni_match,
    (a.ndis_number IS NOT NULL AND a.ndis_number = b.ndis_number) AS ndis_match,
    (a.slk_code IS NOT NULL AND a.slk_code = b.slk_code) AS slk_match,
    (a.phone_e164 IS NOT NULL AND a.phone_e164 = b.phone_e164 AND NOT IFNULL(pp.hub_only, FALSE)) AS phone_match,
    (a.email_norm IS NOT NULL AND a.email_norm = b.email_norm AND NOT IFNULL(pp.hub_only, FALSE)) AS email_match,
    (a.gnaf_address_id IS NOT NULL AND a.gnaf_address_id = b.gnaf_address_id AND NOT IFNULL(pp.hub_only, FALSE))
      OR (a.address_norm IS NOT NULL AND a.address_norm = b.address_norm AND a.postcode_norm = b.postcode_norm AND NOT IFNULL(pp.hub_only, FALSE)) AS address_match,
    -- Name & Alias Cross-Match Signals
    ROUND(1.0 - SAFE_DIVIDE(
      EDIT_DISTANCE(IFNULL(a.given_name_norm, ''), IFNULL(b.given_name_norm, '')),
      GREATEST(LENGTH(IFNULL(a.given_name_norm, '')), LENGTH(IFNULL(b.given_name_norm, '')), 1)
    ), 4) AS forename_similarity,
    ROUND(1.0 - SAFE_DIVIDE(
      EDIT_DISTANCE(IFNULL(a.family_name_norm, ''), IFNULL(b.family_name_norm, '')),
      GREATEST(LENGTH(IFNULL(a.family_name_norm, '')), LENGTH(IFNULL(b.family_name_norm, '')), 1)
    ), 4) AS surname_similarity,
    -- Check if A's forename appears in B's known forenames/aliases or vice versa
    EXISTS (
      SELECT 1 FROM UNNEST(a.all_forenames_norm) AS af
      JOIN UNNEST(b.all_forenames_norm) AS bf ON af = bf
    ) AS forename_or_alias_match,
    EXISTS (
      SELECT 1 FROM UNNEST(a.all_surnames_norm) AS asu
      JOIN UNNEST(b.all_surnames_norm) AS bsu ON asu = bsu
    ) AS surname_or_alias_match,
    -- Check if one forename is a prefix/diminutive of the other (e.g. LACHLAN / LACHIE, JAYDEN / JADEN)
    (SUBSTR(a.given_name_norm, 1, 3) = SUBSTR(b.given_name_norm, 1, 3)
     AND EDIT_DISTANCE(a.given_name_norm, b.given_name_norm) <= 3) AS diminutive_forename_match,
    -- Date of Birth Signals
    (a.dob IS NOT NULL AND a.dob = b.dob) AS dob_exact_match,
    (a.birth_year IS NOT NULL AND a.birth_year = b.birth_year) AS dob_year_match,
    (a.dob_status = 'ESTIMATED' OR b.dob_status = 'ESTIMATED') AS either_dob_estimated,
    (a.dob IS NOT NULL AND b.dob IS NOT NULL AND a.dob != b.dob
     AND a.dob_status = 'VERIFIED' AND b.dob_status = 'VERIFIED') AS verified_dob_conflict,
    -- 2-Hop Neighbourhood Divergence (Unshared Personal Identifiers)
    (a.cni_number IS NOT NULL AND b.cni_number IS NOT NULL AND a.cni_number != b.cni_number) AS cni_conflict,
    (a.ndis_number IS NOT NULL AND b.ndis_number IS NOT NULL AND a.ndis_number != b.ndis_number) AS ndis_conflict,
    (a.childstory_id_ref IS NOT NULL AND b.childstory_id_ref IS NOT NULL AND a.childstory_id_ref != b.childstory_id_ref) AS cs_id_conflict,
    -- Documented Kinship Conflict (Sibling / Parent-Child in Child Protection)
    kk.cp_rel_type AS documented_kin_relationship
  FROM `all-things-cdp.dcj_match.candidate_pairs_fused` AS f
  JOIN `all-things-cdp.dcj_match.stg_source_profiles` AS a ON a.record_id = f.record_id_a
  JOIN `all-things-cdp.dcj_match.stg_source_profiles` AS b ON b.record_id = f.record_id_b
  LEFT JOIN `all-things-cdp.dcj_match.profile_projection` AS pp
    ON pp.record_id_a = f.record_id_a AND pp.record_id_b = f.record_id_b
  LEFT JOIN known_cp_kin AS kk
    ON kk.cs_a = LEAST(IFNULL(a.childstory_id_ref, ''), IFNULL(b.childstory_id_ref, ''))
   AND kk.cs_b = GREATEST(IFNULL(a.childstory_id_ref, ''), IFNULL(b.childstory_id_ref, ''))
),
scored AS (
  SELECT
    *,
    -- Forename conflict: distinct forenames that do NOT match via alias or diminutive
    (a_forename != b_forename
     AND NOT forename_or_alias_match
     AND NOT diminutive_forename_match
     AND forename_similarity < 0.75) AS forename_conflict,
    -- Twin / Sibling SLK-581 Collision Trap: same DOB + same SLK + same address/phone, but distinct forenames!
    (dob_exact_match AND (slk_match OR address_match OR phone_match)
     AND a_forename != b_forename
     AND NOT forename_or_alias_match
     AND NOT diminutive_forename_match) AS twin_or_sibling_trap,
    -- Composite Hybrid Score in [0, 1] combining RRF, Bipartite IDF Rarity, Semantic Similarity & Attribute Agreement
    ROUND(
      LEAST(1.0, GREATEST(0.0,
        0.25 * LEAST(1.0, non_hub_idf_sum / 10.0)
        + 0.25 * semantic_similarity
        + 0.15 * LEAST(1.0, rrf_score * 30.0)
        + IF(cs_id_match OR cni_match OR ndis_match, 0.35, 0.0)
        + IF(phone_match OR email_match, 0.18, 0.0)
        + IF(address_match, 0.12, 0.0)
        + IF(dob_exact_match, 0.18, IF(dob_year_match AND either_dob_estimated, 0.12, 0.0))
        + IF(forename_or_alias_match, 0.15, IF(diminutive_forename_match, 0.10, 0.0))
        + IF(surname_or_alias_match, 0.12, 0.0)
        -- Penalties for contradictions
        - IF(verified_dob_conflict, 0.55, 0.0)
        - IF(cni_conflict OR ndis_conflict OR cs_id_conflict, 0.70, 0.0)
        - IF(documented_kin_relationship IS NOT NULL, 0.80, 0.0)
        - IF(hub_only, 0.45, 0.0)
      )),
      4
    ) AS combined_score
  FROM features
)
SELECT
  s.*,
  CASE
    -- 1. Hard Rejects: Documented Kinship (Siblings/Parent-Child), Hard ID Conflicts, Verified DOB Conflicts, or Hub-Only Collisions
    WHEN s.documented_kin_relationship IS NOT NULL THEN 'REJECT'
    WHEN s.cni_conflict OR s.ndis_conflict OR s.cs_id_conflict THEN 'REJECT'
    WHEN s.verified_dob_conflict THEN 'REJECT'
    WHEN s.hub_only AND (s.forename_conflict OR NOT s.dob_exact_match) THEN 'REJECT'

    -- 2. Grey Zone (Routes to Auditable Gemini Adjudicator):
    --    a) Twin / Sibling SLK-581 Collisions (same DOB + same SLK/address/phone, different forenames)
    --    b) Diminutive / Nickname Crossover Youth (e.g., Lachlan vs Lachie)
    --    c) Adoptive / Foster / Married Surname Changes (different raw surnames, matched via alias or forename+DOB+NDIS/phone)
    --    d) ATSI Cultural / Skin Names vs English Legal Names
    --    e) Estimated DOB vs Verified DOB (01-Jan estimate vs true DOB)
    WHEN s.twin_or_sibling_trap THEN 'GREY_ZONE'
    WHEN s.either_dob_estimated AND s.dob_year_match AND (s.forename_or_alias_match OR s.phone_match OR s.email_match) THEN 'GREY_ZONE'
    WHEN s.a_forename != s.b_forename AND (s.forename_or_alias_match OR s.diminutive_forename_match)
         AND (s.dob_exact_match OR s.cni_match OR s.address_match OR s.phone_match) THEN 'GREY_ZONE'
    WHEN s.a_surname != s.b_surname AND s.dob_exact_match
         AND (s.forename_or_alias_match OR s.ndis_match OR s.cni_match OR s.phone_match) THEN 'GREY_ZONE'
    WHEN s.combined_score >= 0.52 AND s.combined_score < 0.88 AND NOT s.forename_conflict THEN 'GREY_ZONE'

    -- 3. Auto-Match: Uncontested high-confidence matches with exact forename, surname, and verified DOB + rare identifier
    WHEN s.combined_score >= 0.88
         AND s.a_forename = s.b_forename
         AND s.a_surname = s.b_surname
         AND s.dob_exact_match
         AND NOT s.either_dob_estimated
         AND NOT s.twin_or_sibling_trap
         AND NOT s.hub_only THEN 'AUTO_MATCH'

    ELSE 'REJECT'
  END AS tier
FROM scored AS s;
