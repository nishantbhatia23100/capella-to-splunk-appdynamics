#!/usr/bin/env bash
# Turns off the Machine Agent's built-in Sigar hardware monitor (it loads a native library macOS Gatekeeper blocks; we do not use it).
cd "$(dirname "$0")/machine-agent/monitors/JavaHardwareMonitor" || exit 1
[ -f monitor.xml.orig ] || cp monitor.xml monitor.xml.orig
sed -i '' 's#<enabled>true</enabled>#<enabled>false</enabled>#' monitor.xml && echo "SigarHardwareMonitor disabled"
