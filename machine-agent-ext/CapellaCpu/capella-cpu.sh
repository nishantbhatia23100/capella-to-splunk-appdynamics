#!/usr/bin/env bash
# AppDynamics Machine Agent script monitor: reports the HIGHEST Capella node CPU % as a custom metric.
# The public hostname answers /metrics from only one node, so we list every node (system:nodes) and read each.
# The Machine Agent runs scripts with an empty environment, so credentials come from capella.env (written by
# 05-run-machine-agent.sh, deleted on exit).
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$DIR/capella.env" ] && . "$DIR/capella.env"
H="${CB_CONNSTR#couchbases://}"; H="${H%%/*}"
CA="${CAPELLA_CA_PEM:-$DIR/../../../capella-root.pem}"
[ -f "$CA" ] || exit 0
CACHE="$DIR/capella.nodes"   # node list cache, used when the query service is too busy to answer

# 1) node list: from system:nodes, fall back to the cached list, then to the public hostname alone
RESP=$(curl -sS --max-time 15 --cacert "$CA" -u "$CB_USER:$CB_PASSWORD" \
  --data-urlencode 'statement=SELECT name FROM system:nodes' "https://$H:18093/query/service" 2>/dev/null)
NODES=$(printf '%s' "$RESP" | grep -o '"name": *"[^"]*"' | sed -E 's/"name": *"([^":]*)(:[0-9]+)?"/\1/' | sort -u)
if [ -n "$NODES" ]; then printf '%s\n' "$NODES" > "$CACHE"; else NODES=$(cat "$CACHE" 2>/dev/null); fi
[ -n "$NODES" ] || NODES="$H"

# 2) CPU from each node, keep the maximum
MAX=""
for N in $NODES; do
  V=$(curl -sS --max-time 15 --cacert "$CA" -u "$CB_USER:$CB_PASSWORD" "https://$N:18091/metrics" 2>/dev/null \
      | awk '/^sys_cpu_utilization_rate/ {v=$NF; if (v>m) m=v} END {if (m!="") printf "%.0f", m}')
  [ -n "$V" ] && { [ -z "$MAX" ] || [ "$V" -gt "$MAX" ]; } && MAX="$V"
done
[ -n "$MAX" ] && echo "name=Custom Metrics|Capella|CPU Utilization %,value=$MAX,aggregator=OBSERVATION,time-rollup=CURRENT,cluster-rollup=INDIVIDUAL"
exit 0
