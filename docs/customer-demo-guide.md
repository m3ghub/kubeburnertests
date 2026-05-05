# Customer Demo Guide: Visualizing kube-burner Tests in Action

> **Goal:** Show a customer the _live impact_ of benchmark tests on an OpenShift cluster.
> This guide walks you through the exact screens to open, the Prometheus queries to run,
> and the narrative to tell as results appear in real time.

---

## Before You Start

**Open four panes in your terminal:**

```bash
# Pane 1 — watch kube-burner output
# (where you run the test)

# Pane 2 — watch cluster-level resource usage
watch -n5 'oc adm top nodes'

# Pane 3 — watch key object counts live
watch -n3 'echo "=== Running Pods ===" && oc get pods -A --field-selector=status.phase=Running --no-headers | wc -l && echo "=== Running VMIs ===" && oc get vmi -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l && echo "=== Pending Objects ===" && oc get pods vmi -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l'

# Pane 4 — watch events to see what's happening
oc get events -A --watch --field-selector=reason=Scheduled
```

**Open the OpenShift Web Console in a browser:**  
`https://console-openshift-console.apps.<your-cluster-domain>`

---

## Act 1: The Control Plane Under Load

**Run:** Test 18 (node-density) or Test 19 (cluster-density-v2)

### What to show the customer

**Step 1 — Start the test and immediately open the console:**

```
Observe → Metrics → (paste these queries one at a time)
```

| Story | PromQL query |
|---|---|
| "The API server is handling thousands of requests per second" | `sum(rate(apiserver_request_total[1m]))` |
| "etcd is absorbing the write burst" | `rate(etcd_mvcc_put_total[1m])` |
| "The scheduler is racing to place pods" | `rate(scheduler_scheduling_attempt_duration_seconds_count[1m])` |
| "Pod creation latency by percentile" | `histogram_quantile(0.99, sum(rate(scheduler_e2e_scheduling_duration_seconds_bucket[5m])) by (le))` |

**Step 2 — Navigate to Workloads → Pods:**

- Filter by namespace: type `node-density` or `cluster-density` in the namespace filter
- Set the refresh to 15 seconds
- **Narrate:** "Right now, kube-burner is creating 245 pods per worker node. You can see each pod appearing here and transitioning from Pending → Running. This is the same load your cluster would see during a mass application rollout."

**Step 3 — Navigate to Compute → Nodes → (any worker):**

- Show the CPU and Memory utilization graphs
- **Narrate:** "Notice the memory rising as new pods get scheduled. The kubelet is starting containers, pulling images, and reporting back to the API server — all concurrently."

---

## Act 2: OpenShift Virtualization at Scale

**Run:** Test 20 (vmi-density)

### The five things to show during this test

**1. The VM state machine in action**

```bash
# Run this as the test starts — it shows every VMI transitioning
oc get vmi -A -w -o custom-columns=\
"NAME:.metadata.name,NAMESPACE:.metadata.namespace,PHASE:.status.phase,NODE:.status.nodeName"
```

**Narrate:** "Every row you see appearing is a new virtual machine. Watch the PHASE column: it goes from blank → Scheduling → Scheduled → Running. Each transition is a different component of OpenShift Virtualization doing its job."

**2. virt-controller queue depth**

```bash
# In the OpenShift console: Observe → Metrics
kubevirt_virt_controller_ready_vmi_watcher_goroutines
```

Or in terminal:
```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -sg 'http://localhost:9090/api/v1/query?query=kubevirt_virt_controller_ready_vmi_watcher_goroutines' \
  | python3 -m json.tool
```

**Narrate:** "This metric shows how many virtual machines virt-controller is tracking in real time. It directly tells you how hard the KubeVirt control plane is working."

**3. Per-node VM count**

```bash
# See exactly which VMs are on which node
oc get vmi -A -o json | \
  python3 -c "
import json, sys, collections
data = json.load(sys.stdin)
counts = collections.Counter(i['status'].get('nodeName','unscheduled') for i in data['items'])
for node, count in sorted(counts.items()):
    print(f'{count:3d}  {node}')
"
```

**Narrate:** "Each worker node is running N VMs. This shows the scheduler is distributing the workload evenly. In a real customer environment, this would be their VM density baseline — the maximum they can run before adding nodes."

**4. Node memory under pressure**

In the console: **Compute → Nodes → (worker-0) → Memory graph**

```bash
# Or via Prometheus
oc exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -sg 'http://localhost:9090/api/v1/query?query=node_memory_MemAvailable_bytes' \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data['data']['result']:
  gb = float(r['value'][1]) / 1e9
  print(f'{r[\"metric\"].get(\"node\",\"?\"):50s}  {gb:.1f} GB free')
"
```

**Narrate:** "As we add more VMs, the available memory on each node drops. This graph shows us exactly when we'll hit the memory ceiling and need to add workers."

**5. The final result — the number that matters**

When the test ends, kube-burner outputs:

```
INFO vmiLatency P99: 67.3s    ← this is your VM boot SLA
INFO vmiLatency P95: 52.1s
INFO vmiLatency P50: 38.4s
INFO Total VMIs created: 75
INFO Failed: 0
```

**Narrate:** "The P99 VMI latency is 67 seconds. That means 99% of all VMs came up within 67 seconds of being requested. This is the number we commit to in a support contract. Run the same test after a tuning change and watch this number drop."

---

## Act 3: VM Lifecycle Operations Under Stress

**Run:** Test 13 (vm-live-migration) at scale

### What to show

```bash
# Watch migrations progressing
oc get vmim -A -w

# See source → destination node for each migration
oc get vmim -A -o json | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data['items']:
  name = m['metadata']['name']
  phase = m.get('status', {}).get('phase', 'Unknown')
  source = m.get('status', {}).get('sourceNode', '?')
  target = m.get('status', {}).get('targetNode', '?')
  print(f'{name:40s}  {phase:15s}  {source} → {target}')
"
```

**Narrate:** "This is live migration — moving a running virtual machine from one physical host to another with zero downtime. kube-burner is triggering 10 simultaneous migrations. Watch each one showing the source node and destination node. The guest OS never sees an interruption."

---

## Act 4: The "Push to the Limit" Demo

For maximum impact, run tests in sequence and show the degradation curve:

```bash
# Step 1: Baseline — 10 VMIs per node
VMIS_PER_NODE=10 ./examples/workloads/ocp/vmi-density-ocp.sh
# Record P99

# Step 2: Double — 20 VMIs per node
VMIS_PER_NODE=20 ./examples/workloads/ocp/vmi-density-ocp.sh
# Record P99

# Step 3: Triple — push toward the limit
VMIS_PER_NODE=40 ./examples/workloads/ocp/vmi-density-ocp.sh
# Record P99 — watch it start climbing

# Step 4: Show the churn endurance
./examples/workloads/ocp/vmi-density-churn.sh
```

**Narrate:** "Here's the degradation curve. At 10 VMs per node, P99 is 45 seconds. At 20, it's 72 seconds. At 40, it climbs to 180 seconds — that's the knee in the curve. That's the density limit for this cluster configuration. Now you know exactly when to add nodes."

---

## Key Prometheus Dashboard Panels to Open

Open these in the OpenShift console (Observe → Dashboards) or in a Grafana instance:

| Panel | Why it matters to a customer |
|---|---|
| **Kubernetes / API Server** → Request Rate | Shows the platform is not overwhelmed |
| **etcd** → DB Size | Shows you're not filling etcd |
| **Kubernetes / Compute Resources / Node** | Per-node CPU/memory pressure |
| **KubeVirt / Infrastructure Resources** | virt-controller, virt-handler, virt-api load |

---

## After the Test: Reading kube-burner Results

Results are written to `./collected-metrics/<uuid>/`:

```bash
ls ./collected-metrics/
# → <uuid>/
#     ├── podLatency.json      (P50/P95/P99 pod latencies)
#     ├── vmiLatency.json      (P50/P95/P99 VMI latencies)
#     ├── serviceLatency.json  (service endpoint propagation)
#     ├── alerts.json          (any Prometheus alerts that fired)
#     └── metrics/             (raw Prometheus samples as TSDB snapshots)

# Pretty-print the VMI latency results
cat ./collected-metrics/*/vmiLatency.json | python3 -m json.tool
```

**The number to highlight to a customer:** P99 latency.

- Under 60s for VMI ready: ✅ Platform is healthy
- 60–120s: ⚠️ Investigate etcd or node memory
- Over 120s: ❌ Scaling needed or configuration tuning required

---

## Cleanup After Demo

```bash
# Remove all test namespaces (kube-burner creates namespaces with specific prefixes)
oc get ns | grep -E 'node-density|cluster-density|vmi-density|web-burner' | awk '{print $1}' | xargs oc delete ns

# Verify cleanup
oc get vmi -A
```

---

## Pro Tips for Customer Demos

1. **Pre-warm the cluster** — run a small test before the demo so image pulls are cached
2. **Use a terminal multiplexer** — tmux with 3 panes (kube-burner output, `oc get vmi -A -w`, `oc adm top nodes`) is the most impressive live view
3. **Have the Prometheus URL ready** — being able to pull up a live metric during the explanation is powerful
4. **Quote the numbers** — "P99 of 67 seconds" is more credible than "it's fast." Write the numbers on a whiteboard as you go
5. **Run the failing test first** — push `VMIS_PER_NODE` too high on purpose, show the P99 climb, then explain "this is what it looks like when you're over-provisioned — now let me show you the healthy baseline"
