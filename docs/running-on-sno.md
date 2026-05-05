# Running Kube-Burner on Single Node OpenShift (SNO)

This guide covers SNO-specific considerations for running kube-burner benchmarks, based on live testing against an OCP 4.21.8 SNO bare-metal cluster.

---

## What is SNO?

Single Node OpenShift (SNO) deploys all control plane, infrastructure, and worker roles onto a single node. This is common in edge deployments and Red Hat internal lab environments.

**Key characteristics that affect kube-burner:**
- All roles on one node: `control-plane`, `master`, `worker`
- **Hard 250-pod limit** per node — shared between system pods and your workloads
- System pods consume the majority of that capacity
- No horizontal distribution — all pods land on the same node
- Control plane components compete with benchmark workloads for CPU/memory

---

## Cluster Details (Validated Environment)

| Property | Value |
|---|---|
| OCP Version | 4.21.8 |
| Kubernetes | v1.34.5 |
| RHCOS | 9.6.20260324-0 (Plow) |
| CRI-O | 1.34.6 |
| Node roles | control-plane, master, worker |
| CPU (allocatable) | 71,500m (71.5 vCPU) |
| Memory (allocatable) | ~124 GiB |
| Pod limit | 250 |
| Architecture | AMD64 |
| Installed operators | Network Observability v1.11.1, DevWorkspace, Web Terminal |

---

## The SNO Pod Limit — Critical Constraint

> **This is the most important thing to understand before running kube-burner on SNO.**

SNO enforces a hard **250-pod limit** per node. System pods (monitoring, networking, OLM, operators) typically consume **220–225 pods** on a standard OCP 4.21 SNO install. That leaves only **25–30 slots** for your benchmark workloads.

### How to Calculate Available Slots

```bash
# Check how many pods are currently running
oc get pods -A --field-selector=status.phase=Running --no-headers | wc -l

# Check node limit
oc get node -o jsonpath='{.items[0].status.allocatable.pods}'
```

**Example from this cluster:**
```
Running pods (system): 224
Node pod limit:         250
Available for workloads: 26
```

### What Happens If You Exceed the Limit

Pods go into `Pending` with this scheduler event:

```
Warning  FailedScheduling  0/1 nodes are available: 1 Too many pods.
         no new claims to deallocate, preemption: 0/1 nodes are available:
         1 No preemption victims found for incoming pod.
```

kube-burner will block indefinitely at `Waiting up to Xm0s for actions to be completed` and the job will never complete.

### Right-Sizing Your Workload for SNO

Use this formula:

```
max_benchmark_pods = node_pod_limit - running_system_pods - buffer(5)
max_iterations     = floor(max_benchmark_pods / replicas_per_iteration)
```

**Example with 224 system pods:**
```
max_benchmark_pods = 250 - 224 - 5 = 21
max_iterations     = floor(21 / 5) = 4  (with 5 pods per iteration)
```

**Safe configuration:**
```yaml
jobs:
  - name: sno-workload
    jobIterations: 4        # 4 × 5 = 20 pods, 6-pod safety buffer
    objects:
      - objectTemplate: pod.yml
        replicas: 5
```

---

## SNO vs Multi-Node Topology Comparison

| Aspect | SNO (Cluster 3) | 3-Worker Cluster (Clusters 1 & 2) |
|---|---|---|
| OCP Version | 4.21.8 | 4.18.20 |
| Total workers | 1 | 3 |
| vCPU per worker | 71.5 | 15.5 |
| Memory per worker | ~124 GiB | ~30 GiB |
| Pod limit | 250 (shared with system) | 750 (250 per worker) |
| Available benchmark pods | ~26 | ~350+ |
| Control plane isolation | No (shares node) | Yes (dedicated CP nodes) |
| Pod scheduling P99 | 0 ms | 0 ms |
| Iteration creation speed | ~3s for 4 iterations | ~3s for 10–20 iterations |

---

## Running In-Cluster on SNO

The same in-cluster Job approach used for multi-node clusters works on SNO, but account for the pod limit in the Job manifest itself (the kube-burner Job pod also consumes one slot).

### Setup

```bash
oc new-project burner-test
oc apply -f examples/ocp-rbac.yaml
```

### Churn Workload for SNO

```bash
oc create configmap kube-burner-config \
  --from-file=config.yml=examples/workloads/churn-density-sno.yml \
  --from-file=pod.yml=examples/workloads/pod-template-sno.yml \
  --from-file=metrics-endpoints.yml=examples/metrics/metrics-endpoints-ocp.yml \
  --from-file=metrics.yml=examples/metrics/metrics-ocp.yml \
  -n burner-test

oc apply -f examples/ocp-job-churn.yaml
oc logs -f job/kube-burner-churn -n burner-test
```

---

## Prometheus Integration on SNO

SNO ships with the full OCP monitoring stack, including Prometheus. The integration was validated on this cluster.

### Get the Prometheus URL and Token

```bash
# Prometheus route
oc get route prometheus-k8s -n openshift-monitoring -o jsonpath='https://{.spec.host}'
# Output: https://prometheus-k8s-openshift-monitoring.apps.<cluster>/

# Token for the kube-burner service account
oc create token kube-burner -n burner-test --duration=2h
```

### Confirmed Working Prometheus Initialization

```
time="2026-04-23 13:56:19" 📁 Creating local indexer: indexer-0
time="2026-04-23 13:56:19" 👽 Initializing prometheus client with URL:
    https://prometheus-k8s-openshift-monitoring.apps.ilo2m284101d3.rhc-lab.iad.redhat.com
```

### Metrics Endpoint File Format

```yaml
# examples/metrics/metrics-endpoints-ocp.yml
- endpoint: https://prometheus-k8s-openshift-monitoring.apps.<cluster>/
  token: <sa-token>
  skipTLSVerify: true
  metrics:
    - metrics.yml
  indexer:
    type: local
    metricsDirectory: /results
```

Pass it to kube-burner with `-e`:
```bash
kube-burner init -c config.yml -e metrics-endpoints.yml
```

---

## Churn Workload — Observed Behavior

The churn workload was validated on this cluster. Here is the complete observed lifecycle:

```
13:56:19  Local indexer created
13:56:19  Prometheus client initialized (live Prometheus connection confirmed)
13:56:19  kube-burner v2.6.1 started, UUID: c3-churn-001
13:56:25  Pre-load DaemonSet created for pause:3.9 on 1 node
13:56:30  Image pulled on 1 SNO node                          (+5s, cached)
13:56:37  Cleaning up previous runs
13:56:38  podLatency measurement registered
13:56:38  Churn configuration logged:
            Churn cycles:      0 (duration-based)
            Churn duration:    2m0s
            Churn percent:     25%  (1 of 4 namespaces)
            Churn delay:       15s
            Churn delete delay: 5s
            Churn type:        namespaces
13:56:38  Job triggered — all 4 iterations submitted
13:56:40  burner-churn-1 completed
13:56:42  burner-churn-0, 2, 3 completed
13:56:42  Churn phase started
13:56:42  Deleting 1 namespace (25% of 4)
13:56:49  Sleeping 5s after deletion (deleteDelay)
13:56:54  Re-creating 1 deleted namespace
13:56:58  Re-created namespace completed (pods Running)
13:56:58  Sleeping 15s (churn delay between cycles)
13:57:13  Next churn cycle begins...
```

### Churn Cycle Anatomy

Each churn cycle on this configuration:

```
[Delete 1 namespace] → [5s deleteDelay] → [Re-create namespace] → [Wait for pods Ready] → [15s delay] → repeat
```

At 25% churn on 4 namespaces, 1 namespace is recycled per cycle. With a 15s delay + ~8s recreation time, approximately 3–4 churn cycles complete within the 2-minute churn window.

---

## OCP 4.21 vs 4.18 Differences

This SNO runs OCP 4.21.8 (Kubernetes v1.34.5), compared to 4.18.20 (v1.31.10) on clusters 1 and 2.

| Feature | OCP 4.18 | OCP 4.21 |
|---|---|---|
| Kubernetes | v1.31.10 | v1.34.5 |
| RHCOS | 418.94.x (9.4 kernel) | 9.6.20260324-0 (Plow, 9.6 kernel) |
| CRI-O | 1.31.10 | 1.34.6 |
| kube-burner behavior | Same | Same (v2.6.1 compatible) |
| RBAC requirements | Same | Same |
| Namespace naming | `kube-` forbidden | `kube-` forbidden |

kube-burner v2.6.1 is fully compatible with both versions — no configuration changes needed.

---

## Troubleshooting

### Pods stuck in `Pending` with "Too many pods"

This is the SNO pod limit. Calculate available slots:
```bash
available=$(expr $(oc get node -o jsonpath='{.items[0].status.allocatable.pods}') - $(oc get pods -A --field-selector=status.phase=Running --no-headers | wc -l))
echo "Available pod slots: $available"
```

Reduce `jobIterations` and/or `replicas` until `jobIterations × replicas < available - 5`.

### DNS resolution failure for internal lab clusters

Red Hat internal lab clusters (`rhc-lab.iad.redhat.com`) require VPN or Red Hat network access. If you see:
```
dial tcp: lookup api.<cluster>.rhc-lab.iad.redhat.com: no such host
```
Reconnect to the Red Hat VPN and re-login with `oc login`.

### Prometheus token expired

Service account tokens created with `oc create token` are short-lived (default 1 hour). For longer benchmarks:
```bash
# Create a longer-lived token (up to the SA's max)
oc create token kube-burner -n burner-test --duration=24h
```
Or create a non-expiring secret-based token for repeated use.
