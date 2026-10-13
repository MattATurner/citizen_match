#!/usr/bin/env python3
"""
Generates realistic synthetic NSW Department of Communities and Justice (DCJ)
Source Data Model (SDM) data across:
  1. Child Protection (ChildStory):
     - person_file (load 1)
     - person_file_1_ciw (load 2) + MV cp_person_file_1_ciw
     - person_name_1st_batch (load 1)
     - person_names_file_2_ciw (load 2) + MV cp_person_names_file_2_ciw
     - person_relation_file_4_ciw + MV cp_person_relation_file_4_ciw
     - addr_loc_ods + MV cp_address_loc_ciw
     - addr_rel_loc_ods + MV cp_address_rel_loc_ciw
  2. Family Preservation (InfoShare):
     - infoshare_family_preservation_groups + view infoshare_fp_groupsTBL
     - infoshare_family_preservation_groupclients + view infoshare_fp_groupclientsTBL
     - infoshare_family_preservation_clients + view infoshare_fp_clientsTBL
  3. Youth Justice (KIMS):
     - YJ_YO_CDM_Data + MV yj_new_clients_kims + view yj_address_mapping
  4. Geospatial (GNAF):
     - gnaf_address_materialised_view + MV GNAF_address_view
  5. Hidden Ground Truth (dcj_truth):
     - ground_truth_persons
     - ground_truth_records
     - ground_truth_pairs

Includes all 78 relationship_type values, 16 name_usage_code values,
6 GNAF record_type values, 3 party_type_code values, and 8 planted DCJ scenarios.
"""

import datetime
import hashlib
import json
import os
import random
import subprocess

PROJECT_ID = os.environ.get("DCJ_PROJECT", "all-things-cdp")
LOCATION = os.environ.get("DCJ_LOCATION", "us-central1")
SDM_DS = os.environ.get("DCJ_SDM_DS", "dcj_sdm")
TRUTH_DS = os.environ.get("DCJ_TRUTH_DS", "dcj_truth")
SEED = int(os.environ.get("DCJ_SEED", "2026"))

random.seed(SEED)

# Exact 78 relationship_type values from DCJ metadata
RELATIONSHIP_TYPES = [
    "Daughter", "Extended Family Member", "Father's Female Partner", "Father's Partner",
    "Female Partner", "Foster Sibling", "Granddaughter", "Grandparent", "Grandson",
    "Great Aunt/Uncle", "Half-Sibling", "Male Partner", "Mother", "Mother's Female Partner",
    "Mother's Male Partner", "Niece/nephew", "Parent-to-be", "Partner's Son", "Sibling",
    "Step Grandparent", "Uncle", "Wife", "Carer (Family)", "Legal Guardian", "Aunt/Uncle",
    "Divorced from", "Father", "Grandfather", "Grandparent-to-be", "Great Niece/nephew",
    "Half-Sister", "Mother's Partner", "Niece", "Partner", "Partner's Child", "Sister",
    "Son", "Step-grandchild", "Unborn Grandchild", "Father's Male Partner", "Widowed from",
    "Step-father", "ATSI Community Relationship", "Annulled from", "Aunt", "Brother",
    "Child", "Cousin", "Grand Parent", "Grandchild", "Half-Brother", "Husband",
    "Other or Unknown Family Relationship", "Parent", "Partner's Daughter", "Separated from",
    "Significant family member for", "Step Child", "Step child", "Step-Parent",
    "Step-parents partner", "Unborn Child", "Sibling's child", "Carer (Non-Family)",
    "Other relative (extended family)", "Other relative (immediate family)", "Step-mother",
    "Grandmother", "Great Grandchild", "Great Grandparent", "Nephew", "Other",
    "Parent's Partner", "Partners Step Child", "Relative", "Sibling-to-be",
    "Significant family member is", "Step Parent", "Step-Sibling", "Unborn Niece/nephew",
    "Friend"
]

# Exact 16 name_usage_code values from DCJ metadata
NAME_USAGE_CODES = [
    "Legal Name", "Preferred Name", "Adopted Name", "Pre-Adoptive Name",
    "Name at Birth", "Tribal/Cultural Name", "Alias Name", "Married Name",
    "Previous Name", "New Born Identification Name", "Nick Name", "Professional Name",
    "Trading Name", "Business Entity Name", "Unspecified", None
]

# Exact 6 address_location record_type values from DCJ metadata
ADDRESS_RECORD_TYPES = [
    "BUILDING CENTROID", "PROPERTY CENTROID", "GAP GEOCODE",
    "LOCALITY", "STREET LOCALITY", "PROPERTY CENTROID MANUAL"
]

NSW_LOCATIONS = [
    {"suburb": "PARRAMATTA", "postcode": "2150", "lga_pid": "LGA16350", "lga": "Parramatta", "lat": -33.8151, "lon": 151.0011, "sa1": "11703133701", "sa2": "117031337", "electorate": "Parramatta"},
    {"suburb": "BLACKTOWN", "postcode": "2148", "lga_pid": "LGA10750", "lga": "Blacktown", "lat": -33.7668, "lon": 150.9054, "sa1": "11601130301", "sa2": "116011303", "electorate": "Blacktown"},
    {"suburb": "MOUNT DRUITT", "postcode": "2770", "lga_pid": "LGA10750", "lga": "Blacktown", "lat": -33.7689, "lon": 150.8172, "sa1": "11602130901", "sa2": "116021309", "electorate": "Mount Druitt"},
    {"suburb": "PENRITH", "postcode": "2750", "lga_pid": "LGA16350", "lga": "Penrith", "lat": -33.7511, "lon": 150.6942, "sa1": "12403146001", "sa2": "124031460", "electorate": "Penrith"},
    {"suburb": "LIVERPOOL", "postcode": "2170", "lga_pid": "LGA14900", "lga": "Liverpool", "lat": -33.9200, "lon": 150.9256, "sa1": "12703152401", "sa2": "127031524", "electorate": "Liverpool"},
    {"suburb": "CAMPBELLTOWN", "postcode": "2560", "lga_pid": "LGA11500", "lga": "Campbelltown", "lat": -34.0650, "lon": 150.8142, "sa1": "12302143701", "sa2": "123021437", "electorate": "Campbelltown"},
    {"suburb": "DUBBO", "postcode": "2830", "lga_pid": "LGA18230", "lga": "Dubbo Regional", "lat": -32.2430, "lon": 148.6048, "sa1": "10503110001", "sa2": "105031100", "electorate": "Dubbo"},
    {"suburb": "TAMWORTH", "postcode": "2340", "lga_pid": "LGA17310", "lga": "Tamworth Regional", "lat": -31.0927, "lon": 150.9320, "sa1": "11004120301", "sa2": "110041203", "electorate": "Tamworth"},
    {"suburb": "NEWCASTLE", "postcode": "2300", "lga_pid": "LGA15900", "lga": "Newcastle", "lat": -32.9283, "lon": 151.7817, "sa1": "11103122801", "sa2": "111031228", "electorate": "Newcastle"},
    {"suburb": "WOLLONGONG", "postcode": "2500", "lga_pid": "LGA18450", "lga": "Wollongong", "lat": -34.4248, "lon": 150.8931, "sa1": "10704114901", "sa2": "107041149", "electorate": "Wollongong"},
    {"suburb": "KEMPSEY", "postcode": "2440", "lga_pid": "LGA14350", "lga": "Kempsey", "lat": -31.0789, "lon": 152.8306, "sa1": "10802115601", "sa2": "108021156", "electorate": "Oxley"},
    {"suburb": "MOREE", "postcode": "2400", "lga_pid": "LGA15350", "lga": "Moree Plains", "lat": -29.4658, "lon": 149.8417, "sa1": "11002119201", "sa2": "110021192", "electorate": "Northern Tablelands"},
    {"suburb": "WAGGA WAGGA", "postcode": "2650", "lga_pid": "LGA17750", "lga": "Wagga Wagga", "lat": -35.1189, "lon": 147.3689, "sa1": "11303126901", "sa2": "113031269", "electorate": "Wagga Wagga"},
    {"suburb": "BANKSTOWN", "postcode": "2200", "lga_pid": "LGA11570", "lga": "Canterbury-Bankstown", "lat": -33.9173, "lon": 151.0333, "sa1": "11901135401", "sa2": "119011354", "electorate": "Bankstown"},
]

STREET_NAMES = [
    ("MACQUARIE", "ST"), ("GEORGE", "ST"), ("CHURCH", "ST"), ("VICTORIA", "RD"),
    ("RAILWAY", "PD"), ("GREAT WESTERN", "HWY"), ("WINDSOR", "RD"), ("PENNANT HILLS", "RD"),
    ("OXFORD", "ST"), ("KING", "ST"), ("PITT", "ST"), ("ELIZABETH", "ST"),
    ("WARATAH", "AV"), ("BANKSIA", "DR"), ("WATTLE", "PL"), ("JACARANDA", "AV"),
    ("KURRAJONG", "ST"), ("BROLGA", "RD"), ("ILLAWARRA", "RD"), ("DARLING", "ST")
]

MALE_NAMES = [
    ("Lachlan", "Lachie"), ("Jayden", "Jaden"), ("Liam", "Lee"), ("Noah", "Noe"),
    ("Oliver", "Ollie"), ("Jack", "Jacko"), ("Lucas", "Luke"), ("Mason", "Mase"),
    ("Ethan", "Etty"), ("Alexander", "Alex"), ("Samuel", "Sam"), ("Benjamin", "Ben"),
    ("William", "Will"), ("Thomas", "Tom"), ("James", "Jamie"), ("Daniel", "Dan"),
    ("Matthew", "Matt"), ("Ryan", "Ry"), ("Joshua", "Josh"), ("Cooper", "Coop"),
    ("Kian", "Ki"), ("Tariq", "Riq"), ("Xavier", "Xav"), ("jarrah", "Jarra")
]

FEMALE_NAMES = [
    ("Charlotte", "Charlie"), ("Olivia", "Liv"), ("Amelia", "Millie"), ("Isla", "Izzy"),
    ("Mia", "Mimi"), ("Ava", "Avie"), ("Grace", "Gracie"), ("Willow", "Wil"),
    ("Harper", "Harp"), ("Chloe", "Chlo"), ("Ella", "Ellie"), ("Sophie", "Soph"),
    ("Emily", "Em"), ("Ruby", "Rue"), ("Matilda", "Tilly"), ("Zoe", "Zo"),
    ("Maya", "May"), ("Kayla", "Kay"), ("Kirra", "Kiri"), ("Tahlia", "Tali"),
    ("Aaliyah", "Liyah"), ("Sienna", "Sisi"), ("Evie", "Eve"), ("Maddison", "Maddie")
]

ATSI_CULTURAL_NAMES = [
    ("Jarrah", "James", "Wiradjuri"), ("Kirra", "Chloe", "Gamilaraay"),
    ("Bindi", "Rebecca", "Bundjalung"), ("Nullah", "noah", "Dharug"),
    ("Tahlia", "natalie", "Yuin"), ("Marlee", "Mary", "Barkindji"),
    ("Jedda", "Jessica", "Gumbaynggirr"), ("Yarran", "Aaron", "Wiradjuri"),
    ("Allira", "Alice", "Gamilaraay"), ("Kalina", "Kylie", "Dharawal")
]

SURNAMES = [
    "Smith", "Jones", "Williams", "Brown", "Wilson", "Taylor", "Anderson",
    "Thomas", "Jackson", "White", "Harris", "Martin", "Thompson", "Garcia",
    "Martinez", "Robinson", "Clark", "Rodriguez", "Lewis", "Walker",
    "Hall", "Allen", "Young", "King", "Wright", "Lopez", "Hill", "Scott",
    "Nguyen", "Tran", "Le", "pham", "Al-Mansoor", "Haddad", "Khoury",
    "O'Connor", "McAllister", "MacDonald", "Campbell", "Stewart",
    "Mundy", "Saunders", "Daley", "Gordon", "Craig", "french", "Peachey"
]

# Same-2nd/3rd-letter twin name pairs that produce IDENTICAL SLK-581 codes!
# SLK-581 uses 2nd & 3rd letters of given name:
#   Maya (MA-YA -> AY) & Kayla (KA-YLA -> AY)
#   Liam (LI-AM -> IA) & Kian (KI-AN -> IA)
#   Ella (EL-LA -> LL) & Ollie (OL-LIE -> LL)
#   Grace (GR-ACE -> RA) & Frankie (FR-ANKIE -> RA)
SLK_TWIN_PAIRS = [
    ("Maya", "Kayla", "F"),
    ("Liam", "Kian", "M"),
    ("Grace", "Frances", "F"),
    ("Mason", "Jason", "M"),
    ("Chloe", "Phoebe", "F"),
    ("Ethan", "athol", "M"),
]


def compute_slk581(given_name: str, family_name: str, dob: datetime.date, gender: str) -> str:
    fam = "".join(c for c in (family_name or "").upper() if c.isalpha())
    giv = "".join(c for c in (given_name or "").upper() if c.isalpha())
    l2 = fam[1] if len(fam) >= 2 else "2"
    l3 = fam[2] if len(fam) >= 3 else "2"
    l5 = fam[4] if len(fam) >= 5 else "2"
    if not fam:
        l2, l3, l5 = "9", "9", "9"
    f2 = giv[1] if len(giv) >= 2 else "2"
    f3 = giv[2] if len(giv) >= 3 else "2"
    if not giv:
        f2, f3 = "9", "9"
    sex_code = "1" if (gender or "").upper().startswith("M") else ("2" if (gender or "").upper().startswith("F") else "9")
    return f"{l2}{l3}{l5}{f2}{f3}{dob.strftime('%d%m%Y')}{sex_code}"


def enum_struct(val: str, label: str = None):
    if val is None:
        return {"FieldValueENUM": None, "FieldENUMLabel": None}
    return {"FieldValueENUM": val, "FieldENUMLabel": label or val}


def multi_enum_struct(vals, label: str = None):
    if not vals:
        return {"FieldValueMultiENUM": [], "FieldENUMLabel": None}
    return {"FieldValueMultiENUM": list(vals), "FieldENUMLabel": label or ", ".join(vals)}


def build_gnaf_addresses(n_addresses: int = 260):
    addresses = []
    # First 2 addresses are Crisis Refuges / Residential Hubs (for Scenario 6: Hub Hairball)
    hub_specs = [
        ("GNAF-NSW-HUB-0001", "PARRAMATTA WOMEN AND CHILDREN SAFE REFUGE", "UNIT", "1", "10", "14", "GREAT WESTERN", "HWY", NSW_LOCATIONS[0], "BUILDING CENTROID"),
        ("GNAF-NSW-HUB-0002", "WESTERN SYDNEY YOUTH RESIDENTIAL CARE HUB", None, None, "88", "90", "RAILWAY", "PD", NSW_LOCATIONS[1], "PROPERTY CENTROID"),
    ]
    for gnaf_id, bldg, flat_type, flat_no, num_first, num_last, st_name, st_type, loc, rec_type in hub_specs:
        full_addr = f"{f'{flat_type} {flat_no}, ' if flat_no else ''}{num_first} {st_name} {st_type}, {loc['suburb']} NSW {loc['postcode']}"
        addresses.append({
            "id": gnaf_id,
            "building_name": bldg,
            "lot_number_prefix": None,
            "lot_number": str(random.randint(1, 50)),
            "lot_number_suffix": None,
            "flat_type": flat_type,
            "flat_number_prefix": None,
            "flat_number": flat_no,
            "flat_number_suffix": None,
            "number_first_prefix": None,
            "number_first": num_first,
            "number_first_suffix": None,
            "number_last_prefix": None,
            "number_last": num_last,
            "number_last_suffix": None,
            "street_name": st_name,
            "street_type": st_type,
            "street_type_suffix": None,
            "suburb": loc["suburb"],
            "postcode": loc["postcode"],
            "state": "NSW",
            "latitude": round(loc["lat"] + random.uniform(-0.01, 0.01), 6),
            "longitude": round(loc["lon"] + random.uniform(-0.01, 0.01), 6),
            "full_address": full_addr,
            "record_type": rec_type,
            "lga_pid": loc["lga_pid"],
            "lga_name": loc["lga"],
            "sa1_2021": loc["sa1"],
            "sa2_2021": loc["sa2"],
            "electorate": loc["electorate"],
        })

    for i in range(3, n_addresses + 1):
        loc = random.choice(NSW_LOCATIONS)
        st_name, st_type = random.choice(STREET_NAMES)
        num_first = str(random.randint(1, 240))
        has_flat = (i % 5 == 0)
        flat_type = "UNIT" if has_flat else None
        flat_no = str(random.randint(1, 24)) if has_flat else None
        rec_type = ADDRESS_RECORD_TYPES[i % len(ADDRESS_RECORD_TYPES)]
        full_addr = f"{f'UNIT {flat_no}, ' if has_flat else ''}{num_first} {st_name} {st_type}, {loc['suburb']} NSW {loc['postcode']}"
        addresses.append({
            "id": f"GNAF-NSW-{i:05d}",
            "building_name": f"{loc['suburb']} GARDENS" if i % 19 == 0 else None,
            "lot_number_prefix": None,
            "lot_number": str(random.randint(1, 400)),
            "lot_number_suffix": "A" if i % 23 == 0 else None,
            "flat_type": flat_type,
            "flat_number_prefix": None,
            "flat_number": flat_no,
            "flat_number_suffix": None,
            "number_first_prefix": None,
            "number_first": num_first,
            "number_first_suffix": None,
            "number_last_prefix": None,
            "number_last": str(int(num_first) + 2) if i % 17 == 0 else None,
            "number_last_suffix": None,
            "street_name": st_name,
            "street_type": st_type,
            "street_type_suffix": "NORTH" if i % 29 == 0 else None,
            "suburb": loc["suburb"],
            "postcode": loc["postcode"],
            "state": "NSW",
            "latitude": round(loc["lat"] + random.uniform(-0.025, 0.025), 6),
            "longitude": round(loc["lon"] + random.uniform(-0.025, 0.025), 6),
            "full_address": full_addr,
            "record_type": rec_type,
            "lga_pid": loc["lga_pid"],
            "lga_name": loc["lga"],
            "sa1_2021": loc["sa1"],
            "sa2_2021": loc["sa2"],
            "electorate": loc["electorate"],
        })
    return addresses


def generate_all():
    gnaf_addresses = build_gnaf_addresses(260)
    hub_refuge_addr = gnaf_addresses[0]
    hub_youth_addr = gnaf_addresses[1]
    regular_addrs = gnaf_addresses[2:]

    # Ground truth structures
    gt_persons = []
    gt_records = []

    # SDM Table rows
    person_file_rows = []
    person_file_1_ciw_rows = []
    person_name_1st_batch_rows = []
    person_names_file_2_ciw_rows = []
    person_relation_file_4_ciw_rows = []
    addr_loc_ods_rows = []
    addr_rel_loc_ods_rows = []

    infoshare_groups_rows = []
    infoshare_groupclients_rows = []
    infoshare_clients_rows = []

    yj_rows = []

    # Populate addr_loc_ods from gnaf_addresses
    now_iso = "2026-10-01T00:00:00Z"
    for idx, a in enumerate(gnaf_addresses, start=1):
        addr_loc_ods_rows.append({
            "ADDR_LOC_ID": f"CP-LOC-{idx:05d}",
            "GNAF_PID": a["id"],
            "BUILDING_NAME": a["building_name"],
            "FLAT_TYPE": a["flat_type"],
            "FLAT_NUMBER": a["flat_number"],
            "STREET_NUMBER_FIRST": a["number_first"],
            "STREET_NUMBER_LAST": a["number_last"],
            "STREET_NAME": a["street_name"],
            "STREET_TYPE": a["street_type"],
            "SUBURB": a["suburb"],
            "STATE": a["state"],
            "POSTCODE": a["postcode"],
            "LATITUDE": a["latitude"],
            "LONGITUDE": a["longitude"],
            "FULL_ADDRESS": a["full_address"],
            "RECORD_TYPE": a["record_type"],
            "W_INSERT_DT": now_iso,
        })

    addr_id_to_cp_loc = {a["id"]: f"CP-LOC-{idx:05d}" for idx, a in enumerate(gnaf_addresses, start=1)}

    # Counters
    person_seq = 0
    cp_seq = 10000
    fp_client_seq = 50000
    fp_group_seq = 8000
    fp_gc_seq = 90000
    yj_seq = 30000
    cp_name_seq = 1
    cp_rel_seq = 1
    cp_addr_rel_seq = 1

    def next_true_person(scenario, given, middle, family, gender, dob, atsi_status, is_protected=False, is_cald=False, cni=None, ndis=None, addr=None):
        nonlocal person_seq
        person_seq += 1
        tp_id = f"TRUE-PER-{person_seq:04d}"
        p = {
            "true_person_id": tp_id,
            "scenario": scenario,
            "canonical_given_name": given,
            "canonical_middle_name": middle,
            "canonical_family_name": family,
            "gender": gender,
            "dob": dob.isoformat(),
            "atsi_status": atsi_status,
            "is_protected": is_protected,
            "is_cald": is_cald,
            "cni_number": cni,
            "ndis_number": ndis,
            "primary_gnaf_id": addr["id"] if addr else None,
        }
        gt_persons.append(p)
        return p

    def add_cp_record(tp, load_batch, given, middle, family, dob, gender, email, home_phn, mobile_phn,
                      addr, dob_status="VERIFIED", indig_status="No", protected="N",
                      extra_names=None, cs_id_override=None, scenario_note=""):
        nonlocal cp_seq, cp_name_seq, cp_addr_rel_seq
        cp_seq += 1
        cs_id = cs_id_override or f"CS-{cp_seq}"
        rec_id = f"CP-REC-{cp_seq}"
        row = {
            "CHILDSTORY_ID": cs_id,
            "ID": rec_id,
            "GENDER": "Male" if gender == "M" else ("Female" if gender == "F" else "Unknown"),
            "DOB": f"{dob.isoformat()}T00:00:00Z",
            "DOB_STATUS": dob_status,
            "INDIG_STATUS": indig_status,
            "VITAL_STATUS": "Alive",
            "EMAIL": email,
            "HOME_PHN": home_phn,
            "MOBILE_PHN": mobile_phn,
            "ALIASES": extra_names[0]["given"] + " " + extra_names[0]["family"] if extra_names else None,
            "PROTECTED_INDIVIDUAL": protected,
            "UPD_KEY": f"UPD-{cp_seq}",
            "W_INSERT_DT": "2026-09-15T10:00:00Z" if load_batch == 1 else "2026-10-02T14:30:00Z",
            "INSERT_UPDATE_DELETE_FLG": "I",
            "INGESTTIME": "2026-09-15T10:05:00Z" if load_batch == 1 else "2026-10-02T14:35:00Z",
            "INGESTTYPE": "BATCH",
            "FILENAME": f"childstory_person_batch_{load_batch}.csv",
            "BATCHID": f"BATCH-CP-{load_batch:02d}",
        }
        if load_batch == 1:
            person_file_rows.append(row)
        else:
            person_file_1_ciw_rows.append(row)

        # Primary name row
        cp_name_seq += 1
        name_row = {
            "CHILDSTORY_ID": cs_id,
            "FST_NAME": given,
            "MID_NAME": middle,
            "LAST_NAME": family,
            "TYPE": "Legal Name",
            "PRIMARY_FLG": "Y",
            "ID": f"CP-NM-{cp_name_seq:06d}",
            "UPD_KEY": f"UPDNM-{cp_name_seq}",
            "W_INSERT_DT": row["W_INSERT_DT"],
            "INSERT_UPDATE_DELETE_FLG": "I",
            "INGESTTIME": row["INGESTTIME"],
            "INGESTTYPE": "BATCH",
            "FILENAME": f"childstory_names_batch_{load_batch}.csv",
            "BATCHID": row["BATCHID"],
        }
        if load_batch == 1:
            name_row_b1 = dict(name_row)
            name_row_b1["source_program"] = "Child Protection"
            person_name_1st_batch_rows.append(name_row_b1)
        else:
            person_names_file_2_ciw_rows.append(name_row)

        # Extra names (Adopted, Pre-Adoptive, Tribal/Cultural, Alias, Married, etc.)
        for ex in (extra_names or []):
            cp_name_seq += 1
            ex_row = {
                "CHILDSTORY_ID": cs_id,
                "FST_NAME": ex.get("given", given),
                "MID_NAME": ex.get("middle", middle),
                "LAST_NAME": ex.get("family", family),
                "TYPE": ex.get("type", "Alias Name"),
                "PRIMARY_FLG": "N",
                "ID": f"CP-NM-{cp_name_seq:06d}",
                "UPD_KEY": f"UPDNM-{cp_name_seq}",
                "W_INSERT_DT": row["W_INSERT_DT"],
                "INSERT_UPDATE_DELETE_FLG": "I",
                "INGESTTIME": row["INGESTTIME"],
                "INGESTTYPE": "BATCH",
                "FILENAME": f"childstory_names_batch_{load_batch}.csv",
                "BATCHID": row["BATCHID"],
            }
            if load_batch == 1:
                ex_row_b1 = dict(ex_row)
                ex_row_b1["source_program"] = "Child Protection"
                person_name_1st_batch_rows.append(ex_row_b1)
            else:
                person_names_file_2_ciw_rows.append(ex_row)

        # Address link
        if addr:
            cp_addr_rel_seq += 1
            addr_rel_loc_ods_rows.append({
                "ADDR_REL_ID": f"CP-AREL-{cp_addr_rel_seq:06d}",
                "CHILDSTORY_ID": cs_id,
                "ADDR_LOC_ID": addr_id_to_cp_loc[addr["id"]],
                "PRIMARY_ADDR_FLG": "Y",
                "ADDR_PURPOSE": "Residential",
                "START_DT": "2024-01-15T00:00:00Z",
                "END_DT": None,
                "W_INSERT_DT": row["W_INSERT_DT"],
            })

        gt_records.append({
            "source_record_id": f"CP:{rec_id}",
            "source_system": "CHILDSTORY",
            "source_program": "Child Protection",
            "source_person_id": cs_id,
            "true_person_id": tp["true_person_id"],
            "scenario": tp["scenario"],
            "scenario_note": scenario_note or tp["scenario"],
        })
        return cs_id, rec_id

    def add_fp_client(tp, given, family, dob, gender, addr, phone, email,
                      cs_id_link=None, cni=None, ndis=None, is_dob_est="No",
                      atsi="No", alias_str=None, carer1=None, carer_ph1=None,
                      group_auto_id=None, org_auto_id=401, slk_override=None,
                      is_homeless="No", lang="English", scenario_note=""):
        nonlocal fp_client_seq, fp_gc_seq
        fp_client_seq += 1
        auto_id = fp_client_seq
        client_id = f"FP-CL-{auto_id}"
        slk = slk_override or compute_slk581(given, family, dob, gender)
        point_wkt = f"POINT({addr['longitude']} {addr['latitude']})" if addr else None

        row = {
            "AutoID": auto_id,
            "ClientLabel": f"{given} {family}",
            "ChildStoryID": cs_id_link,
            "FirstName": given,
            "LastName": family,
            "BirthDate": dob.isoformat(),
            "Suburb": addr["suburb"] if addr else "PARRAMATTA",
            "OrganisationAutoID": org_auto_id,
            "MetaDataSetLabel": "PROGRAM/FamilyPreservation/NSW_DCJ_2026",
            "ClientID": client_id,
            "SLK": slk,
            "IsBirthDateAnEstimate": enum_struct("Y" if is_dob_est == "Yes" else "N", is_dob_est),
            "ClientGroupStatus": enum_struct("ACTIVE", "Active"),
            "Gender": enum_struct(gender, "Male" if gender == "M" else "Female"),
            "ClientConsented": enum_struct("Y", "Yes"),
            "AboriginalOrTorresStraitIslanderOrigin": enum_struct("ATSI" if atsi != "No" else "NON_ATSI", atsi),
            "IsHomeless": enum_struct("Y" if is_homeless == "Yes" else "N", is_homeless),
            "Address": addr["full_address"] if addr else None,
            "HouseholdComposition": enum_struct("FAMILY", "Family Household"),
            "BirthCountry": enum_struct("AUS", "Australia"),
            "Language": enum_struct("ENG" if lang == "English" else "OTR", lang),
            "ProficiencyInSpokenEnglish": enum_struct("VERY_WELL", "Very Well"),
            "InterpreterRequired": enum_struct("N", "No"),
            "CaregiverStatus": enum_struct("PRIMARY", "Primary Caregiver"),
            "Disabilities": bool(ndis),
            "IntellectualLearning": False,
            "PhysicalDiverse": False,
            "Psychiatric": False,
            "SensorySpeech": False,
            "ManualAddressLine1": f"{addr['number_first']} {addr['street_name']} {addr['street_type']}" if addr else None,
            "ManualSuburb": addr["suburb"] if addr else None,
            "ManualState": "NSW",
            "ManualPostcode": addr["postcode"] if addr else None,
            "Dataset": "GNAF_2026",
            "GeoDatumCode": "GDA2020",
            "Point": point_wkt,
            "Longitude": addr["longitude"] if addr else None,
            "Latitude": addr["latitude"] if addr else None,
            "LotIdentifier": addr["lot_number"] if addr else None,
            "StreetNumber1": addr["number_first"] if addr else None,
            "StreetName": addr["street_name"] if addr else None,
            "StreetType": addr["street_type"] if addr else None,
            "LocalityName": addr["suburb"] if addr else None,
            "StateTerritory": "NSW",
            "Postcode": addr["postcode"] if addr else None,
            "CadastralIdentifier": f"CAD-{auto_id}",
            "FormattedAddress": addr["full_address"] if addr else None,
            "AddressId": addr["id"] if addr else None,
            "AddressRecordType": addr["record_type"] if addr else "PROPERTY CENTROID",
            "LgaPID": addr["lga_pid"] if addr else "LGA16350",
            "StateElectoralPID": "NSW_EL_01",
            "CommElectoralPID": "FED_EL_01",
            "2016_mbID": "1000001",
            "2016_sa1ID": addr["sa1_2021"] if addr else "11703133701",
            "2016_sa2ID": addr["sa2_2021"] if addr else "117031337",
            "2016_sa3ID": "11703",
            "2016_sa4ID": "117",
            "2021_mbID": "2000001",
            "2021_sa1ID": addr["sa1_2021"] if addr else "11703133701",
            "2021_sa2ID": addr["sa2_2021"] if addr else "117031337",
            "2021_sa3ID": "11703",
            "2021_sa4ID": "117",
            "CommElectoralName": addr["electorate"] if addr else "Parramatta",
            "LgaName": addr["lga_name"] if addr else "Parramatta",
            "LgaShortName": addr["lga_name"] if addr else "Parramatta",
            "StateElectoralName": addr["electorate"] if addr else "Parramatta",
            "StateElectoralType": "General",
            "IsDeleted": False,
            "IsAddressValidated": True,
            "RevalidationResults": 100,
            "CreatedByUsername": "infoshare_worker",
            "CreatedOn": "2026-09-20T09:00:00Z",
            "UpdatedByUsername": "infoshare_worker",
            "UpdatedOn": "2026-10-05T11:00:00Z",
            "ContactPost": addr["full_address"] if addr else None,
            "ChildDOB": None,
            "ContactEmail": email,
            "AS_ClientPriority": enum_struct("HIGH", "High Priority"),
            "AS_howdidyouhearaboutus": enum_struct("DCJ_REFERRAL", "DCJ Referral"),
            "AS_Indicators_ChildAbuseMaterial": enum_struct("N", "No"),
            "AS_Indicators_DeceptiveRecruitment": enum_struct("N", "No"),
            "AS_Indicators_ForcedMarriage": enum_struct("N", "No"),
            "AS_Indicators_OrganTrafficking": enum_struct("N", "No"),
            "AS_Indicators_ServitudeOffenses": enum_struct("N", "No"),
            "AS_Indicators_SexualServitudeOffenses": enum_struct("N", "No"),
            "AS_Indicators_TraffickingChildren": enum_struct("N", "No"),
            "AS_Indicators_TraffickingPersons": enum_struct("N", "No"),
            "ClientRepresentation": enum_struct("SELF", "Self / Family"),
            "Degreeofimpairment": enum_struct("NONE", "None"),
            "Disability": enum_struct("Y" if ndis else "N", "Yes" if ndis else "No"),
            "DisabilityStatus": enum_struct("CONFIRMED" if ndis else "NONE", "Confirmed" if ndis else "None"),
            "DisabilityType": enum_struct("NDIS_SUPPORTED" if ndis else "NONE", "NDIS Supported" if ndis else "None"),
            "ReporterType": enum_struct("CASEWORKER", "DCJ Caseworker"),
            "TranslationNeed": enum_struct("N", "No"),
            "AS_Indicators_ForcedLabourOffenses": multi_enum_struct(["NONE"], "None"),
            "ContactPhoneNumber": phone,
            "DisabilitySupportNeeded": "NDIS Plan Active" if ndis else None,
            "FamilyName": family,
            "FirstName_JSON": given,
            "Issues": scenario_note or "Family Preservation Support",
            "ATSICode": enum_struct("1" if atsi != "No" else "4", atsi),
            "HasDisabilities": enum_struct("Y" if ndis else "N", "Yes" if ndis else "No"),
            "ICFType": multi_enum_struct([], None),
            "Seeing": multi_enum_struct([], None),
            "Hearing": multi_enum_struct([], None),
            "Mobility": multi_enum_struct([], None),
            "Communication": multi_enum_struct([], None),
            "Cognition": multi_enum_struct([], None),
            "Selfcare": multi_enum_struct([], None),
            "Behaviour": multi_enum_struct([], None),
            "WorkEmployment": multi_enum_struct([], None),
            "EducationLearning": multi_enum_struct([], None),
            "Other": multi_enum_struct([], None),
            "CNINumber": cni,
            "HowCNI": enum_struct("VERIFIED", "Police CNI Verified") if cni else enum_struct(None, None),
            "ClientStatus": enum_struct("OPEN", "Open Case"),
            "PendingStart": "2026-01-10",
            "AnyKnownAlias": enum_struct("Y" if alias_str else "N", alias_str or "No"),
            "AltAddress": enum_struct("N", "No"),
            "AltAddressValue": None,
            "ContactNumber": phone,
            "CarerNameandRelationship1": carer1,
            "CarerNameandRelationship2": None,
            "CarerNameandRelationship3": None,
            "CarerContactNumber1": carer_ph1,
            "CarerContactNumber2": None,
            "CarerContactNumber3": None,
            "YoungParent": enum_struct("N", "No"),
            "NDISPackage": enum_struct("Y" if ndis else "N", "Yes" if ndis else "No"),
            "NDISNumber": ndis,
            "NDISPackageStart": "2025-07-01" if ndis else None,
            "NDISPackageEnd": "2027-06-30" if ndis else None,
            "AmountSupport": "24000" if ndis else None,
            "AmountTotal": "24000" if ndis else None,
            "ProgramManagement": enum_struct("DCJ_FP", "DCJ Family Preservation"),
            "CaseManager": enum_struct("CW_01", "Senior Caseworker"),
            "CaseManagerNumber": "+61299991000",
            "CaseManagerEmail": "caseworker.fp@dcj.nsw.gov.au",
            "LOAD_DATETIME": "2026-10-05T12:00:00Z",
        }
        infoshare_clients_rows.append(row)

        if group_auto_id:
            fp_gc_seq += 1
            infoshare_groupclients_rows.append({
                "AutoID": fp_gc_seq,
                "OrganisationAutoID": org_auto_id,
                "ClientAutoID": auto_id,
                "GroupAutoID": group_auto_id,
                "MetaDataSetLabel": "PROGRAM/FamilyPreservation/NSW_DCJ_2026",
                "IsDeleted": False,
                "BATCHID": "BATCH-FP-01",
                "source_program": "InfoShare- Family Preservation",
            })

        gt_records.append({
            "source_record_id": f"FP:{client_id}",
            "source_system": "INFOSHARE",
            "source_program": "InfoShare- Family Preservation",
            "source_person_id": client_id,
            "true_person_id": tp["true_person_id"],
            "scenario": tp["scenario"],
            "scenario_note": scenario_note or tp["scenario"],
        })
        return client_id, auto_id

    def add_fp_group(group_label, org_auto_id, num_children, oldest_dob, atsi="No"):
        nonlocal fp_group_seq
        fp_group_seq += 1
        g_auto_id = fp_group_seq
        infoshare_groups_rows.append({
            "AutoID": g_auto_id,
            "GroupLabel": group_label,
            "OrganisationAutoID": org_auto_id,
            "MetaDataSetLabel": "PROGRAM/FamilyPreservation/NSW_DCJ_2026",
            "GroupID": f"FP-GRP-{g_auto_id}",
            "OutletActivityID": f"OUTLET-{org_auto_id}",
            "GroupClients": group_label,
            "GroupType": enum_struct("FAMILY_GROUP", "Family Group"),
            "NumberofUnidentifiedGroupMembers": 0,
            "OtherDCJServicesReceived": enum_struct("CHILD_PROTECTION", "Child Protection"),
            "NumberofDependentChildren": num_children,
            "OldestChildDOB": oldest_dob.isoformat(),
            "ATSICode": enum_struct("1" if atsi != "No" else "4", atsi),
            "AnyChildOfATSIOrigin": enum_struct("Y" if atsi != "No" else "N", atsi),
            "IsDeleted": False,
            "CreatedByUsername": "infoshare_worker",
            "CreatedOn": "2026-09-10T09:00:00Z",
            "UpdatedByUsername": "infoshare_worker",
            "UpdatedOn": "2026-10-01T09:00:00Z",
            "BATCHID": "BATCH-FP-01",
            "source_program": "InfoShare- Family Preservation",
        })
        return g_auto_id

    def add_yj_record(tp_yo, given, family, dob, gender, indig, addr,
                      rel_tp=None, rel_given=None, rel_family=None, rel_type=None,
                      desc="Youth Justice KIMS client record"):
        nonlocal yj_seq
        yj_seq += 1
        yo_id = f"YJ-{yj_seq}"
        street_str = (
            f"{addr['flat_number']}/{addr['number_first']} {addr['street_name'].title()} {addr['street_type']}"
            if addr and addr.get("flat_number")
            else (f"{addr['number_first']} {addr['street_name'].title()} {addr['street_type']}" if addr else "10 George St")
        )
        row = {
            "Young_Offender_Id": yo_id,
            "First_Name": given,
            "Last_name": family,
            "Date_of_Birth": dob.isoformat(),
            "Sex": gender,
            "Indigenous_Status": indig,
            "Address_Street": street_str,
            "Address_Suburb": addr["suburb"] if addr else "PARRAMATTA",
            "Postcode": addr["postcode"] if addr else "2150",
            "YO_Relation_First_Name": rel_given,
            "YO_Relation_Last_Name": rel_family,
            "Is_YO_Flag": "Y",
            "Relationship_To_YO": rel_type,
            "Desc": desc,
        }
        yj_rows.append(row)
        gt_records.append({
            "source_record_id": f"YJ:{yo_id}",
            "source_system": "KIMS_YJ",
            "source_program": "Youth Justice",
            "source_person_id": yo_id,
            "true_person_id": tp_yo["true_person_id"],
            "scenario": tp_yo["scenario"],
            "scenario_note": desc,
        })
        return yo_id

    def add_cp_relation(subj_cs_id, rel_type, rel_cs_id):
        nonlocal cp_rel_seq
        cp_rel_seq += 1
        person_relation_file_4_ciw_rows.append({
            "SUBJECT_PERSON_NUMBER": subj_cs_id,
            "REL_TYPE": rel_type,
            "RELATED_PERSON_NUMBER": rel_cs_id,
            "ID": f"CP-REL-{cp_rel_seq:06d}",
            "W_INSERT_DT": "2026-10-02T15:00:00Z",
            "INSERT_UPDATE_DELETE_FLG": "I",
            "INGESTTIME": "2026-10-02T15:05:00Z",
            "INGESTTYPE": "BATCH",
            "FILENAME": "childstory_relations_batch_2.csv",
            "BATCHID": "BATCH-CP-02",
        })

    # =====================================================================
    # SCENARIO 1: CROSSOVER_YOUTH (45 Young People + 45 Mothers = 90 people)
    # Appears in Child Protection, InfoShare Family Preservation, AND Youth Justice
    # with nickname/diminutive in YJ, missing ChildStoryID in YJ, and relative link.
    # =====================================================================
    for i in range(45):
        addr = regular_addrs[i % len(regular_addrs)]
        is_male = (i % 2 == 0)
        given, nick = (MALE_NAMES[i % len(MALE_NAMES)] if is_male else FEMALE_NAMES[i % len(FEMALE_NAMES)])
        family = SURNAMES[i % len(SURNAMES)]
        gender = "M" if is_male else "F"
        dob = datetime.date(2009 + (i % 4), ((i % 12) + 1), ((i % 27) + 1))
        atsi = "Aboriginal" if i % 3 == 0 else "No"
        cni = f"CNI-{700000 + i}"
        ndis = f"43{1000000 + i}" if i % 4 == 0 else None
        mob = f"04{11000000 + i:08d}"
        email = f"{given.lower()}.{family.lower()}{i}@example.org.au"

        # Mother
        mom_given, _ = FEMALE_NAMES[(i + 5) % len(FEMALE_NAMES)]
        mom_dob = datetime.date(1984 + (i % 6), ((i % 12) + 1), ((i % 25) + 1))
        mom_mob = f"04{22000000 + i:08d}"
        mom_email = f"{mom_given.lower()}.{family.lower()}{i}@familymail.au"

        tp_youth = next_true_person("CROSSOVER_YOUTH", given, "James" if is_male else "Louise", family, gender, dob, atsi, cni=cni, ndis=ndis, addr=addr)
        tp_mom = next_true_person("CROSSOVER_YOUTH_PARENT", mom_given, "Anne", family, "F", mom_dob, atsi, addr=addr)

        cs_youth, _ = add_cp_record(
            tp_youth, load_batch=2, given=given, middle="James" if is_male else "Louise", family=family,
            dob=dob, gender=gender, email=email, home_phn=None, mobile_phn=mob, addr=addr,
            indig_status=atsi, extra_names=[{"given": nick, "family": family, "type": "Preferred Name"}],
            scenario_note="Crossover youth in ChildStory, InfoShare FP, and Youth Justice KIMS"
        )
        cs_mom, _ = add_cp_record(
            tp_mom, load_batch=2, given=mom_given, middle="Anne", family=family,
            dob=mom_dob, gender="F", email=mom_email, home_phn=None, mobile_phn=mom_mob, addr=addr,
            indig_status=atsi, scenario_note="Mother of crossover youth"
        )
        add_cp_relation(cs_mom, "Mother", cs_youth)
        add_cp_relation(cs_youth, "Son" if is_male else "Daughter", cs_mom)

        grp_id = add_fp_group(f"{family} Family Group #{i+1}", 401 + (i % 3), 1, dob, atsi=atsi)
        add_fp_client(
            tp_youth, given=given, family=family, dob=dob, gender=gender, addr=addr,
            phone=mob, email=email, cs_id_link=cs_youth if i % 2 == 0 else None,
            cni=cni, ndis=ndis, atsi=atsi, alias_str=f"{nick} {family}",
            carer1=f"{mom_given} {family} (Mother)", carer_ph1=mom_mob, group_auto_id=grp_id,
            scenario_note="Crossover youth in InfoShare Family Preservation"
        )
        add_fp_client(
            tp_mom, given=mom_given, family=family, dob=mom_dob, gender="F", addr=addr,
            phone=mom_mob, email=mom_email, cs_id_link=cs_mom, atsi=atsi, group_auto_id=grp_id,
            scenario_note="Mother in InfoShare Family Preservation"
        )

        # In Youth Justice, recorded under diminutive/nickname (e.g. Lachie instead of Lachlan)
        add_yj_record(
            tp_youth, given=nick, family=family, dob=dob, gender=gender, indig=atsi, addr=addr,
            rel_tp=tp_mom, rel_given=mom_given, rel_family=family, rel_type="Mother",
            desc=f"Crossover Youth ({nick} vs {given}) with Mother {mom_given} {family}"
        )

    # =====================================================================
    # SCENARIO 2: TWIN_SIBLING_SLK_COLLISION (30 twin pairs = 60 people)
    # Twins living at the same GNAF address, sharing carer phone, AND
    # having identical SLK-581 codes (e.g., Maya & Kayla born same day).
    # Must NOT be merged into one person!
    # =====================================================================
    for i in range(30):
        addr = regular_addrs[(45 + i) % len(regular_addrs)]
        t1_given, t2_given, gender = SLK_TWIN_PAIRS[i % len(SLK_TWIN_PAIRS)]
        family = SURNAMES[(i + 12) % len(SURNAMES)]
        dob = datetime.date(2012 + (i % 4), ((i % 11) + 1), ((i % 26) + 1))
        shared_carer_ph = f"04{33000000 + i:08d}"
        shared_email = f"family.{family.lower()}{i}@homemail.com.au"

        tp_t1 = next_true_person("TWIN_SIBLING_SLK_COLLISION", t1_given, "Rose" if gender == "F" else "John", family, gender, dob, "No", addr=addr)
        tp_t2 = next_true_person("TWIN_SIBLING_SLK_COLLISION", t2_given, "Jane" if gender == "F" else "Mark", family, gender, dob, "No", addr=addr)

        cs_t1, _ = add_cp_record(
            tp_t1, load_batch=2, given=t1_given, middle="Rose" if gender == "F" else "John", family=family,
            dob=dob, gender=gender, email=shared_email, home_phn=None, mobile_phn=shared_carer_ph, addr=addr,
            scenario_note=f"Twin A ({t1_given} {family}) — shares DOB, address, phone & SLK-581 with Twin B ({t2_given})"
        )
        cs_t2, _ = add_cp_record(
            tp_t2, load_batch=2, given=t2_given, middle="Jane" if gender == "F" else "Mark", family=family,
            dob=dob, gender=gender, email=shared_email, home_phn=None, mobile_phn=shared_carer_ph, addr=addr,
            scenario_note=f"Twin B ({t2_given} {family}) — shares DOB, address, phone & SLK-581 with Twin A ({t1_given})"
        )
        add_cp_relation(cs_t1, "Sibling", cs_t2)
        add_cp_relation(cs_t2, "Brother" if gender == "M" else "Sister", cs_t1)

        grp_id = add_fp_group(f"{family} Twin Household #{i+1}", 402, 2, dob)
        add_fp_client(
            tp_t1, given=t1_given, family=family, dob=dob, gender=gender, addr=addr,
            phone=shared_carer_ph, email=shared_email, cs_id_link=None, group_auto_id=grp_id,
            scenario_note=f"Twin A ({t1_given}) in InfoShare — identical SLK-581 collision test"
        )
        add_fp_client(
            tp_t2, given=t2_given, family=family, dob=dob, gender=gender, addr=addr,
            phone=shared_carer_ph, email=shared_email, cs_id_link=None, group_auto_id=grp_id,
            scenario_note=f"Twin B ({t2_given}) in InfoShare — identical SLK-581 collision test"
        )

    # =====================================================================
    # SCENARIO 3: ADOPTIVE_FOSTER_NAME_CHANGE (35 people)
    # Recorded under Pre-Adoptive / Name at Birth in Load 1, and Adopted Name
    # in Load 2 & InfoShare, linked by NDISNumber or ChildStory history.
    # =====================================================================
    for i in range(35):
        addr = regular_addrs[(75 + i) % len(regular_addrs)]
        is_male = (i % 2 == 1)
        given, _ = MALE_NAMES[(i + 3) % len(MALE_NAMES)] if is_male else FEMALE_NAMES[(i + 3) % len(FEMALE_NAMES)]
        birth_family = SURNAMES[(i + 7) % len(SURNAMES)]
        adopted_family = SURNAMES[(i + 21) % len(SURNAMES)]
        gender = "M" if is_male else "F"
        dob = datetime.date(2013 + (i % 5), ((i % 12) + 1), ((i % 27) + 1))
        ndis = f"43{5000000 + i}"
        ph = f"04{44000000 + i:08d}"

        tp = next_true_person("ADOPTIVE_FOSTER_NAME_CHANGE", given, "Lee", adopted_family, gender, dob, "No", ndis=ndis, addr=addr)

        # Load 1: birth surname
        cs_id, _ = add_cp_record(
            tp, load_batch=1, given=given, middle="Lee", family=birth_family,
            dob=dob, gender=gender, email=None, home_phn=None, mobile_phn=ph, addr=addr,
            extra_names=[
                {"given": given, "family": birth_family, "type": "Pre-Adoptive Name"},
                {"given": given, "family": birth_family, "type": "Name at Birth"},
                {"given": given, "family": adopted_family, "type": "Adopted Name"},
            ],
            scenario_note=f"Adoptive surname change: {birth_family} (Pre-Adoptive) -> {adopted_family} (Adopted Name)"
        )
        # InfoShare: recorded under Adopted Name
        add_fp_client(
            tp, given=given, family=adopted_family, dob=dob, gender=gender, addr=addr,
            phone=ph, email=f"carer.{adopted_family.lower()}{i}@example.com.au",
            cs_id_link=None, ndis=ndis, alias_str=f"{given} {birth_family}",
            scenario_note=f"Adopted child under new surname {adopted_family}, prior surname {birth_family}"
        )

    # =====================================================================
    # SCENARIO 4: ATSI_CULTURAL_SKIN_NAME (40 people)
    # First Nations person recorded under Tribal/Cultural Name in one source
    # and English Legal Name in another, sharing CNI/DOB/Address/Kin.
    # =====================================================================
    for i in range(40):
        addr = regular_addrs[(110 + i) % len(regular_addrs)]
        cult_given, eng_given, nation = ATSI_CULTURAL_NAMES[i % len(ATSI_CULTURAL_NAMES)]
        family = SURNAMES[(i + 30) % len(SURNAMES)]
        gender = "F" if i % 2 == 0 else "M"
        dob = datetime.date(2007 + (i % 6), ((i % 12) + 1), ((i % 27) + 1))
        cni = f"CNI-{810000 + i}"
        ph = f"04{55000000 + i:08d}"

        tp = next_true_person("ATSI_CULTURAL_SKIN_NAME", cult_given, eng_given, family, gender, dob, "Aboriginal", cni=cni, addr=addr)

        cs_id, _ = add_cp_record(
            tp, load_batch=2, given=eng_given.title(), middle=None, family=family,
            dob=dob, gender=gender, email=None, home_phn=None, mobile_phn=ph, addr=addr,
            indig_status="Aboriginal",
            extra_names=[
                {"given": cult_given, "family": family, "type": "Tribal/Cultural Name"},
                {"given": cult_given, "family": family, "type": "Preferred Name"},
            ],
            scenario_note=f"ATSI Cultural Name ({cult_given}) & English Legal Name ({eng_given.title()}) - {nation}"
        )
        add_fp_client(
            tp, given=cult_given, family=family, dob=dob, gender=gender, addr=addr,
            phone=ph, email=None, cs_id_link=None, cni=cni, atsi="Aboriginal",
            alias_str=f"{eng_given.title()} {family}",
            scenario_note=f"InfoShare client recorded under Cultural Name {cult_given} {family}"
        )
        if i < 20:
            add_yj_record(
                tp, given=cult_given, family=family, dob=dob, gender=gender, indig="Aboriginal", addr=addr,
                rel_given="Aunty Mary", rel_family=family, rel_type="ATSI Community Relationship",
                desc=f"First Nations youth ({cult_given} / {eng_given.title()} {family}) with ATSI Community Relationship"
            )

    # =====================================================================
    # SCENARIO 5: ESTIMATED_VS_VERIFIED_DOB (35 people)
    # InfoShare has IsBirthDateAnEstimate = 'Yes' (01-Jan of birth year or shifted days),
    # while ChildStory has DOB_STATUS = 'VERIFIED'.
    # =====================================================================
    for i in range(35):
        addr = regular_addrs[(150 + i) % len(regular_addrs)]
        is_male = (i % 2 == 0)
        given, _ = MALE_NAMES[(i + 9) % len(MALE_NAMES)] if is_male else FEMALE_NAMES[(i + 9) % len(FEMALE_NAMES)]
        family = SURNAMES[(i + 15) % len(SURNAMES)]
        gender = "M" if is_male else "F"
        true_dob = datetime.date(2005 + (i % 8), ((i % 10) + 2), ((i % 20) + 5))
        est_dob = datetime.date(true_dob.year, 1, 1)  # Classic 01-Jan estimated DOB!
        ph = f"04{66000000 + i:08d}"
        email = f"{given.lower()}.{family.lower()}.est{i}@mail.au"

        tp = next_true_person("ESTIMATED_VS_VERIFIED_DOB", given, None, family, gender, true_dob, "No", is_cald=(i % 2 == 0), addr=addr)

        add_cp_record(
            tp, load_batch=2, given=given, middle=None, family=family,
            dob=true_dob, gender=gender, email=email, home_phn=None, mobile_phn=ph, addr=addr,
            dob_status="VERIFIED",
            scenario_note=f"Verified DOB {true_dob.isoformat()} vs Estimated DOB {est_dob.isoformat()}"
        )
        add_fp_client(
            tp, given=given, family=family, dob=est_dob, gender=gender, addr=addr,
            phone=ph, email=email, is_dob_est="Yes",
            lang="Arabic" if i % 2 == 0 else "Vietnamese",
            scenario_note=f"Estimated DOB ({est_dob.isoformat()}) on intake before verification"
        )

    # =====================================================================
    # SCENARIO 6: CRISIS_REFUGE_HUB_HAIRBALL (50 distinct unrelated people)
    # All 50 share the Crisis Refuge GNAF address AND the refuge reception phone
    # (+61298760000) and intake email (intake.parramatta@dcj.nsw.gov.au).
    # Naive Connected Components merges all 50 into a giant hairball!
    # =====================================================================
    refuge_phone = "0298760000"
    refuge_email = "intake.parramatta@dcj.nsw.gov.au"
    for i in range(50):
        addr = hub_refuge_addr if i < 30 else hub_youth_addr
        given, _ = FEMALE_NAMES[i % len(FEMALE_NAMES)] if i < 35 else MALE_NAMES[i % len(MALE_NAMES)]
        family = SURNAMES[(i * 3 + 4) % len(SURNAMES)]
        gender = "F" if i < 35 else "M"
        dob = datetime.date(1988 + (i % 22), ((i % 12) + 1), ((i % 27) + 1))

        tp = next_true_person("CRISIS_REFUGE_HUB_HAIRBALL", given, None, family, gender, dob, "No", is_protected=(i < 15), addr=addr)

        add_cp_record(
            tp, load_batch=2, given=given, middle=None, family=family,
            dob=dob, gender=gender, email=refuge_email, home_phn=refuge_phone, mobile_phn=refuge_phone,
            addr=addr, protected="Y" if i < 15 else "N",
            scenario_note="Resident at Crisis Refuge / Residential Hub sharing promiscuous refuge phone & email"
        )
        if i % 2 == 0:
            add_fp_client(
                tp, given=given, family=family, dob=dob, gender=gender, addr=addr,
                phone=refuge_phone, email=refuge_email, is_homeless="Yes",
                scenario_note="Crisis Refuge intake sharing refuge contact details"
            )

    # =====================================================================
    # SCENARIO 7: DV_PROTECTED_PERSON_RELOCATION (30 people)
    # Protected persons (PROTECTED_INDIVIDUAL = 'Y') who changed surname
    # (Married Name -> Previous Name / Legal Name) and relocated to a new address.
    # =====================================================================
    for i in range(30):
        old_addr = regular_addrs[(185 + i) % len(regular_addrs)]
        new_addr = regular_addrs[(215 + i) % len(regular_addrs)]
        given, _ = FEMALE_NAMES[(i + 7) % len(FEMALE_NAMES)]
        married_family = SURNAMES[(i + 2) % len(SURNAMES)]
        maiden_family = SURNAMES[(i + 19) % len(SURNAMES)]
        dob = datetime.date(1985 + (i % 12), ((i % 12) + 1), ((i % 27) + 1))
        personal_mob = f"04{77000000 + i:08d}"
        cni = f"CNI-{920000 + i}"

        tp = next_true_person("DV_PROTECTED_PERSON_RELOCATION", given, "Marie", maiden_family, "F", dob, "No", is_protected=True, cni=cni, addr=new_addr)

        cs_id, _ = add_cp_record(
            tp, load_batch=1, given=given, middle="Marie", family=married_family,
            dob=dob, gender="F", email=f"{given.lower()}.{i}.safe@proton.me",
            home_phn=None, mobile_phn=personal_mob, addr=old_addr, protected="Y",
            extra_names=[
                {"given": given, "family": married_family, "type": "Married Name"},
                {"given": given, "family": maiden_family, "type": "Previous Name"},
            ],
            scenario_note=f"Protected DV relocation: {given} {married_family} -> {maiden_family}"
        )
        add_fp_client(
            tp, given=given, family=maiden_family, dob=dob, gender="F", addr=new_addr,
            phone=personal_mob, email=f"{given.lower()}.{i}.safe@proton.me",
            cni=cni, alias_str=f"{given} {married_family}",
            scenario_note=f"Relocated protected client reverted to maiden surname {maiden_family}"
        )

    # =====================================================================
    # SCENARIO 8: YJ_RELATIVE_EXTRACTION & ALL 78 KINSHIP RELATIONSHIPS
    # Remaining population (~305 people) forming extended multi-generational
    # families covering every single one of the 78 DCJ relationship types
    # and all 16 name_usage_code values.
    # =====================================================================
    remaining_count = 600 - len(gt_persons)
    family_anchors = []
    for i in range(remaining_count):
        addr = regular_addrs[(i * 5) % len(regular_addrs)]
        is_male = (i % 2 == 0)
        given, nick = MALE_NAMES[i % len(MALE_NAMES)] if is_male else FEMALE_NAMES[i % len(FEMALE_NAMES)]
        family = SURNAMES[(i // 3) % len(SURNAMES)]
        gender = "M" if is_male else "F"
        dob = datetime.date(1975 + (i % 40), ((i % 12) + 1), ((i % 27) + 1))
        atsi = "Torres Strait Islander" if i % 15 == 0 else ("Aboriginal and Torres Strait Islander" if i % 20 == 0 else "No")
        ph = f"04{88000000 + i:08d}"
        email = f"{given.lower()}.{family.lower()}.fam{i}@nswmail.au"

        tp = next_true_person("EXTENDED_KINSHIP_AND_YJ_RELATIVES", given, None, family, gender, dob, atsi, is_cald=(i % 7 == 0), addr=addr)

        # Ensure all 16 NAME_USAGE_CODES are exercised
        usage_code = NAME_USAGE_CODES[i % len(NAME_USAGE_CODES)]
        extra_nms = [{"given": nick, "family": family, "type": usage_code}] if usage_code != "Legal Name" else []

        cs_id, _ = add_cp_record(
            tp, load_batch=2 if i % 3 != 0 else 1, given=given, middle=None, family=family,
            dob=dob, gender=gender, email=email, home_phn=None, mobile_phn=ph, addr=addr,
            indig_status=atsi, extra_names=extra_nms,
            scenario_note="Extended kinship & multi-source baseline population"
        )
        family_anchors.append((tp, cs_id, given, family, dob, gender, addr, ph, email, atsi))

        if i % 2 == 0:
            add_fp_client(
                tp, given=given, family=family, dob=dob, gender=gender, addr=addr,
                phone=ph, email=email, cs_id_link=cs_id if i % 4 == 0 else None, atsi=atsi,
                scenario_note="Multi-source Family Preservation client"
            )

    # Wire all 78 RELATIONSHIP_TYPES across family_anchors in person_relation_file_4_ciw
    for idx, rel_type in enumerate(RELATIONSHIP_TYPES):
        a1 = family_anchors[idx % len(family_anchors)]
        a2 = family_anchors[(idx + 1) % len(family_anchors)]
        if a1[1] != a2[1]:
            add_cp_relation(a1[1], rel_type, a2[1])

    # Also add additional Youth Justice records with Relative linkages to existing family_anchors
    for idx in range(40):
        yo_anchor = family_anchors[(idx * 2) % len(family_anchors)]
        rel_anchor = family_anchors[(idx * 2 + 1) % len(family_anchors)]
        rel_type = RELATIONSHIP_TYPES[idx % len(RELATIONSHIP_TYPES)]
        add_yj_record(
            yo_anchor[0],
            given=yo_anchor[2],
            family=yo_anchor[3],
            dob=yo_anchor[4],
            gender=yo_anchor[5],
            indig=yo_anchor[9],
            addr=yo_anchor[6],
            rel_tp=rel_anchor[0],
            rel_given=rel_anchor[2],
            rel_family=rel_anchor[3],
            rel_type=rel_type,
            desc=f"Youth Justice client with linked relative ({rel_type}: {rel_anchor[2]} {rel_anchor[3]})"
        )

    # Compute ground_truth_pairs (every pair of source records sharing the same true_person_id)
    by_tp = {}
    for r in gt_records:
        by_tp.setdefault(r["true_person_id"], []).append(r)

    gt_pairs = []
    for tp_id, recs in by_tp.items():
        if len(recs) > 1:
            recs_sorted = sorted(recs, key=lambda x: x["source_record_id"])
            for i in range(len(recs_sorted)):
                for j in range(i + 1, len(recs_sorted)):
                    gt_pairs.append({
                        "record_id_a": recs_sorted[i]["source_record_id"],
                        "record_id_b": recs_sorted[j]["source_record_id"],
                        "true_person_id": tp_id,
                        "scenario": recs_sorted[i]["scenario"],
                        "source_a": recs_sorted[i]["source_system"],
                        "source_b": recs_sorted[j]["source_system"],
                    })

    return {
        "gnaf": gnaf_addresses,
        "person_file": person_file_rows,
        "person_file_1_ciw": person_file_1_ciw_rows,
        "person_name_1st_batch": person_name_1st_batch_rows,
        "person_names_file_2_ciw": person_names_file_2_ciw_rows,
        "person_relation_file_4_ciw": person_relation_file_4_ciw_rows,
        "addr_loc_ods": addr_loc_ods_rows,
        "addr_rel_loc_ods": addr_rel_loc_ods_rows,
        "infoshare_family_preservation_groups": infoshare_groups_rows,
        "infoshare_family_preservation_groupclients": infoshare_groupclients_rows,
        "infoshare_family_preservation_clients": infoshare_clients_rows,
        "YJ_YO_CDM_Data": yj_rows,
        "ground_truth_persons": gt_persons,
        "ground_truth_records": gt_records,
        "ground_truth_pairs": gt_pairs,
    }


def load_to_bigquery(datasets):
    # Strip helper key 'electorate' from gnaf before loading
    gnaf_clean = [{k: v for k, v in row.items() if k != "electorate"} for row in datasets["gnaf"]]
    with open("data/gnaf_clean.jsonl", "w") as f:
        for r in gnaf_clean:
            f.write(json.dumps(r) + "\n")

    sdm_tables = [
        ("gnaf_address_materialised_view", "data/gnaf_clean.jsonl", len(gnaf_clean)),
        ("person_file", "data/person_file.jsonl", len(datasets["person_file"])),
        ("person_file_1_ciw", "data/person_file_1_ciw.jsonl", len(datasets["person_file_1_ciw"])),
        ("person_name_1st_batch", "data/person_name_1st_batch.jsonl", len(datasets["person_name_1st_batch"])),
        ("person_names_file_2_ciw", "data/person_names_file_2_ciw.jsonl", len(datasets["person_names_file_2_ciw"])),
        ("person_relation_file_4_ciw", "data/person_relation_file_4_ciw.jsonl", len(datasets["person_relation_file_4_ciw"])),
        ("addr_loc_ods", "data/addr_loc_ods.jsonl", len(datasets["addr_loc_ods"])),
        ("addr_rel_loc_ods", "data/addr_rel_loc_ods.jsonl", len(datasets["addr_rel_loc_ods"])),
        ("infoshare_family_preservation_groups", "data/infoshare_family_preservation_groups.jsonl", len(datasets["infoshare_family_preservation_groups"])),
        ("infoshare_family_preservation_groupclients", "data/infoshare_family_preservation_groupclients.jsonl", len(datasets["infoshare_family_preservation_groupclients"])),
        ("infoshare_family_preservation_clients", "data/infoshare_family_preservation_clients.jsonl", len(datasets["infoshare_family_preservation_clients"])),
        ("YJ_YO_CDM_Data", "data/YJ_YO_CDM_Data.jsonl", len(datasets["YJ_YO_CDM_Data"])),
    ]

    for table_name, file_path, count in sdm_tables:
        table_ref = f"{PROJECT_ID}:{SDM_DS}.{table_name}"
        subprocess.run(
            [
                "bq", "load",
                f"--project_id={PROJECT_ID}",
                f"--location={LOCATION}",
                "--replace",
                "--source_format=NEWLINE_DELIMITED_JSON",
                table_ref,
                file_path,
            ],
            check=True,
        )
        print(f"[SDM] Loaded {count:5d} rows -> {table_ref}")

    truth_tables = [
        ("ground_truth_persons", "data/ground_truth_persons.jsonl", len(datasets["ground_truth_persons"])),
        ("ground_truth_records", "data/ground_truth_records.jsonl", len(datasets["ground_truth_records"])),
        ("ground_truth_pairs", "data/ground_truth_pairs.jsonl", len(datasets["ground_truth_pairs"])),
    ]
    for table_name, file_path, count in truth_tables:
        table_ref = f"{PROJECT_ID}:{TRUTH_DS}.{table_name}"
        subprocess.run(
            [
                "bq", "load",
                f"--project_id={PROJECT_ID}",
                f"--location={LOCATION}",
                "--replace",
                "--autodetect",
                "--source_format=NEWLINE_DELIMITED_JSON",
                table_ref,
                file_path,
            ],
            check=True,
        )
        print(f"[TRUTH] Loaded {count:5d} rows -> {table_ref}")


if __name__ == "__main__":
    print("Generating synthetic NSW DCJ SDM & Ground Truth corpus...")
    data = generate_all()
    os.makedirs("data", exist_ok=True)
    for k, rows in data.items():
        with open(f"data/{k}.jsonl", "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
    print(
        f"Generated {len(data['ground_truth_persons'])} true people, "
        f"{len(data['ground_truth_records'])} SDM records, and "
        f"{len(data['ground_truth_pairs'])} true cross-record pairs."
    )
    load_to_bigquery(data)
    print("Done.")
