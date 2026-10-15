#!/usr/bin/env bash
# Drives Capella CPU up to test the "Capella CPU > 50" alert. Time-limited (BURN_SECONDS, default 180). Needs CB_* in env.
set -euo pipefail
cd "$(dirname "$0")"
export JAVA_HOME="$PWD/$(ls -d tools/jdk-11*/Contents/Home | head -1)"; export PATH="$JAVA_HOME/bin:$PATH"
exec ./tools/apache-maven-3.9.9/bin/mvn -q -B compile exec:java -DmainClass=demo.CpuBurn
