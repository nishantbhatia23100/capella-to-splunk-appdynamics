#!/usr/bin/env bash
# Lists cluster nodes + services (system:nodes) and reads CPU % from each node's /metrics. Needs CB_* in env. Prints no secrets.
set -uo pipefail
cd "$(dirname "$0")"
: "${CB_CONNSTR:?}" "${CB_USER:?}" "${CB_PASSWORD:?}"
H="${CB_CONNSTR#couchbases://}"; H="${H%%/*}"
echo "== nodes (from system:nodes) =="
NODES=$(curl -sS --max-time 20 --cacert capella-root.pem -u "$CB_USER:$CB_PASSWORD" \
  --data-urlencode 'statement=SELECT name, services FROM system:nodes' "https://$H:18093/query/service")
echo "$NODES" | python3 -c 'import sys,json; d=json.load(sys.stdin); [print(r["name"], r.get("services")) for r in d.get("results",[])] or print(d.get("errors") or d)'
echo; echo "== CPU % per node =="
echo "$NODES" | python3 -c 'import sys,json; d=json.load(sys.stdin); [print(r["name"].split(":")[0]) for r in d.get("results",[])]' | sort -u | while read -r N; do
  V=$(curl -sS --max-time 20 --cacert capella-root.pem -u "$CB_USER:$CB_PASSWORD" "https://$N:18091/metrics" | awk '/^sys_cpu_utilization_rate/ {printf "%s ", $NF}')
  echo "$N  cpu=${V:-no data}"
done
