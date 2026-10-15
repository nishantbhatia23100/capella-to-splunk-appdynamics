# Monitoring Couchbase Capella with AppDynamics (Java SDK)

Tested 2026-10-14 on macOS with a Capella cluster, an AppDynamics SaaS free trial, Java agent 26.9.0, Couchbase Java SDK 3.7.5 and Temurin JDK 11.

## 1. How the integration works

Capella is a managed service, so you cannot install an AppDynamics agent on its nodes. You monitor it from the application side:

```
Java app (Couchbase SDK)  --TLS-->  Capella cluster
   |  AppDynamics Java agent (-javaagent)
   v
AppDynamics SaaS controller
```

The agent instruments the Couchbase SDK and records each KV and query call as an exit call to a Couchbase backend. It reports call counts, response time, errors and snapshots per business transaction.

What this gives you: latency and errors for the calls your application makes to Capella, as seen by the application.

What it does not give you: server-side cluster metrics (CPU, memory, disk, ops/sec, node health). Those come from Capella's own metrics (Capella UI, or its Prometheus metrics endpoint). This guide did not test that path.

## 2. What we saw (test result)

- Flow Map: `capella-client` (Java) to 2 Couchbase backends, shown as async calls.
- Business transaction `capella-doWork`: 97 calls, about 49 calls/min, 418 ms average, in the first few minutes.
- Slow Response Times tab: individual snapshots of 700 to 1,300 ms. The test ran from a laptop over the internet to Capella, so this is network round trip plus several Couchbase calls per transaction, not a cluster problem.
- Registration confirmed in the agent log: `Registered BT Name[capella-doWork]` and a Couchbase backend resolved.
- Database Calls page was empty. That page lists SQL databases. Couchbase calls appear on the transaction Flow Map instead.
- The Errors panel showed no data in our screenshot even though the app reads missing documents on purpose (the SDK exception is caught inside `doWork`). Do not assume caught SDK exceptions are reported as errors.

## 3. Prerequisites

| Item | Notes |
|---|---|
| Capella cluster | Running, with a bucket, a database access user and password, and your IP on the allowed list |
| Capella root certificate | Needed by curl and Java (see step 2) |
| AppDynamics SaaS account | Free trial from the Cisco AppDynamics trial page. This is separate from Splunk Cloud |
| JDK 8 or newer | A JRE is not enough, Maven needs `javac`. We used Temurin 11 |
| Maven | We used 3.9.9, kept in `tools/` |

## 4. Steps

### Step 1. Check the Capella API key (optional)
```bash
export CAPELLA_API_KEY='...'
./01-check-capella.sh        # lists your organizations
```
This only proves the management API key works. The application does not use it. It uses the database user.

### Step 2. Get the Capella root certificate
Capella clusters use a certificate chain rooted in a Couchbase CA that is not in any public trust store. curl fails with "self signed certificate in certificate chain", and Java rejects it as well.

Download the root certificate from the Capella UI (cluster, Connect, Security), or for a quick test extract it from the server chain:
```bash
export CB_CONNSTR='couchbases://cb.xxxx.cloud.couchbase.com'
export CB_USER='...'; read -s "CB_PASSWORD?DB password: "; export CB_PASSWORD
./02-fetch-capella-ca.sh      # writes capella-root.pem, then tests the endpoint
```
Expect `capella data endpoint: 200`. Taking the root from the same connection is fine for a test. For production, use the UI download and compare fingerprints.

### Step 3. Build the sample app
The app (`src/main/java/demo/CapellaLoad.java`) connects over TLS using `capella-root.pem`, then loops: upsert, get, a N1QL count every fifth iteration, and a deliberate missing-document read every 20th. Each iteration runs inside `doWork(...)`, which matters for step 7.

Key SDK setting:
```java
SecurityConfig.enableTls(true).trustCertificate(Paths.get("capella-root.pem"))
```

Install Maven and a JDK (project-local in `tools/`), then run once without AppDynamics to prove Capella connectivity:
```bash
CB_BUCKET=travel-sample RUN_SECONDS=30 ./03-run.sh
```
Expect `Connected to travel-sample` and `i=0 count=[...]` lines. If it times out, check the cluster's allowed IPs.

### Step 4. Get an AppDynamics controller
1. Start the free trial. You receive a SaaS URL like `<name>.saas.appdynamics.com`.
2. Log in and open the gear menu, then License, then the Account section. Note the Account Name and Account Access Key.

### Step 5. Download the Java agent
Use the Getting Started wizard (Java) in the controller, or the AppDynamics download portal. Choose the ZIP (not RPM, which is Linux only). Unzip it so that `appdynamics-agent/javaagent.jar` exists:
```bash
mkdir -p appdynamics-agent && unzip -q ~/Downloads/AppServerAgent-*.zip -d appdynamics-agent
```
The `conf/controller-info.xml` in the download is empty. We pass the settings as JVM flags instead (next step).

### Step 6. Configure and run with the agent
Export these in your shell, or put them in `.env` (gitignored, never commit it):
```bash
export APPD_CONTROLLER_HOST='<name>.saas.appdynamics.com'   # bare hostname, no https://
export APPD_ACCOUNT_NAME='<Account Name from the License page>'
read -s "APPD_ACCESS_KEY?AppD access key: "; export APPD_ACCESS_KEY
```
`03-run.sh` attaches the agent when `appdynamics-agent/javaagent.jar` and `APPD_ACCESS_KEY` are present. The flags it passes:

```
-javaagent:appdynamics-agent/javaagent.jar
-Dappdynamics.controller.hostName=<host>   -Dappdynamics.controller.port=443
-Dappdynamics.controller.ssl.enabled=true
-Dappdynamics.agent.accountName=<account>  -Dappdynamics.agent.accountAccessKey=<key>
-Dappdynamics.agent.applicationName=capella-demo
-Dappdynamics.agent.tierName=capella-client  -Dappdynamics.agent.nodeName=node1
```

Run it:
```bash
RUN_SECONDS=300 ./03-run.sh 2>&1 | tee run.log | grep --line-buffered -E "AppDynamics|Connected|count=|ERROR|Exception" | cut -c1-200
```
Expect `>> AppDynamics agent ATTACHED`. In `appdynamics-agent/ver*/logs/node1/agent.*.log` look for `Registration information received Node ID[...]`. A `401 Unauthorized` means the account name or key is wrong.

### Step 7. Create the business transaction (required for a plain Java app)
AppDynamics only records exit calls (Couchbase calls) inside a business transaction. A web app gets these automatically from incoming HTTP requests. A standalone program has no entry point, so the application shows 0 calls until you define one.

In the controller: Applications, `capella-demo`, Configuration, Instrumentation, Transaction Detection, Rules, then **Add**:

| Field | Value |
|---|---|
| Rule type | Custom Match Rule |
| Agent type | Java |
| Entry point type | POJO |
| Name | `capella-doWork` |
| Scope | Default Scope |
| Class name | equals `demo.CapellaLoad` |
| Method name | equals `doWork` |

Save, then restart the app. The agent log should show `Registered BT Name[capella-doWork]`.

For a real application you would not need this step if it is a servlet or Spring web app, because the agent detects those entry points automatically.

### Step 8. Verify in the controller
Wait 2 to 3 minutes of traffic, then check:
1. Applications, `capella-demo`: the tile shows calls per minute and response time.
2. Business Transactions, `capella-doWork`: dashboard with Flow Map (`capella-client` to Couchbase backends), load, response time.
3. Slow Response Times and Transaction Snapshots: individual calls. Open a snapshot and its call graph to see time spent in Couchbase calls.
4. DB Queries tab on the transaction: query statements, where captured.

### Step 9. Health rules and alerts (tested)
An error-rate alert on the Capella calls fired and sent an email about two minutes after errors started: "Errors per Minute's value 4.00 was greater than the threshold 1.00 for the last 4 minutes". The latency rule was created the same way, but its violation was not confirmed in the test.

1. Health rules (Alert & Respond, Health Rules, +). Type: Business Transaction Performance, affecting `capella-doWork` only.

| Rule | Critical condition |
|---|---|
| `capella-doWork slow` | Average Response Time (ms) is greater than a specific value, 300 |
| `capella-doWork errors` | Errors per Minute is greater than a specific value, 1 |

   On the Overview tab set "Use data from last" to 5 minutes and "Wait Time after Violation" to 5. Leave "15 times in the last 30 min" unticked. Changing the rule type resets the conditions, so set the type first.
2. Action (Alert & Respond, Actions, Create): Send an Email. Under Email / SMS Configuration keep the built-in SMTP host and port and fill in a From Address.
3. Policy (Alert & Respond, Policies, +): name `capella-alerts`, trigger on Health Rule Violation Started (Warning and Critical), Health Rule Scope "These Health Rules" with both rules added through +, and the email action.
4. Trigger it. Errors caught inside the method are not counted by AppDynamics, so `INJECT_ERROR_EVERY=N` makes every Nth call fail out of `doWork`:
```bash
INJECT_ERROR_EVERY=3 RUN_SECONDS=600 ./03-run.sh
```
The violation appears under Alert & Respond, Health Rules and in the application's Events within 3 to 5 minutes, and the email arrives.

### Step 10. Alert on Capella node CPU (tested at 5 and 50)
The Java agent only sees the app's calls, so node CPU comes from Capella's own `/metrics` endpoint (port 18091) through the Machine Agent. The full customer version is in `guide/Capella-AppDynamics-Setup-Guide.pdf`.

1. Check the endpoint: `./04-check-metrics.sh` prints `sys_cpu_utilization_rate` (CPU %).
2. The public hostname answers from one node only. `capella-cpu.sh` therefore lists every node (`system:nodes`) and reports the highest CPU as `Custom Metrics|Capella|CPU Utilization %`.
3. Download the Machine Agent ZIP from the AppDynamics portal, unzip to `machine-agent/`, and copy `machine-agent-ext/CapellaCpu` into `machine-agent/monitors/`.
4. The Machine Agent runs scripts with an empty environment, so `05-run-machine-agent.sh` writes the credentials to `monitors/CapellaCpu/capella.env` (mode 600) and deletes it on exit. Start it with `./05-run-machine-agent.sh` and keep it running. It uses the same application, tier and node names as the Java agent.
5. Metric Browser path: `Application Infrastructure Performance|capella-client|Individual Nodes|node1|Custom Metrics|Capella|CPU Utilization %`.
6. Health rule: type Tier / Node Health, affects Nodes then `node1`. The metric picker does not list custom metrics, so choose Specify a Relative Metric Path: `Custom Metrics|Capella|CPU Utilization %`, greater than a specific value. Add the rule to the `capella-alerts` policy.
7. Drive load with `BURN_THREADS=24 BURN_SECONDS=300 ./07-cpu-burn.sh`. `08-diagnose-nodes.sh` lists the nodes and each node's CPU.

Result: with CPU at about 100% the policy sent an email at a threshold of 5 ("CPU Utilization %'s value 100.00 was greater than the threshold 5.00 for the last 5 minutes"), and the alert also fired at the real threshold of 50 ("CPU Utilization %'s value 100.00 was greater than the threshold 50.00", node1).

Behavior to know: while CPU stays high the violation stays open and AppDynamics sends no new "Started" alert. To re-test, stop the load, wait for CPU to drop and the violation to clear, then run the load again. To get repeat emails, add Violation Continues to the policy trigger.

## 5. Troubleshooting (everything we hit)

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (60) SSL certificate problem: self signed certificate in certificate chain` | Capella root CA is not in your trust store | Step 2, use `--cacert capella-root.pem` or the SDK `trustCertificate` |
| `No compiler is provided ... JRE rather than a JDK` | Only a JRE installed | Install a JDK (we used a portable Temurin 11 in `tools/`) |
| Agent log: `401 Unauthorized` on registration | Wrong account name or access key. In our case the key was entered wrongly | Copy both from gear, License, Account. Re-enter the key with `read -s` and check its length |
| Controller shows `hostName=https://...` in the agent log | Scheme included in `APPD_CONTROLLER_HOST` | Use a bare hostname. `03-run.sh` strips it |
| Application visible but 0 calls, no Couchbase backend | No business transaction entry point in a standalone app | Step 7, POJO rule on `demo.CapellaLoad.doWork` |
| Run shows `Running WITHOUT AppDynamics agent` or `CB_CONNSTR not set` | Variables not exported in that shell | Export them in the same shell, or use `.env` |
| No output from the `grep` pipeline for minutes | `grep` buffers when piped | Use `grep --line-buffered` |
| Agent log: `NoSuchMethodException ... GetRequest.statement()` | Agent tries to read a query statement from a KV call | Harmless noise for KV operations |

## 6. Security notes
- Keep the database password, Capella API key and AppDynamics access key out of git. `.env` is in `.gitignore`.
- The AppDynamics access key was visible in a screenshot during testing. For a real environment, rotate any key that has been displayed or shared. For the trial this is optional.
- `capella-root.pem` is a public CA certificate, not a secret.

## 7. Not covered
- Capella server-side metrics (Prometheus endpoint) into AppDynamics or an OpenTelemetry collector.
- Capella's own alerting (cluster alerts in the Capella UI), the latency rule's violation (created, not confirmed), and the shell version of the CPU load loop.
- AppDynamics dashboards.
- Running the agent in a container or Kubernetes.
- Whether the two Couchbase backends correspond to key-value and query services was not verified.
