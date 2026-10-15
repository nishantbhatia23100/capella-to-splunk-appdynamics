#!/usr/bin/env bash
# Verifies the Capella API key works and lists your clusters. Needs CAPELLA_API_KEY in env.
set -euo pipefail
: "${CAPELLA_API_KEY:?export CAPELLA_API_KEY first}"
API=https://cloudapi.cloud.couchbase.com
echo "== organizations =="
curl -sS -H "Authorization: Bearer $CAPELLA_API_KEY" "$API/v4/organizations" | jq '.data[] | {id,name}'
