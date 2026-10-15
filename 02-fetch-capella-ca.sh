#!/usr/bin/env bash
# Saves the Capella root CA (last self-signed cert in the chain) to capella-root.pem and
# re-tests the data endpoint with it. Needs CB_CONNSTR, CB_USER, CB_PASSWORD in env.
set -euo pipefail
: "${CB_CONNSTR:?}" "${CB_USER:?}" "${CB_PASSWORD:?}"
H="${CB_CONNSTR#couchbases://}"
echo | openssl s_client -connect "$H:18091" -servername "$H" -showcerts 2>/dev/null \
  | awk '/BEGIN CERT/{n++} {if(n)buf[n]=buf[n] $0 "\n"} END{printf "%s", buf[n]}' > capella-root.pem
openssl x509 -in capella-root.pem -noout -subject -issuer -fingerprint -sha256
echo "== test with CA =="
curl -sS --max-time 10 --cacert capella-root.pem -o /dev/null \
  -w "capella data endpoint: %{http_code} %{time_connect}s\n" \
  "https://$H:18091/pools" -u "$CB_USER:$CB_PASSWORD"
