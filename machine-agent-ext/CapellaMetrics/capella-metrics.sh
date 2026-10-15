#!/usr/bin/env bash
# AppDynamics Machine Agent script monitor: reports Capella metrics as custom metrics.
# Which metrics to report is listed in metrics.conf (one line per metric).
# The Machine Agent runs scripts with an empty environment, so credentials come from capella.env
# (written by your start script, deleted on exit).
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$DIR/capella.env" ] && . "$DIR/capella.env"
H="${CB_CONNSTR#couchbases://}"; H="${H%%/*}"
CA="${CAPELLA_CA_PEM:-$DIR/../../../capella-root.pem}"
CONF="$DIR/metrics.conf"
[ -f "$CA" ] && [ -f "$CONF" ] || exit 0
CACHE="$DIR/capella.nodes"   # node list cache, used when the query service is too busy to answer

# 1) node list: from system:nodes, fall back to the cached list, then to the public hostname alone
RESP=$(curl -sS --max-time 15 --cacert "$CA" -u "$CB_USER:$CB_PASSWORD" \
  --data-urlencode 'statement=SELECT name FROM system:nodes' "https://$H:18093/query/service" 2>/dev/null)
NODES=$(printf '%s' "$RESP" | grep -o '"name": *"[^"]*"' | sed -E 's/"name": *"([^":]*)(:[0-9]+)?"/\1/' | sort -u)
if [ -n "$NODES" ]; then printf '%s\n' "$NODES" > "$CACHE"; else NODES=$(cat "$CACHE" 2>/dev/null); fi
[ -n "$NODES" ] || NODES="$H"

# 2) download /metrics from every node once
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
i=0
for N in $NODES; do
  curl -sS --max-time 15 --cacert "$CA" -u "$CB_USER:$CB_PASSWORD" "https://$N:18091/metrics" -o "$TMP/$i" 2>/dev/null
  i=$((i+1))
done

# 3) one output line per metric in metrics.conf:  Display name | metric name | max/min/avg/sum | optional filter
grep -v '^[[:space:]]*#' "$CONF" | while IFS='|' read -r LABEL METRIC AGG FILTER; do
  [ -n "$LABEL" ] && [ -n "$METRIC" ] || continue
  VAL=$(cat "$TMP"/* 2>/dev/null | awk -v m="$METRIC" -v agg="${AGG:-max}" -v f="$FILTER" '
    index($0, m) == 1 && substr($0, length(m) + 1, 1) ~ /[{ ]/ && (f == "" || index($0, f) > 0) {
      v = $NF + 0; n++; sum += v
      if (n == 1 || v > mx) mx = v
      if (n == 1 || v < mn) mn = v
    }
    END { if (n == 0) exit
          r = (agg == "min") ? mn : (agg == "sum") ? sum : (agg == "avg") ? sum / n : mx
          printf "%.0f", r }')
  [ -n "$VAL" ] && echo "name=Custom Metrics|Capella|$LABEL,value=$VAL,aggregator=OBSERVATION,time-rollup=CURRENT,cluster-rollup=INDIVIDUAL"
done
exit 0
