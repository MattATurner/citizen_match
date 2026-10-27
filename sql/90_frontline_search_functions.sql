-- =====================================================================
-- 90 · Frontline Person & Property Search Functions (`dcj_match`)
--
-- Wraps `fn_person_match` (AI.EMBED + VECTOR_SEARCH + Lexical + RRF)
-- and `GRAPH_TABLE(dcj_tdm.dcj_person_graph)` for the Frontline
-- Caseworker & Data Steward Search Application.
-- =====================================================================

-- 90a · Frontline Omnibox + Structured Person Search TVF
CREATE OR REPLACE TABLE FUNCTION `all-things-cdp.dcj_match.fn_frontline_person_search`(
  in_raw_query   STRING,
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
  q_clean AS (
    SELECT
      UPPER(TRIM(IFNULL(in_raw_query, ''))) AS q_raw,
      ARRAY(
        SELECT tok
        FROM UNNEST(SPLIT(REGEXP_REPLACE(UPPER(TRIM(IFNULL(in_raw_query, ''))), r'[,;|]+', ' '), ' ')) AS tok
        WHERE LENGTH(TRIM(tok)) >= 2
      ) AS q_tokens
  ),
  -- 1. Core Hybrid TVF (`fn_person_match`: Lexical + AI.EMBED + VECTOR_SEARCH + RRF)
  tvf_hits AS (
    SELECT
      person_id,
      rrf_score,
      semantic_similarity,
      lexical_strength,
      hybrid_match_score,
      retrieved_by,
      recommended_action
    FROM `all-things-cdp.dcj_match.fn_person_match`(
      in_given_name,
      in_family_name,
      in_dob,
      in_gender,
      in_address,
      in_suburb,
      in_postcode,
      in_phone,
      in_identifier
    )
  ),
  -- 2. Direct Omnibox Token Boost (catches Golden PER-... IDs, Cultural/Alias single-token searches, Street/Suburb, CNI/NDIS/SLK)
  omnibox_direct AS (
    SELECT
      a.person_id,
      MAX(
        (CASE
          WHEN qc.q_raw != '' AND a.person_id = qc.q_raw THEN 220
          WHEN qc.q_raw != '' AND qc.q_raw IN (s.record_id, s.source_person_id, IFNULL(s.childstory_id_ref, ''), IFNULL(s.cni_number, ''), IFNULL(s.ndis_number, ''), IFNULL(s.slk_code, '')) THEN 210
          ELSE 0
        END)
        + (SELECT IFNULL(SUM(
            CASE
              WHEN tok IN UNNEST(s.all_forenames_norm) AND tok IN UNNEST(s.all_surnames_norm) THEN 65
              WHEN tok IN UNNEST(s.all_surnames_norm) THEN 55
              WHEN tok IN UNNEST(s.all_forenames_norm) THEN 50
              WHEN SUBSTR(s.given_name_norm, 1, 3) = SUBSTR(tok, 1, 3) AND LENGTH(tok) >= 4 THEN 28
              WHEN tok = s.postcode_norm THEN 30
              WHEN s.suburb_norm = tok THEN 30
              WHEN s.address_norm LIKE CONCAT('%', tok, '%') THEN 22
              WHEN UPPER(IFNULL(s.alias_names_concat, '')) LIKE CONCAT('%', tok, '%') THEN 45
              WHEN UPPER(IFNULL(s.childstory_id_ref, '')) = tok OR UPPER(IFNULL(s.cni_number, '')) = tok OR UPPER(IFNULL(s.ndis_number, '')) = tok OR UPPER(IFNULL(s.slk_code, '')) = tok OR UPPER(s.source_person_id) = tok THEN 160
              ELSE 0
            END
          ), 0)
          FROM UNNEST(qc.q_tokens) AS tok
        )
      ) AS omni_boost
    FROM `all-things-cdp.dcj_match.stg_source_profiles` AS s
    JOIN `all-things-cdp.dcj_match.person_assignment` AS a USING (record_id)
    CROSS JOIN q_clean AS qc
    WHERE qc.q_raw != ''
    GROUP BY a.person_id
    HAVING omni_boost >= 40
  ),
  merged AS (
    SELECT
      COALESCE(t.person_id, o.person_id) AS person_id,
      IFNULL(t.rrf_score, 0.0120) AS rrf_score,
      IFNULL(t.semantic_similarity, 0.0) AS semantic_similarity,
      GREATEST(IFNULL(t.lexical_strength, 0), IFNULL(o.omni_boost, 0)) AS lexical_strength,
      ROUND(
        LEAST(
          1.0,
          GREATEST(
            IFNULL(t.hybrid_match_score, 0.0),
            0.50 * LEAST(1.0, GREATEST(IFNULL(t.lexical_strength, 0), IFNULL(o.omni_boost, 0)) / 150.0)
            + 0.35 * IFNULL(t.semantic_similarity, 0.65)
            + 0.15 * LEAST(1.0, IFNULL(t.rrf_score, 0.016) * 30.0)
          )
        ),
        4
      ) AS hybrid_match_score,
      CASE
        WHEN t.retrieved_by IS NOT NULL AND o.person_id IS NOT NULL AND t.retrieved_by = 'SEMANTIC_ONLY' THEN 'BOTH'
        WHEN t.retrieved_by IS NOT NULL THEN t.retrieved_by
        ELSE 'LEXICAL_ONLY'
      END AS retrieved_by
    FROM tvf_hits AS t
    FULL OUTER JOIN omnibox_direct AS o USING (person_id)
  ),
  audit_rollup AS (
    SELECT
      pa.person_id,
      COUNT(DISTINCT CASE WHEN re.decision = 'LINK' THEN CONCAT(re.record_id_a, '|', re.record_id_b) END) AS linked_pairs_count,
      COUNT(DISTINCT CASE WHEN re.decision != 'LINK' OR re.suppressed_by_contradiction THEN CONCAT(re.record_id_a, '|', re.record_id_b) END) AS vetoed_pairs_count,
      COUNT(DISTINCT CASE WHEN re.decided_by IN ('GEMINI_ADJUDICATOR', 'LLM_AND_TWIN_GUARD') THEN CONCAT(re.record_id_a, '|', re.record_id_b) END) AS ai_adjudicated_count,
      STRING_AGG(DISTINCT NULLIF(TRIM(adj.scenario_classified), ''), ' · ' LIMIT 3) AS adjudicated_scenarios
    FROM `all-things-cdp.dcj_match.person_assignment` AS pa
    JOIN `all-things-cdp.dcj_match.resolution_edges` AS re
      ON re.record_id_a = pa.record_id OR re.record_id_b = pa.record_id
    LEFT JOIN `all-things-cdp.dcj_match.v_adjudications_current` AS adj
      ON adj.record_id_a = re.record_id_a AND adj.record_id_b = re.record_id_b
    GROUP BY pa.person_id
  ),
  kin_rollup AS (
    SELECT
      party_id AS person_id,
      COUNT(DISTINCT other_id) AS kinship_count
    FROM (
      SELECT subject_party_id AS party_id, related_party_id AS other_id FROM `all-things-cdp.dcj_tdm.party_relationship`
      UNION ALL
      SELECT related_party_id AS party_id, subject_party_id AS other_id FROM `all-things-cdp.dcj_tdm.party_relationship`
    )
    GROUP BY party_id
  ),
  src_rollup AS (
    SELECT
      person_id,
      COUNT(DISTINCT source_record_id) AS source_record_count,
      STRING_AGG(DISTINCT CONCAT(source_app_id, ':', source_person_id), ', ' ORDER BY CONCAT(source_app_id, ':', source_person_id)) AS matched_source_records,
      STRING_AGG(DISTINCT source_program, ', ' ORDER BY source_program) AS contributing_programs
    FROM `all-things-cdp.dcj_tdm.person_source_linkage`
    GROUP BY person_id
  )
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY
        m.hybrid_match_score DESC,
        m.lexical_strength DESC,
        m.rrf_score DESC,
        m.semantic_similarity DESC
    ) AS match_rank,
    m.person_id,
    p_nm.full_name AS primary_full_name,
    all_nm.all_known_names,
    per.date_of_birth,
    per.dob_certainty_code,
    per.gender,
    per.indigenous_status,
    per.is_cald,
    per.is_protected_person,
    prot.reason AS protection_reason,
    addr.address_id AS primary_address_id,
    addr.full_address AS primary_address,
    addr.building_name AS primary_building_name,
    addr.suburb AS primary_suburb,
    addr.postcode AS primary_postcode,
    sr.source_record_count,
    sr.contributing_programs,
    sr.matched_source_records,
    IFNULL(kr.kinship_count, 0) AS kinship_count,
    IFNULL(ar.linked_pairs_count, 0) AS linked_pairs_count,
    IFNULL(ar.vetoed_pairs_count, 0) AS vetoed_pairs_count,
    IFNULL(ar.ai_adjudicated_count, 0) AS ai_adjudicated_count,
    ar.adjudicated_scenarios,
    m.retrieved_by,
    m.rrf_score,
    m.semantic_similarity,
    m.lexical_strength,
    m.hybrid_match_score,
    CASE
      WHEN m.lexical_strength >= 130 OR (m.lexical_strength >= 95 AND m.semantic_similarity >= 0.78) THEN 'AUTO_LINK'
      WHEN m.lexical_strength >= 65 OR m.semantic_similarity >= 0.72 THEN 'GEMINI_ADJUDICATE_OR_STEWARD'
      ELSE 'LOW_CONFIDENCE_CANDIDATE'
    END AS recommended_action
  FROM merged AS m
  JOIN `all-things-cdp.dcj_tdm.person` AS per USING (person_id)
  LEFT JOIN src_rollup AS sr USING (person_id)
  LEFT JOIN audit_rollup AS ar USING (person_id)
  LEFT JOIN kin_rollup AS kr USING (person_id)
  LEFT JOIN (
    SELECT person_id, ANY_VALUE(full_name) AS full_name
    FROM `all-things-cdp.dcj_tdm.person_name`
    WHERE primary_name_flag
    GROUP BY person_id
  ) AS p_nm USING (person_id)
  LEFT JOIN (
    SELECT
      person_id,
      STRING_AGG(DISTINCT CONCAT(REGEXP_REPLACE(full_name, r'\s+', ' '), ' [', IFNULL(name_usage_code, 'Name'), ']'), ' · ') AS all_known_names
    FROM `all-things-cdp.dcj_tdm.person_name`
    GROUP BY person_id
  ) AS all_nm USING (person_id)
  LEFT JOIN (
    SELECT
      ar2.person_id,
      ANY_VALUE(al.id) AS address_id,
      ANY_VALUE(al.full_address) AS full_address,
      ANY_VALUE(al.building_name) AS building_name,
      ANY_VALUE(al.suburb) AS suburb,
      ANY_VALUE(al.postcode) AS postcode
    FROM `all-things-cdp.dcj_tdm.address_relation` AS ar2
    JOIN `all-things-cdp.dcj_tdm.address_location` AS al ON al.id = ar2.address_location_id
    WHERE ar2.primary_address_flag
    GROUP BY ar2.person_id
  ) AS addr USING (person_id)
  LEFT JOIN (
    SELECT person_id, ANY_VALUE(reason) AS reason
    FROM `all-things-cdp.dcj_tdm.person_protection_event`
    GROUP BY person_id
  ) AS prot USING (person_id)
  ORDER BY match_rank ASC
  LIMIT 12
);

-- 90b · Frontline Property / GNAF Graph Search TVF (`GRAPH_TABLE` over `dcj_person_graph`)
CREATE OR REPLACE TABLE FUNCTION `all-things-cdp.dcj_match.fn_frontline_property_search`(
  in_query STRING
)
AS (
  WITH
  q AS (
    SELECT
      UPPER(TRIM(IFNULL(in_query, ''))) AS q_raw,
      ARRAY(
        SELECT tok
        FROM UNNEST(SPLIT(REGEXP_REPLACE(UPPER(TRIM(IFNULL(in_query, ''))), r'[,;|]+', ' '), ' ')) AS tok
        WHERE LENGTH(TRIM(tok)) >= 1
      ) AS toks
  ),
  graph_residents AS (
    SELECT *
    FROM GRAPH_TABLE(
      `all-things-cdp.dcj_tdm.dcj_person_graph`
      MATCH (p:Person)-[la:LIVES_AT]->(al:AddressLocation)
      COLUMNS (
        al.id AS address_id,
        al.building_name,
        al.full_address,
        al.number_first,
        al.street_name,
        al.street_type,
        al.suburb,
        al.postcode,
        al.state,
        al.latitude,
        al.longitude,
        al.record_type,
        p.person_id,
        p.is_protected_person,
        la.primary_address_flag,
        la.address_purpose,
        la.source_program
      )
    )
  ),
  names_lookup AS (
    SELECT person_id, ANY_VALUE(REGEXP_REPLACE(full_name, r'\s+', ' ')) AS primary_name
    FROM `all-things-cdp.dcj_tdm.person_name`
    WHERE primary_name_flag
    GROUP BY person_id
  ),
  prop_agg AS (
    SELECT
      gr.address_id,
      ANY_VALUE(gr.building_name) AS building_name,
      ANY_VALUE(gr.full_address) AS full_address,
      ANY_VALUE(gr.suburb) AS suburb,
      ANY_VALUE(gr.postcode) AS postcode,
      ANY_VALUE(gr.state) AS state,
      ANY_VALUE(gr.latitude) AS latitude,
      ANY_VALUE(gr.longitude) AS longitude,
      ANY_VALUE(gr.record_type) AS record_type,
      ANY_VALUE(gr.address_purpose) AS primary_purpose,
      COUNT(DISTINCT gr.person_id) AS total_residents,
      COUNT(DISTINCT IF(gr.primary_address_flag, gr.person_id, NULL)) AS current_residents,
      COUNT(DISTINCT IF(gr.is_protected_person, gr.person_id, NULL)) AS protected_residents,
      STRING_AGG(DISTINCT gr.source_program, ', ' ORDER BY gr.source_program) AS programs_at_property,
      STRING_AGG(DISTINCT nm.primary_name, ', ' ORDER BY nm.primary_name LIMIT 6) AS resident_preview
    FROM graph_residents AS gr
    LEFT JOIN names_lookup AS nm USING (person_id)
    GROUP BY gr.address_id
  ),
  scored AS (
    SELECT
      pa.*,
      IFNULL(id_node.degree, pa.total_residents) AS bipartite_degree,
      IFNULL(id_node.idf_weight, 0.0) AS idf_weight,
      (IFNULL(id_node.is_promiscuous, FALSE) OR STARTS_WITH(pa.address_id, 'GNAF-NSW-HUB')) AS is_crisis_hub,
      (
        IF(q.q_raw != '' AND UPPER(pa.address_id) = q.q_raw, 200, 0)
        + IF(q.q_raw != '' AND UPPER(IFNULL(pa.full_address, '')) LIKE CONCAT('%', q.q_raw, '%'), 120, 0)
        + IF(q.q_raw != '' AND UPPER(IFNULL(pa.building_name, '')) LIKE CONCAT('%', q.q_raw, '%'), 120, 0)
        + (SELECT IFNULL(SUM(
            CASE
              WHEN UPPER(pa.address_id) = tok THEN 150
              WHEN UPPER(IFNULL(pa.building_name, '')) LIKE CONCAT('%', tok, '%') THEN 45
              WHEN UPPER(IFNULL(pa.suburb, '')) = tok THEN 40
              WHEN pa.postcode = tok THEN 40
              WHEN UPPER(IFNULL(pa.full_address, '')) LIKE CONCAT('%', tok, '%') THEN 25
              WHEN UPPER(IFNULL(pa.resident_preview, '')) LIKE CONCAT('%', tok, '%') THEN 18
              ELSE 0
            END
          ), 0)
          FROM UNNEST(q.toks) AS tok
        )
      ) AS prop_score
    FROM prop_agg AS pa
    CROSS JOIN q
    LEFT JOIN `all-things-cdp.dcj_match.identifier` AS id_node
      ON id_node.identifier_id = CONCAT('GNAF:', pa.address_id)
    WHERE q.q_raw != ''
  )
  SELECT
    ROW_NUMBER() OVER (ORDER BY prop_score DESC, total_residents DESC) AS property_rank,
    address_id,
    building_name,
    full_address,
    suburb,
    postcode,
    state,
    latitude,
    longitude,
    record_type,
    primary_purpose,
    is_crisis_hub,
    bipartite_degree,
    idf_weight,
    total_residents,
    current_residents,
    protected_residents,
    programs_at_property,
    resident_preview,
    prop_score
  FROM scored
  WHERE prop_score >= 25
  ORDER BY property_rank ASC
  LIMIT 8
);
