-- =====================================================================
-- 70 · Target Graph Representation of the DCJ TDM (`dcj_person_graph`)
--
-- Declares the unified ISO GQL BigQuery Property Graph over:
--   - All 9 TDM Entities (`Party`, `Person`, `PersonName`, `AddressLocation`,
--     `IdentityInstrument`, `ProtectionEvent`, `SourceRecord`, `PARTY_RELATIONSHIP`,
--     `LIVES_AT`, `HAS_NAME`, `HOLDS_INSTRUMENT`, `ISSUED_BY`, `HAS_PROTECTION_EVENT`,
--     `INITIATED_BY`, `RESOLVES_TO`)
--   - The Bipartite Identifier & GenAI Adjudicator Audit Subgraph (`Identifier`,
--     `HAS_IDENTIFIER`, `COMPARED_WITH`)
--
-- Includes full `OPTIONS(description, synonyms)` metadata for BigQuery Studio
-- Graph Visualiser (`%%bigquery --graph`) and Conversational Analytics Agents.
-- =====================================================================

CREATE OR REPLACE PROPERTY GRAPH `all-things-cdp.dcj_tdm.dcj_person_graph`
  NODE TABLES (
    `all-things-cdp.dcj_tdm.party` AS Party
      KEY (party_id)
      DEFAULT LABEL OPTIONS (
        description = 'Root entity in the DCJ Target Data Model representing a person, family preservation group, or statutory/NGO organisation.',
        synonyms = ['entity', 'actor', 'person or organisation', 'group']
      )
      PROPERTIES (
        party_id           OPTIONS (description = 'Unique party identifier (PER-..., GRP-..., ORG-...)'),
        party_id_int64     OPTIONS (description = 'Deterministic 64-bit integer party ID'),
        party_type_code    OPTIONS (description = 'Party category: person, group, or organisation'),
        party_display_name OPTIONS (description = 'Display name of the person, group, or organisation'),
        created_timestamp  OPTIONS (description = 'Timestamp when the party was first recorded')
      ),

    `all-things-cdp.dcj_tdm.person` AS Person
      KEY (person_id)
      DEFAULT LABEL OPTIONS (
        description = 'A mastered Golden Person resolved across NSW DCJ Child Protection (ChildStory), Family Preservation (InfoShare), and Youth Justice (KIMS).',
        synonyms = ['golden person', 'client', 'individual', 'child', 'young offender']
      )
      PROPERTIES (
        person_id           OPTIONS (description = 'Golden Person ID (same as Party ID)'),
        gender              OPTIONS (description = 'Survivored gender (Male, Female, Unknown)'),
        date_of_birth       OPTIONS (description = 'Survivored date of birth'),
        dob_certainty_code  OPTIONS (description = 'Accuracy of DOB (VERIFIED or ESTIMATED)'),
        date_of_death       OPTIONS (description = 'Known date of death if applicable'),
        dod_certainty_code  OPTIONS (description = 'Accuracy of date of death'),
        is_protected_person OPTIONS (description = 'TRUE if subject to statutory confidentiality or DV protection (critical for RLS)'),
        is_cald             OPTIONS (description = 'TRUE if Culturally and Linguistically Diverse'),
        indigenous_status   OPTIONS (description = 'Aboriginal and/or Torres Strait Islander origin status'),
        source_program      OPTIONS (description = 'Primary authoritative DCJ program for this golden record')
      ),

    `all-things-cdp.dcj_tdm.person_name` AS PersonName
      KEY (person_name_id)
      DEFAULT LABEL OPTIONS (
        description = 'A current or historical name assertion for a Person across the 16 DCJ name usage contexts (Legal, Preferred, Adopted, Pre-Adoptive, Tribal/Cultural, Alias, Married, etc.).',
        synonyms = ['alias', 'legal name', 'cultural name', 'birth name', 'adopted name']
      )
      PROPERTIES (
        person_name_id    OPTIONS (description = 'Unique MD5-derived person name record ID'),
        person_id         OPTIONS (description = 'Golden Person ID'),
        name_usage_code   OPTIONS (description = 'Name usage context (Legal Name, Preferred Name, Adopted Name, Pre-Adoptive Name, Tribal/Cultural Name, Alias Name, etc.)'),
        primary_name_flag OPTIONS (description = 'TRUE if this is the current primary name for the person'),
        given_name        OPTIONS (description = 'First / given name'),
        middle_name       OPTIONS (description = 'Middle name'),
        family_name       OPTIONS (description = 'Family name / surname'),
        full_name         OPTIONS (description = 'Full concatenated name'),
        start_date        OPTIONS (description = 'Effective start timestamp of the name'),
        end_date          OPTIONS (description = 'End timestamp if historical/superseded (NULL = Active)'),
        source_program    OPTIONS (description = 'Originating DCJ program asserting this name')
      ),

    `all-things-cdp.dcj_tdm.address_location` AS AddressLocation
      KEY (id)
      DEFAULT LABEL OPTIONS (
        description = 'A unique de-duplicated physical location in NSW standardised against GNAF.',
        synonyms = ['address', 'gnaf location', 'residence', 'dwelling']
      )
      PROPERTIES (
        id            OPTIONS (description = 'GNAF address identifier'),
        building_name OPTIONS (description = 'Building or facility name (e.g. Crisis Refuge)'),
        flat_type     OPTIONS (description = 'Unit or flat type'),
        flat_number   OPTIONS (description = 'Unit or flat number'),
        number_first  OPTIONS (description = 'Street number'),
        street_name   OPTIONS (description = 'Street name'),
        street_type   OPTIONS (description = 'Street type (ST, RD, AV, PD, HWY)'),
        suburb        OPTIONS (description = 'NSW suburb / locality'),
        postcode      OPTIONS (description = '4-digit NSW postcode'),
        state         OPTIONS (description = 'State code (NSW)'),
        latitude      OPTIONS (description = 'WGS84 latitude'),
        longitude     OPTIONS (description = 'WGS84 longitude'),
        full_address  OPTIONS (description = 'Formatted full street address'),
        record_type   OPTIONS (description = 'GNAF record type (BUILDING CENTROID, PROPERTY CENTROID, GAP GEOCODE, LOCALITY, STREET LOCALITY, PROPERTY CENTROID MANUAL)')
      ),

    `all-things-cdp.dcj_tdm.person_identity_instrument` AS IdentityInstrument
      KEY (instrument_id)
      DEFAULT LABEL OPTIONS (
        description = 'An official government or statistical identity instrument (NSW Police CNI, NDIS Number, ChildStory ID, or AIHW SLK-581).',
        synonyms = ['id document', 'cni', 'ndis', 'slk-581', 'identity reference']
      )
      PROPERTIES (
        instrument_id        OPTIONS (description = 'Unique instrument record ID'),
        person_id            OPTIONS (description = 'Golden Person ID'),
        instrument_type_code OPTIONS (description = 'Instrument type: CNI, NDIS, CHILDSTORY_ID, or SLK_581'),
        designation_number   OPTIONS (description = 'Identifier value on the instrument'),
        issuer_party_id      OPTIONS (description = 'Party ID of the issuing authority'),
        status_code          OPTIONS (description = 'Validity status (Active, Verified, Statistical)'),
        is_primary           OPTIONS (description = 'TRUE if primary instrument'),
        source_program       OPTIONS (description = 'Originating DCJ source program')
      ),

    `all-things-cdp.dcj_tdm.person_protection_event` AS ProtectionEvent
      KEY (protection_event_id)
      DEFAULT LABEL OPTIONS (
        description = 'A statutory confidentiality or Domestic & Family Violence (DV) restriction event protecting a person record.',
        synonyms = ['confidentiality order', 'dv protection', 'restricted access event']
      )
      PROPERTIES (
        protection_event_id OPTIONS (description = 'Unique protection event ID'),
        person_id           OPTIONS (description = 'Protected Golden Person ID'),
        protect_start_date  OPTIONS (description = 'Start timestamp of protection restriction'),
        protect_end_date    OPTIONS (description = 'End timestamp of protection restriction (NULL = Active)'),
        reason              OPTIONS (description = 'Statutory or safety reason for restriction'),
        initiator_party_id  OPTIONS (description = 'Party ID of the authority initiating protection'),
        source_program      OPTIONS (description = 'Originating DCJ source program')
      ),

    `all-things-cdp.dcj_tdm.person_source_linkage` AS SourceRecord
      KEY (source_record_id)
      DEFAULT LABEL OPTIONS (
        description = 'An originating source system record from ChildStory (Child Protection), InfoShare (Family Preservation), or KIMS (Youth Justice).',
        synonyms = ['sdm record', 'source profile', 'agency record']
      )
      PROPERTIES (
        linkage_id       OPTIONS (description = 'Unique source linkage ID'),
        source_record_id OPTIONS (description = 'Prefixed source record key (CP:..., FP:..., YJ:...)'),
        person_id        OPTIONS (description = 'Mastered Golden Person ID'),
        source_app_id    OPTIONS (description = 'Originating application (CHILDSTORY, INFOSHARE, KIMS_YJ)'),
        source_person_id OPTIONS (description = 'Native ID in the source system'),
        source_program   OPTIONS (description = 'DCJ program domain'),
        is_mastered      OPTIONS (description = 'TRUE when mastered into a Golden Person'),
        last_updated_ts  OPTIONS (description = 'Timestamp when linkage was verified')
      ),

    `all-things-cdp.dcj_tdm.identifier` AS Identifier
      KEY (identifier_id)
      DEFAULT LABEL OPTIONS (
        description = 'A normalised bipartite identifier node with degree, Inverse Document Frequency (IDF) rarity weight, and promiscuous hub detection.',
        synonyms = ['match key token', 'bipartite node', 'contact or id key']
      )
      PROPERTIES (
        identifier_id   OPTIONS (description = 'Prefixed identifier (CS:, CNI:, NDIS:, SLK:, PH:, EM:, GNAF:)'),
        identifier_type OPTIONS (description = 'Category of identifier'),
        degree          OPTIONS (description = 'Number of distinct source records sharing this identifier'),
        idf_weight      OPTIONS (description = 'Inverse Document Frequency rarity weight LN(N/degree)'),
        is_promiscuous  OPTIONS (description = 'TRUE if shared by >12 records (e.g. Crisis Refuge or intake phone)'),
        sources         OPTIONS (description = 'Source systems asserting this identifier')
      )
  )
  EDGE TABLES (
    `all-things-cdp.dcj_tdm.person` AS IsParty
      KEY (person_id)
      SOURCE KEY (person_id) REFERENCES Person (person_id)
      DESTINATION KEY (person_id) REFERENCES Party (party_id)
      LABEL IS_PARTY
      PROPERTIES (
        source_program OPTIONS (description = 'Primary authoritative source program')
      ),

    `all-things-cdp.dcj_tdm.party_relationship` AS PartyRelationship
      KEY (relationship_id)
      SOURCE KEY (subject_party_id) REFERENCES Party (party_id)
      DESTINATION KEY (related_party_id) REFERENCES Party (party_id)
      LABEL PARTY_RELATIONSHIP
      PROPERTIES (
        relationship_id             OPTIONS (description = 'Unique relationship ID'),
        relationship_type           OPTIONS (description = 'Raw DCJ relationship type across all 78 kinship, carer & group types'),
        canonical_relationship_type OPTIONS (description = 'Canonicalised relationship type'),
        relationship_category       OPTIONS (description = 'High-level category (IMMEDIATE_FAMILY, STEP_OR_BLENDED_FAMILY, EXTENDED_OR_KINSHIP_FAMILY, CARER_OR_GUARDIANSHIP, SERVICE_OR_GROUP)'),
        start_date                  OPTIONS (description = 'Effective start date'),
        end_date                    OPTIONS (description = 'End date'),
        comment                     OPTIONS (description = 'Relationship provenance comment'),
        source_program              OPTIONS (description = 'Originating DCJ program')
      ),

    `all-things-cdp.dcj_tdm.person_name` AS HasName
      KEY (person_name_id)
      SOURCE KEY (person_id) REFERENCES Person (person_id)
      DESTINATION KEY (person_name_id) REFERENCES PersonName (person_name_id)
      LABEL HAS_NAME
      PROPERTIES (
        name_usage_code   OPTIONS (description = 'Context of name usage'),
        primary_name_flag OPTIONS (description = 'TRUE if primary name'),
        source_program    OPTIONS (description = 'Originating DCJ program')
      ),

    `all-things-cdp.dcj_tdm.address_relation` AS LivesAt
      KEY (address_relation_id)
      SOURCE KEY (person_id) REFERENCES Person (person_id)
      DESTINATION KEY (address_location_id) REFERENCES AddressLocation (id)
      LABEL LIVES_AT
      PROPERTIES (
        address_relation_id         OPTIONS (description = 'Unique address relation ID'),
        primary_address_flag        OPTIONS (description = 'TRUE if current primary address for this person'),
        address_purpose             OPTIONS (description = 'Residential or Crisis / Short-Term Accommodation'),
        address_relation_start_date OPTIONS (description = 'Effective start timestamp'),
        address_relation_end_date   OPTIONS (description = 'Effective end timestamp'),
        source_program              OPTIONS (description = 'Originating DCJ program')
      ),

    `all-things-cdp.dcj_tdm.person_identity_instrument` AS HoldsInstrument
      KEY (instrument_id)
      SOURCE KEY (person_id) REFERENCES Person (person_id)
      DESTINATION KEY (instrument_id) REFERENCES IdentityInstrument (instrument_id)
      LABEL HOLDS_INSTRUMENT
      PROPERTIES (
        instrument_type_code OPTIONS (description = 'Type of identity instrument'),
        is_primary           OPTIONS (description = 'TRUE if primary instrument'),
        status_code          OPTIONS (description = 'Validity status'),
        source_program       OPTIONS (description = 'Originating DCJ program')
      ),

    `all-things-cdp.dcj_tdm.person_identity_instrument` AS IssuedBy
      KEY (instrument_id)
      SOURCE KEY (instrument_id) REFERENCES IdentityInstrument (instrument_id)
      DESTINATION KEY (issuer_party_id) REFERENCES Party (party_id)
      LABEL ISSUED_BY
      PROPERTIES (
        instrument_type_code OPTIONS (description = 'Type of instrument issued'),
        issue_date           OPTIONS (description = 'Issue date')
      ),

    `all-things-cdp.dcj_tdm.person_protection_event` AS HasProtectionEvent
      KEY (protection_event_id)
      SOURCE KEY (person_id) REFERENCES Person (person_id)
      DESTINATION KEY (protection_event_id) REFERENCES ProtectionEvent (protection_event_id)
      LABEL HAS_PROTECTION_EVENT
      PROPERTIES (
        reason             OPTIONS (description = 'Reason for protection'),
        protect_start_date OPTIONS (description = 'Start timestamp of restriction'),
        source_program     OPTIONS (description = 'Originating DCJ program')
      ),

    `all-things-cdp.dcj_tdm.person_protection_event` AS InitiatedBy
      KEY (protection_event_id)
      SOURCE KEY (protection_event_id) REFERENCES ProtectionEvent (protection_event_id)
      DESTINATION KEY (initiator_party_id) REFERENCES Party (party_id)
      LABEL INITIATED_BY
      PROPERTIES (
        reason OPTIONS (description = 'Reason for initiating protection')
      ),

    `all-things-cdp.dcj_tdm.person_source_linkage` AS ResolvesTo
      KEY (linkage_id)
      SOURCE KEY (source_record_id) REFERENCES SourceRecord (source_record_id)
      DESTINATION KEY (person_id) REFERENCES Person (person_id)
      LABEL RESOLVES_TO
      PROPERTIES (
        source_app_id  OPTIONS (description = 'Originating agency application'),
        source_program OPTIONS (description = 'Originating DCJ program'),
        is_mastered    OPTIONS (description = 'TRUE if mastered')
      ),

    `all-things-cdp.dcj_tdm.has_identifier` AS HasIdentifier
      KEY (record_id, identifier_id)
      SOURCE KEY (record_id) REFERENCES SourceRecord (source_record_id)
      DESTINATION KEY (identifier_id) REFERENCES Identifier (identifier_id)
      LABEL HAS_IDENTIFIER
      PROPERTIES (
        identifier_type OPTIONS (description = 'Identifier category'),
        is_anchor       OPTIONS (description = 'TRUE if high-trust anchor ID'),
        sources         OPTIONS (description = 'Source systems reporting this link')
      ),

    `all-things-cdp.dcj_tdm.resolution_edges` AS ComparedWith
      KEY (record_id_a, record_id_b)
      SOURCE KEY (record_id_a) REFERENCES SourceRecord (source_record_id)
      DESTINATION KEY (record_id_b) REFERENCES SourceRecord (source_record_id)
      LABEL COMPARED_WITH
      PROPERTIES (
        decision                    OPTIONS (description = 'Resolution decision: LINK, UNLINK, or STEWARD'),
        decided_by                  OPTIONS (description = 'Decider: RULE_AND_GRAPH, GEMINI_ADJUDICATOR, or LLM_AND_TWIN_GUARD'),
        confidence                  OPTIONS (description = 'Confidence score in [0, 1]'),
        rationale                   OPTIONS (description = 'Plain-English statutory rationale'),
        decisive_evidence           OPTIONS (description = 'Primary supporting/refuting signal'),
        contradiction               OPTIONS (description = 'Explicit contradicting evidence cited'),
        retrieved_by                OPTIONS (description = 'Retrieval leg: BOTH, LEXICAL_ONLY, or SEMANTIC_ONLY'),
        combined_score              OPTIONS (description = 'Composite hybrid score'),
        rrf_score                   OPTIONS (description = 'Reciprocal Rank Fusion score'),
        semantic_similarity         OPTIONS (description = 'Cosine similarity of record embeddings'),
        suppressed_by_contradiction OPTIONS (description = 'TRUE if pruned in Pass 2 by the Contradiction Guard')
      )
  );

-- Summary view of Graph Node and Edge counts
CREATE OR REPLACE VIEW `all-things-cdp.dcj_tdm.v_dcj_graph_summary` AS
SELECT 'NODE · Party (person, group, organisation)' AS graph_element, COUNT(*) AS element_count FROM `all-things-cdp.dcj_tdm.party`
UNION ALL SELECT 'NODE · Person (Mastered Golden Profile)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person`
UNION ALL SELECT 'NODE · PersonName (16 Usage Codes)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person_name`
UNION ALL SELECT 'NODE · AddressLocation (GNAF De-duplicated)', COUNT(*) FROM `all-things-cdp.dcj_tdm.address_location`
UNION ALL SELECT 'NODE · IdentityInstrument (CNI, NDIS, CS_ID, SLK)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person_identity_instrument`
UNION ALL SELECT 'NODE · ProtectionEvent (DV / Confidentiality)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person_protection_event`
UNION ALL SELECT 'NODE · SourceRecord (SDM Lineage)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person_source_linkage`
UNION ALL SELECT 'NODE · Identifier (Bipartite Graph)', COUNT(*) FROM `all-things-cdp.dcj_tdm.identifier`
UNION ALL SELECT 'EDGE · PARTY_RELATIONSHIP (78 Kinship & Group Types)', COUNT(*) FROM `all-things-cdp.dcj_tdm.party_relationship`
UNION ALL SELECT 'EDGE · LIVES_AT (Address Relations)', COUNT(*) FROM `all-things-cdp.dcj_tdm.address_relation`
UNION ALL SELECT 'EDGE · HAS_NAME (Person -> PersonName)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person_name`
UNION ALL SELECT 'EDGE · HOLDS_INSTRUMENT (Person -> Instrument)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person_identity_instrument`
UNION ALL SELECT 'EDGE · HAS_PROTECTION_EVENT (Person -> Protection)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person_protection_event`
UNION ALL SELECT 'EDGE · RESOLVES_TO (SourceRecord -> Golden Person)', COUNT(*) FROM `all-things-cdp.dcj_tdm.person_source_linkage`
UNION ALL SELECT 'EDGE · HAS_IDENTIFIER (SourceRecord -> Identifier)', COUNT(*) FROM `all-things-cdp.dcj_tdm.has_identifier`
UNION ALL SELECT 'EDGE · COMPARED_WITH (Hybrid Match + AI Audit)', COUNT(*) FROM `all-things-cdp.dcj_tdm.resolution_edges`;
