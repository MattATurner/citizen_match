#!/usr/bin/env python3
"""Deploy a local Jupyter Notebook (.ipynb) to BigQuery Studio (Dataform API).

BigQuery Studio stores single-file Python notebooks as Dataform repositories
labeled with `single-file-asset-type=notebook` and root file `content.ipynb`.

Usage:
  python3 scripts/deploy_notebook_to_bq_studio.py \
      --project all-things-cdp \
      --location us-central1 \
      --notebook-id cdp-walkthrough \
      --display-name cdp-walkthrough \
      --file notebooks/cdp-walkthrough.ipynb
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request


def get_adc_token() -> str:
  """Fetch an Application Default Credentials (ADC) OAuth2 access token."""
  try:
    import google.auth
    import google.auth.transport.requests

    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(google.auth.transport.requests.Request())
    if creds.token:
      return creds.token
  except Exception:
    pass

  res = subprocess.run(
      ["gcloud", "auth", "application-default", "print-access-token"],
      capture_output=True,
      text=True,
      check=True,
  )
  return res.stdout.strip()


def api_request(
    method: str,
    url: str,
    token: str,
    quota_project: str,
    payload: dict | None = None,
) -> tuple[int, dict]:
  headers = {
      "Authorization": f"Bearer {token}",
      "x-goog-user-project": quota_project,
      "Content-Type": "application/json",
  }
  data = json.dumps(payload).encode("utf-8") if payload is not None else None
  req = urllib.request.Request(url, data=data, headers=headers, method=method)
  try:
    with urllib.request.urlopen(req, timeout=60) as resp:
      body = resp.read().decode("utf-8")
      return resp.status, json.loads(body) if body else {}
  except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8")
    try:
      err_json = json.loads(body)
    except Exception:
      err_json = {"raw": body}
    return e.code, err_json


def main() -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--project", default="all-things-cdp")
  parser.add_argument("--location", default="us-central1")
  parser.add_argument("--notebook-id", default="cdp-walkthrough")
  parser.add_argument("--display-name", default="cdp-walkthrough")
  parser.add_argument(
      "--file",
      default="notebooks/cdp-walkthrough.ipynb",
      help="Path to the .ipynb file to deploy",
  )
  parser.add_argument("--author-name", default="Matt Turner")
  parser.add_argument("--author-email", default="mattturner@google.com")
  args = parser.parse_args()

  nb_path = Path(args.file).resolve()
  if not nb_path.is_file():
    print(f"ERROR: Notebook file not found: {nb_path}", file=sys.stderr)
    return 1

  raw_bytes = nb_path.read_bytes()
  # Validate JSON structure before uploading
  nb_json = json.loads(raw_bytes.decode("utf-8"))
  cell_count = len(nb_json.get("cells", []))

  token = get_adc_token()
  base_url = (
      f"https://dataform.googleapis.com/v1beta1/projects/{args.project}"
      f"/locations/{args.location}/repositories"
  )
  repo_url = f"{base_url}/{args.notebook_id}"

  # 1. Check if repository exists; create if not
  status, repo = api_request("GET", repo_url, token, args.project)
  if status == 404:
    print(
        f"Creating BigQuery Studio notebook asset `{args.notebook_id}` in"
        f" {args.project} ({args.location})..."
    )
    create_url = f"{base_url}?repositoryId={args.notebook_id}"
    create_payload = {
        "displayName": args.display_name,
        "labels": {"single-file-asset-type": "notebook"},
        "setAuthenticatedUserAdmin": True,
    }
    c_status, repo = api_request(
        "POST", create_url, token, args.project, create_payload
    )
    if c_status not in (200, 201):
      print(
          f"ERROR creating repository ({c_status}): {json.dumps(repo, indent=2)}",
          file=sys.stderr,
      )
      return 1
  elif status != 200:
    print(
        f"ERROR checking repository ({status}): {json.dumps(repo, indent=2)}",
        file=sys.stderr,
    )
    return 1
  else:
    print(
        f"Found existing BigQuery Studio notebook asset `{args.notebook_id}`"
        f" (displayName={repo.get('displayName')!r}). Updating content..."
    )

  # 2. Commit content.ipynb to the repository main branch
  commit_url = f"{repo_url}:commit"
  commit_payload = {
      "commitMetadata": {
          "author": {
              "name": args.author_name,
              "emailAddress": args.author_email,
          },
          "commitMessage": (
              f"Deploy {args.display_name} ({cell_count} cells,"
              f" {len(raw_bytes):,} bytes)"
          ),
      },
      "fileOperations": {
          "content.ipynb": {
              "writeFile": {
                  "contents": base64.b64encode(raw_bytes).decode("ascii")
              }
          }
      },
  }
  cm_status, cm_resp = api_request(
      "POST", commit_url, token, args.project, commit_payload
  )
  if cm_status != 200:
    print(
        f"ERROR committing content.ipynb ({cm_status}):"
        f" {json.dumps(cm_resp, indent=2)}",
        file=sys.stderr,
    )
    return 1

  # 3. Verify round-trip readFile
  read_url = f"{repo_url}:readFile?path=content.ipynb"
  r_status, r_resp = api_request("GET", read_url, token, args.project)
  if r_status != 200 or "contents" not in r_resp:
    print(
        f"ERROR verifying content.ipynb ({r_status}):"
        f" {json.dumps(r_resp, indent=2)}",
        file=sys.stderr,
    )
    return 1

  verified_bytes = base64.b64decode(r_resp["contents"])
  verified_cells = len(json.loads(verified_bytes.decode("utf-8")).get("cells", []))
  console_url = (
      "https://console.cloud.google.com/bigquery"
      f"?project={args.project}&ws=!1m7!1m6!12m5!1m3!1s{args.project}"
      f"!2s{args.location}!3s{args.notebook_id}!2e2"
  )
  print(
      f"SUCCESS: Deployed `{args.display_name}` to BigQuery Studio!\n"
      f"  Resource : {repo.get('name')}\n"
      f"  Cells    : {verified_cells} ({len(verified_bytes):,} bytes)\n"
      f"  Console  : {console_url}"
  )
  return 0


if __name__ == "__main__":
  sys.exit(main())
