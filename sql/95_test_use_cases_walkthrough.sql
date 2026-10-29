-- =====================================================================
-- 95 · End-to-End NSW DCJ Test Use-Cases & Walkthrough Verification Suite
--
-- Exercises all 8 statutory, cultural, kinship, and crisis-property scenarios
-- across `fn_frontline_person_search`, `fn_person_match`,
-- `fn_frontline_property_search`, `GRAPH_TABLE(dcj_tdm.dcj_person_graph)`,
-- `field_survivorship`, `person_match_adjudications`, and ground-truth views.
-- =====================================================================

-- Test 1 · CROSSOVER_YOUTH: Diminutive 'Lachie Smith' across ChildStory, InfoShare & KIMS YJ
SELECT
  'TEST_01_CROSSOVER_YOUTH' AS test_case,
  match_rank,
  person_id,
  primary_full_name,
  date_of_birth,
  source_record_count,
  contributing_programs,
  matched_source_records,
  hybrid_match_score,
  recommended_action
FROM `all-things-cdp.dcj_match.fn_frontline_person_search`(
  'Lachie Smith', 'Lachie', 'Smith', NULL, NULL, NULL, NULL, NULL, NULL, NULL
)
WHERE match_rank <= 2;

-- Test 2 · TWIN_SIBLING_SLK_COLLISION: Twin Sisters Chloe & Phoebe Clark Kept Separate + Audit Trail
SELECT
  'TEST_02_TWIN_SLK_GUARD' AS test_case,
  re.record_id_a,
  re.record_id_b,
  t.a_name,
  t.b_name,
  t.a_dob,
  t.a_slk,
  t.b_slk,
  re.decision,
  re.decided_by,
  re.rationale,
  re.contradiction
FROM `all-things-cdp.dcj_match.resolution_edges` AS re
JOIN `all-things-cdp.dcj_match.candidate_pair_tiers` AS t
  ON t.record_id_a = re.record_id_a AND t.record_id_b = re.record_id_b
WHERE re.record_id_a IN (SELECT record_id FROM `all-things-cdp.dcj_match.person_assignment` WHERE person_id = 'PER-0EA1A1464868')
   OR re.record_id_b IN (SELECT record_id FROM `all-things-cdp.dcj_match.person_assignment` WHERE person_id = 'PER-0EA1A1464868')
ORDER BY t.twin_or_sibling_trap DESC, re.decision = 'LINK' DESC
LIMIT 5;

-- Test 3 · ATSI_CULTURAL_SKIN_NAME: First Nations Cultural Name 'Allira Campbell' -> Legal Spine 'Alice Campbell'
SELECT
  'TEST_03_ATSI_CULTURAL_NAME' AS test_case,
  match_rank,
  person_id,
  primary_full_name,
  indigenous_status,
  all_known_names,
  contributing_programs,
  hybrid_match_score
FROM `all-things-cdp.dcj_match.fn_frontline_person_search`(
  'Allira Campbell', 'Allira', 'Campbell', NULL, NULL, NULL, NULL, NULL, NULL, NULL
)
WHERE match_rank = 1;

-- Test 4 · ADOPTIVE_FOSTER_NAME_CHANGE: Pre-Adoptive Surname 'Oliver Peachey' -> 'Oliver Lee Al-Mansoor'
SELECT
  'TEST_04_ADOPTIVE_NAME_CHANGE' AS test_case,
  match_rank,
  person_id,
  primary_full_name,
  all_known_names,
  contributing_programs,
  retrieved_by,
  hybrid_match_score
FROM `all-things-cdp.dcj_match.fn_frontline_person_search`(
  'Oliver Peachey', 'Oliver', 'Peachey', NULL, NULL, NULL, NULL, NULL, NULL, NULL
)
WHERE match_rank = 1;

-- Test 5 · DV_PROTECTED_PERSON_RELOCATION: Statutory Protection Banner & ISO GQL Protection Traversal
SELECT
  'TEST_05_DV_PROTECTED_PERSON' AS test_case,
  *
FROM GRAPH_TABLE(
  `all-things-cdp.dcj_tdm.dcj_person_graph`
  MATCH (p:Person)-[:HAS_PROTECTION_EVENT]->(pe:ProtectionEvent)-[:INITIATED_BY]->(org:Party)
  WHERE p.person_id = 'PER-B26A1D09250D'
  COLUMNS (
    p.person_id,
    p.is_protected_person,
    pe.protection_event_id,
    pe.reason,
    pe.protect_start_date,
    org.party_display_name AS initiating_authority
  )
);

-- Test 6 · ESTIMATED_VS_VERIFIED_DOB: Field-Level Survivorship Audit ('Alexander Robinson' PER-5AC911336C97)
SELECT
  'TEST_06_DOB_SURVIVORSHIP' AS test_case,
  person_id,
  field_name,
  surviving_value,
  won_from_program,
  won_from_record_id,
  source_trust,
  was_contested
FROM `all-things-cdp.dcj_match.field_survivorship`
WHERE person_id = 'PER-5AC911336C97'
ORDER BY was_contested DESC, field_name ASC;

-- Test 7 · CRISIS_REFUGE_HUB_HAIRBALL: 30-Resident Crisis Refuge Property Search & IDF=0.0 Suppression
SELECT
  'TEST_07_CRISIS_REFUGE_HUB' AS test_case,
  property_rank,
  address_id,
  building_name,
  full_address,
  is_crisis_hub,
  total_residents,
  protected_residents,
  bipartite_degree,
  idf_weight
FROM `all-things-cdp.dcj_match.fn_frontline_property_search`(
  '10 Great Western Hwy Parramatta'
)
WHERE property_rank = 1;

-- Test 8 · EXTENDED_KINSHIP_AND_HOUSEHOLD_GRAPH: Multi-Generational Property & ISO GQL Kinship Network
SELECT
  'TEST_08_KINSHIP_GRAPH' AS test_case,
  *
FROM GRAPH_TABLE(
  `all-things-cdp.dcj_tdm.dcj_person_graph`
  MATCH (p1:Party)-[rel:PARTY_RELATIONSHIP]->(p2:Party)
  WHERE p1.party_id = 'PER-698E72DBC085' OR p2.party_id = 'PER-698E72DBC085'
  COLUMNS (
    p1.party_id AS from_id,
    p1.party_display_name AS from_party,
    rel.canonical_relationship_type,
    rel.relationship_category,
    p2.party_id AS to_id,
    p2.party_display_name AS to_party,
    rel.source_program
  )
);

-- Test 9 · Automated Ground-Truth Regression Assertions (100% Precision, 100% Recall, 1.0000 F1, 0 Hairballs)
ASSERT (
  SELECT precision_pct = 100.0 AND recall_pct = 100.0 AND resolved_entities = 600 AND hairball_clusters = 0
  FROM `all-things-cdp.dcj_match.v_dcj_method_comparison`
  WHERE method = '3_dcj_hybrid_genai'
) AS 'Regression failure: 3_dcj_hybrid_genai must achieve 100% Precision, 100% Recall, 600 resolved entities, and 0 hairballs.';

ASSERT (
  SELECT COUNTIF(recall_pct < 100.0 OR false_merge_pairs > 0) = 0
  FROM `all-things-cdp.dcj_match.v_dcj_scenario_scorecard`
) AS 'Regression failure: All planted NSW DCJ scenarios must achieve 100% recall and 0 false merges.';
