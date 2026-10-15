#!/usr/bin/env bash
# Starts the AppDynamics Machine Agent (runs the CapellaCpu monitor every 60s). Foreground; Ctrl-C to stop.
# Needs CB_CONNSTR, CB_USER, CB_PASSWORD, APPD_CONTROLLER_HOST, APPD_ACCOUNT_NAME, APPD_ACCESS_KEY in env.
set -euo pipefail
cd "$(dirname "$0")"
: "${CB_CONNSTR:?}" "${CB_USER:?}" "${CB_PASSWORD:?}" "${APPD_CONTROLLER_HOST:?}" "${APPD_ACCOUNT_NAME:?}" "${APPD_ACCESS_KEY:?}"
export JAVA_HOME="$PWD/$(ls -d tools/jdk-11*/Contents/Home | head -1)"
export PATH="$JAVA_HOME/bin:$PATH"
HOST="${APPD_CONTROLLER_HOST#*://}"; HOST="${HOST%%/*}"; HOST="${HOST%%:*}"
export CAPELLA_CA_PEM="$PWD/capella-root.pem"
ENVF="machine-agent/monitors/CapellaCpu/capella.env"
umask 077
printf "CB_CONNSTR='%s'\nCB_USER='%s'\nCB_PASSWORD='%s'\nCAPELLA_CA_PEM='%s'\n" "$CB_CONNSTR" "$CB_USER" "$CB_PASSWORD" "$CAPELLA_CA_PEM" > "$ENVF"
trap 'rm -f "$ENVF"' EXIT INT TERM
cp machine-agent-ext/CapellaCpu/capella-cpu.sh machine-agent/monitors/CapellaCpu/capella-cpu.sh
java \
  -Dappdynamics.controller.hostName="$HOST" -Dappdynamics.controller.port=443 -Dappdynamics.controller.ssl.enabled=true \
  -Dappdynamics.agent.accountName="$APPD_ACCOUNT_NAME" -Dappdynamics.agent.accountAccessKey="$APPD_ACCESS_KEY" \
  -Dappdynamics.agent.applicationName="${APPD_APP_NAME:-capella-demo}" -Dappdynamics.agent.tierName=capella-client -Dappdynamics.agent.nodeName=node1 \
  -Dappdynamics.sim.enabled=false \
  -jar machine-agent/machineagent.jar
