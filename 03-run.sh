#!/usr/bin/env bash
# Runs the Capella load app. Uses project-local JDK + Maven. Needs CB_* vars in env.
# If appdynamics-agent/javaagent.jar exists AND APPD_* vars are set, attaches the AppDynamics agent.
set -euo pipefail
cd "$(dirname "$0")"
# Optional: load secrets from .env (gitignored) so you do not have to export them per terminal tab
# Only non-empty .env values are used, and they never override variables already exported in your shell.
if [ -f .env ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    k="${line%%=*}"; v="${line#*=}"
    v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    v="${v#\'}"; v="${v%\'}"; v="${v#\"}"; v="${v%\"}"
    [ -n "$v" ] && [ -z "${!k:-}" ] && export "$k=$v"
  done < .env
fi
export JAVA_HOME="$PWD/$(ls -d tools/jdk-11*/Contents/Home | head -1)"
export PATH="$JAVA_HOME/bin:$PATH"
MVN=./tools/apache-maven-3.9.9/bin/mvn
AGENT=appdynamics-agent/javaagent.jar
OPTS=""
# controller host must be a bare hostname: strip scheme, path and port if pasted from the browser
APPD_HOST="${APPD_CONTROLLER_HOST:-}"; APPD_HOST="${APPD_HOST#*://}"; APPD_HOST="${APPD_HOST%%/*}"; APPD_HOST="${APPD_HOST%%:*}"
if [ -f "$AGENT" ] && [ -n "${APPD_ACCESS_KEY:-}" ]; then
  OPTS="-javaagent:$PWD/$AGENT \
 -Dappdynamics.controller.hostName=$APPD_HOST -Dappdynamics.controller.port=443 -Dappdynamics.controller.ssl.enabled=true \
 -Dappdynamics.agent.accountName=$APPD_ACCOUNT_NAME -Dappdynamics.agent.accountAccessKey=$APPD_ACCESS_KEY \
 -Dappdynamics.agent.applicationName=${APPD_APP_NAME:-capella-demo} -Dappdynamics.agent.tierName=capella-client -Dappdynamics.agent.nodeName=node1"
  echo ">> AppDynamics agent ATTACHED"
else
  echo ">> Running WITHOUT AppDynamics agent"
fi
exec $MVN -q -B compile exec:exec -Dexec.executable="$JAVA_HOME/bin/java" \
  -Dexec.args="$OPTS -cp %classpath demo.CapellaLoad"
