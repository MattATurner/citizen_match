#!/usr/bin/env python3
"""NSW DCJ Frontline Person & Property Search + ISO GQL Graph API Server.

Executes live BigQuery Hybrid Search (`dcj_match.fn_frontline_person_search` ->
`fn_person_match` with AI.EMBED + VECTOR_SEARCH + RRF), Property Search
(`dcj_match.fn_frontline_property_search`), ISO GQL Property Graph traversals
(`GRAPH_TABLE(dcj_tdm.dcj_person_graph)`), Field Survivorship, and Immutable
Gemini Platform Adjudication Audit Ledger queries on `all-things-cdp`.
"""

from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import date, datetime
from decimal import Decimal
import os
import re
import threading
import time
from typing import Any, Dict, List, Optional, Tuple

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import bigquery

DATA_PROJECT = os.environ.get("BQ_DATA_PROJECT", "all-things-cdp")
JOB_PROJECT = os.environ.get("BQ_JOB_PROJECT", "all-things-cdp")
LOCATION = os.environ.get("BQ_LOCATION", "us-central1")

EXECUTOR = ThreadPoolExecutor(max_workers=10)
_bq_local = threading.local()

# In-memory typeahead index warmed asynchronously at startup
AUTOCOMPLETE_CACHE: Dict[str, Any] = {
    "ready": False,
    "persons": [],
    "properties": [],
}

STREET_SUFFIXES = {
    "ST", "STREET", "RD", "ROAD", "AV", "AVE", "AVENUE", "PD", "PDE", "PARADE",
    "HWY", "HIGHWAY", "DR", "DRIVE", "LN", "LANE", "CT", "COURT", "PL", "PLACE",
    "CR", "CRES", "CRESCENT", "WAY", "BLVD", "CL", "CLOSE", "TCE", "TERRACE",
}

KNOWN_SUBURBS = {
    "PARRAMATTA", "BLACKTOWN", "PENRITH", "MOUNT DRUITT", "CAMPBELLTOWN",
    "LIVERPOOL", "BANKSTOWN", "NEWCASTLE", "DUBBO", "KEMPSEY", "WAGGA WAGGA",
    "TAMWORTH", "NOWRA", "ORANGE", "BATHURST", "BROKEN HILL", "LISMORE",
    "WOLLONGONG", "GOSFORD", "WYONG", "MAITLAND", "COFFS HARBOUR", "MOREE",
    "BOURKE", "TAREE", "GRAFTON", "ALBURY", "ARMIDALE",
}

PROPERTY_KEYWORDS = {
    "UNIT", "FLAT", "LOT", "REFUGE", "HUB", "RESIDENTIAL", "CARE", "SAFE",
    "GNAF", "BUILDING", "CENTRE", "CENTER", "HOUSE",
}


def get_bq() -> bigquery.Client:
  client = getattr(_bq_local, "client", None)
  if client is None:
    client = bigquery.Client(project=JOB_PROJECT, location=LOCATION)
    _bq_local.client = client
  return client


def clean_val(v: Any) -> Any:
  if v is None:
    return None
  if isinstance(v, (datetime, date)):
    return v.isoformat()
  if isinstance(v, Decimal):
    return float(v)
  if isinstance(v, list):
    return [clean_val(x) for x in v]
  if isinstance(v, dict):
    return {k: clean_val(val) for k, val in v.items()}
  return v


def run_bq(
    sql: str, params: Optional[List[Any]] = None
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
  t0 = time.perf_counter()
  client = get_bq()
  job_config = bigquery.QueryJobConfig(use_query_cache=True)
  if params:
    job_config.query_parameters = params
  job = client.query(sql, job_config=job_config, location=LOCATION)
  rows = [
      {k: clean_val(row[k]) for k in row.keys()} for row in job.result()
  ]
  ms = round((time.perf_counter() - t0) * 1000.0, 1)
  meta = {
      "job_id": job.job_id,
      "elapsed_ms": ms,
      "row_count": len(rows),
      "sql": sql.strip(),
  }
  return rows, meta


def norm_spaces(s: Optional[str]) -> str:
  if not s:
    return ""
  return re.sub(r"\s+", " ", s).strip()


def warm_autocomplete() -> None:
  try:
    p_sql = f"""
      SELECT
        per.person_id,
        ANY_VALUE(REGEXP_REPLACE(pnm.full_name, r'\\s+', ' ')) AS primary_name,
        STRING_AGG(DISTINCT REGEXP_REPLACE(anm.full_name, r'\\s+', ' '), ' · ') AS all_names,
        STRING_AGG(DISTINCT CONCAT(anm.full_name, ' (', anm.name_usage_code, ')'), '; ') AS names_typed,
        ANY_VALUE(CAST(per.date_of_birth AS STRING)) AS dob,
        ANY_VALUE(per.gender) AS gender,
        ANY_VALUE(per.indigenous_status) AS indigenous_status,
        ANY_VALUE(per.is_protected_person) AS is_protected_person,
        ANY_VALUE(al.full_address) AS primary_address,
        ANY_VALUE(al.suburb) AS suburb,
        ANY_VALUE(al.postcode) AS postcode,
        STRING_AGG(DISTINCT lnk.source_program, ', ' ORDER BY lnk.source_program) AS programs,
        STRING_AGG(DISTINCT CONCAT(inst.instrument_type_code, ':', inst.designation_number), ' ') AS instruments
      FROM `{DATA_PROJECT}.dcj_tdm.person` AS per
      LEFT JOIN `{DATA_PROJECT}.dcj_tdm.person_name` AS pnm
        ON pnm.person_id = per.person_id AND pnm.primary_name_flag
      LEFT JOIN `{DATA_PROJECT}.dcj_tdm.person_name` AS anm
        ON anm.person_id = per.person_id
      LEFT JOIN `{DATA_PROJECT}.dcj_tdm.address_relation` AS ar
        ON ar.person_id = per.person_id AND ar.primary_address_flag
      LEFT JOIN `{DATA_PROJECT}.dcj_tdm.address_location` AS al
        ON al.id = ar.address_location_id
      LEFT JOIN `{DATA_PROJECT}.dcj_tdm.person_source_linkage` AS lnk
        ON lnk.person_id = per.person_id
      LEFT JOIN `{DATA_PROJECT}.dcj_tdm.person_identity_instrument` AS inst
        ON inst.person_id = per.person_id
      GROUP BY per.person_id
    """
    a_sql = f"""
      SELECT
        al.id AS address_id,
        al.building_name,
        al.full_address,
        al.suburb,
        al.postcode,
        STARTS_WITH(al.id, 'GNAF-NSW-HUB') AS is_crisis_hub,
        COUNT(DISTINCT ar.person_id) AS residents
      FROM `{DATA_PROJECT}.dcj_tdm.address_location` AS al
      LEFT JOIN `{DATA_PROJECT}.dcj_tdm.address_relation` AS ar
        ON ar.address_location_id = al.id
      GROUP BY 1, 2, 3, 4, 5, 6
      HAVING residents > 0
      ORDER BY residents DESC
    """
    persons, _ = run_bq(p_sql)
    props, _ = run_bq(a_sql)
    for p in persons:
      p["haystack"] = " ".join(
          str(p.get(k) or "")
          for k in (
              "person_id",
              "primary_name",
              "all_names",
              "dob",
              "primary_address",
              "suburb",
              "postcode",
              "instruments",
          )
      ).lower()
    for pr in props:
      pr["haystack"] = " ".join(
          str(pr.get(k) or "")
          for k in (
              "address_id",
              "building_name",
              "full_address",
              "suburb",
              "postcode",
          )
      ).lower()
    AUTOCOMPLETE_CACHE["persons"] = persons
    AUTOCOMPLETE_CACHE["properties"] = props
    AUTOCOMPLETE_CACHE["ready"] = True
  except Exception as exc:
    print(f"Autocomplete warmup warning: {exc}")


@asynccontextmanager
async def lifespan(_: FastAPI):
  EXECUTOR.submit(warm_autocomplete)
  yield


app = FastAPI(
    title="NSW DCJ Frontline Person & Property Search API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


def parse_omnibox_query(
    q: str,
    given_name: Optional[str] = None,
    family_name: Optional[str] = None,
    dob: Optional[str] = None,
    gender: Optional[str] = None,
    address: Optional[str] = None,
    suburb: Optional[str] = None,
    postcode: Optional[str] = None,
    phone: Optional[str] = None,
    identifier: Optional[str] = None,
) -> Dict[str, Any]:
  """Parses a Google-style free-text search string + optional structured overrides."""
  raw = norm_spaces(q)
  out = {
      "raw_query": raw,
      "given_name": norm_spaces(given_name) or None,
      "family_name": norm_spaces(family_name) or None,
      "dob": norm_spaces(dob) or None,
      "gender": norm_spaces(gender) or None,
      "address": norm_spaces(address) or None,
      "suburb": norm_spaces(suburb) or None,
      "postcode": norm_spaces(postcode) or None,
      "phone": norm_spaces(phone) or None,
      "identifier": norm_spaces(identifier) or None,
      "looks_like_property": False,
  }
  if not raw:
    raw = " ".join(
        x
        for x in [
            out["given_name"],
            out["family_name"],
            out["dob"],
            out["address"],
            out["suburb"],
            out["postcode"],
            out["phone"],
            out["identifier"],
        ]
        if x
    )
    out["raw_query"] = raw
    return out

  upper = raw.upper()
  # Check GNAF / property hints
  tokens_upper = re.split(r"[\s,]+", upper)
  if (
      upper.startswith("GNAF-")
      or any(t in STREET_SUFFIXES for t in tokens_upper)
      or any(t in PROPERTY_KEYWORDS for t in tokens_upper)
      or (tokens_upper and re.match(r"^\d+[A-Z]?$", tokens_upper[0]) and len(tokens_upper) >= 2)
  ):
    out["looks_like_property"] = True
    if not out["address"] and not upper.startswith("GNAF-"):
      out["address"] = raw

  remaining = raw

  # Extract ISO date YYYY-MM-DD or DD/MM/YYYY
  m_iso = re.search(r"\b((?:19|20)\d{2}-\d{2}-\d{2})\b", remaining)
  if m_iso and not out["dob"]:
    out["dob"] = m_iso.group(1)
    remaining = remaining.replace(m_iso.group(0), " ")
  else:
    m_au = re.search(r"\b(\d{1,2})/(\d{1,2})/((?:19|20)\d{2})\b", remaining)
    if m_au and not out["dob"]:
      d_i, m_i, y_i = int(m_au.group(1)), int(m_au.group(2)), int(m_au.group(3))
      out["dob"] = f"{y_i:04d}-{m_i:02d}-{d_i:02d}"
      remaining = remaining.replace(m_au.group(0), " ")

  # Extract Australian phone (04xx..., +61...)
  m_ph = re.search(r"(\+61\s?\d[\d\s]{7,10}|\b0[2478][\d\s]{8,10}\b)", remaining)
  if m_ph and not out["phone"]:
    out["phone"] = re.sub(r"\s+", "", m_ph.group(1))
    remaining = remaining.replace(m_ph.group(0), " ")

  # Extract Government / System IDs (CS-..., FP-CL-..., YJ-..., PER-..., CNI..., NDIS..., SLK...)
  m_id = re.search(
      r"\b((?:PER|CS|FP-CL|FP-REC|CP-REC|YJ|CNI|NDIS|GNAF-NSW)[A-Z0-9\-]+|[A-Z]{5}\d{8}[129])\b",
      remaining,
      re.IGNORECASE,
  )
  if m_id and not out["identifier"]:
    id_val = m_id.group(1).upper()
    if not id_val.startswith("GNAF-"):
      out["identifier"] = id_val
      remaining = re.sub(re.escape(m_id.group(0)), " ", remaining, flags=re.IGNORECASE)

  # Extract 4-digit NSW Postcode (2000-2999) if not a birth year context
  m_pc = re.search(r"\b(2\d{3})\b", remaining)
  if m_pc and not out["postcode"]:
    pc = m_pc.group(1)
    # Check if there's another name/address token; if alone like "2009" it could be birth year or postcode
    other_words = norm_spaces(remaining.replace(pc, " "))
    if other_words and (out["looks_like_property"] or int(pc) > 2026):
      out["postcode"] = pc
      remaining = remaining.replace(pc, " ")
    elif other_words and not out["dob"] and 1940 <= int(pc) <= 2025:
      # Could be birth year like "Lachie Smith 2009" -> leave out of postcode, set 01-01 estimate if helpful? Better keep clean!
      remaining = remaining.replace(pc, " ")

  # Extract known multi-word or single-word NSW suburbs
  rem_up = norm_spaces(remaining).upper()
  rem_up = re.sub(r"\bNSW\b", " ", rem_up)
  for sub in sorted(KNOWN_SUBURBS, key=len, reverse=True):
    if re.search(rf"\b{re.escape(sub)}\b", rem_up):
      if not out["suburb"]:
        out["suburb"] = sub
      if not out["looks_like_property"]:
        rem_up = re.sub(rf"\b{re.escape(sub)}\b", " ", rem_up)
      break

  if not out["looks_like_property"] and not out["given_name"] and not out["family_name"]:
    clean_words = [
        w
        for w in re.split(r"[\s,]+", norm_spaces(rem_up))
        if w and w not in {"MALE", "FEMALE", "NSW"}
    ]
    if len(clean_words) == 1:
      # Single token could be either forename (e.g. Allira, Lachie) or surname (e.g. Peachey, Campbell)
      out["given_name"] = clean_words[0].title()
      out["family_name"] = clean_words[0].title()
    elif len(clean_words) >= 2:
      out["given_name"] = clean_words[0].title()
      out["family_name"] = clean_words[-1].title()

  return out


@app.get("/api/health")
def api_health() -> Dict[str, Any]:
  return {
      "status": "ok",
      "data_project": DATA_PROJECT,
      "location": LOCATION,
      "autocomplete_ready": AUTOCOMPLETE_CACHE["ready"],
      "cached_persons": len(AUTOCOMPLETE_CACHE["persons"]),
      "cached_properties": len(AUTOCOMPLETE_CACHE["properties"]),
  }


@app.get("/api/autocomplete")
def api_autocomplete(q: str = Query("", min_length=1)) -> Dict[str, Any]:
  needle = norm_spaces(q).lower()
  if not needle:
    return {"persons": [], "properties": []}
  if not AUTOCOMPLETE_CACHE["ready"]:
    warm_autocomplete()

  terms = [t for t in needle.split(" ") if t]
  person_hits = []
  for p in AUTOCOMPLETE_CACHE["persons"]:
    hay = p["haystack"]
    if all(t in hay for t in terms):
      score = 0
      pname = (p.get("primary_name") or "").lower()
      if pname.startswith(needle):
        score += 100
      elif needle in pname:
        score += 65
      elif needle in (p.get("all_names") or "").lower():
        score += 50
      if needle.upper() == p.get("person_id"):
        score += 200
      person_hits.append((score, p))

  person_hits.sort(key=lambda x: (-x[0], x[1].get("primary_name") or ""))
  top_persons = [
      {
          "person_id": p["person_id"],
          "primary_name": p["primary_name"],
          "names_typed": p["names_typed"],
          "dob": p["dob"],
          "suburb": p["suburb"],
          "postcode": p["postcode"],
          "programs": p["programs"],
          "is_protected_person": p["is_protected_person"],
      }
      for _, p in person_hits[:6]
  ]

  prop_hits = []
  for pr in AUTOCOMPLETE_CACHE["properties"]:
    hay = pr["haystack"]
    if all(t in hay for t in terms):
      score = (100 if pr.get("is_crisis_hub") else 20) + int(pr.get("residents") or 0)
      if (pr.get("full_address") or "").lower().startswith(needle):
        score += 80
      prop_hits.append((score, pr))

  prop_hits.sort(key=lambda x: -x[0])
  top_props = [
      {
          "address_id": pr["address_id"],
          "building_name": pr["building_name"],
          "full_address": pr["full_address"],
          "suburb": pr["suburb"],
          "postcode": pr["postcode"],
          "is_crisis_hub": pr["is_crisis_hub"],
          "residents": pr["residents"],
      }
      for _, pr in prop_hits[:4]
  ]
  return {"persons": top_persons, "properties": top_props}


@app.get("/api/search")
def api_search(
    q: str = Query(""),
    mode: str = Query("all"),  # all | person | property
    given_name: Optional[str] = Query(None),
    family_name: Optional[str] = Query(None),
    dob: Optional[str] = Query(None),
    gender: Optional[str] = Query(None),
    address: Optional[str] = Query(None),
    suburb: Optional[str] = Query(None),
    postcode: Optional[str] = Query(None),
    phone: Optional[str] = Query(None),
    identifier: Optional[str] = Query(None),
) -> Dict[str, Any]:
  t0 = time.perf_counter()
  parsed = parse_omnibox_query(
      q=q,
      given_name=given_name,
      family_name=family_name,
      dob=dob,
      gender=gender,
      address=address,
      suburb=suburb,
      postcode=postcode,
      phone=phone,
      identifier=identifier,
  )
  if not parsed["raw_query"]:
    raise HTTPException(status_code=400, detail="Please enter a search query or structured filter.")

  person_sql = f"""
    SELECT *
    FROM `{DATA_PROJECT}.dcj_match.fn_frontline_person_search`(
      @raw_query,
      @given_name,
      @family_name,
      @dob,
      @gender,
      @address,
      @suburb,
      @postcode,
      @phone,
      @identifier
    )
  """
  dob_date: Optional[date] = None
  if parsed["dob"]:
    try:
      dob_date = date.fromisoformat(parsed["dob"])
    except ValueError:
      dob_date = None

  person_params = [
      bigquery.ScalarQueryParameter("raw_query", "STRING", parsed["raw_query"]),
      bigquery.ScalarQueryParameter("given_name", "STRING", parsed["given_name"]),
      bigquery.ScalarQueryParameter("family_name", "STRING", parsed["family_name"]),
      bigquery.ScalarQueryParameter("dob", "DATE", dob_date),
      bigquery.ScalarQueryParameter("gender", "STRING", parsed["gender"]),
      bigquery.ScalarQueryParameter("address", "STRING", parsed["address"]),
      bigquery.ScalarQueryParameter("suburb", "STRING", parsed["suburb"]),
      bigquery.ScalarQueryParameter("postcode", "STRING", parsed["postcode"]),
      bigquery.ScalarQueryParameter("phone", "STRING", parsed["phone"]),
      bigquery.ScalarQueryParameter("identifier", "STRING", parsed["identifier"]),
  ]

  prop_query_str = parsed["raw_query"]
  prop_sql = f"""
    SELECT *
    FROM `{DATA_PROJECT}.dcj_match.fn_frontline_property_search`(@prop_query)
  """
  prop_params = [
      bigquery.ScalarQueryParameter("prop_query", "STRING", prop_query_str),
  ]

  futures = {}
  if mode in ("all", "person"):
    futures["person"] = EXECUTOR.submit(run_bq, person_sql, person_params)
  if mode in ("all", "property"):
    futures["property"] = EXECUTOR.submit(run_bq, prop_sql, prop_params)

  persons, person_meta = futures["person"].result() if "person" in futures else ([], None)
  properties, prop_meta = futures["property"].result() if "property" in futures else ([], None)

  # Clean double spaces in full names
  for p in persons:
    if p.get("primary_full_name"):
      p["primary_full_name"] = norm_spaces(p["primary_full_name"])

  primary_focus = "person"
  if mode == "property":
    primary_focus = "property"
  elif mode == "all" and parsed["looks_like_property"] and properties:
    primary_focus = "property"
  elif mode == "all" and not persons and properties:
    primary_focus = "property"

  total_ms = round((time.perf_counter() - t0) * 1000.0, 1)
  return {
      "query": q,
      "mode": mode,
      "primary_focus": primary_focus,
      "parsed": parsed,
      "persons": persons,
      "properties": properties,
      "telemetry": {
          "total_ms": total_ms,
          "person_query": person_meta,
          "property_query": prop_meta,
      },
  }


@app.get("/api/person/{person_id}")
def api_person_dossier(person_id: str) -> Dict[str, Any]:
  """Fetches 100% of mastered TDM, SDM lineage, Survivorship, Adjudication Audit & ISO GQL Property Graph."""
  t0 = time.perf_counter()
  pid = person_id.strip().upper()
  p_param = [bigquery.ScalarQueryParameter("pid", "STRING", pid)]

  # 1. Core Golden Person + Names + Instruments + Protection Events via TDM & Graph
  q_core = f"""
    SELECT
      per.person_id,
      pty.party_id_int64,
      REGEXP_REPLACE(pty.party_display_name, r'\\s+', ' ') AS party_display_name,
      pty.created_timestamp,
      per.gender,
      per.date_of_birth,
      per.dob_certainty_code,
      per.date_of_death,
      per.dod_certainty_code,
      per.is_protected_person,
      per.is_cald,
      per.indigenous_status,
      per.source_program
    FROM `{DATA_PROJECT}.dcj_tdm.person` AS per
    JOIN `{DATA_PROJECT}.dcj_tdm.party` AS pty
      ON pty.party_id = per.person_id
    WHERE per.person_id = @pid
  """

  # 2. ISO GQL Property Graph: Source Lineage -> Golden Person -> Multi-Name History
  q_graph_names_sources = f"""
    SELECT *
    FROM GRAPH_TABLE(
      `{DATA_PROJECT}.dcj_tdm.dcj_person_graph`
      MATCH (p:Person)-[hn:HAS_NAME]->(pn:PersonName)
      WHERE p.person_id = @pid
      COLUMNS (
        pn.person_name_id,
        pn.name_usage_code,
        pn.primary_name_flag,
        pn.given_name,
        pn.middle_name,
        pn.family_name,
        REGEXP_REPLACE(pn.full_name, r'\\s+', ' ') AS full_name,
        pn.start_date,
        pn.end_date,
        pn.source_program
      )
    )
    ORDER BY primary_name_flag DESC, end_date IS NULL DESC, start_date DESC
  """

  # 3. ISO GQL Property Graph: Identity Instruments & Issuing Authorities + Protection Events
  q_graph_instruments = f"""
    SELECT *
    FROM GRAPH_TABLE(
      `{DATA_PROJECT}.dcj_tdm.dcj_person_graph`
      MATCH (p:Person)-[hi:HOLDS_INSTRUMENT]->(inst:IdentityInstrument)-[ib:ISSUED_BY]->(org:Party)
      WHERE p.person_id = @pid
      COLUMNS (
        inst.instrument_id,
        inst.instrument_type_code,
        inst.designation_number,
        inst.status_code,
        inst.is_primary,
        inst.source_program,
        ib.issue_date,
        org.party_id AS issuer_party_id,
        org.party_display_name AS issuer_name
      )
    )
    ORDER BY is_primary DESC, instrument_type_code ASC
  """

  q_graph_protections = f"""
    SELECT *
    FROM GRAPH_TABLE(
      `{DATA_PROJECT}.dcj_tdm.dcj_person_graph`
      MATCH (p:Person)-[hp:HAS_PROTECTION_EVENT]->(pe:ProtectionEvent)-[inb:INITIATED_BY]->(org:Party)
      WHERE p.person_id = @pid
      COLUMNS (
        pe.protection_event_id,
        pe.protect_start_date,
        pe.protect_end_date,
        pe.reason,
        pe.source_program,
        org.party_id AS initiator_party_id,
        org.party_display_name AS initiator_name
      )
    )
  """

  # 4. ISO GQL Property Graph: GNAF Addresses, Hub Status & Co-Residents
  q_graph_addresses = f"""
    WITH my_addrs AS (
      SELECT *
      FROM GRAPH_TABLE(
        `{DATA_PROJECT}.dcj_tdm.dcj_person_graph`
        MATCH (p:Person)-[la:LIVES_AT]->(al:AddressLocation)
        WHERE p.person_id = @pid
        COLUMNS (
          la.address_relation_id,
          la.primary_address_flag,
          la.address_purpose,
          la.address_relation_start_date AS start_date,
          la.address_relation_end_date AS end_date,
          la.source_program,
          al.id AS address_id,
          al.building_name,
          al.full_address,
          al.suburb,
          al.postcode,
          al.state,
          al.latitude,
          al.longitude,
          al.record_type
        )
      )
    ),
    co_res AS (
      SELECT
        ar.address_location_id AS address_id,
        COUNT(DISTINCT ar.person_id) AS total_residents_at_addr,
        ARRAY_AGG(
          IF(ar.person_id != @pid,
             STRUCT(
               ar.person_id,
               COALESCE(REGEXP_REPLACE(nm.full_name, r'\\s+', ' '), ar.person_id) AS full_name,
               per.date_of_birth AS dob,
               per.is_protected_person,
               ar.source_program
             ),
             NULL)
          IGNORE NULLS
          ORDER BY ar.primary_address_flag DESC, ar.person_id
          LIMIT 8
        ) AS co_residents
      FROM `{DATA_PROJECT}.dcj_tdm.address_relation` AS ar
      JOIN `{DATA_PROJECT}.dcj_tdm.person` AS per ON per.person_id = ar.person_id
      LEFT JOIN (
        SELECT person_id, ANY_VALUE(full_name) AS full_name
        FROM `{DATA_PROJECT}.dcj_tdm.person_name` WHERE primary_name_flag GROUP BY person_id
      ) AS nm ON nm.person_id = ar.person_id
      WHERE ar.address_location_id IN (SELECT address_id FROM my_addrs)
      GROUP BY ar.address_location_id
    )
    SELECT
      ma.*,
      IFNULL(idn.degree, cr.total_residents_at_addr) AS bipartite_degree,
      IFNULL(idn.idf_weight, 0.0) AS idf_weight,
      (IFNULL(idn.is_promiscuous, FALSE) OR STARTS_WITH(ma.address_id, 'GNAF-NSW-HUB')) AS is_crisis_hub,
      IFNULL(cr.total_residents_at_addr, 1) AS total_residents_at_addr,
      cr.co_residents
    FROM my_addrs AS ma
    LEFT JOIN co_res AS cr USING (address_id)
    LEFT JOIN `{DATA_PROJECT}.dcj_match.identifier` AS idn
      ON idn.identifier_id = CONCAT('GNAF:', ma.address_id)
    ORDER BY ma.primary_address_flag DESC, ma.start_date DESC
  """

  # 5. ISO GQL Property Graph: 1-Hop & 2-Hop Kinship, Household Groups & Service Providers
  q_graph_kinship = f"""
    WITH hop1 AS (
      SELECT *
      FROM GRAPH_TABLE(
        `{DATA_PROJECT}.dcj_tdm.dcj_person_graph`
        MATCH (p1:Party)-[rel:PARTY_RELATIONSHIP]->(p2:Party)
        WHERE p1.party_id = @pid OR p2.party_id = @pid
        COLUMNS (
          rel.relationship_id,
          p1.party_id AS from_id,
          REGEXP_REPLACE(p1.party_display_name, r'\\s+', ' ') AS from_name,
          p1.party_type_code AS from_type,
          p2.party_id AS to_id,
          REGEXP_REPLACE(p2.party_display_name, r'\\s+', ' ') AS to_name,
          p2.party_type_code AS to_type,
          rel.relationship_type,
          rel.canonical_relationship_type,
          rel.relationship_category,
          rel.start_date,
          rel.end_date,
          rel.comment,
          rel.source_program
        )
      )
    ),
    hop1_parties AS (
      SELECT DISTINCT IF(from_id = @pid, to_id, from_id) AS mid_id
      FROM hop1
      WHERE IF(from_id = @pid, to_id, from_id) NOT LIKE 'ORG-%'
    ),
    hop2 AS (
      SELECT *
      FROM GRAPH_TABLE(
        `{DATA_PROJECT}.dcj_tdm.dcj_person_graph`
        MATCH (p1:Party)-[rel:PARTY_RELATIONSHIP]->(p2:Party)
        COLUMNS (
          rel.relationship_id,
          p1.party_id AS from_id,
          REGEXP_REPLACE(p1.party_display_name, r'\\s+', ' ') AS from_name,
          p1.party_type_code AS from_type,
          p2.party_id AS to_id,
          REGEXP_REPLACE(p2.party_display_name, r'\\s+', ' ') AS to_name,
          p2.party_type_code AS to_type,
          rel.relationship_type,
          rel.canonical_relationship_type,
          rel.relationship_category,
          rel.start_date,
          rel.end_date,
          rel.comment,
          rel.source_program
        )
      )
      WHERE (from_id IN (SELECT mid_id FROM hop1_parties) OR to_id IN (SELECT mid_id FROM hop1_parties))
        AND from_id != @pid AND to_id != @pid
      LIMIT 20
    ),
    combined AS (
      SELECT 1 AS hop, * FROM hop1
      UNION ALL
      SELECT 2 AS hop, * FROM hop2
    )
    SELECT
      c.*,
      per_f.date_of_birth AS from_dob,
      per_f.is_protected_person AS from_protected,
      per_t.date_of_birth AS to_dob,
      per_t.is_protected_person AS to_protected
    FROM combined AS c
    LEFT JOIN `{DATA_PROJECT}.dcj_tdm.person` AS per_f ON per_f.person_id = c.from_id
    LEFT JOIN `{DATA_PROJECT}.dcj_tdm.person` AS per_t ON per_t.person_id = c.to_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY relationship_id ORDER BY hop ASC) = 1
    ORDER BY hop ASC, relationship_category ASC
  """

  # 6. Raw SDM Source Lineage + Bipartite Identifiers + Field Survivorship
  q_sources_identifiers = f"""
    WITH id_agg AS (
      SELECT
        hi.record_id,
        ARRAY_AGG(
          STRUCT(
            hi.identifier_id,
            hi.identifier_type,
            hi.is_anchor,
            idn.degree,
            idn.idf_weight,
            idn.is_promiscuous
          )
          ORDER BY idn.idf_weight DESC
        ) AS identifiers
      FROM `{DATA_PROJECT}.dcj_match.has_identifier` AS hi
      JOIN `{DATA_PROJECT}.dcj_match.identifier` AS idn USING (identifier_id)
      WHERE hi.record_id IN (
        SELECT source_record_id FROM `{DATA_PROJECT}.dcj_tdm.person_source_linkage` WHERE person_id = @pid
      )
      GROUP BY hi.record_id
    )
    SELECT
      lnk.linkage_id,
      lnk.source_record_id,
      lnk.source_app_id,
      lnk.source_person_id,
      lnk.source_program,
      lnk.last_updated_ts,
      s.source_trust,
      s.given_name_raw,
      s.middle_name_raw,
      s.family_name_raw,
      s.alias_names_concat,
      s.gender_norm,
      s.dob,
      s.dob_status,
      s.indigenous_status,
      s.is_cald,
      s.is_protected,
      s.email_norm,
      s.phone_e164,
      s.gnaf_address_id,
      s.address_norm,
      s.suburb_norm,
      s.postcode_norm,
      s.childstory_id_ref,
      s.cni_number,
      s.ndis_number,
      s.slk_code,
      s.kin_context,
      s.match_key,
      s.blocking_keys,
      s.record_ts,
      ia.identifiers
    FROM `{DATA_PROJECT}.dcj_tdm.person_source_linkage` AS lnk
    JOIN `{DATA_PROJECT}.dcj_match.stg_source_profiles` AS s
      ON s.record_id = lnk.source_record_id
    LEFT JOIN id_agg AS ia
      ON ia.record_id = lnk.source_record_id
    WHERE lnk.person_id = @pid
    ORDER BY s.source_trust DESC, lnk.source_record_id ASC
  """

  q_survivorship = f"""
    WITH fa_agg AS (
      SELECT
        fa.person_id,
        fa.field_name,
        ARRAY_AGG(
          STRUCT(
            fa.record_id,
            fa.source_system,
            fa.source_program,
            fa.source_trust,
            fa.field_value,
            fa.record_ts
          )
          ORDER BY fa.source_trust DESC, fa.record_ts DESC
        ) AS assertions
      FROM `{DATA_PROJECT}.dcj_match.field_assertions` AS fa
      WHERE fa.person_id = @pid
      GROUP BY fa.person_id, fa.field_name
    )
    SELECT
      fs.field_name,
      fs.surviving_value,
      fs.won_from_record_id,
      fs.won_from_program,
      fs.source_trust,
      fs.corroborating_programs,
      fs.was_contested,
      fa_agg.assertions
    FROM `{DATA_PROJECT}.dcj_match.field_survivorship` AS fs
    LEFT JOIN fa_agg
      ON fa_agg.person_id = fs.person_id AND fa_agg.field_name = fs.field_name
    WHERE fs.person_id = @pid
    ORDER BY fs.was_contested DESC, fs.field_name ASC
  """

  # 7. Complete Adjudication & Pair Resolution Audit History (Accepted LINKs + Vetoed UNLINKs + Full Ledger History)
  q_adjudications = f"""
    WITH my_recs AS (
      SELECT record_id FROM `{DATA_PROJECT}.dcj_match.person_assignment` WHERE person_id = @pid
    ),
    ledger_agg AS (
      SELECT
        j.record_id_a,
        j.record_id_b,
        ARRAY_AGG(
          STRUCT(
            j.verdict,
            j.confidence,
            j.rationale,
            j.decisive_evidence,
            j.contradiction,
            j.scenario_classified,
            j.injection_detected,
            j.model,
            j.prompt_version,
            j.adjudicated_at,
            j.input_tokens,
            j.output_tokens
          )
          ORDER BY j.adjudicated_at DESC
        ) AS ledger_history
      FROM `{DATA_PROJECT}.dcj_match.person_match_adjudications` AS j
      WHERE j.record_id_a IN (SELECT record_id FROM my_recs)
         OR j.record_id_b IN (SELECT record_id FROM my_recs)
      GROUP BY j.record_id_a, j.record_id_b
    ),
    rel_pairs AS (
      SELECT
        re.record_id_a,
        re.record_id_b,
        re.decision,
        re.decided_by,
        re.confidence,
        re.rationale,
        re.decisive_evidence,
        re.contradiction,
        re.retrieved_by,
        re.combined_score,
        re.rrf_score,
        re.semantic_similarity,
        re.suppressed_by_contradiction,
        t.tier,
        t.non_hub_idf_sum,
        t.twin_or_sibling_trap,
        t.hub_only,
        t.documented_kin_relationship,
        t.shared_identifiers,
        t.a_program, t.a_name, t.a_aliases, t.a_dob, t.a_dob_status, t.a_gender, t.a_atsi,
        t.a_address, t.a_suburb, t.a_postcode, t.a_phone, t.a_email, t.a_cs_id, t.a_cni, t.a_ndis, t.a_slk, t.a_kin,
        t.b_program, t.b_name, t.b_aliases, t.b_dob, t.b_dob_status, t.b_gender, t.b_atsi,
        t.b_address, t.b_suburb, t.b_postcode, t.b_phone, t.b_email, t.b_cs_id, t.b_cni, t.b_ndis, t.b_slk, t.b_kin,
        pa_a.person_id AS person_id_a,
        REGEXP_REPLACE(nm_a.full_name, r'\\s+', ' ') AS person_name_a,
        pa_b.person_id AS person_id_b,
        REGEXP_REPLACE(nm_b.full_name, r'\\s+', ' ') AS person_name_b,
        la.ledger_history
      FROM `{DATA_PROJECT}.dcj_match.resolution_edges` AS re
      JOIN `{DATA_PROJECT}.dcj_match.candidate_pair_tiers` AS t
        ON t.record_id_a = re.record_id_a AND t.record_id_b = re.record_id_b
      LEFT JOIN ledger_agg AS la
        ON la.record_id_a = re.record_id_a AND la.record_id_b = re.record_id_b
      LEFT JOIN `{DATA_PROJECT}.dcj_match.person_assignment` AS pa_a ON pa_a.record_id = re.record_id_a
      LEFT JOIN `{DATA_PROJECT}.dcj_match.person_assignment` AS pa_b ON pa_b.record_id = re.record_id_b
      LEFT JOIN (
        SELECT person_id, ANY_VALUE(full_name) AS full_name
        FROM `{DATA_PROJECT}.dcj_tdm.person_name` WHERE primary_name_flag GROUP BY person_id
      ) AS nm_a ON nm_a.person_id = pa_a.person_id
      LEFT JOIN (
        SELECT person_id, ANY_VALUE(full_name) AS full_name
        FROM `{DATA_PROJECT}.dcj_tdm.person_name` WHERE primary_name_flag GROUP BY person_id
      ) AS nm_b ON nm_b.person_id = pa_b.person_id
      WHERE re.record_id_a IN (SELECT record_id FROM my_recs)
         OR re.record_id_b IN (SELECT record_id FROM my_recs)
    )
    SELECT
      *,
      COUNT(*) OVER () AS total_candidate_pairs_evaluated
    FROM rel_pairs
    ORDER BY
      decision = 'LINK' DESC,
      decided_by IN ('GEMINI_ADJUDICATOR', 'LLM_AND_TWIN_GUARD') DESC,
      tier = 'GREY_ZONE' DESC,
      suppressed_by_contradiction DESC,
      twin_or_sibling_trap DESC,
      documented_kin_relationship IS NOT NULL DESC,
      combined_score DESC
    LIMIT 30
  """

  f_core = EXECUTOR.submit(run_bq, q_core, p_param)
  f_names = EXECUTOR.submit(run_bq, q_graph_names_sources, p_param)
  f_inst = EXECUTOR.submit(run_bq, q_graph_instruments, p_param)
  f_prot = EXECUTOR.submit(run_bq, q_graph_protections, p_param)
  f_addr = EXECUTOR.submit(run_bq, q_graph_addresses, p_param)
  f_kin = EXECUTOR.submit(run_bq, q_graph_kinship, p_param)
  f_src = EXECUTOR.submit(run_bq, q_sources_identifiers, p_param)
  f_surv = EXECUTOR.submit(run_bq, q_survivorship, p_param)
  f_adj = EXECUTOR.submit(run_bq, q_adjudications, p_param)

  core_rows, m_core = f_core.result()
  if not core_rows:
    raise HTTPException(status_code=404, detail=f"Person '{pid}' not found in dcj_tdm.person.")
  profile = core_rows[0]

  names, m_names = f_names.result()
  instruments, m_inst = f_inst.result()
  protections, m_prot = f_prot.result()
  addresses, m_addr = f_addr.result()
  relationships, m_kin = f_kin.result()
  source_records, m_src = f_src.result()
  survivorship, m_surv = f_surv.result()
  adjudications, m_adj = f_adj.result()

  primary_name = next((n["full_name"] for n in names if n.get("primary_name_flag")), profile.get("party_display_name") or pid)
  profile["primary_full_name"] = primary_name

  # Assemble unified Property Graph { nodes, edges } for visualisation
  graph = build_person_graph(
      pid=pid,
      profile=profile,
      names=names,
      instruments=instruments,
      protections=protections,
      addresses=addresses,
      relationships=relationships,
      source_records=source_records,
      adjudications=adjudications,
  )

  total_pairs = adjudications[0]["total_candidate_pairs_evaluated"] if adjudications else 0
  total_ms = round((time.perf_counter() - t0) * 1000.0, 1)

  return {
      "entity_type": "person",
      "profile": profile,
      "names": names,
      "instruments": instruments,
      "protections": protections,
      "addresses": addresses,
      "relationships": relationships,
      "source_records": source_records,
      "survivorship": survivorship,
      "adjudications": adjudications,
      "total_candidate_pairs_evaluated": total_pairs,
      "graph": graph,
      "telemetry": {
          "total_ms": total_ms,
          "queries": [m_core, m_names, m_inst, m_prot, m_addr, m_kin, m_src, m_surv, m_adj],
      },
  }


def build_person_graph(
    pid: str,
    profile: Dict[str, Any],
    names: List[Dict[str, Any]],
    instruments: List[Dict[str, Any]],
    protections: List[Dict[str, Any]],
    addresses: List[Dict[str, Any]],
    relationships: List[Dict[str, Any]],
    source_records: List[Dict[str, Any]],
    adjudications: List[Dict[str, Any]],
) -> Dict[str, Any]:
  nodes: Dict[str, Dict[str, Any]] = {}
  edges: List[Dict[str, Any]] = []
  seen_edges = set()

  def add_node(nid: str, ntype: str, label: str, sublabel: str = "", props: Optional[Dict[str, Any]] = None, ring: int = 1, is_focus: bool = False):
    if nid not in nodes:
      nodes[nid] = {
          "id": nid,
          "type": ntype,
          "label": label,
          "sublabel": sublabel,
          "ring": ring,
          "is_focus": is_focus,
          "props": props or {},
      }

  def add_edge(src: str, dst: str, label: str, category: str, status: str = "normal", props: Optional[Dict[str, Any]] = None):
    key = (src, dst, label)
    if key in seen_edges:
      return
    seen_edges.add(key)
    edges.append({
        "id": f"{src}--{label}--{dst}",
        "source": src,
        "target": dst,
        "label": label,
        "category": category,
        "status": status,
        "props": props or {},
    })

  # 1. Central Golden Person Node
  add_node(
      pid,
      "Person",
      profile.get("primary_full_name") or pid,
      f"Golden Person · DOB {profile.get('date_of_birth') or 'Unknown'}",
      props=profile,
      ring=0,
      is_focus=True,
  )

  # 2. PersonName Nodes
  for nm in names:
    nid = nm["person_name_id"]
    usage = nm.get("name_usage_code") or "Name"
    add_node(
        nid,
        "PersonName",
        nm["full_name"],
        f"{usage}{' ★ Primary' if nm.get('primary_name_flag') else ''}",
        props=nm,
        ring=1,
    )
    add_edge(pid, nid, "HAS_NAME", "identity", props={"usage": usage, "program": nm.get("source_program")})

  # 3. IdentityInstrument & Issuing Organisation Nodes
  for inst in instruments:
    iid = inst["instrument_id"]
    itype = inst.get("instrument_type_code") or "ID"
    add_node(
        iid,
        "IdentityInstrument",
        f"{itype}: {inst.get('designation_number')}",
        inst.get("status_code") or "Active",
        props=inst,
        ring=1,
    )
    add_edge(pid, iid, "HOLDS_INSTRUMENT", "identity", props=inst)
    if inst.get("issuer_party_id"):
      oid = inst["issuer_party_id"]
      add_node(
          oid,
          "Organisation",
          inst.get("issuer_name") or oid,
          "Issuing Authority",
          props={"party_id": oid, "party_display_name": inst.get("issuer_name")},
          ring=2,
      )
      add_edge(iid, oid, "ISSUED_BY", "identity", props={"issue_date": inst.get("issue_date")})

  # 4. ProtectionEvent Nodes
  for pe in protections:
    peid = pe["protection_event_id"]
    add_node(
        peid,
        "ProtectionEvent",
        "Statutory Protection",
        pe.get("reason") or "Restricted Record",
        props=pe,
        ring=1,
    )
    add_edge(pid, peid, "HAS_PROTECTION_EVENT", "identity", status="alert", props=pe)
    if pe.get("initiator_party_id"):
      oid = pe["initiator_party_id"]
      add_node(
          oid,
          "Organisation",
          pe.get("initiator_name") or oid,
          "Statutory Authority",
          props={"party_id": oid, "party_display_name": pe.get("initiator_name")},
          ring=2,
      )
      add_edge(peid, oid, "INITIATED_BY", "identity", status="alert", props={"reason": pe.get("reason")})

  # 5. AddressLocation & Co-Resident Nodes
  for addr in addresses:
    aid = addr["address_id"]
    bldg = addr.get("building_name")
    lbl = bldg if bldg else (addr.get("full_address") or aid).split(",")[0]
    sub = f"{addr.get('suburb') or ''} {addr.get('postcode') or ''}".strip()
    if addr.get("is_crisis_hub"):
      sub = f"Crisis Refuge Hub ({addr.get('total_residents_at_addr')} residents)"
    add_node(
        aid,
        "AddressLocation",
        lbl,
        sub,
        props=addr,
        ring=1,
    )
    add_edge(
        pid,
        aid,
        "LIVES_AT",
        "property",
        status="hub" if addr.get("is_crisis_hub") else "normal",
        props=addr,
    )
    # Co-residents: show up to 4 on non-hub residential addresses, or 2 sample residents on crisis hubs
    max_co = 2 if addr.get("is_crisis_hub") else 5
    for co in (addr.get("co_residents") or [])[:max_co]:
      coid = co["person_id"]
      add_node(
          coid,
          "Person",
          co.get("full_name") or coid,
          f"Co-Resident · DOB {co.get('dob') or '—'}",
          props={"person_id": coid, "primary_full_name": co.get("full_name"), "date_of_birth": co.get("dob"), "is_protected_person": co.get("is_protected_person")},
          ring=2,
      )
      add_edge(coid, aid, "LIVES_AT", "property", props={"role": "Co-Resident", "source_program": co.get("source_program")})

  # 6. Kinship, Household Group & NGO Service Relationships (1-hop & 2-hop)
  for rel in relationships:
    for side_id, side_name, side_type, side_dob, side_prot in [
        (rel["from_id"], rel["from_name"], rel["from_type"], rel.get("from_dob"), rel.get("from_protected")),
        (rel["to_id"], rel["to_name"], rel["to_type"], rel.get("to_dob"), rel.get("to_protected")),
    ]:
      if side_id == pid:
        continue
      mapped_type = (
          "Group" if side_type == "group" else "Organisation" if side_type == "organisation" else "Person"
      )
      sub = (
          "Family Preservation Group"
          if mapped_type == "Group"
          else "Service Provider NGO"
          if mapped_type == "Organisation"
          else f"Kin / Relative · DOB {side_dob or '—'}"
      )
      add_node(
          side_id,
          mapped_type,
          side_name or side_id,
          sub,
          props={
              "person_id": side_id if mapped_type == "Person" else None,
              "party_id": side_id,
              "primary_full_name": side_name,
              "date_of_birth": side_dob,
              "is_protected_person": side_prot,
          },
          ring=1 if rel.get("hop") == 1 else 2,
      )
    add_edge(
        rel["from_id"],
        rel["to_id"],
        rel.get("canonical_relationship_type") or rel.get("relationship_type") or "RELATED_TO",
        "kinship",
        props=rel,
    )

  # 7. SourceRecords & Bipartite Identifiers
  my_rec_ids = set()
  for sr in source_records:
    rid = sr["source_record_id"]
    my_rec_ids.add(rid)
    raw_nm = norm_spaces(f"{sr.get('given_name_raw') or ''} {sr.get('family_name_raw') or ''}")
    add_node(
        rid,
        "SourceRecord",
        f"{sr['source_app_id']}: {sr['source_person_id']}",
        f"{raw_nm} ({sr.get('dob') or '—'})",
        props=sr,
        ring=1,
    )
    add_edge(rid, pid, "RESOLVES_TO", "lineage", status="linked", props={"program": sr.get("source_program"), "trust": sr.get("source_trust")})

    for idn in (sr.get("identifiers") or [])[:6]:
      id_key = idn["identifier_id"]
      add_node(
          id_key,
          "Identifier",
          id_key,
          f"IDF {idn.get('idf_weight')} · deg={idn.get('degree')}{' (HUB)' if idn.get('is_promiscuous') else ''}",
          props=idn,
          ring=2,
      )
      add_edge(
          rid,
          id_key,
          "HAS_IDENTIFIER",
          "lineage",
          status="hub" if idn.get("is_promiscuous") else "normal",
          props=idn,
      )

  # 8. Adjudication & Resolution Comparison Edges (`COMPARED_WITH`)
  veto_added = 0
  for adj in adjudications:
    ra, rb = adj["record_id_a"], adj["record_id_b"]
    dec = adj.get("decision") or "UNLINK"
    is_link = dec == "LINK" and not adj.get("suppressed_by_contradiction")
    if is_link:
      if ra in nodes and rb in nodes:
        add_edge(
            ra,
            rb,
            f"LINK ({adj.get('decided_by')})",
            "audit_link",
            status="linked",
            props=adj,
        )
    else:
      # Show top 5 high-interest vetoed/rejected comparisons (Gemini NO_MATCH, Twin Guard, Kinship veto, Contradiction Guard, or highest combined_score)
      is_high_signal_veto = (
          adj.get("decided_by") in ("GEMINI_ADJUDICATOR", "LLM_AND_TWIN_GUARD")
          or adj.get("twin_or_sibling_trap")
          or adj.get("suppressed_by_contradiction")
          or adj.get("documented_kin_relationship") is not None
          or (adj.get("combined_score") or 0) >= 0.45
      )
      if veto_added >= 5 and not is_high_signal_veto:
        continue
      if veto_added >= 7:
        continue
      veto_added += 1

      # Ensure external SourceRecord & its resolved Person exist in the graph so user can see WHO was kept separate!
      for rec_id, p_other_id, p_other_name, rec_prog, rec_name, rec_dob in [
          (ra, adj.get("person_id_a"), adj.get("person_name_a"), adj.get("a_program"), adj.get("a_name"), adj.get("a_dob")),
          (rb, adj.get("person_id_b"), adj.get("person_name_b"), adj.get("b_program"), adj.get("b_name"), adj.get("b_dob")),
      ]:
        if rec_id not in my_rec_ids:
          add_node(
              rec_id,
              "SourceRecord",
              rec_id,
              f"External · {rec_name or ''} ({rec_dob or ''})",
              props={"source_record_id": rec_id, "source_program": rec_prog, "person_id": p_other_id, "person_name": p_other_name},
              ring=2,
          )
          if p_other_id and p_other_id != pid:
            add_node(
                p_other_id,
                "Person",
                p_other_name or p_other_id,
                f"Distinct Person (Kept Separate)",
                props={"person_id": p_other_id, "primary_full_name": p_other_name, "date_of_birth": rec_dob},
                ring=2,
            )
            add_edge(rec_id, p_other_id, "RESOLVES_TO", "audit_veto", status="normal", props={"note": "Resolved to distinct individual"})

      veto_tag = (
          "VETO: TWIN GUARD"
          if adj.get("twin_or_sibling_trap")
          else "VETO: KINSHIP"
          if adj.get("documented_kin_relationship")
          else "NO_MATCH (GEMINI)"
          if adj.get("decided_by") == "GEMINI_ADJUDICATOR"
          else "UNLINK (GUARD)"
      )
      add_edge(ra, rb, veto_tag, "audit_veto", status="vetoed", props=adj)

  type_counts: Dict[str, int] = {}
  for n in nodes.values():
    type_counts[n["type"]] = type_counts.get(n["type"], 0) + 1

  return {
      "focus_id": pid,
      "focus_type": "Person",
      "nodes": list(nodes.values()),
      "edges": edges,
      "stats": {
          "node_count": len(nodes),
          "edge_count": len(edges),
          "by_type": type_counts,
      },
  }


@app.get("/api/property/{address_id}")
def api_property_dossier(address_id: str) -> Dict[str, Any]:
  """Fetches 360° GNAF Property dossier, all residents, intra-property kinship, hub suppression & Property Graph."""
  t0 = time.perf_counter()
  aid = address_id.strip().upper()
  a_param = [bigquery.ScalarQueryParameter("aid", "STRING", aid)]

  q_prop = f"""
    SELECT
      al.*,
      IFNULL(idn.degree, 0) AS bipartite_degree,
      IFNULL(idn.idf_weight, 0.0) AS idf_weight,
      (IFNULL(idn.is_promiscuous, FALSE) OR STARTS_WITH(al.id, 'GNAF-NSW-HUB')) AS is_crisis_hub,
      idn.sources AS bipartite_sources
    FROM `{DATA_PROJECT}.dcj_tdm.address_location` AS al
    LEFT JOIN `{DATA_PROJECT}.dcj_match.identifier` AS idn
      ON idn.identifier_id = CONCAT('GNAF:', al.id)
    WHERE UPPER(al.id) = @aid
  """

  q_residents = f"""
    SELECT *
    FROM GRAPH_TABLE(
      `{DATA_PROJECT}.dcj_tdm.dcj_person_graph`
      MATCH (p:Person)-[la:LIVES_AT]->(al:AddressLocation)
      WHERE UPPER(al.id) = @aid
      COLUMNS (
        p.person_id,
        p.gender,
        p.date_of_birth,
        p.dob_certainty_code,
        p.indigenous_status,
        p.is_protected_person,
        p.is_cald,
        la.address_relation_id,
        la.primary_address_flag,
        la.address_purpose,
        la.address_relation_start_date AS start_date,
        la.address_relation_end_date AS end_date,
        la.source_program
      )
    )
  """

  q_res_names = f"""
    SELECT
      ar.person_id,
      ANY_VALUE(IF(pn.primary_name_flag, REGEXP_REPLACE(pn.full_name, r'\\s+', ' '), NULL)) AS primary_full_name,
      STRING_AGG(DISTINCT CONCAT(REGEXP_REPLACE(pn.full_name, r'\\s+', ' '), ' [', pn.name_usage_code, ']'), ' · ') AS all_known_names,
      COUNT(DISTINCT lnk.source_record_id) AS source_record_count,
      STRING_AGG(DISTINCT lnk.source_program, ', ' ORDER BY lnk.source_program) AS contributing_programs
    FROM `{DATA_PROJECT}.dcj_tdm.address_relation` AS ar
    LEFT JOIN `{DATA_PROJECT}.dcj_tdm.person_name` AS pn ON pn.person_id = ar.person_id
    LEFT JOIN `{DATA_PROJECT}.dcj_tdm.person_source_linkage` AS lnk ON lnk.person_id = ar.person_id
    WHERE UPPER(ar.address_location_id) = @aid
    GROUP BY ar.person_id
  """

  q_intra_kin = f"""
    WITH res AS (
      SELECT DISTINCT person_id FROM `{DATA_PROJECT}.dcj_tdm.address_relation` WHERE UPPER(address_location_id) = @aid
    )
    SELECT *
    FROM GRAPH_TABLE(
      `{DATA_PROJECT}.dcj_tdm.dcj_person_graph`
      MATCH (p1:Party)-[rel:PARTY_RELATIONSHIP]->(p2:Party)
      COLUMNS (
        rel.relationship_id,
        p1.party_id AS from_id,
        REGEXP_REPLACE(p1.party_display_name, r'\\s+', ' ') AS from_name,
        p1.party_type_code AS from_type,
        p2.party_id AS to_id,
        REGEXP_REPLACE(p2.party_display_name, r'\\s+', ' ') AS to_name,
        p2.party_type_code AS to_type,
        rel.relationship_type,
        rel.canonical_relationship_type,
        rel.relationship_category,
        rel.comment,
        rel.source_program
      )
    )
    WHERE from_id IN (SELECT person_id FROM res)
       OR to_id IN (SELECT person_id FROM res)
    LIMIT 40
  """

  q_prop_audit = f"""
    WITH addr_recs AS (
      SELECT record_id FROM `{DATA_PROJECT}.dcj_match.stg_source_profiles` WHERE UPPER(gnaf_address_id) = @aid
    )
    SELECT
      re.record_id_a,
      re.record_id_b,
      re.decision,
      re.decided_by,
      re.confidence,
      re.rationale,
      re.decisive_evidence,
      re.contradiction,
      re.combined_score,
      re.rrf_score,
      re.semantic_similarity,
      t.tier,
      t.hub_only,
      t.twin_or_sibling_trap,
      t.documented_kin_relationship,
      t.a_name, t.a_program, t.a_dob,
      t.b_name, t.b_program, t.b_dob,
      adj.verdict,
      adj.scenario_classified,
      adj.model,
      adj.adjudicated_at
    FROM `{DATA_PROJECT}.dcj_match.resolution_edges` AS re
    JOIN `{DATA_PROJECT}.dcj_match.candidate_pair_tiers` AS t
      ON t.record_id_a = re.record_id_a AND t.record_id_b = re.record_id_b
    LEFT JOIN `{DATA_PROJECT}.dcj_match.v_adjudications_current` AS adj
      ON adj.record_id_a = re.record_id_a AND adj.record_id_b = re.record_id_b
    WHERE re.record_id_a IN (SELECT record_id FROM addr_recs)
      AND re.record_id_b IN (SELECT record_id FROM addr_recs)
    ORDER BY
      re.decided_by IN ('GEMINI_ADJUDICATOR', 'LLM_AND_TWIN_GUARD') DESC,
      re.decision = 'LINK' DESC,
      t.twin_or_sibling_trap DESC,
      t.hub_only DESC,
      re.combined_score DESC
    LIMIT 25
  """

  f_p = EXECUTOR.submit(run_bq, q_prop, a_param)
  f_r = EXECUTOR.submit(run_bq, q_residents, a_param)
  f_rn = EXECUTOR.submit(run_bq, q_res_names, a_param)
  f_k = EXECUTOR.submit(run_bq, q_intra_kin, a_param)
  f_a = EXECUTOR.submit(run_bq, q_prop_audit, a_param)

  prop_rows, m_p = f_p.result()
  if not prop_rows:
    raise HTTPException(status_code=404, detail=f"Property '{aid}' not found.")
  prop = prop_rows[0]
  residents_raw, m_r = f_r.result()
  res_names, m_rn = f_rn.result()
  kinship, m_k = f_k.result()
  adjudications, m_a = f_a.result()

  nm_map = {r["person_id"]: r for r in res_names}
  residents = []
  for r in residents_raw:
    enrich = nm_map.get(r["person_id"], {})
    merged_r = {**r, **enrich}
    residents.append(merged_r)
  residents.sort(key=lambda x: (not bool(x.get("primary_address_flag")), x.get("primary_full_name") or ""))

  # Build Property-Centric Graph
  nodes: Dict[str, Dict[str, Any]] = {}
  edges: List[Dict[str, Any]] = []
  seen_e = set()

  def add_n(nid: str, ntype: str, label: str, sub: str = "", props: Optional[Dict[str, Any]] = None, ring: int = 1, is_focus: bool = False):
    if nid not in nodes:
      nodes[nid] = {"id": nid, "type": ntype, "label": label, "sublabel": sub, "ring": ring, "is_focus": is_focus, "props": props or {}}

  def add_e(s: str, d: str, lbl: str, cat: str, st: str = "normal", props: Optional[Dict[str, Any]] = None):
    if (s, d, lbl) in seen_e:
      return
    seen_e.add((s, d, lbl))
    edges.append({"id": f"{s}--{lbl}--{d}", "source": s, "target": d, "label": lbl, "category": cat, "status": st, "props": props or {}})

  title = prop.get("building_name") or prop.get("full_address") or aid
  add_n(
      aid,
      "AddressLocation",
      title,
      f"{prop.get('full_address')} {'· CRISIS HUB' if prop.get('is_crisis_hub') else ''}",
      props=prop,
      ring=0,
      is_focus=True,
  )
  gnaf_token = f"GNAF:{aid}"
  add_n(
      gnaf_token,
      "Identifier",
      gnaf_token,
      f"IDF {prop.get('idf_weight')} · deg={prop.get('bipartite_degree')}{' (SUPPRESSED HUB)' if prop.get('is_crisis_hub') else ''}",
      props={"identifier_id": gnaf_token, "degree": prop.get("bipartite_degree"), "idf_weight": prop.get("idf_weight"), "is_promiscuous": prop.get("is_crisis_hub")},
      ring=1,
  )
  add_e(aid, gnaf_token, "HAS_GNAF_TOKEN", "lineage", st="hub" if prop.get("is_crisis_hub") else "normal")

  for r in residents[:24]:
    pid = r["person_id"]
    add_n(
        pid,
        "Person",
        r.get("primary_full_name") or pid,
        f"DOB {r.get('date_of_birth') or '—'} · {'Protected' if r.get('is_protected_person') else r.get('address_purpose') or 'Resident'}",
        props=r,
        ring=1,
    )
    add_e(pid, aid, "LIVES_AT", "property", st="alert" if r.get("is_protected_person") else "normal", props=r)

  for k in kinship:
    for sid, sname, stype in [(k["from_id"], k["from_name"], k["from_type"]), (k["to_id"], k["to_name"], k["to_type"])]:
      mtype = "Group" if stype == "group" else "Organisation" if stype == "organisation" else "Person"
      add_n(sid, mtype, sname or sid, mtype, props={"party_id": sid, "person_id": sid if mtype == "Person" else None, "primary_full_name": sname}, ring=2)
    add_e(k["from_id"], k["to_id"], k.get("canonical_relationship_type") or k.get("relationship_type"), "kinship", props=k)

  total_ms = round((time.perf_counter() - t0) * 1000.0, 1)
  type_counts: Dict[str, int] = {}
  for n in nodes.values():
    type_counts[n["type"]] = type_counts.get(n["type"], 0) + 1

  return {
      "entity_type": "property",
      "property": prop,
      "residents": residents,
      "relationships": kinship,
      "adjudications": adjudications,
      "graph": {
          "focus_id": aid,
          "focus_type": "AddressLocation",
          "nodes": list(nodes.values()),
          "edges": edges,
          "stats": {"node_count": len(nodes), "edge_count": len(edges), "by_type": type_counts},
      },
      "telemetry": {
          "total_ms": total_ms,
          "queries": [m_p, m_r, m_rn, m_k, m_a],
      },
  }


@app.get("/api/overview")
def api_overview() -> Dict[str, Any]:
  f_m = EXECUTOR.submit(run_bq, f"SELECT * FROM `{DATA_PROJECT}.dcj_match.v_dcj_method_comparison` ORDER BY method")
  f_s = EXECUTOR.submit(run_bq, f"SELECT * FROM `{DATA_PROJECT}.dcj_match.v_dcj_scenario_scorecard` ORDER BY scenario")
  f_g = EXECUTOR.submit(run_bq, f"SELECT * FROM `{DATA_PROJECT}.dcj_match.v_dcj_graph_summary`")
  methods, _ = f_m.result()
  scenarios, _ = f_s.result()
  graph_summary, _ = f_g.result()
  return {
      "method_comparison": methods,
      "scenario_scorecard": scenarios,
      "graph_summary": graph_summary,
  }
