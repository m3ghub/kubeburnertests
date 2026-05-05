# Test Viewer's Guide: What You're Looking At

> **Purpose:** Hand this to anyone watching a test run — customer, engineer, manager.
> Each section answers the same three questions:
> 1. What is this test doing?
> 2. What do I see on the screen right now?
> 3. What does a good result look like?

---

## Before any test: the three-pane setup

Open these in a terminal multiplexer (tmux/iTerm split) before starting any test.
They apply to all 22 tests.

```bash
# Pane A — live resource counts (update every 5s)
watch -n5 '
echo "Pods Running:    $(oc get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
echo "Pods Pending:    $(oc get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)"
echo "VMIs Running:    $(oc get vmi -A --no-headers 2>/dev/null | grep Running | wc -l)"
echo "VMIs Other:      $(oc get vmi -A --no-headers 2>/dev/null | grep -v Running | wc -l)"
echo "Nodes Ready:     $(oc get nodes --no-headers | grep Ready | wc -l)"
'

# Pane B — live events (what is the cluster actually doing right now)
oc get events -A --watch --sort-by='.lastTimestamp' 2>/dev/null | \
  grep -v "^NAMESPACE" | tail -1

# Pane C — node resource pressure
watch -n10 'oc adm top nodes 2>/dev/null'
```

Then run the test in a fourth pane.

---

## Tests 01–08: Core Kubernetes Tests

---

### Test 01 — Pod Density

**What the test does:**  
Creates a large number of pods as fast as the API server allows. Nothing inside the pods
runs — they use `pause` (a container that does nothing) to test scheduling speed, not
application performance.

**What you see on screen:**

```
# kube-burner output — you'll see lines like:
INFO Initialized job pod-density
INFO Iteration 1 running...
INFO podLatency: {P50: 1200ms, P95: 1800ms, P99: 2100ms, Max: 3400ms}
```

On `oc get pods -A --watch` you'll see hundreds of entries appearing simultaneously in
`ContainerCreating` → `Running`.

**What a good result looks like:**  
P99 pod-ready latency under 3,000 ms on a standard 3-worker cluster.  
If P99 exceeds 10s, the scheduler or kubelet is a bottleneck.

---

### Test 02 — Node Density

**What the test does:**  
Creates Deployments + Services targeting each worker node. Tests the Deployment controller
and Service endpoint propagation — not just pod scheduling.

**What you see:** Deployments appearing in `oc get deployments -A`. Services being created.
Watch `oc get endpoints -A` to see endpoint slices propagate.

**What a good result looks like:**  
P99 under 3,000 ms. Endpoint propagation visible within 5s of pod Ready.

---

### Test 03 — Cluster Density

**What the test does:**  
Creates multiple namespaces, each with a full application stack: Deployment + Service +
ConfigMap + Secret. Tests the control plane under a realistic multi-tenant workload.

**What you see:** Namespaces appearing in `oc get ns`. Multiple objects per namespace.

**What a good result looks like:**  
P99 pod-ready under 5s. No namespace stuck in `Terminating`.

---

### Test 04 — Cluster Density v2

**What the test does:**  
Same as Test 03 plus NetworkPolicies. Tests the SDN/OVN controller in addition to
the core API server load. This is heavier than Test 03.

**What you see:** Same as Test 03 plus `oc get networkpolicies -A` filling up.

**What a good result looks like:**  
P99 pod-ready under 8s. NetworkPolicy events visible in `oc get events -A`.

---

### Test 05 — Churn

**What the test does:**  
Creates a set of resources, waits, then deletes a percentage of them and recreates —
cycling continuously. This tests whether the control plane can keep up with a
constant stream of object creation and deletion without falling behind.

**What you see:**  
Pod count fluctuating in Pane A. Pods appearing in `ContainerCreating` while others are
`Terminating`. The net count stays roughly constant.

**What a good result looks like:**  
Each churn cycle completes in roughly the same time. If cycles slow down over time,
the garbage collector or etcd compaction is lagging.

---

### Test 06 — Read Workload

**What the test does:**  
Issues LIST and GET calls to the API server at high rate. Tests read throughput
and API server cache hit rate. No objects are created.

**What you see:**  
Nothing visible changes in the cluster. The kube-burner output shows request/response
counts and latencies. Watch the API server latency metric to see it spike.

**What a good result looks like:**  
Zero errors. API server P99 read latency under 200ms.

---

### Test 07 — Patch Workload

**What the test does:**  
Issues PATCH calls to update existing objects (Deployments, ConfigMaps, etc.) at high rate.
Tests write throughput and etcd write pressure without the overhead of object creation.

**What you see:**  
`oc get events -A` shows Update events. etcd write rate metric climbs.

**What a good result looks like:**  
Zero errors. All patch operations confirm the expected field value after update.

---

### Test 08 — Delete Workload

**What the test does:**  
Deletes a batch of pre-created objects. Tests the garbage collection pipeline —
deletion propagation through ownerReferences, finalizer removal, and etcd compaction.

**What you see:**  
Objects disappearing from `oc get` output. Count in Pane A drops.

**What a good result looks like:**  
All objects deleted within the configured timeout. No objects stuck in `Terminating`.

---

## Tests 09–12: KubeVirt & Observability

---

### Test 09 — KubeVirt Density (VM lifecycle baseline)

**What the test does:**  
Creates N VirtualMachines, starts them (waits for Running), stops them, then deletes them.
This is the **gateway test for OpenShift Virtualization** — if this doesn't pass, no
other VM test is meaningful.

**What you see:**  
```bash
# Watch VMIs transitioning
oc get vmi -A -w -o custom-columns="NAME:.metadata.name,PHASE:.status.phase,NODE:.status.nodeName"
```

You'll see the Phase column cycle: `(blank)` → `Scheduling` → `Scheduled` → `Running` → then deleted.

**The VM state machine:** Every VMI passes through these states:
- **Scheduling** — KubeVirt scheduler is finding a node
- **Scheduled** — virt-handler on the target node has accepted the VMI
- **Running** — virt-launcher pod is running, guest OS is up
- *stop is triggered* → VMI disappears, VM returns to stopped state

**What a good result looks like:**  
All VMs reach Running. P99 VMI-ready latency under 90s. Zero stuck VMIs.

---

### Test 10 — Health Check

**What the test does:**  
Runs `kube-burner health-check` which queries the cluster's basic API endpoints and
reports whether the cluster is healthy enough to run benchmarks.

**What you see:**  
A pass/fail output line: `"Cluster is healthy."` or a list of failing checks.

**What a good result looks like:**  
`"Cluster is healthy."` Always run this first.

---

### Test 11 — Check Alerts

**What the test does:**  
Queries Prometheus for any firing alerts above a configurable severity threshold.
Surfaces any cluster health problems that would corrupt benchmark results.

**What you see:**  
```
INFO Alerts found: 3 (all info severity — acceptable)
WARN Alert: KubeletTooManyPods — node worker-2 is at 95% pod capacity
```

**What a good result looks like:**  
Zero `warning` or `critical` alerts. `info` alerts are acceptable.

---

### Test 12 — Index Metrics

**What the test does:**  
Captures a snapshot of Prometheus metrics and stores them to the configured indexer
(local files or Elasticsearch/OpenSearch). No load is applied — this is a baseline capture.

**What you see:**  
Files appearing in `./collected-metrics/<uuid>/metrics/`.

**What a good result looks like:**  
Metrics files written without error. Used as a "before" snapshot for comparison after changes.

---

## Tests 13–17: Advanced Virtualization

---

### Test 13 — VM Live Migration

**What the test does:**  
Boots a VM on one node, then moves it — live, while it is running — to a different node.
The guest OS sees no interruption. Tests the migration pipeline end-to-end.

**What you see:**
```bash
# Watch the migration object
oc get vmim -A -w

# See the node change
oc get vmi -A -o wide
```

Before migration: `NODE: worker-0`  
After migration: `NODE: worker-1`  
The migration object shows: `Pending` → `Scheduling` → `Preparing` → `TargetReady` → `Running` → `Succeeded`

**What to say to a customer:** *"This VM is running right now. Watch the node column. In about 30 seconds, that VM will have moved to a different physical host — with zero downtime to the guest OS. That's live migration."*

**What a good result looks like:**  
P99 migration latency under 120s. `vmim.status.phase = Succeeded`. Source ≠ destination node.

---

### Test 14 — VM Density Scaling

**What the test does:**  
Scales up to N VMs simultaneously across all worker nodes, then scales back down.
Tests the KubeVirt scheduler and virt-handler's ability to handle concurrent VM creation.

**What you see:**  
A burst of VMI creation events, then the Running count climbing in Pane A, then
a burst of deletions.

**What a good result looks like:**  
All VMs reach Running. P99 scale-up latency proportional to count (roughly linear).

---

### Test 15 — VM Churn

**What the test does:**  
Continuously creates a batch of VMs, waits for them all to reach Running, then deletes
them all — repeating for N cycles. Tests endurance of the VM lifecycle pipeline.

**What you see:**  
Pane A VMI count rises → holds → drops → rises again, in regular cycles.
Watch `virt-controller` memory to ensure no leak across cycles.

**What a good result looks like:**  
Consistent cycle time (not slowing down). Zero VMIs stuck in Terminating.

---

### Test 16 — VM Pause/Unpause Storm

**What the test does:**  
Boots N VMs, then pauses them all simultaneously, then unpauses them all simultaneously.
Tests `virt-handler`'s ability to process parallel pause/unpause events without dropping any.

**What you see:**
```bash
# Watch the Paused condition on VMIs
oc get vmi -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Paused")].status}{"\n"}{end}'
```

All VMIs transition to `Paused=True` within seconds of each other, then back to `Paused=False`.

**What a good result looks like:**  
All N VMIs paused and unpaused with no stragglers. Pause latency P99 under 10s.

---

### Test 17 — VM Hot-plug Storage

**What the test does:**  
Boots a VM, then attaches a new disk to it while it is running (hot-plug), verifies the
disk appears in the VMI's status, then detaches it. Tests the CDI + KubeVirt volume
attachment pipeline.

**What you see:**
```bash
# Watch the DataVolume being created and becoming ready
oc get datavolume -A --watch

# Watch the volume appearing in VMI status
oc get vmi <name> -o jsonpath='{.status.volumeStatus}' | python3 -m json.tool
```

**What a good result looks like:**  
DataVolume reaches `Succeeded`. VMI status shows the hotplugged volume. Remove completes cleanly.

---

## Tests 18–22: kube-burner-ocp (separate binary)

---

### Test 18 — OCP Node Density

**What the test does:**  
Schedules 245 pods per worker node using OpenShift-tuned resource settings and collects
the full OCP metrics profile (etcd, API server, scheduler).

**What you see:**  
Pod count in Pane A climbing rapidly. Node memory rising in Pane C.

**OpenShift console:** Workloads → Pods → filter `node-density`

**What a good result looks like:**  
P99 pod-ready under 15s. `etcd_mvcc_put_total` rate normalizes within 60s of completion.

---

### Test 19 — OCP Cluster Density v2

**What the test does:**  
Creates 500 namespaces each containing Deployment + Service + Route + ConfigMap + Secret +
NetworkPolicy. The most production-representative control-plane test.

**What you see:**  
Projects appearing in OpenShift console. Routes getting `Accepted` status.

**OpenShift console:** Home → Projects (count climbing) and Networking → Routes

**What a good result looks like:**  
P99 pod-ready under 15s. All Routes show `Accepted`. Zero namespaces stuck in `Terminating`.

---

### Test 20 — OCP VMI Density

**What the test does:**  
Creates N VMIs per worker node simultaneously. The flagship OpenShift Virtualization scale test.

**What you see:**  
VMI count climbing in Pane A. Worker node memory rising in Pane C.

**OpenShift console:** Virtualization → VirtualMachines + Observe → Metrics →
`kubevirt_vmi_phase_count{phase="Running"}` climbing in real time.

**What a good result looks like:**  
All VMIs Running. P99 VMI-ready under 90s (25/node on 3-worker). Zero failed.

---

### Test 21 — OCP Web Burner

**What the test does:**  
Creates realistic web application namespaces: multi-container Deployments, TLS Routes,
HPAs, and NetworkPolicies. The most visually impressive test for product demos.

**What you see:**  
HPAs appearing in Workloads → HorizontalPodAutoscalers. Routes with TLS badges in
Networking → Routes.

**What a good result looks like:**  
All HPAs reach their min replicas. All Routes show `Accepted` with TLS status.

---

### Test 22 — OCP VMI Density + Churn (Endurance)

**What the test does:**  
Brings up a density of VMIs, then continuously deletes and recreates 20% of them in cycles.
This is the endurance/soak test — run for 30+ minutes to surface leaks and backlogs.

**What you see:**  
VMI count fluctuating in cycles. The most important thing to watch is
`virt-controller` memory in `oc top pods -n kubevirt`.

**What a good result looks like:**  
virt-controller RSS flat or gently growing. No VMIs stuck in Terminating across cycles.
Churn cycle duration consistent (not growing) across all N cycles.

---

## Universal signals: what bad looks like

| Signal | What you see | What it means |
|---|---|---|
| Pods stuck in `Pending` > 5 min | Pane A: Pending count not dropping | Scheduler backlog or node pressure |
| VMIs stuck in `Scheduling` > 5 min | `oc get vmi -A` showing `Scheduling` long-term | virt-controller queue backed up |
| Pods stuck in `Terminating` > 2 min | `oc get pods -A \| grep Terminating` | Finalizer not removed; check kubelet |
| Node `NotReady` | Pane C shows missing node | Node health issue — stop the test |
| etcd leader election in events | `oc get events -A \| grep leader` | etcd instability — stop the test |
| kube-burner `ERROR` lines | Test output shows failures | Check `alerts.json` in results folder |

---

## After the test: reading results

```bash
# All test results land here
ls ./collected-metrics/<uuid>/

# The numbers that matter
cat ./collected-metrics/*/podLatency.json    | python3 -m json.tool
cat ./collected-metrics/*/vmiLatency.json    | python3 -m json.tool
cat ./collected-metrics/*/serviceLatency.json | python3 -m json.tool
cat ./collected-metrics/*/alerts.json        | python3 -m json.tool
```

**How to read the latency numbers:**

```json
{
  "P50":  2300,   ← half of all pods/VMIs were ready within 2.3s
  "P95":  5100,   ← 95% were ready within 5.1s
  "P99":  8400,   ← 99% were ready within 8.4s  (this is your SLA number)
  "Max": 12100    ← the single slowest one
}
```

The **P99** is what you quote to a customer.
P99 under 60s for VMIs = healthy platform.
P99 under 5s for pods = healthy control plane.
