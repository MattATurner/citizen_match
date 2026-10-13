-- =====================================================================
-- 80 · Interactive `fn_person_match` Table-Valued Function (TVF)
--      & 3-Method Ground-Truth Benchmark Scorecard
-- =====================================================================

-- 80a · Callable Real-Time / Interactive Person Match Function (`dcj_match.fn_person_match`)
--       Combines Lexical/Identifier matching + AI.EMBED + VECTOR_SEARCH + RRF Ranking
--       and resolves directly to the Mastered Golden Person in `dcj_tdm.person`.
CREATE OR REPLACE TABLE FUNCTION `all-things-cdp.dcj_match.fn_person_match`(
  in_given_name  STRING,
  in_family_name STRING,
  in_dob         DATE,
  in_gender      STRING,
  in_address     STRING,
  in_suburb      STRING,
  in_postcode    STRING,
  in_phone       STRING,
  in_identifier  STRING
)
AS (
  WITH
  probe AS (
    SELECT
      UPPER(TRIM(`all-things-cdp.dcj_match.fold_diacritics`(in_given_name))) AS q_forename,
      UPPER(TRIM(`all-things-cdp.dcj_match.fold_diacritics`(in_family_name))) AS q_surname,
      in_dob AS q_dob,
      CASE
        WHEN UPPER(SUBSTR(IFNULL(in_gender, ''), 1, 1)) = 'M' THEN 'Male'
        WHEN UPPER(SUBSTR(IFNULL(in_gender, ''), 1, 1)) = 'F' THEN 'Female'
        ELSE 'Unknown'
      END AS q_gender,
      `all-things-cdp.dcj_sdm.standardize_address`(in_address) AS q_addr,
      UPPER(TRIM(in_suburb)) AS q_suburb,
      TRIM(in_postcode) AS q_postcode,
      `all-things-cdp.dcj_match.norm_phone`(in_phone) AS q_phone,
      UPPER(TRIM(in_identifier)) AS q_id,
      `all-things-cdp.dcj_match.compute_slk581`(in_given_name, in_family_name, in_dob, in_gender) AS q_slk,
      CONCAT(
        'NAME: ', UPPER(TRIM(CONCAT(IFNULL(in_given_name, ''), ' ', IFNULL(in_family_name, '')))),
        ' | DOB: ', IFNULL(CAST(in_dob AS STRING), 'UNKNOWN'),
        ' | SEX: ', IFNULL(in_gender, 'Unknown'),
        ' | ADDR: ', IFNULL(`all-things-cdp.dcj_sdm.standardize_address`(in_address), ''), ' ', IFNULL(UPPER(in_suburb), ''), ' ', IFNULL(in_postcode, ''),
        IF(in_phone IS NOT NULL, CONCAT(' | PH: ', `all-things-cdp.dcj_match.norm_phone`(in_phone)), ''),
        IF(in_identifier IS NOT NULL, CONCAT(' | ID: ', UPPER(TRIM(in_identifier))), '')
      ) AS probe_match_key
  ),
  probe_vec AS (
    SELECT
      p.*,
      AI.EMBED(
        p.probe_match_key,
        connection_id => 'all-things-cdp.us-central1.dcj-conn',
        endpoint      => 'text-embedding-005'
      ).result AS embedding
    FROM probe AS p
  ),
  -- Leg 1: Lexical & Deterministic Identifier Retrieval
  lexical_hits AS (
    SELECT
      s.record_id,
      (
        IF(p.q_id IS NOT NULL AND p.q_id != '' AND p.q_id IN (s.childstory_id_ref, s.cni_number, s.ndis_number, s.source_person_id), 100, 0)
        + IF(p.q_phone IS NOT NULL AND p.q_phone = s.phone_e164, 75, 0)
        + IF(p.q_slk IS NOT NULL AND p.q_slk = s.slk_code, 65, 0)
        + IF(p.q_surname IS NOT NULL AND p.q_surname != '' AND p.q_surname IN UNNEST(s.all_surnames_norm), 45, 0)
        + IF(p.q_forename IS NOT NULL AND p.q_forename != '' AND (p.q_forename IN UNNEST(s.all_forenames_norm) OR SUBSTR(p.q_forename, 1, 3) = SUBSTR(s.given_name_norm, 1, 3)), 35, 0)
        + IF(p.q_dob IS NOT NULL AND p.q_dob = s.dob, 45, IF(p.q_dob IS NOT NULL AND EXTRACT(YEAR FROM p.q_dob) = s.birth_year AND s.dob_status = 'ESTIMATED', 25, 0))
        + IF(p.q_postcode IS NOT NULL AND p.q_postcode = s.postcode_norm, 20, 0)
      ) AS lexical_strength
    FROM `all-things-cdp.dcj_match.stg_source_profiles` AS s
    CROSS JOIN probe AS p
    WHERE
      (p.q_id IS NOT NULL AND p.q_id != '' AND p.q_id IN (s.childstory_id_ref, s.cni_number, s.ndis_number, s.source_person_id))
      OR (p.q_phone IS NOT NULL AND p.q_phone = s.phone_e164)
      OR (p.q_slk IS NOT NULL AND p.q_slk = s.slk_code)
      OR (p.q_surname IS NOT NULL AND p.q_surname != '' AND p.q_surname IN UNNEST(s.all_surnames_norm))
      OR (p.q_dob IS NOT NULL AND p.q_dob = s.dob)
  ),
  lexical_ranked AS (
    SELECT
      record_id,
      lexical_strength,
      RANK() OVER (ORDER BY lexical_strength DESC) AS rank_lexical
    FROM lexical_hits
    WHERE lexical_strength >= 40
    QUALIFY rank_lexical <= 25
  ),
  -- Leg 2: Semantic Vector Retrieval via VECTOR_SEARCH
  semantic_hits AS (
    SELECT
      base.record_id,
      ROUND(1.0 - distance, 4) AS semantic_similarity,
      RANK() OVER (ORDER BY distance ASC) AS rank_semantic
    FROM VECTOR_SEARCH(
      TABLE `all-things-cdp.dcj_match.source_profile_vectors`, 'embedding',
      (SELECT embedding FROM probe_vec),
      'embedding',
      top_k         => 25,
      distance_type => 'COSINE'
    )
  ),
  -- Fuse via Reciprocal Rank Fusion (RRF, k = 60)
  fused AS (
    SELECT
      COALESCE(l.record_id, s.record_id) AS record_id,
      l.lexical_strength,
      l.rank_lexical,
      s.semantic_similarity,
      s.rank_semantic,
      ROUND(
        IFNULL(SAFE_DIVIDE(1.0, 60 + l.rank_lexical), 0.0)
        + IFNULL(SAFE_DIVIDE(1.0, 60 + s.rank_semantic), 0.0),
        6
      ) AS rrf_score,
      CASE
        WHEN l.record_id IS NOT NULL AND s.record_id IS NOT NULL THEN 'BOTH'
        WHEN l.record_id IS NOT NULL                             THEN 'LEXICAL_ONLY'
        ELSE                                                          'SEMANTIC_ONLY'
      END AS retrieved_by
    FROM lexical_ranked AS l
    FULL OUTER JOIN semantic_hits AS s USING (record_id)
  ),
  -- Roll up to Mastered Golden Person in `dcj_tdm.person`
  person_rollup AS (
    SELECT
      lnk.person_id,
      MAX(f.rrf_score) AS rrf_score,
      MAX(IFNULL(f.semantic_similarity, 0.0)) AS semantic_similarity,
      MAX(IFNULL(f.lexical_strength, 0)) AS lexical_strength,
      STRING_AGG(DISTINCT f.retrieved_by, ', ' ORDER BY f.retrieved_by) AS retrieved_by,
      STRING_AGG(DISTINCT CONCAT(lnk.source_app_id, ':', lnk.source_person_id), ', ' ORDER BY CONCAT(lnk.source_app_id, ':', lnk.source_person_id)) AS matched_source_records,
      STRING_AGG(DISTINCT lnk.source_program, ', ' ORDER BY lnk.source_program) AS contributing_programs
    FROM fused AS f
    JOIN `all-things-cdp.dcj_tdm.person_source_linkage` AS lnk
      ON lnk.source_record_id = f.record_id
    GROUP BY lnk.person_id
  )
  SELECT
    RANK() OVER (ORDER BY pr.rrf_score DESC, pr.lexical_strength DESC, pr.semantic_similarity DESC) AS match_rank,
    pr.person_id,
    p_nm.full_name AS primary_full_name,
    all_nm.all_known_names,
    per.date_of_birth,
    per.dob_certainty_code,
    per.gender,
    per.indigenous_status,
    per.is_protected_person,
    addr.full_address AS primary_address,
    pr.contributing_programs,
    pr.matched_source_records,
    pr.retrieved_by,
    pr.rrf_score,
    pr.semantic_similarity,
    pr.lexical_strength,
    ROUND(
      LEAST(1.0, 0.45 * LEAST(1.0, pr.lexical_strength / 180.0) + 0.35 * pr.semantic_similarity + 0.20 * LEAST(1.0, pr.rrf_score * 32.0)),
      4
    ) AS hybrid_match_score,
    CASE
      WHEN pr.lexical_strength >= 140 AND pr.semantic_similarity >= 0.80 THEN 'AUTO_LINK'
      WHEN pr.lexical_strength >= 75 OR pr.semantic_similarity >= 0.72   THEN 'GEMINI_ADJUDICATE_OR_STEWARD'
      ELSE                                                                    'LOW_CONFIDENCE_CANDIDATE'
    END AS recommended_action
  FROM person_rollup AS pr
  JOIN `all-things-cdp.dcj_tdm.person` AS per USING (person_id)
  LEFT JOIN (
    SELECT person_id, ANY_VALUE(full_name) AS full_name
    FROM `all-things-cdp.dcj_tdm.person_name`
    WHERE primary_name_flag
    GROUP BY person_id
  ) AS p_nm USING (person_id)
  LEFT JOIN (
    SELECT person_id, STRING_AGG(DISTINCT CONCAT(full_name, ' (', IFNULL(name_usage_code, 'Unspecified'), ')'), '; ') AS all_known_names
    FROM `all-things-cdp.dcj_tdm.person_name`
    GROUP BY person_id
  ) AS all_nm USING (person_id)
  LEFT JOIN (
    SELECT ar.person_id, ANY_VALUE(al.full_address) AS full_address
    FROM `all-things-cdp.dcj_tdm.address_relation` AS ar
    JOIN `all-things-cdp.dcj_tdm.address_location` AS al ON al.id = ar.address_location_id
    WHERE ar.primary_address_flag
    GROUP BY ar.person_id
  ) AS addr USING (person_id)
  ORDER BY match_rank ASC
  LIMIT 10
);

-- =====================================================================
-- 80b · 3-Method Benchmark (Baseline SLK+Hub CC vs. IDF Weighted CC vs.
--       DCJ Hybrid Search + RRF + Gemini Adjudicator + Contradiction Guard)
-- =====================================================================

-- Method 1: Naive Connected Components over all shared identifiers (including SLK-581 & Refuge Hubs)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.edges_baseline_cc`
AS
WITH id_anchors AS (
  SELECT
    record_id,
    MIN(record_id) OVER (PARTITION BY identifier_id) AS anchor_record_id
  FROM `all-things-cdp.dcj_match.has_identifier`
)
SELECT DISTINCT record_id AS src, anchor_record_id AS dst
FROM id_anchors WHERE record_id != anchor_record_id
UNION DISTINCT
SELECT DISTINCT anchor_record_id AS src, record_id AS dst
FROM id_anchors WHERE record_id != anchor_record_id;

CALL `all-things-cdp.dcj_match.sp_connected_components`(
  'all-things-cdp.dcj_match.graph_nodes',
  'all-things-cdp.dcj_match.edges_baseline_cc',
  'all-things-cdp.dcj_match.cc_baseline',
  15
);

-- Method 2: Deterministic IDF-Weighted CC (non_hub_idf_sum >= 6.5, no LLM or semantic vector leg)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.edges_weighted_cc`
AS
SELECT record_id_a AS src, record_id_b AS dst
FROM `all-things-cdp.dcj_match.profile_projection`
WHERE non_hub_idf_sum >= 6.5 AND NOT hub_only
UNION ALL
SELECT record_id_b AS src, record_id_a AS dst
FROM `all-things-cdp.dcj_match.profile_projection`
WHERE non_hub_idf_sum >= 6.5 AND NOT hub_only;

CALL `all-things-cdp.dcj_match.sp_connected_components`(
  'all-things-cdp.dcj_match.graph_nodes',
  'all-things-cdp.dcj_match.edges_weighted_cc',
  'all-things-cdp.dcj_match.cc_weighted',
  15
);

-- Pairwise Evaluation across all 3 methods against `dcj_truth.ground_truth_pairs`
CREATE OR REPLACE VIEW `all-things-cdp.dcj_match.v_dcj_method_comparison` AS
WITH
all_methods AS (
  SELECT '1_naive_slk_and_hub_cc' AS method, node AS record_id, comp AS cluster_id FROM `all-things-cdp.dcj_match.cc_baseline`
  UNION ALL
  SELECT '2_deterministic_idf_cc' AS method, node AS record_id, comp AS cluster_id FROM `all-things-cdp.dcj_match.cc_weighted`
  UNION ALL
  SELECT '3_dcj_hybrid_genai'     AS method, record_id, person_id AS cluster_id    FROM `all-things-cdp.dcj_match.person_assignment`
),
predicted_pairs AS (
  SELECT
    a.method,
    a.record_id AS record_id_a,
    b.record_id AS record_id_b
  FROM all_methods AS a
  JOIN all_methods AS b
    ON a.method = b.method
   AND a.cluster_id = b.cluster_id
   AND a.record_id < b.record_id
),
truth AS (
  SELECT record_id_a, record_id_b, scenario
  FROM `all-things-cdp.dcj_truth.ground_truth_pairs`
),
truth_total AS (
  SELECT COUNT(*) AS n_true_pairs FROM truth
),
cluster_stats AS (
  SELECT
    method,
    COUNT(DISTINCT cluster_id) AS resolved_entities,
    MAX(cnt) AS largest_cluster,
    COUNTIF(cnt >= 15) AS hairball_clusters
  FROM (
    SELECT method, cluster_id, COUNT(*) AS cnt
    FROM all_methods
    GROUP BY method, cluster_id
  )
  GROUP BY method
),
pair_eval AS (
  SELECT
    p.method,
    COUNT(*) AS predicted_pairs,
    COUNTIF(t.record_id_a IS NOT NULL) AS true_positives,
    COUNTIF(t.record_id_a IS NULL) AS false_positives
  FROM predicted_pairs AS p
  LEFT JOIN truth AS t
    ON t.record_id_a = p.record_id_a AND t.record_id_b = p.record_id_b
  GROUP BY p.method
)
SELECT
  e.method,
  cs.resolved_entities,
  cs.largest_cluster,
  cs.hairball_clusters,
  e.true_positives AS pairwise_tp,
  e.false_positives AS pairwise_fp,
  (tt.n_true_pairs - e.true_positives) AS pairwise_fn,
  ROUND(100.0 * SAFE_DIVIDE(e.true_positives, e.predicted_pairs), 2) AS precision_pct,
  ROUND(100.0 * SAFE_DIVIDE(e.true_positives, tt.n_true_pairs), 2) AS recall_pct,
  ROUND(
    SAFE_DIVIDE(
      2.0 * SAFE_DIVIDE(e.true_positives, e.predicted_pairs) * SAFE_DIVIDE(e.true_positives, tt.n_true_pairs),
      SAFE_DIVIDE(e.true_positives, e.predicted_pairs) + SAFE_DIVIDE(e.true_positives, tt.n_true_pairs)
    ),
    4
  ) AS f1_score
FROM pair_eval AS e
JOIN cluster_stats AS cs USING (method)
CROSS JOIN truth_total AS tt
ORDER BY e.method;

-- Scenario-by-Scenario Recall & False-Merge Breakdown
CREATE OR REPLACE VIEW `all-things-cdp.dcj_match.v_dcj_scenario_scorecard` AS
WITH
pred AS (
  SELECT
    a.record_id AS record_id_a,
    b.record_id AS record_id_b
  FROM `all-things-cdp.dcj_match.person_assignment` AS a
  JOIN `all-things-cdp.dcj_match.person_assignment` AS b
    ON a.person_id = b.person_id AND a.record_id < b.record_id
),
recall_by_scenario AS (
  SELECT
    t.scenario,
    COUNT(*) AS true_pairs,
    COUNTIF(p.record_id_a IS NOT NULL) AS matched_tp,
    ROUND(100.0 * COUNTIF(p.record_id_a IS NOT NULL) / COUNT(*), 2) AS recall_pct
  FROM `all-things-cdp.dcj_truth.ground_truth_pairs` AS t
  LEFT JOIN pred AS p
    ON p.record_id_a = t.record_id_a AND p.record_id_b = t.record_id_b
  GROUP BY t.scenario
),
fp_by_scenario AS (
  SELECT
    ga.scenario,
    COUNT(*) AS false_merges
  FROM pred AS p
  JOIN `all-things-cdp.dcj_truth.ground_truth_records` AS ga ON ga.source_record_id = p.record_id_a
  JOIN `all-things-cdp.dcj_truth.ground_truth_records` AS gb ON gb.source_record_id = p.record_id_b
  WHERE ga.true_person_id != gb.true_person_id
  GROUP BY ga.scenario
)
SELECT
  s.scenario,
  COUNT(DISTINCT s.true_person_id) AS true_people,
  COUNT(DISTINCT s.source_record_id) AS source_records,
  IFNULL(r.true_pairs, 0) AS true_cross_record_pairs,
  IFNULL(r.matched_tp, 0) AS resolved_tp_pairs,
  IFNULL(fp.false_merges, 0) AS false_merge_pairs,
  IFNULL(r.recall_pct, 100.0) AS recall_pct
FROM `all-things-cdp.dcj_truth.ground_truth_records` AS s
LEFT JOIN recall_by_scenario AS r USING (scenario)
LEFT JOIN fp_by_scenario AS fp USING (scenario)
GROUP BY s.scenario, r.true_pairs, r.matched_tp, fp.false_merges, r.recall_pct
ORDER BY s.scenario;
