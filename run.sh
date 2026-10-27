#!/usr/bin/env bash
# =============================================================================
# NSW Department of Communities and Justice (DCJ)
# First Iteration Person Data Model (SDM -> TDM), Hybrid Entity Resolution,
# Gemini Platform Adjudicator, BigQuery Property Graph & Knowledge Catalog
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

MODE="${1:---all}"

run_sql() {
  local sql_file="$1"
  echo "=================================================================="
  echo "==> Executing SQL Stage: $(basename "${sql_file}")"
  echo "=================================================================="
  bq query \
    --project_id="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --use_legacy_sql=false \
    < "${sql_file}"
}

if [[ "${MODE}" == "--all" || "${MODE}" == "--setup" ]]; then
  run_sql "${SCRIPT_DIR}/sql/00_setup_and_sdm.sql"
  echo "==> Generating & Loading NSW DCJ Synthetic SDM Data + Ground Truth ..."
  python3 "${SCRIPT_DIR}/scripts/generate_dcj_sdm_data.py"
fi

if [[ "${MODE}" == "--all" || "${MODE}" == "--elt" ]]; then
  run_sql "${SCRIPT_DIR}/sql/10_stage_sources.sql"
  run_sql "${SCRIPT_DIR}/sql/20_bipartite_graph.sql"
  run_sql "${SCRIPT_DIR}/sql/30_embed_and_search.sql"
  run_sql "${SCRIPT_DIR}/sql/40_hybrid_candidates_rrf.sql"
  run_sql "${SCRIPT_DIR}/sql/50_genai_adjudicator.sql"
  run_sql "${SCRIPT_DIR}/sql/60_connected_components_and_tdm.sql"
  run_sql "${SCRIPT_DIR}/sql/70_property_graph.sql"
  run_sql "${SCRIPT_DIR}/sql/80_person_match_tvf_and_scorecard.sql"
  run_sql "${SCRIPT_DIR}/sql/90_frontline_search_functions.sql"
fi

if [[ "${MODE}" == "--all" || "${MODE}" == "--catalog" ]]; then
  echo "==> Populating BigQuery Knowledge Catalog Business Glossary & Column Links ..."
  python3 "${SCRIPT_DIR}/scripts/populate_dcj_knowledge_catalog.py"
fi

if [[ "${MODE}" == "--all" || "${MODE}" == "--verify" ]]; then
  echo "==> Running 3-Method Benchmark & Scenario Scorecard Verification ..."
  bq query --project_id="${PROJECT_ID}" --location="${LOCATION}" --use_legacy_sql=false \
    "SELECT * FROM \`${PROJECT_ID}.${MATCH_DATASET}.v_dcj_method_comparison\` ORDER BY method;"
  bq query --project_id="${PROJECT_ID}" --location="${LOCATION}" --use_legacy_sql=false \
    "SELECT * FROM \`${PROJECT_ID}.${MATCH_DATASET}.v_dcj_scenario_scorecard\` ORDER BY scenario;"
fi

echo "🎉 NSW DCJ Person Data Model Pipeline Completed Successfully!"
