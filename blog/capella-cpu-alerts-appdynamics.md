---
title: "Alert on Couchbase Capella metrics from AppDynamics"
---

Capella is a managed database, so you cannot install an AppDynamics agent on its nodes. That raises a practical question: how do you see Capella from AppDynamics, and how do you get an email when a Capella metric crosses a limit? This post shows a setup that works with the Java agent and the Machine Agent, including the common pitfalls. We use CPU as the first test metric; any metric on Capella's metrics endpoint works the same way.

## The idea

Two views, one AppDynamics:

1. **App view.** The Java agent watches your app's calls to Capella: latency, calls per minute and errors.
2. **Cluster metrics.** A small script reads Capella's Prometheus-format `/metrics` endpoint. The metrics to report are listed in one file, `metrics.conf`. The Machine Agent reports them to AppDynamics as custom metrics, and a health rule turns any of them into an email.

```
Java app --TLS--> Capella
   | Java agent
   v
AppDynamics <-- Machine Agent <-- /metrics from every Capella node
   |
   +--> Health rule (metric above or below a limit) --> Policy --> Email
```

## What you need

**Accounts and access**

- A running Capella cluster: connection string, a database user and password, and your hosts' IPs on the allowed IP list.
- An AppDynamics SaaS account: controller URL, Account Name and Account Access Key (gear icon, License, Account).
- A Java application on the Couchbase Java SDK 3.x, and a Linux or macOS host for the Machine Agent.

**Downloads**

| What | Where |
|---|---|
| AppDynamics Java Agent (ZIP) | AppDynamics Downloads portal, Type: Java Agent |
| AppDynamics Machine Agent (ZIP) | Same portal, Type: Machine Agent, your OS (bundle with JRE if listed) |
| Capella root certificate | Capella UI (Connect), or the command in Step 1 |
| Couchbase Java SDK 3.x | Maven Central, pulled in by your build tool |
| JDK 8 or newer, Maven or Gradle | Only if not already installed |

**Network:** the app host reaches Capella on TCP 11207 and 18091 to 18096; the Machine Agent host reaches Capella on 18091 and 18093; both reach the controller on 443.

## Step 1. Connect to Capella over TLS

Capella's certificate chain is rooted in a Couchbase CA that Java and curl do not trust by default. You will see `self signed certificate in certificate chain` until you provide it. Download the root certificate from the Capella UI, or for a quick test extract it:

```bash
H=cb.xxxx.cloud.couchbase.com
echo | openssl s_client -connect "$H:18091" -servername "$H" -showcerts 2>/dev/null \
  | awk '/BEGIN CERT/{n++} {if(n)buf[n]=buf[n] $0 "\n"} END{printf "%s", buf[n]}' > capella-root.pem
```

Use it in the SDK:

```java
ClusterEnvironment env = ClusterEnvironment.builder()
    .securityConfig(SecurityConfig.enableTls(true)
        .trustCertificate(Paths.get("capella-root.pem")))
    .build();
Cluster cluster = Cluster.connect("couchbases://cb.xxxx.cloud.couchbase.com",
    ClusterOptions.clusterOptions(user, password).environment(env));
```

## Step 2. See the Capella calls in AppDynamics

Attach the Java agent. The controller host must be a bare hostname with no `https://`:

```bash
java -javaagent:/opt/appdynamics/java-agent/javaagent.jar \
  -Dappdynamics.controller.hostName=YOURNAME.saas.appdynamics.com \
  -Dappdynamics.controller.port=443 \
  -Dappdynamics.controller.ssl.enabled=true \
  -Dappdynamics.agent.accountName=ACCOUNT_NAME \
  -Dappdynamics.agent.accountAccessKey=ACCESS_KEY \
  -Dappdynamics.agent.applicationName=capella-demo \
  -Dappdynamics.agent.tierName=capella-client \
  -Dappdynamics.agent.nodeName=node1 \
  -jar your-app.jar
```

Check `agent.log` for `Registration information received`. A `401 Unauthorized` means the account name or access key is wrong; copy both from gear, License, Account.

**Trap: 0 calls.** AppDynamics only records Couchbase calls inside a business transaction. Web apps get one per request. A plain Java program has none, so put the work in one method and add a POJO rule (Applications, your app, Configuration, Instrumentation, Transaction Detection, Rules, Add: Custom Match Rule, Java, POJO, class equals your class, method equals `doWork`):

```java
public static void doWork(Cluster cluster, Collection col, int i) {   // the unit of work
    col.upsert("doc::" + i, JsonObject.create().put("i", i));
    col.get("doc::" + i);
}
```

The Flow Map then shows your tier calling Couchbase backends.

## Step 3. Report Capella metrics to AppDynamics

Capella exposes Couchbase Server metrics on port 18091. Every line of the output is a metric you can report:

```bash
curl -s --cacert capella-root.pem -u "$CB_USER:$CB_PASSWORD" "https://$H:18091/metrics" \
  | grep '^sys_cpu_utilization_rate'
# sys_cpu_utilization_rate{category="system",instance="ns_server",job="general"} 8.6
```

**Trap: one node.** The public hostname answers from a single node, so a busy node can hide behind a quiet one. The script below lists every node and combines the values (highest, lowest, average or sum).

Install the Machine Agent and add a script monitor:

```bash
unzip MachineAgent-*.zip -d /opt/appdynamics/machine-agent
mkdir -p /opt/appdynamics/machine-agent/monitors/CapellaMetrics
# save monitor.xml, capella-metrics.sh and metrics.conf (below) in that folder, then:
chmod +x /opt/appdynamics/machine-agent/monitors/CapellaMetrics/capella-metrics.sh
```

`monitor.xml`:

```xml
<monitor>
  <name>CapellaMetrics</name>
  <type>managed</type>
  <description>Reports Capella metrics from the Prometheus /metrics endpoint</description>
  <monitor-configuration></monitor-configuration>
  <monitor-run-task>
    <execution-style>periodic</execution-style>
    <execution-frequency-in-seconds>60</execution-frequency-in-seconds>
    <name>Capella Metrics</name>
    <display-name>Capella Metrics</display-name>
    <description>Capella metrics</description>
    <type>executable</type>
    <execution-timeout-in-secs>60</execution-timeout-in-secs>
    <task-arguments></task-arguments>
    <executable-task>
      <type>file</type>
      <file os-type="linux">capella-metrics.sh</file>
      <file os-type="mac">capella-metrics.sh</file>
    </executable-task>
  </monitor-run-task>
</monitor>
```

`metrics.conf` is the list of metrics to report, one per line. It starts with CPU, our test metric:

```text
# Metrics to report to AppDynamics. One per line:
#   Display name | Prometheus metric name | how to combine nodes: max, min, avg or sum | optional filter
# Lines starting with # are ignored.
CPU Utilization %|sys_cpu_utilization_rate|max
```

`capella-metrics.sh` prints one custom-metric line for every entry in `metrics.conf`:

```bash
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
```

**Trap: empty environment.** The Machine Agent runs scripts with no environment variables, so `export` does nothing. Put the credentials in a file next to the script:

```
CB_CONNSTR='couchbases://cb.xxxx.cloud.couchbase.com'
CB_USER='metrics-user'
CB_PASSWORD='the-password'
CAPELLA_CA_PEM='/opt/appdynamics/machine-agent/capella-root.pem'
```

```bash
chmod 600 /opt/appdynamics/machine-agent/monitors/CapellaMetrics/capella.env
```

Test the script, then start the Machine Agent with the same application, tier and node names as the Java agent:

```bash
/opt/appdynamics/machine-agent/monitors/CapellaMetrics/capella-metrics.sh
# name=Custom Metrics|Capella|CPU Utilization %,value=9,aggregator=OBSERVATION,time-rollup=CURRENT,cluster-rollup=INDIVIDUAL
```

```bash
java -Dappdynamics.controller.hostName=YOURNAME.saas.appdynamics.com \
  -Dappdynamics.controller.port=443 -Dappdynamics.controller.ssl.enabled=true \
  -Dappdynamics.agent.accountName=ACCOUNT_NAME \
  -Dappdynamics.agent.accountAccessKey=ACCESS_KEY \
  -Dappdynamics.agent.applicationName=capella-demo \
  -Dappdynamics.agent.tierName=capella-client \
  -Dappdynamics.agent.nodeName=node1 \
  -Dappdynamics.sim.enabled=false \
  -jar /opt/appdynamics/machine-agent/machineagent.jar
```

After a minute or two, each line of `metrics.conf` shows in Metric Browser under `Custom Metrics | Capella`. For CPU:

`Application Infrastructure Performance | capella-client | Individual Nodes | node1 | Custom Metrics | Capella | CPU Utilization %`

## Step 4. Alert on a metric

Create an email action (Alert and Respond, Actions), then a health rule per metric (Alert and Respond, Health Rules, +). CPU is the worked example:

| Tab | Setting |
|---|---|
| Overview | Name `Capella CPU > 50`. Data from last 5 min. Wait after violation 5 min. |
| Affected Entities | Type Tier / Node Health. Affects Nodes, then your node. |
| Critical Criteria | Metric by relative path `Custom Metrics|Capella|<display name from metrics.conf>`. For CPU: `Custom Metrics|Capella|CPU Utilization %`, greater than 50. Keep Any Node. |

**Trap: the metric picker.** The tree in the dialog lists only the standard hardware metrics. Choose Specify a Relative Metric Path and type the path above.

Last, one policy (Alert and Respond, Policies, +): trigger on Health Rule Violation Started (Warning and Critical), add your rules under Health Rule Scope, and attach the email action. Every new rule you create later is added to this same policy.

## Step 5. Test it

Test with CPU, because it is the easiest metric to push up. Set the rule to 5 first. Idle CPU is above that, so the alert fires without any load. Then set it back to 50 and generate load. This loop runs CPU-heavy queries and reads or writes no data, so run it on a test cluster:

```bash
# Optional load test. Starts 24 parallel CPU-heavy queries for 5 minutes (no data is read or written).
for i in $(seq 1 24); do
  ( while true; do
      curl -s --cacert capella-root.pem -u "$CB_USER:$CB_PASSWORD" \
        --data-urlencode 'statement=SELECT SUM(x*x) FROM ARRAY_RANGE(0,3000000) AS x' \
        "https://$H:18093/query/service" > /dev/null
    done ) &
done
sleep 300; kill $(jobs -p)
```

Watch Metric Browser, then Events, then your inbox. Put the value back to 50 afterwards.

**One alert per violation.** While the metric stays past the threshold the violation stays open, and AppDynamics does not send a new "Started" alert. To re-test, stop the load, wait for the metric to recover and the violation to clear, then run the load again. If you want repeat emails, add "Violation Continues" to the policy trigger.

## Step 6. Add any other metric

CPU was only the test. To report another metric, edit `metrics.conf`. No restart is needed, because the script reads the file every minute. Find the metric name:

```bash
# 1. Find the metric you want. Search the endpoint output by keyword, for example "resident":
curl -s --cacert capella-root.pem -u "$CB_USER:$CB_PASSWORD" "https://$H:18091/metrics" \
  | grep -i resident | grep -v '^#' | head
```

Then add one line with four fields separated by `|`: a display name, the exact metric name, how to combine the nodes (`max`, `min`, `avg` or `sum`) and an optional filter such as `bucket="travel-sample"` to report one bucket only:

```text
# Display name | metric name | combine nodes | optional filter
CPU Utilization %|sys_cpu_utilization_rate|max
Resident Ratio %|REPLACE_WITH_METRIC_NAME|min
Resident Ratio travel-sample %|REPLACE_WITH_METRIC_NAME|min|bucket="travel-sample"
```

Use `max` when high is bad (CPU) and `min` when low is bad (a resident ratio). After a minute the new name appears under `Custom Metrics | Capella`. Create a health rule as in Step 4 with that display name in the relative path, for example less than 90 for a resident ratio, and add it to the same policy.

## Good to know

- Capella also has built-in alerts with fixed levels. A custom 50% threshold needs a setup like this one.
- While CPU stays high the violation stays open and you get one alert. Add "Violation Continues" to the policy trigger for repeats.

## Common pitfalls

1. Capella's root certificate is not trusted by default.
2. The controller host must not include `https://`.
3. A plain Java program shows 0 calls until you add a business transaction.
4. The public Capella hostname reports one node, so read every node.
5. Machine Agent scripts run with an empty environment.
6. An open violation sends one alert, not a stream.
