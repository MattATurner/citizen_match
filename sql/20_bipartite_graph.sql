-- =====================================================================
-- 20 · Bipartite Identifier Graph, IDF Rarity & Hub Detection
--
-- Constructs the Profile <-> Identifier Bipartite Graph:
--   1. `dcj_match.has_identifier`     (SourceRecord -> Identifier edges)
--   2. `dcj_match.identifier`         (Identifier nodes with degree,
--                                    IDF rarity weight LN(N/degree), and
--                                    promiscuous hub detection for crisis
--                                    refuges and shared caseworker phones)
--   3. `dcj_match.profile_projection` (2-hop shared-identifier projection)
-- =====================================================================

-- 1. Extract Profile -> Identifier links
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.has_identifier`
CLUSTER BY record_id, identifier_id
AS
WITH raw_links AS (
  SELECT record_id, source_system, record_ts, CONCAT('CS:', childstory_id_ref) AS identifier_id, 'CHILDSTORY_ID' AS identifier_type, TRUE AS is_anchor
  FROM `all-things-cdp.dcj_match.stg_source_profiles` WHERE childstory_id_ref IS NOT NULL
  UNION ALL
  SELECT record_id, source_system, record_ts, CONCAT('CNI:', cni_number), 'CNI_NUMBER', TRUE
  FROM `all-things-cdp.dcj_match.stg_source_profiles` WHERE cni_number IS NOT NULL
  UNION ALL
  SELECT record_id, source_system, record_ts, CONCAT('NDIS:', ndis_number), 'NDIS_NUMBER', TRUE
  FROM `all-things-cdp.dcj_match.stg_source_profiles` WHERE ndis_number IS NOT NULL
  UNION ALL
  SELECT record_id, source_system, record_ts, CONCAT('SLK:', slk_code), 'SLK_581', FALSE
  FROM `all-things-cdp.dcj_match.stg_source_profiles` WHERE slk_code IS NOT NULL
  UNION ALL
  SELECT record_id, source_system, record_ts, CONCAT('PH:', phone_e164), 'PHONE', FALSE
  FROM `all-things-cdp.dcj_match.stg_source_profiles` WHERE phone_e164 IS NOT NULL
  UNION ALL
  SELECT record_id, source_system, record_ts, CONCAT('EM:', email_norm), 'EMAIL', FALSE
  FROM `all-things-cdp.dcj_match.stg_source_profiles` WHERE email_norm IS NOT NULL
  UNION ALL
  SELECT record_id, source_system, record_ts, CONCAT('GNAF:', gnaf_address_id), 'GNAF_ADDRESS', FALSE
  FROM `all-things-cdp.dcj_match.stg_source_profiles` WHERE gnaf_address_id IS NOT NULL
)
SELECT
  record_id,
  identifier_id,
  ANY_VALUE(identifier_type) AS identifier_type,
  LOGICAL_OR(is_anchor) AS is_anchor,
  STRING_AGG(DISTINCT source_system, '|' ORDER BY source_system) AS sources,
  MIN(record_ts) AS first_seen_ts
FROM raw_links
GROUP BY record_id, identifier_id;

-- 2. Identifier Nodes with Degree, IDF Rarity & Promiscuous Hub Detection
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.identifier`
CLUSTER BY identifier_id
AS
WITH corpus AS (
  SELECT COUNT(*) AS total_records FROM `all-things-cdp.dcj_match.stg_source_profiles`
),
agg AS (
  SELECT
    h.identifier_id,
    ANY_VALUE(h.identifier_type) AS identifier_type,
    COUNT(DISTINCT h.record_id) AS degree,
    COUNTIF(h.is_anchor) AS n_anchor_links,
    STRING_AGG(DISTINCT h.sources, '|') AS sources,
    MIN(h.first_seen_ts) AS first_seen_ts,
    MAX(h.first_seen_ts) AS last_seen_ts
  FROM `all-things-cdp.dcj_match.has_identifier` AS h
  GROUP BY h.identifier_id
)
SELECT
  a.identifier_id,
  a.identifier_type,
  a.degree,
  a.n_anchor_links,
  -- Inverse Document Frequency rarity: LN(N / degree). Promiscuous hubs (>12 records) get 0 weight.
  IF(a.degree > 12, 0.0, ROUND(LN(SAFE_DIVIDE(c.total_records, a.degree)), 4)) AS idf_weight,
  -- Crisis refuges, residential care homes, and DCJ intake phones/emails are shared by >12 unrelated clients
  a.degree > 12 AS is_promiscuous,
  a.sources,
  a.first_seen_ts,
  a.last_seen_ts
FROM agg AS a
CROSS JOIN corpus AS c;

-- 3. 2-Hop Bipartite Projection (Record A <-> Shared Identifier <-> Record B)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_match.profile_projection`
CLUSTER BY record_id_a, record_id_b
AS
SELECT
  a.record_id AS record_id_a,
  b.record_id AS record_id_b,
  ARRAY_AGG(DISTINCT i.identifier_id ORDER BY i.identifier_id) AS shared_identifiers,
  ARRAY_AGG(DISTINCT i.identifier_type ORDER BY i.identifier_type) AS shared_id_types,
  ROUND(SUM(i.idf_weight), 4) AS weight,
  ROUND(SUM(IF(NOT i.is_promiscuous, i.idf_weight, 0.0)), 4) AS non_hub_idf_sum,
  MIN(i.degree) AS min_shared_degree,
  LOGICAL_OR(i.is_promiscuous) AS via_hub,
  LOGICAL_AND(i.is_promiscuous) AS hub_only
FROM `all-things-cdp.dcj_match.has_identifier` AS a
JOIN `all-things-cdp.dcj_match.has_identifier` AS b
  ON a.identifier_id = b.identifier_id
 AND a.record_id < b.record_id
JOIN `all-things-cdp.dcj_match.identifier` AS i
  ON i.identifier_id = a.identifier_id
GROUP BY a.record_id, b.record_id;
