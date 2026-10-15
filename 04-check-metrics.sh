#!/usr/bin/env bash
# Reads CPU metrics from the Capella cluster's Prometheus endpoint (same host, port 18091, /metrics).
# Needs CB_CONNSTR, CB_USER, CB_PASSWORD in env and capella-root.pem in this folder. Prints only metric lines.
set -uo pipefail
cd "$(dirname "$0")"
: "${CB_CONNSTR:?}" "${CB_USER:?}" "${CB_PASSWORD:?}"
H="${CB_CONNSTR#couchbases://}"; H="${H%%/*}"
OUT=$(mktemp)
CODE=$(curl -sS --max-time 20 --cacert capella-root.pem -u "$CB_USER:$CB_PASSWORD" -o "$OUT" -w '%{http_code}' "https://$H:18091/metrics")
echo "HTTP $CODE  bytes=$(wc -c < "$OUT")"
if [ "$CODE" = 200 ]; then
  echo "--- CPU metrics:"; grep -E '^sys_cpu_(utilization|host_utilization)_rate|^sys_cpu_(user|sys|idle)_rate' "$OUT" | head -20
  echo "--- total metric lines: $(grep -vc '^#' "$OUT")"
else
  head -c 300 "$OUT"; echo
fi
rm -f "$OUT"
