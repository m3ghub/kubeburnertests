# Running Kube-Burner on OpenShift (OCP)

This guide covers everything you need to run kube-burner against a live OpenShift cluster, based on validated testing against **OCP 4.18.20 / Kubernetes v1.31.10**.

---

## Table of Contents

- [Cluster Requirements](#cluster-requirements)
- [OCP-Specific Constraints](#ocp-specific-constraints)
- [Method 1: Run In-Cluster (Recommended)](#method-1-run-in-cluster-recommended)
- [Method 2: Run Locally Against OCP](#method-2-run-locally-against-ocp)
- [RBAC Reference](#rbac-reference)
- [Real Benchmark Results](#real-benchmark-results)
- [Prometheus Integration on OCP](#prometheus-integration-on-ocp)
- [OpenShift Virtualization Workloads](#openshift-virtualization-workloads)
- [Troubleshooting](#troubleshooting)

---

## Cluster Requirements

This guide was tested on:

| Component | Version |
|---|---|
| OpenShift | 4.18.20 |
| Kubernetes | v1.31.10 |
| CRI-O | 1.31.10 |
| RHCOS | 418.94.202507091512-0 |
| kube-burner | v2.7.3 |

**Cluster topology:**
- 3 control plane nodes (15.5 vCPU, ~30 GiB RAM each)
- 3 worker nodes (15.5 vCPU, ~30 GiB RAM each, max 250 pods per node)

---

## OCP-Specific Constraints

### Namespace Naming

OpenShift **forbids project/namespace names that start with `kube-`**. This affects the `namespace` field in your kube-burner jobs.

```yaml
# WRONG — will fail on OCP
jobs:
  - namespace: kube-burner-test

# CORRECT
jobs:
  - namespace: burner-test
  - namespace: density-test
  - namespace: perf-workload
```

Error you will see if you violate this:
```
Error from server (Forbidden): project.project.openshift.io "kube-burner-test" is forbidden:
cannot request a project starting with "kube-"
```

### Security Context Constraints (SCC)

OCP enforces SCCs. The `pause` image used in most kube-burner examples runs as restricted. If you use application images, you may need to grant additional SCCs:

```bash
# Allow a service account to use the anyuid SCC (only if required)
oc adm policy add-scc-to-user anyuid -z kube-burner -n burner-test
```

For most benchmarks using pause or minimal images, the default `restricted-v2` SCC is sufficient.

---

## Method 1: Run In-Cluster (Recommended)

Running kube-burner as a pod inside the cluster is the recommended approach for OCP. It avoids network access issues, uses in-cluster config automatically, and is how Red Hat's own CI pipelines run it.

### Step 1: Create Namespace and RBAC

```bash
oc new-project burner-test
oc apply -f examples/ocp-rbac.yaml
```

The RBAC creates:
- `ServiceAccount/kube-burner` in `burner-test`
- `ClusterRole/kube-burner` with all necessary permissions
- `ClusterRoleBinding/kube-burner`

> **Important:** The `events` resource must be included at the cluster scope in the ClusterRole. Without it, kube-burner's `podLatency` measurement cannot track pod lifecycle events and will log repeated errors (though the benchmark still runs).

### Step 2: Create a ConfigMap with Your Benchmark Config

```bash
oc create configmap kube-burner-config \
  --from-file=config.yml=examples/workloads/pod-density-ocp.yml \
  --from-file=pod.yml=examples/workloads/pod-template-ocp.yml \
  -n burner-test
```

> kube-burner reads from a ConfigMap using `--configmap=<name>` and `--namespace=<namespace>`. The ConfigMap **must** contain a key named `config.yml` as the main config file. Additional template files are also stored as keys in the same ConfigMap.

### Step 3: Deploy the Benchmark Job

```bash
oc apply -f examples/ocp-job.yaml
```

The Job uses an `initContainer` to copy the ConfigMap files into a writable `emptyDir` volume, because the kube-burner container image has a read-only root filesystem.

> **Why an initContainer?** When kube-burner reads a ConfigMap via `--configmap`, it writes the files to disk before parsing them. The container's working directory must be writable. Using `emptyDir` + an init container is the clean solution.

### Step 4: Stream Logs

```bash
oc logs -f job/kube-burner-pod-density -n burner-test
```

### Step 5: Clean Up

```bash
oc delete job kube-burner-pod-density -n burner-test
oc delete configmap kube-burner-config -n burner-test
# The benchmark itself GCs its namespaces if gc: true is set
```

---

## Method 2: Run Locally Against OCP

If you have kube-burner installed locally and network access to the OCP API server:

### Login and Export Kubeconfig

```bash
oc login --token=<your-token> --server=https://api.<cluster>.example.com:6443 --insecure-skip-tls-verify=true
oc config view --minify --flatten > my-cluster-kubeconfig.yaml
```

### Run With Explicit Kubeconfig

```bash
kube-burner init \
  -c examples/workloads/pod-density-ocp.yml \
  --kubeconfig my-cluster-kubeconfig.yaml \
  --uuid ocp-local-001
```

---

## RBAC Reference

The following permissions are required for a full kube-burner run with `podLatency` measurements. All validated against OCP 4.18.20.

```yaml
rules:
  - apiGroups: [""]
    resources:
      - namespaces
      - pods
      - services
      - endpoints
      - replicationcontrollers
      - persistentvolumeclaims
      - configmaps
      - secrets
      - nodes
      - events          # Required for podLatency measurement
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]

  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]

  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]

  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
```

See the full file at [`examples/ocp-rbac.yaml`](../examples/ocp-rbac.yaml).

---

## Real Benchmark Results

Two benchmarks were run against two identical OCP 4.18.20 clusters. Full results and analysis are in [`docs/benchmark-results.md`](benchmark-results.md).

### Run 1 — Pod Density (Cluster 1, UUID: `ocp-test-001`)

**Workload:** 3 iterations × 5 bare pods = 15 pods total, QPS=10

```
13:34:30  Pre-load: All images pulled on 3 nodes  (11s, cold pull)
13:37:52  Job triggered
13:37:54  All 3 namespaces completed              (2s)
13:38:09  GC complete                             total: 3m46s
```

| Condition | P99 | Max | Avg |
|---|---|---|---|
| `PodScheduled` | 0 ms | 0 ms | 0 ms |
| `Ready` | 2000 ms | 2000 ms | 1866 ms |
| `ContainersStarted` | 2025 ms | 2070 ms | 1716 ms |

### Run 2 — Node Density: Deployments + Services (Cluster 2, UUID: `c2-node-density-001`)

**Workload:** 10 iterations × (1 Deployment × 5 pods + 1 Service) = 50 pods, 10 Deployments, 10 Services, QPS=20

```
13:41:19  Pre-load: All images pulled on 3 nodes  (5s, cached)
13:41:30  Job triggered, all 10 iterations created in <1s
13:41:35  All 10 namespaces completed             (5s)
13:41:35  GC started                              total: ~27s
```

| Condition | P99 | Max | Avg |
|---|---|---|---|
| `PodScheduled` | 0 ms | 0 ms | 0 ms |
| `Ready` | 3000 ms | 3000 ms | 2220 ms |
| `ContainersStarted` | 3108 ms | 3109 ms | 2248 ms |

### Cross-Run Takeaways

- **Scheduling is not the bottleneck** at this scale — P99 PodScheduled = 0ms on both clusters
- **Deployment overhead adds ~1s** vs bare pods (3s vs 2s Ready P99)
- **CRI-O startup is the dominant cost** (~2–3s for `pause:3.9`)
- **Image caching halves pre-load time** (11s cold → 5s cached)

---

## Prometheus Integration on OCP

OCP ships with a built-in Prometheus stack in `openshift-monitoring`. kube-burner can scrape it directly.

### Get the Prometheus Route and Token

```bash
# Get Prometheus URL
PROM_URL=$(oc get route prometheus-k8s -n openshift-monitoring -o jsonpath='{.spec.host}')
echo "https://${PROM_URL}"

# Get token for the kube-burner service account
PROM_TOKEN=$(oc create token kube-burner -n burner-test)
```

### Configure Metrics Endpoint

Create a `metrics-endpoints.yml`:

```yaml
- endpoint: https://prometheus-k8s-openshift-monitoring.apps.<cluster>.example.com
  token: <token>
  metrics: [examples/metrics/metrics.yml]
  alerts: [examples/metrics/alerts.yml]
  skipTLSVerify: true
  indexer:
    type: local
    metricsDirectory: ./results
```

Then run:

```bash
kube-burner init -c config.yml -e metrics-endpoints.yml
```

### Available Prometheus Endpoints on OCP 4.18

| Route | URL | Purpose |
|---|---|---|
| `prometheus-k8s` | `prometheus-k8s-openshift-monitoring.apps.<cluster>/api` | Main Prometheus |
| `thanos-querier` | `thanos-querier-openshift-monitoring.apps.<cluster>/api` | Cross-namespace query |
| `alertmanager-main` | `alertmanager-main-openshift-monitoring.apps.<cluster>/api` | Alertmanager |

---

## OpenShift Virtualization Workloads

This cluster has **OpenShift Virtualization 4.18.8** installed. kube-burner supports KubeVirt workloads via the `kubevirt` job type.

### Worker Node KubeVirt Capabilities

Each worker node exposes:
- `devices.kubevirt.io/kvm: 1k`
- `devices.kubevirt.io/tun: 1k`
- `devices.kubevirt.io/vhost-net: 1k`
- `bridge.network.kubevirt.io/br-flat: 1k`

### KubeVirt Job Example

```yaml
jobs:
  - name: start-vms
    jobType: kubevirt
    executionMode: parallel
    objects:
      - kubeVirtOp: start
        labelSelector: {kube-burner.io/job: create-vms}

  - name: stop-vms
    jobType: kubevirt
    executionMode: sequential
    objects:
      - kubeVirtOp: stop
        labelSelector: {kube-burner.io/job: create-vms}
        inputVars:
          force: false
```

---

## Troubleshooting

### "cannot request a project starting with kube-"

Rename your namespace in the config. OCP reserves the `kube-` prefix.

### "permission denied" writing config files

The kube-burner container image has a read-only filesystem. Use the `initContainer` + `emptyDir` pattern shown in [`examples/ocp-job.yaml`](../examples/ocp-job.yaml). Running kube-burner with `--configmap` causes it to write config files to disk before use.

### Events RBAC errors on podLatency

```
failed to list *v1.Event: events is forbidden
```

Add `events` to your ClusterRole at cluster scope. The `examples/ocp-rbac.yaml` file already includes this. Without it, pod latency measurement still runs but may miss some data points.

### Image pull failures

```
Pre-load: Waiting for images to be pulled on N nodes
```

If this times out (`preLoadPeriod` default is `10m`), the container image may not be reachable from the cluster. Use an image from the OCP internal registry or a registry accessible from within the cluster network.

### Pods stuck in Pending after benchmark starts

Check node resource availability:
```bash
oc describe nodes | grep -A6 "Allocated resources"
```

Each OCP worker in this cluster has `15500m` CPU and `~30Gi` memory allocatable, with a 250-pod limit per node.
