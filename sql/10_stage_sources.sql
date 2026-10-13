-- =====================================================================
-- 10 · Stage & Normalise Cross-Program SDM Sources
--
-- Unifies Child Protection (ChildStory), Family Preservation (InfoShare),
-- and Youth Justice (KIMS) into a single normalised staging table
-- `dcj_tdm.stg_source_profiles` with:
--   - All historical, cultural, pre-adoptive, adopted & alias names
--   - Standardised GNAF & street addresses
--   - Government & statistical identifiers (ChildStoryID, CNI, NDIS, SLK-581)
--   - Known kinship/carer context for 2-hop graph disambiguation
--   - Canonical `match_key` and multi-leg `blocking_keys`
-- =====================================================================

CREATE OR REPLACE TABLE `all-things-cdp.dcj_tdm.stg_source_profiles`
CLUSTER BY postcode_norm, family_name_norm
AS
WITH
-- 1. Child Protection Names (Load 1 + Load 2 Materialized View)
cp_names_raw AS (
  SELECT
    CHILDSTORY_ID,
    FST_NAME,
    MID_NAME,
    LAST_NAME,
    TYPE AS name_usage_code,
    PRIMARY_FLG = 'Y' AS is_primary,
    W_INSERT_DT
  FROM `all-things-cdp.dcj_sdm.person_name_1st_batch`
  UNION ALL
  SELECT
    CHILDSTORY_ID,
    FST_NAME,
    MID_NAME,
    LAST_NAME,
    TYPE AS name_usage_code,
    PRIMARY_FLG = 'Y' AS is_primary,
    W_INSERT_DT
  FROM `all-things-cdp.dcj_sdm.cp_person_names_file_2_ciw`
),
cp_names_agg AS (
  SELECT
    CHILDSTORY_ID,
    ARRAY_AGG(
      STRUCT(
        FST_NAME AS given_name,
        MID_NAME AS middle_name,
        LAST_NAME AS family_name,
        name_usage_code,
        is_primary
      )
      ORDER BY is_primary DESC, W_INSERT_DT DESC
    ) AS names_arr,
    STRING_AGG(
      DISTINCT IF(NOT is_primary, CONCAT(IFNULL(FST_NAME, ''), ' ', IFNULL(LAST_NAME, ''), ' (', IFNULL(name_usage_code, 'Unspecified'), ')'), NULL),
      ' ; '
    ) AS alt_names_summary,
    ARRAY_AGG(DISTINCT UPPER(`all-things-cdp.dcj_tdm.fold_diacritics`(LAST_NAME)) IGNORE NULLS) AS all_surnames_norm,
    ARRAY_AGG(DISTINCT UPPER(`all-things-cdp.dcj_tdm.fold_diacritics`(FST_NAME)) IGNORE NULLS) AS all_forenames_norm
  FROM cp_names_raw
  GROUP BY CHILDSTORY_ID
),
-- 2. Child Protection Addresses
cp_addr_joined AS (
  SELECT
    r.CHILDSTORY_ID,
    l.GNAF_PID AS gnaf_address_id,
    l.FULL_ADDRESS,
    l.STREET_NUMBER_FIRST,
    l.STREET_NAME,
    l.STREET_TYPE,
    l.SUBURB,
    l.POSTCODE,
    l.STATE,
    l.RECORD_TYPE,
    r.ADDR_PURPOSE,
    r.START_DT,
    r.END_DT,
    ROW_NUMBER() OVER (PARTITION BY r.CHILDSTORY_ID ORDER BY r.PRIMARY_ADDR_FLG = 'Y' DESC, r.START_DT DESC) AS rn
  FROM `all-things-cdp.dcj_sdm.cp_address_rel_loc_ciw` AS r
  JOIN `all-things-cdp.dcj_sdm.cp_address_loc_ciw` AS l
    ON l.ADDR_LOC_ID = r.ADDR_LOC_ID
),
-- 3. Child Protection Kinship Summary
cp_kin_summary AS (
  SELECT
    SUBJECT_PERSON_NUMBER AS CHILDSTORY_ID,
    STRING_AGG(CONCAT(REL_TYPE, ':', RELATED_PERSON_NUMBER), ', ' ORDER BY RELATED_PERSON_NUMBER LIMIT 5) AS kin_summary,
    LOGICAL_OR(LOWER(REL_TYPE) IN ('sibling', 'brother', 'sister', 'half-sibling', 'half-brother', 'half-sister', 'step-sibling', 'foster sibling')) AS has_sibling_relation
  FROM `all-things-cdp.dcj_sdm.cp_person_relation_file_4_ciw`
  GROUP BY SUBJECT_PERSON_NUMBER
),
-- 4. Child Protection Base Records (Load 1 + Load 2 MV)
cp_persons_raw AS (
  SELECT *, 'Child Protection' AS source_program, 1 AS batch_num FROM `all-things-cdp.dcj_sdm.person_file`
  UNION ALL
  SELECT *, 2 AS batch_num FROM `all-things-cdp.dcj_sdm.cp_person_file_1_ciw`
),
cp_staged AS (
  SELECT
    CONCAT('CP:', p.ID) AS record_id,
    'CHILDSTORY' AS source_system,
    p.source_program,
    95 AS source_trust,
    p.CHILDSTORY_ID AS source_person_id,
    p.CHILDSTORY_ID AS childstory_id_ref,
    CAST(NULL AS STRING) AS cni_number,
    CAST(NULL AS STRING) AS ndis_number,
    na.names_arr[SAFE_OFFSET(0)].given_name AS given_name_raw,
    na.names_arr[SAFE_OFFSET(0)].middle_name AS middle_name_raw,
    na.names_arr[SAFE_OFFSET(0)].family_name AS family_name_raw,
    COALESCE(na.alt_names_summary, p.ALIASES) AS alias_names_concat,
    na.names_arr AS all_names_arr,
    na.all_surnames_norm,
    na.all_forenames_norm,
    CASE
      WHEN UPPER(SUBSTR(p.GENDER, 1, 1)) = 'M' THEN 'Male'
      WHEN UPPER(SUBSTR(p.GENDER, 1, 1)) = 'F' THEN 'Female'
      ELSE 'Unknown'
    END AS gender_norm,
    DATE(p.DOB) AS dob,
    IFNULL(p.DOB_STATUS, 'VERIFIED') AS dob_status,
    IFNULL(p.INDIG_STATUS, 'No') AS indigenous_status,
    FALSE AS is_cald,
    p.PROTECTED_INDIVIDUAL = 'Y' AS is_protected,
    LOWER(TRIM(p.EMAIL)) AS email_norm,
    `all-things-cdp.dcj_tdm.norm_phone`(COALESCE(p.MOBILE_PHN, p.HOME_PHN)) AS phone_e164,
    `all-things-cdp.dcj_tdm.norm_phone`(p.HOME_PHN) AS home_phone_e164,
    ca.gnaf_address_id,
    `all-things-cdp.dcj_sdm.standardize_address`(
      COALESCE(ca.FULL_ADDRESS, CONCAT(IFNULL(ca.STREET_NUMBER_FIRST, ''), ' ', IFNULL(ca.STREET_NAME, ''), ' ', IFNULL(ca.STREET_TYPE, '')))
    ) AS address_norm,
    UPPER(TRIM(ca.SUBURB)) AS suburb_norm,
    TRIM(ca.POSTCODE) AS postcode_norm,
    ks.kin_summary AS kin_context,
    IFNULL(ks.has_sibling_relation, FALSE) AS has_documented_sibling,
    p.W_INSERT_DT AS record_ts
  FROM cp_persons_raw AS p
  LEFT JOIN cp_names_agg AS na USING (CHILDSTORY_ID)
  LEFT JOIN cp_addr_joined AS ca ON ca.CHILDSTORY_ID = p.CHILDSTORY_ID AND ca.rn = 1
  LEFT JOIN cp_kin_summary AS ks ON ks.CHILDSTORY_ID = p.CHILDSTORY_ID
),
-- 5. Family Preservation (InfoShare Clients View)
fp_staged AS (
  SELECT
    CONCAT('FP:', c.ClientID) AS record_id,
    'INFOSHARE' AS source_system,
    'InfoShare- Family Preservation' AS source_program,
    85 AS source_trust,
    c.ClientID AS source_person_id,
    c.ChildStoryID AS childstory_id_ref,
    c.CNINumber AS cni_number,
    c.NDISNumber AS ndis_number,
    c.FirstName AS given_name_raw,
    CAST(NULL AS STRING) AS middle_name_raw,
    COALESCE(c.LastName, c.FamilyName) AS family_name_raw,
    IF(c.AnyKnownAlias.FieldValueENUM = 'Y', c.AnyKnownAlias.FieldENUMLabel, NULL) AS alias_names_concat,
    ARRAY_CONCAT(
      [STRUCT(c.FirstName AS given_name, CAST(NULL AS STRING) AS middle_name, COALESCE(c.LastName, c.FamilyName) AS family_name, 'Legal Name' AS name_usage_code, TRUE AS is_primary)],
      IF(c.AnyKnownAlias.FieldValueENUM = 'Y' AND c.AnyKnownAlias.FieldENUMLabel IS NOT NULL,
         [STRUCT(SPLIT(c.AnyKnownAlias.FieldENUMLabel, ' ')[SAFE_OFFSET(0)] AS given_name,
                 CAST(NULL AS STRING) AS middle_name,
                 SPLIT(c.AnyKnownAlias.FieldENUMLabel, ' ')[SAFE_OFFSET(1)] AS family_name,
                 'Alias Name' AS name_usage_code,
                 FALSE AS is_primary)],
         [])
    ) AS all_names_arr,
    ARRAY_CONCAT(
      [UPPER(`all-things-cdp.dcj_tdm.fold_diacritics`(COALESCE(c.LastName, c.FamilyName)))],
      IF(c.AnyKnownAlias.FieldValueENUM = 'Y' AND SPLIT(c.AnyKnownAlias.FieldENUMLabel, ' ')[SAFE_OFFSET(1)] IS NOT NULL,
         [UPPER(`all-things-cdp.dcj_tdm.fold_diacritics`(SPLIT(c.AnyKnownAlias.FieldENUMLabel, ' ')[SAFE_OFFSET(1)]))],
         [])
    ) AS all_surnames_norm,
    ARRAY_CONCAT(
      [UPPER(`all-things-cdp.dcj_tdm.fold_diacritics`(c.FirstName))],
      IF(c.AnyKnownAlias.FieldValueENUM = 'Y' AND SPLIT(c.AnyKnownAlias.FieldENUMLabel, ' ')[SAFE_OFFSET(0)] IS NOT NULL,
         [UPPER(`all-things-cdp.dcj_tdm.fold_diacritics`(SPLIT(c.AnyKnownAlias.FieldENUMLabel, ' ')[SAFE_OFFSET(0)]))],
         [])
    ) AS all_forenames_norm,
    CASE
      WHEN UPPER(SUBSTR(c.Gender.FieldValueENUM, 1, 1)) = 'M' THEN 'Male'
      WHEN UPPER(SUBSTR(c.Gender.FieldValueENUM, 1, 1)) = 'F' THEN 'Female'
      ELSE 'Unknown'
    END AS gender_norm,
    c.BirthDate AS dob,
    IF(c.IsBirthDateAnEstimate.FieldValueENUM = 'Y', 'ESTIMATED', 'VERIFIED') AS dob_status,
    IFNULL(c.AboriginalOrTorresStraitIslanderOrigin.FieldENUMLabel, 'No') AS indigenous_status,
    IFNULL(c.Language.FieldENUMLabel, 'English') != 'English' AS is_cald,
    FALSE AS is_protected,
    LOWER(TRIM(c.ContactEmail)) AS email_norm,
    `all-things-cdp.dcj_tdm.norm_phone`(COALESCE(c.ContactPhoneNumber, c.ContactNumber, c.CarerContactNumber1)) AS phone_e164,
    `all-things-cdp.dcj_tdm.norm_phone`(c.CarerContactNumber1) AS home_phone_e164,
    c.AddressId AS gnaf_address_id,
    `all-things-cdp.dcj_sdm.standardize_address`(COALESCE(c.FormattedAddress, c.Address, c.ManualAddressLine1)) AS address_norm,
    UPPER(TRIM(COALESCE(c.LocalityName, c.Suburb, c.ManualSuburb))) AS suburb_norm,
    TRIM(COALESCE(c.Postcode, c.ManualPostcode)) AS postcode_norm,
    CONCAT(
      IFNULL(CONCAT('Carer:', c.CarerNameandRelationship1), ''),
      IF(gc.GroupAutoID IS NOT NULL, CONCAT(' Group:', CAST(gc.GroupAutoID AS STRING)), '')
    ) AS kin_context,
    FALSE AS has_documented_sibling,
    c.UpdatedOn AS record_ts
  FROM `all-things-cdp.dcj_sdm.infoshare_fp_clientsTBL` AS c
  LEFT JOIN `all-things-cdp.dcj_sdm.infoshare_fp_groupclientsTBL` AS gc
    ON gc.ClientAutoID = c.AutoID
),
-- 6. Youth Justice (KIMS yj_address_mapping View)
yj_staged AS (
  SELECT
    CONCAT('YJ:', y.Young_Offender_Id) AS record_id,
    'KIMS_YJ' AS source_system,
    y.source_program,
    80 AS source_trust,
    y.Young_Offender_Id AS source_person_id,
    CAST(NULL AS STRING) AS childstory_id_ref,
    CAST(NULL AS STRING) AS cni_number,
    CAST(NULL AS STRING) AS ndis_number,
    y.First_Name AS given_name_raw,
    CAST(NULL AS STRING) AS middle_name_raw,
    y.Last_name AS family_name_raw,
    CAST(NULL AS STRING) AS alias_names_concat,
    [STRUCT(y.First_Name AS given_name, CAST(NULL AS STRING) AS middle_name, y.Last_name AS family_name, 'Preferred Name' AS name_usage_code, TRUE AS is_primary)] AS all_names_arr,
    [UPPER(`all-things-cdp.dcj_tdm.fold_diacritics`(y.Last_name))] AS all_surnames_norm,
    [UPPER(`all-things-cdp.dcj_tdm.fold_diacritics`(y.First_Name))] AS all_forenames_norm,
    CASE
      WHEN UPPER(SUBSTR(y.Sex, 1, 1)) = 'M' THEN 'Male'
      WHEN UPPER(SUBSTR(y.Sex, 1, 1)) = 'F' THEN 'Female'
      ELSE 'Unknown'
    END AS gender_norm,
    y.Date_of_Birth AS dob,
    'VERIFIED' AS dob_status,
    IFNULL(y.Indigenous_Status, 'No') AS indigenous_status,
    FALSE AS is_cald,
    FALSE AS is_protected,
    CAST(NULL AS STRING) AS email_norm,
    CAST(NULL AS STRING) AS phone_e164,
    CAST(NULL AS STRING) AS home_phone_e164,
    g.id AS gnaf_address_id,
    `all-things-cdp.dcj_sdm.standardize_address`(
      CONCAT(y.standardized_address, ', ', UPPER(y.Address_Suburb), ' NSW ', y.Postcode)
    ) AS address_norm,
    UPPER(TRIM(y.Address_Suburb)) AS suburb_norm,
    TRIM(y.Postcode) AS postcode_norm,
    IF(y.YO_Relation_First_Name IS NOT NULL,
       CONCAT(IFNULL(y.Relationship_To_YO, 'Relative'), ':', y.YO_Relation_First_Name, ' ', IFNULL(y.YO_Relation_Last_Name, '')),
       NULL) AS kin_context,
    FALSE AS has_documented_sibling,
    TIMESTAMP('2026-10-06T08:00:00Z') AS record_ts
  FROM `all-things-cdp.dcj_sdm.yj_address_mapping` AS y
  LEFT JOIN `all-things-cdp.dcj_sdm.GNAF_address_view` AS g
    ON UPPER(g.suburb) = UPPER(TRIM(y.Address_Suburb))
   AND g.postcode = TRIM(y.Postcode)
   AND `all-things-cdp.dcj_sdm.standardize_address`(CONCAT(g.number_first, ' ', g.street_name, ' ', g.street_type))
       = `all-things-cdp.dcj_sdm.standardize_address`(REGEXP_REPLACE(y.standardized_address, r'^UNIT\s+\d+/', ''))
),
unioned AS (
  SELECT * FROM cp_staged
  UNION ALL
  SELECT * FROM fp_staged
  UNION ALL
  SELECT * FROM yj_staged
),
enriched AS (
  SELECT
    u.*,
    UPPER(TRIM(`all-things-cdp.dcj_tdm.fold_diacritics`(u.given_name_raw))) AS given_name_norm,
    UPPER(TRIM(`all-things-cdp.dcj_tdm.fold_diacritics`(u.middle_name_raw))) AS middle_name_norm,
    UPPER(TRIM(`all-things-cdp.dcj_tdm.fold_diacritics`(u.family_name_raw))) AS family_name_norm,
    UPPER(TRIM(`all-things-cdp.dcj_tdm.fold_diacritics`(
      CONCAT(IFNULL(u.given_name_raw, ''), ' ', IFNULL(u.family_name_raw, ''))
    ))) AS full_name_norm,
    `all-things-cdp.dcj_tdm.compute_slk581`(u.given_name_raw, u.family_name_raw, u.dob, u.gender_norm) AS slk_code,
    EXTRACT(YEAR FROM u.dob) AS birth_year
  FROM unioned AS u
)
SELECT
  e.*,
  -- Canonical Match Key for AI.EMBED and Hybrid Search
  CONCAT(
    'NAME: ', IFNULL(e.full_name_norm, ''),
    IF(e.alias_names_concat IS NOT NULL, CONCAT(' | ALIASES: ', UPPER(e.alias_names_concat)), ''),
    ' | DOB: ', IFNULL(CAST(e.dob AS STRING), 'UNKNOWN'), ' (', e.dob_status, ')',
    ' | SEX: ', e.gender_norm,
    ' | ATSI: ', e.indigenous_status,
    ' | ADDR: ', IFNULL(e.address_norm, ''), ' ', IFNULL(e.suburb_norm, ''), ' ', IFNULL(e.postcode_norm, ''),
    IF(e.phone_e164 IS NOT NULL, CONCAT(' | PH: ', e.phone_e164), ''),
    IF(e.email_norm IS NOT NULL, CONCAT(' | EM: ', e.email_norm), ''),
    IF(e.childstory_id_ref IS NOT NULL, CONCAT(' | CS_ID: ', e.childstory_id_ref), ''),
    IF(e.cni_number IS NOT NULL, CONCAT(' | CNI: ', e.cni_number), ''),
    IF(e.ndis_number IS NOT NULL, CONCAT(' | NDIS: ', e.ndis_number), ''),
    IF(e.slk_code IS NOT NULL, CONCAT(' | SLK: ', e.slk_code), ''),
    IF(e.kin_context IS NOT NULL AND e.kin_context != '', CONCAT(' | KIN: ', e.kin_context), '')
  ) AS match_key,
  -- Multi-leg Deterministic Blocking Keys
  ARRAY_CONCAT(
    IF(e.childstory_id_ref IS NOT NULL, [CONCAT('CS:', e.childstory_id_ref)], []),
    IF(e.cni_number IS NOT NULL, [CONCAT('CNI:', e.cni_number)], []),
    IF(e.ndis_number IS NOT NULL, [CONCAT('NDIS:', e.ndis_number)], []),
    IF(e.slk_code IS NOT NULL, [CONCAT('SLK:', e.slk_code)], []),
    IF(e.phone_e164 IS NOT NULL, [CONCAT('PH:', e.phone_e164)], []),
    IF(e.email_norm IS NOT NULL, [CONCAT('EM:', e.email_norm)], []),
    IF(e.gnaf_address_id IS NOT NULL, [CONCAT('GNAF:', e.gnaf_address_id)], []),
    IF(e.address_norm IS NOT NULL AND e.postcode_norm IS NOT NULL, [CONCAT('AD:', e.address_norm, '|', e.postcode_norm)], []),
    -- Surname + DOB across all primary & alias surnames
    ARRAY(
      SELECT DISTINCT CONCAT('ND:', sn, '|', CAST(e.dob AS STRING))
      FROM UNNEST(e.all_surnames_norm) AS sn
      WHERE sn IS NOT NULL AND sn != '' AND e.dob IS NOT NULL
    ),
    -- Surname + Birth Year (catches Estimated DOBs where month/day is 01-01)
    ARRAY(
      SELECT DISTINCT CONCAT('NY:', sn, '|', CAST(e.birth_year AS STRING))
      FROM UNNEST(e.all_surnames_norm) AS sn
      WHERE sn IS NOT NULL AND sn != '' AND e.birth_year IS NOT NULL
    ),
    -- Forename + DOB (catches Adoptive / Foster / Married Surname Changes!)
    ARRAY(
      SELECT DISTINCT CONCAT('FD:', fn, '|', CAST(e.dob AS STRING))
      FROM UNNEST(e.all_forenames_norm) AS fn
      WHERE fn IS NOT NULL AND fn != '' AND e.dob IS NOT NULL
    ),
    -- Soundex(Surname) + Postcode
    IF(e.family_name_norm IS NOT NULL AND e.postcode_norm IS NOT NULL,
       [CONCAT('SX:', SOUNDEX(e.family_name_norm), '|', e.postcode_norm)],
       [])
  ) AS blocking_keys
FROM enriched AS e;
