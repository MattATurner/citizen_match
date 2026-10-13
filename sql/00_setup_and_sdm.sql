-- =====================================================================
-- 00 · Setup, Standardisation Functions & SDM Schema DDL
--
-- Creates:
--   1. all-things-cdp.dcj_sdm   (Source Data Model across Child Protection,
--                                Family Preservation, Youth Justice, GNAF)
--   2. all-things-cdp.dcj_match (Working Entity Resolution Dataset: Staging,
--                                Bipartite Graph, Vector Search, RRF Tiers,
--                                Gemini Adjudicator Ledger & Connected Components)
--   3. all-things-cdp.dcj_tdm   (Target Data Model ONLY: 9 Mastered Target
--                                Tables + Native BigQuery Property Graph)
--   4. all-things-cdp.dcj_truth (Hidden Ground Truth for Benchmarking)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS `all-things-cdp.dcj_sdm`
OPTIONS (
  location = 'us-central1',
  description = 'NSW DCJ Source Data Model (SDM) — Child Protection (ChildStory), Family Preservation (InfoShare), Youth Justice (KIMS), and GNAF.'
);

CREATE SCHEMA IF NOT EXISTS `all-things-cdp.dcj_match`
OPTIONS (
  location = 'us-central1',
  description = 'NSW DCJ Person Entity Resolution Working Dataset — Staging, Bipartite Identifiers, Vector Embeddings, RRF Candidate Tiers, Gemini 3.5 Adjudications, Connected Components, and Benchmark Views.'
);

CREATE SCHEMA IF NOT EXISTS `all-things-cdp.dcj_tdm`
OPTIONS (
  location = 'us-central1',
  description = 'NSW DCJ Target Data Model (TDM) — 9 Mastered Party/Person Target Tables and Native BigQuery Property Graph (dcj_person_graph).'
);

CREATE SCHEMA IF NOT EXISTS `all-things-cdp.dcj_truth`
OPTIONS (
  location = 'us-central1',
  description = 'NSW DCJ Ground Truth Dataset — Used strictly for stage 80 precision/recall evaluation across the 8 planted DCJ scenarios.'
);

-- =====================================================================
-- 00a · Normalisation & Standardisation Functions
-- =====================================================================

-- 1. Address Standardisation Function required by yj_address_mapping view
CREATE OR REPLACE FUNCTION `all-things-cdp.dcj_sdm.standardize_address`(raw_addr STRING) AS (
  TRIM(
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(
              REGEXP_REPLACE(
                REGEXP_REPLACE(
                  UPPER(IFNULL(raw_addr, '')),
                  r'\bSTREET\b|\bSTR\b', 'ST'
                ),
                r'\bROAD\b', 'RD'
              ),
              r'\bAVENUE\b|\bAVE\b', 'AV'
            ),
            r'\bPARADE\b|\bPDE\b', 'PD'
          ),
          r'\bDRIVE\b|\bDRV\b', 'DR'
        ),
        r'\bPLACE\b', 'PL'
      ),
      r'\s+', ' '
    )
  )
);

-- 2. Diacritic & Unicode Folding for Match Keys
CREATE OR REPLACE FUNCTION `all-things-cdp.dcj_match.fold_diacritics`(s STRING) AS (
  REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
  REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
    REGEXP_REPLACE(NORMALIZE(IFNULL(s, ''), NFKD), r'\p{Mn}', '')
  , 'ł', 'l'), 'Ł', 'L')
  , 'ø', 'o'), 'Ø', 'O')
  , 'đ', 'd'), 'Đ', 'D')
  , 'ß', 'ss')
  , 'æ', 'ae'), 'Æ', 'AE')
  , 'œ', 'oe'), 'Œ', 'OE')
);

-- 3. Australian Phone E.164 Normalisation (+614... mobile, +612... NSW landline)
CREATE OR REPLACE FUNCTION `all-things-cdp.dcj_match.norm_phone`(p STRING) AS (
  CASE
    WHEN p IS NULL OR LENGTH(REGEXP_REPLACE(p, r'[^0-9]', '')) < 8 THEN NULL
    WHEN STARTS_WITH(REGEXP_REPLACE(p, r'[^0-9]', ''), '61') AND LENGTH(REGEXP_REPLACE(p, r'[^0-9]', '')) = 11
      THEN CONCAT('+', REGEXP_REPLACE(p, r'[^0-9]', ''))
    WHEN STARTS_WITH(REGEXP_REPLACE(p, r'[^0-9]', ''), '0') AND LENGTH(REGEXP_REPLACE(p, r'[^0-9]', '')) = 10
      THEN CONCAT('+61', SUBSTR(REGEXP_REPLACE(p, r'[^0-9]', ''), 2))
    WHEN LENGTH(REGEXP_REPLACE(p, r'[^0-9]', '')) = 8
      THEN CONCAT('+612', REGEXP_REPLACE(p, r'[^0-9]', ''))
    ELSE CONCAT('+', REGEXP_REPLACE(p, r'[^0-9]', ''))
  END
);

-- 4. AIHW Statistical Linkage Key (SLK-581) Function
--    Format: LLL (2nd, 3rd, 5th of Surname) + FF (2nd, 3rd of Given Name) + DDMMYYYY + Sex (1=M, 2=F, 9=U)
CREATE OR REPLACE FUNCTION `all-things-cdp.dcj_match.compute_slk581`(
  given_name STRING,
  family_name STRING,
  dob DATE,
  gender STRING
) AS (
  IF(dob IS NULL, NULL,
    CONCAT(
      -- Surname letters 2, 3, 5 (padded with '2' if short, '999' if missing)
      CASE
        WHEN family_name IS NULL OR LENGTH(REGEXP_REPLACE(UPPER(family_name), r'[^A-Z]', '')) = 0 THEN '999'
        ELSE CONCAT(
          COALESCE(NULLIF(SUBSTR(REGEXP_REPLACE(UPPER(family_name), r'[^A-Z]', ''), 2, 1), ''), '2'),
          COALESCE(NULLIF(SUBSTR(REGEXP_REPLACE(UPPER(family_name), r'[^A-Z]', ''), 3, 1), ''), '2'),
          COALESCE(NULLIF(SUBSTR(REGEXP_REPLACE(UPPER(family_name), r'[^A-Z]', ''), 5, 1), ''), '2')
        )
      END,
      -- Given name letters 2, 3 (padded with '2' if short, '99' if missing)
      CASE
        WHEN given_name IS NULL OR LENGTH(REGEXP_REPLACE(UPPER(given_name), r'[^A-Z]', '')) = 0 THEN '99'
        ELSE CONCAT(
          COALESCE(NULLIF(SUBSTR(REGEXP_REPLACE(UPPER(given_name), r'[^A-Z]', ''), 2, 1), ''), '2'),
          COALESCE(NULLIF(SUBSTR(REGEXP_REPLACE(UPPER(given_name), r'[^A-Z]', ''), 3, 1), ''), '2')
        )
      END,
      FORMAT_DATE('%d%m%Y', dob),
      CASE
        WHEN UPPER(SUBSTR(IFNULL(gender, ''), 1, 1)) = 'M' THEN '1'
        WHEN UPPER(SUBSTR(IFNULL(gender, ''), 1, 1)) = 'F' THEN '2'
        ELSE '9'
      END
    )
  )
);

-- 5. Canonical Relationship Normaliser (harmonises the 78 DCJ relationship types)
CREATE OR REPLACE FUNCTION `all-things-cdp.dcj_match.canonical_relationship_type`(rel STRING) AS (
  CASE
    WHEN LOWER(TRIM(rel)) IN ('step child', 'step-child') THEN 'Step Child'
    WHEN LOWER(TRIM(rel)) IN ('step parent', 'step-parent') THEN 'Step-Parent'
    WHEN LOWER(TRIM(rel)) IN ('grandparent', 'grand parent') THEN 'Grandparent'
    WHEN LOWER(TRIM(rel)) IN ('niece/nephew', 'niece / nephew') THEN 'Niece/nephew'
    ELSE TRIM(rel)
  END
);

-- 6. High-Level Relationship Category for Graph Analytics
CREATE OR REPLACE FUNCTION `all-things-cdp.dcj_match.relationship_category`(rel STRING) AS (
  CASE
    WHEN LOWER(TRIM(rel)) IN (
      'mother', 'father', 'parent', 'son', 'daughter', 'child',
      'brother', 'sister', 'sibling', 'half-sibling', 'half-brother', 'half-sister',
      'husband', 'wife', 'partner', 'male partner', 'female partner',
      'other relative (immediate family)'
    ) THEN 'IMMEDIATE_FAMILY'
    WHEN LOWER(TRIM(rel)) IN (
      'step child', 'step-parent', 'step parent', 'step-father', 'step-mother',
      'step-sibling', 'step grandparent', 'step-grandchild', 'step-parents partner',
      'partners step child', 'partner\'s child', 'partner\'s son', 'partner\'s daughter',
      'father\'s partner', 'father\'s female partner', 'father\'s male partner',
      'mother\'s partner', 'mother\'s female partner', 'mother\'s male partner',
      'parent\'s partner'
    ) THEN 'STEP_OR_BLENDED_FAMILY'
    WHEN LOWER(TRIM(rel)) IN (
      'atsi community relationship', 'grandparent', 'grand parent', 'grandmother', 'grandfather',
      'grandchild', 'granddaughter', 'grandson', 'great grandparent', 'great grandchild',
      'aunt', 'uncle', 'aunt/uncle', 'great aunt/uncle', 'niece', 'nephew', 'niece/nephew',
      'great niece/nephew', 'cousin', 'sibling\'s child', 'extended family member',
      'other relative (extended family)', 'relative', 'significant family member for',
      'significant family member is', 'other or unknown family relationship'
    ) THEN 'EXTENDED_OR_KINSHIP_FAMILY'
    WHEN LOWER(TRIM(rel)) IN (
      'carer (family)', 'carer (non-family)', 'legal guardian', 'foster sibling'
    ) THEN 'CARER_OR_GUARDIANSHIP'
    WHEN LOWER(TRIM(rel)) IN (
      'unborn child', 'unborn grandchild', 'unborn niece/nephew',
      'parent-to-be', 'grandparent-to-be', 'sibling-to-be'
    ) THEN 'PRENATAL_OR_UNBORN'
    WHEN LOWER(TRIM(rel)) IN (
      'divorced from', 'separated from', 'widowed from', 'annulled from'
    ) THEN 'FORMER_PARTNER'
    WHEN LOWER(TRIM(rel)) IN ('group member', 'case managed by', 'service provider') THEN 'SERVICE_OR_GROUP'
    ELSE 'OTHER_SOCIAL'
  END
);

-- =====================================================================
-- 00b · SDM Tables & Views (Exact DCJ Specification)
-- =====================================================================

-- 1. GNAF Base Table & Materialized View
CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.gnaf_address_materialised_view`
(
  id STRING NOT NULL,
  building_name STRING,
  lot_number_prefix STRING,
  lot_number STRING,
  lot_number_suffix STRING,
  flat_type STRING,
  flat_number_prefix STRING,
  flat_number STRING,
  flat_number_suffix STRING,
  number_first_prefix STRING,
  number_first STRING,
  number_first_suffix STRING,
  number_last_prefix STRING,
  number_last STRING,
  number_last_suffix STRING,
  street_name STRING,
  street_type STRING,
  street_type_suffix STRING,
  suburb STRING,
  postcode STRING,
  state STRING,
  latitude FLOAT64,
  longitude FLOAT64,
  full_address STRING,
  record_type STRING,
  lga_pid STRING,
  lga_name STRING,
  sa1_2021 STRING,
  sa2_2021 STRING
);

DROP MATERIALIZED VIEW IF EXISTS `all-things-cdp.dcj_sdm.GNAF_address_view`;
CREATE MATERIALIZED VIEW `all-things-cdp.dcj_sdm.GNAF_address_view`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  refresh_interval_minutes=1440.0
)
AS SELECT
  *
FROM
  `all-things-cdp.dcj_sdm.gnaf_address_materialised_view`;

-- 2. Child Protection: person_file (load 1) & person_file_1_ciw (load 2) + MV
CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.person_file`
(
  CHILDSTORY_ID STRING,
  ID STRING,
  GENDER STRING,
  DOB TIMESTAMP,
  DOB_STATUS STRING,
  INDIG_STATUS STRING,
  VITAL_STATUS STRING,
  EMAIL STRING,
  HOME_PHN STRING,
  MOBILE_PHN STRING,
  ALIASES STRING,
  PROTECTED_INDIVIDUAL STRING,
  UPD_KEY STRING,
  W_INSERT_DT TIMESTAMP,
  INSERT_UPDATE_DELETE_FLG STRING,
  INGESTTIME STRING,
  INGESTTYPE STRING,
  FILENAME STRING,
  BATCHID STRING
);

CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.person_file_1_ciw`
(
  CHILDSTORY_ID STRING,
  ID STRING,
  GENDER STRING,
  DOB TIMESTAMP,
  DOB_STATUS STRING,
  INDIG_STATUS STRING,
  VITAL_STATUS STRING,
  EMAIL STRING,
  HOME_PHN STRING,
  MOBILE_PHN STRING,
  ALIASES STRING,
  PROTECTED_INDIVIDUAL STRING,
  UPD_KEY STRING,
  W_INSERT_DT TIMESTAMP,
  INSERT_UPDATE_DELETE_FLG STRING,
  INGESTTIME STRING NOT NULL,
  INGESTTYPE STRING NOT NULL,
  FILENAME STRING NOT NULL,
  BATCHID STRING NOT NULL
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")]
);

DROP MATERIALIZED VIEW IF EXISTS `all-things-cdp.dcj_sdm.cp_person_file_1_ciw`;
CREATE MATERIALIZED VIEW `all-things-cdp.dcj_sdm.cp_person_file_1_ciw`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  refresh_interval_minutes=1440.0
)
AS SELECT
  *,
  'Child Protection' AS source_program
FROM
  `all-things-cdp.dcj_sdm.person_file_1_ciw`;

-- 3. Child Protection: person_name_1st_batch & person_names_file_2_ciw + MV
CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.person_name_1st_batch`
(
  CHILDSTORY_ID STRING,
  FST_NAME STRING,
  MID_NAME STRING,
  LAST_NAME STRING,
  TYPE STRING,
  PRIMARY_FLG STRING,
  ID STRING,
  UPD_KEY STRING,
  W_INSERT_DT TIMESTAMP,
  INSERT_UPDATE_DELETE_FLG STRING,
  INGESTTIME STRING,
  INGESTTYPE STRING,
  FILENAME STRING,
  BATCHID STRING,
  source_program STRING
);

CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.person_names_file_2_ciw`
(
  CHILDSTORY_ID STRING,
  FST_NAME STRING,
  MID_NAME STRING,
  LAST_NAME STRING,
  TYPE STRING,
  PRIMARY_FLG STRING,
  ID STRING,
  UPD_KEY STRING,
  W_INSERT_DT TIMESTAMP,
  INSERT_UPDATE_DELETE_FLG STRING,
  INGESTTIME STRING NOT NULL,
  INGESTTYPE STRING NOT NULL,
  FILENAME STRING NOT NULL,
  BATCHID STRING NOT NULL
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")]
);

DROP MATERIALIZED VIEW IF EXISTS `all-things-cdp.dcj_sdm.cp_person_names_file_2_ciw`;
CREATE MATERIALIZED VIEW `all-things-cdp.dcj_sdm.cp_person_names_file_2_ciw`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  refresh_interval_minutes=1440.0
)
AS SELECT
  *,
  'Child Protection' AS source_program
FROM
  `all-things-cdp.dcj_sdm.person_names_file_2_ciw`;

-- 4. Child Protection: person_relation_file_4_ciw + MV
CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.person_relation_file_4_ciw`
(
  SUBJECT_PERSON_NUMBER STRING,
  REL_TYPE STRING,
  RELATED_PERSON_NUMBER STRING,
  ID STRING,
  W_INSERT_DT TIMESTAMP,
  INSERT_UPDATE_DELETE_FLG STRING,
  INGESTTIME STRING NOT NULL,
  INGESTTYPE STRING NOT NULL,
  FILENAME STRING NOT NULL,
  BATCHID STRING NOT NULL
)
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")]
);

DROP MATERIALIZED VIEW IF EXISTS `all-things-cdp.dcj_sdm.cp_person_relation_file_4_ciw`;
CREATE MATERIALIZED VIEW `all-things-cdp.dcj_sdm.cp_person_relation_file_4_ciw`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  refresh_interval_minutes=1440.0
)
AS SELECT
  *,
  'Child Protection' AS source_program
FROM
  `all-things-cdp.dcj_sdm.person_relation_file_4_ciw`;

-- 5. Child Protection: addr_loc_ods & addr_rel_loc_ods + Materialized Views
CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.addr_loc_ods`
(
  ADDR_LOC_ID STRING,
  GNAF_PID STRING,
  BUILDING_NAME STRING,
  FLAT_TYPE STRING,
  FLAT_NUMBER STRING,
  STREET_NUMBER_FIRST STRING,
  STREET_NUMBER_LAST STRING,
  STREET_NAME STRING,
  STREET_TYPE STRING,
  SUBURB STRING,
  STATE STRING,
  POSTCODE STRING,
  LATITUDE FLOAT64,
  LONGITUDE FLOAT64,
  FULL_ADDRESS STRING,
  RECORD_TYPE STRING,
  W_INSERT_DT TIMESTAMP
);

DROP MATERIALIZED VIEW IF EXISTS `all-things-cdp.dcj_sdm.cp_address_loc_ciw`;
CREATE MATERIALIZED VIEW `all-things-cdp.dcj_sdm.cp_address_loc_ciw`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  refresh_interval_minutes=1440.0
)
AS SELECT
  *,
  'Child Protection' AS source_program
FROM
  `all-things-cdp.dcj_sdm.addr_loc_ods`;

CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.addr_rel_loc_ods`
(
  ADDR_REL_ID STRING,
  CHILDSTORY_ID STRING,
  ADDR_LOC_ID STRING,
  PRIMARY_ADDR_FLG STRING,
  ADDR_PURPOSE STRING,
  START_DT TIMESTAMP,
  END_DT TIMESTAMP,
  W_INSERT_DT TIMESTAMP
);

DROP MATERIALIZED VIEW IF EXISTS `all-things-cdp.dcj_sdm.cp_address_rel_loc_ciw`;
CREATE MATERIALIZED VIEW `all-things-cdp.dcj_sdm.cp_address_rel_loc_ciw`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  refresh_interval_minutes=1440.0
)
AS SELECT
  *,
  'Child Protection' AS source_program
FROM
  `all-things-cdp.dcj_sdm.addr_rel_loc_ods`;

-- 6. InfoShare Family Preservation: Groups, GroupClients, and Clients (Tables + Raw JSON Views)
CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.infoshare_family_preservation_groups`
(
  AutoID INT64,
  GroupLabel STRING,
  OrganisationAutoID INT64,
  MetaDataSetLabel STRING,
  GroupID STRING,
  OutletActivityID STRING,
  GroupClients STRING,
  GroupType STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  NumberofUnidentifiedGroupMembers INT64,
  OtherDCJServicesReceived STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  NumberofDependentChildren INT64,
  OldestChildDOB DATE,
  ATSICode STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AnyChildOfATSIOrigin STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  IsDeleted BOOL,
  CreatedByUsername STRING,
  CreatedOn TIMESTAMP,
  UpdatedByUsername STRING,
  UpdatedOn TIMESTAMP,
  BATCHID STRING,
  source_program STRING
);

CREATE OR REPLACE VIEW `all-things-cdp.dcj_sdm.infoshare_fp_groupsTBL`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")]
)
AS SELECT * FROM `all-things-cdp.dcj_sdm.infoshare_family_preservation_groups`;

CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.infoshare_family_preservation_groupclients`
(
  AutoID INT64,
  OrganisationAutoID INT64,
  ClientAutoID INT64,
  GroupAutoID INT64,
  MetaDataSetLabel STRING,
  IsDeleted BOOL,
  BATCHID STRING,
  source_program STRING
);

CREATE OR REPLACE VIEW `all-things-cdp.dcj_sdm.infoshare_fp_groupclientsTBL`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")]
)
AS SELECT * FROM `all-things-cdp.dcj_sdm.infoshare_family_preservation_groupclients`;

CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.infoshare_family_preservation_clients`
(
  AutoID INT64,
  ClientLabel STRING,
  ChildStoryID STRING,
  FirstName STRING,
  LastName STRING,
  BirthDate DATE,
  Suburb STRING,
  OrganisationAutoID INT64,
  MetaDataSetLabel STRING,
  ClientID STRING,
  SLK STRING,
  IsBirthDateAnEstimate STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  ClientGroupStatus STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  Gender STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  ClientConsented STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AboriginalOrTorresStraitIslanderOrigin STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  IsHomeless STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  Address STRING,
  HouseholdComposition STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  BirthCountry STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  Language STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  ProficiencyInSpokenEnglish STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  InterpreterRequired STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  CaregiverStatus STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  Disabilities BOOL,
  IntellectualLearning BOOL,
  PhysicalDiverse BOOL,
  Psychiatric BOOL,
  SensorySpeech BOOL,
  ManualAddressLine1 STRING,
  ManualSuburb STRING,
  ManualState STRING,
  ManualPostcode STRING,
  Dataset STRING,
  GeoDatumCode STRING,
  Point GEOGRAPHY,
  Longitude FLOAT64,
  Latitude FLOAT64,
  LotIdentifier STRING,
  StreetNumber1 STRING,
  StreetName STRING,
  StreetType STRING,
  LocalityName STRING,
  StateTerritory STRING,
  Postcode STRING,
  CadastralIdentifier STRING,
  FormattedAddress STRING,
  AddressId STRING,
  AddressRecordType STRING,
  LgaPID STRING,
  StateElectoralPID STRING,
  CommElectoralPID STRING,
  `2016_mbID` STRING,
  `2016_sa1ID` STRING,
  `2016_sa2ID` STRING,
  `2016_sa3ID` STRING,
  `2016_sa4ID` STRING,
  `2021_mbID` STRING,
  `2021_sa1ID` STRING,
  `2021_sa2ID` STRING,
  `2021_sa3ID` STRING,
  `2021_sa4ID` STRING,
  CommElectoralName STRING,
  LgaName STRING,
  LgaShortName STRING,
  StateElectoralName STRING,
  StateElectoralType STRING,
  IsDeleted BOOL,
  IsAddressValidated BOOL,
  RevalidationResults INT64,
  CreatedByUsername STRING,
  CreatedOn TIMESTAMP,
  UpdatedByUsername STRING,
  UpdatedOn TIMESTAMP,
  ContactPost STRING,
  ChildDOB STRING,
  ContactEmail STRING,
  AS_ClientPriority STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_howdidyouhearaboutus STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_ChildAbuseMaterial STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_DeceptiveRecruitment STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_ForcedMarriage STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_OrganTrafficking STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_ServitudeOffenses STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_SexualServitudeOffenses STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_TraffickingChildren STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_TraffickingPersons STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  ClientRepresentation STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  Degreeofimpairment STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  Disability STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  DisabilityStatus STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  DisabilityType STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  ReporterType STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  TranslationNeed STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AS_Indicators_ForcedLabourOffenses STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  ContactPhoneNumber STRING,
  DisabilitySupportNeeded STRING,
  FamilyName STRING,
  FirstName_JSON STRING,
  Issues STRING,
  ATSICode STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  HasDisabilities STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  ICFType STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  Seeing STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  Hearing STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  Mobility STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  Communication STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  Cognition STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  Selfcare STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  Behaviour STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  WorkEmployment STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  EducationLearning STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  Other STRUCT<FieldValueMultiENUM ARRAY<STRING>, FieldENUMLabel STRING>,
  CNINumber STRING,
  HowCNI STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  ClientStatus STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  PendingStart DATE,
  AnyKnownAlias STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AltAddress STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  AltAddressValue STRING,
  ContactNumber STRING,
  CarerNameandRelationship1 STRING,
  CarerNameandRelationship2 STRING,
  CarerNameandRelationship3 STRING,
  CarerContactNumber1 STRING,
  CarerContactNumber2 STRING,
  CarerContactNumber3 STRING,
  YoungParent STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  NDISPackage STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  NDISNumber STRING,
  NDISPackageStart DATE,
  NDISPackageEnd DATE,
  AmountSupport STRING,
  AmountTotal STRING,
  ProgramManagement STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  CaseManager STRUCT<FieldValueENUM STRING, FieldENUMLabel STRING>,
  CaseManagerNumber STRING,
  CaseManagerEmail STRING,
  LOAD_DATETIME STRING
);

CREATE OR REPLACE VIEW `all-things-cdp.dcj_sdm.infoshare_fp_clientsTBL`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")]
)
AS SELECT * FROM `all-things-cdp.dcj_sdm.infoshare_family_preservation_clients`;

-- 7. Youth Justice: YJ_YO_CDM_Data + Materialized View yj_new_clients_kims + View yj_address_mapping
CREATE OR REPLACE TABLE `all-things-cdp.dcj_sdm.YJ_YO_CDM_Data`
(
  Young_Offender_Id STRING,
  First_Name STRING,
  Last_name STRING,
  Date_of_Birth DATE,
  Sex STRING,
  Indigenous_Status STRING,
  Address_Street STRING,
  Address_Suburb STRING,
  Postcode STRING,
  YO_Relation_First_Name STRING,
  YO_Relation_Last_Name STRING,
  Is_YO_Flag STRING,
  Relationship_To_YO STRING,
  `Desc` STRING
);

DROP MATERIALIZED VIEW IF EXISTS `all-things-cdp.dcj_sdm.yj_new_clients_kims`;
CREATE MATERIALIZED VIEW `all-things-cdp.dcj_sdm.yj_new_clients_kims`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")],
  refresh_interval_minutes=1440.0
)
AS SELECT
  *,
  'Youth Justice' AS source_program
FROM
  `all-things-cdp.dcj_sdm.YJ_YO_CDM_Data`;

CREATE OR REPLACE VIEW `all-things-cdp.dcj_sdm.yj_address_mapping`
OPTIONS(
  labels=[("goog-terraform-provisioned", "true")]
)
AS WITH first AS (
  SELECT
    Young_Offender_Id,
    First_Name,
    Last_name,
    Date_of_Birth,
    Sex,
    Indigenous_Status,
    REGEXP_REPLACE(`all-things-cdp.dcj_sdm.standardize_address`(Address_Street), r'\s+', ' ')
      AS Trim_Address_Street,
    Address_Suburb,
    Postcode,
    YO_Relation_First_Name,
    YO_Relation_Last_Name,
    Is_YO_Flag,
    Relationship_To_YO,
    `Desc`,
    source_program
  FROM `all-things-cdp.dcj_sdm.yj_new_clients_kims`
  WHERE Address_Street IS NOT NULL
)
SELECT
  *,
  IF(`all-things-cdp.dcj_sdm.standardize_address`(Trim_Address_Street) LIKE '%/%'
      AND `all-things-cdp.dcj_sdm.standardize_address`(Trim_Address_Street) NOT LIKE '%Unit%',
    CONCAT('Unit ', `all-things-cdp.dcj_sdm.standardize_address`(Trim_Address_Street)),
    `all-things-cdp.dcj_sdm.standardize_address`(Trim_Address_Street))
  AS standardized_address
FROM first;
