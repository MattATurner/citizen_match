#!/usr/bin/env bash
# Deploy the NSW DCJ Frontline Search & Graph API to Google Cloud Run
set -euo pipefail

RUN_PROJECT="${RUN_PROJECT:-all-things-presentations}"
DATA_PROJECT="${DATA_PROJECT:-all-things-cdp}"
REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-dcj-search-api}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_PROJECT_NUMBER="$(gcloud projects describe "${RUN_PROJECT}" --format='value(projectNumber)')"
COMPUTE_SA="${RUN_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "==> Granting BigQuery & Connection IAM on ${DATA_PROJECT} to ${COMPUTE_SA}..."
for ROLE in roles/bigquery.jobUser roles/bigquery.dataViewer roles/bigquery.connectionUser; do
  gcloud projects add-iam-policy-binding "${DATA_PROJECT}" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="${ROLE}" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> Deploying Cloud Run service ${SERVICE_NAME} in ${RUN_PROJECT} (${REGION})..."
gcloud run deploy "${SERVICE_NAME}" \
  --quiet \
  --source "${SCRIPT_DIR}" \
  --project "${RUN_PROJECT}" \
  --region "${REGION}" \
  --allow-unauthenticated \
  --memory "1Gi" \
  --cpu "2" \
  --min-instances "0" \
  --max-instances "10" \
  --set-env-vars "BQ_DATA_PROJECT=${DATA_PROJECT},BQ_JOB_PROJECT=${DATA_PROJECT},BQ_LOCATION=${REGION}"

gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
  --project="${RUN_PROJECT}" \
  --region="${REGION}" \
  --member="allUsers" \
  --role="roles/run.invoker" \
  --quiet >/dev/null

API_URL="$(gcloud run services describe "${SERVICE_NAME}" --project="${RUN_PROJECT}" --region="${REGION}" --format='value(status.url)')"
echo "✅ DCJ Frontline Search API deployed: ${API_URL}"
