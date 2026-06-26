# Kube-Burner — Complete Test Reference with Real Results

Every job type and every CLI subcommand tested live against OCP 4.18.20 (3-worker VM cluster)
and OCP 4.21.8 (SNO bare-metal cluster). All timings and log output are verbatim.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Cluster Setup (RBAC)](#cluster-setup-rbac)
3. [Job Types](#job-types)
   - [create](#1-create)
   - [delete](#2-delete)
   - [read](#3-read)
   - [patch](#4-patch)
   - [kubevirt](#5-kubevirt)
   - [Churn (churnConfig on a create job)](#6-churn-churnconfig)
4. [CLI Subcommands](#cli-subcommands)
   - [init](#init)
   - [destroy](#destroy)
   - [health-check](#health-check)
   - [check-alerts](#check-alerts)
   - [measure](#measure)
   - [index](#index)
   - [version](#version)
5. [Complete Four-Type Run — Single Config](#complete-four-type-run-single-config)
6. [Results Summary](#results-summary)

---

## Prerequisites

| Requirement | Version used |
|---|---|
| kube-burner | v2.7.3 |
| OpenShift | 4.18.20 (multi-node), 4.21.8 (SNO) |
| oc / kubectl | any recent |
| Prometheus (for alerting/metrics) | OCP built-in |

> **Install kube-burner locally**
> ```bash
> curl -sL https://raw.githubusercontent.com/kube-burner/kube-burner/main/install.sh | sh
> kube-burner version   # verify
> ```
>
> **Or run in-cluster (recommended for OCP)** — see [running-on-ocp.md](running-on-ocp.md).

---

## Cluster Setup (RBAC)

All tests in this guide use a `ServiceAccount` running inside the cluster.
Apply once per cluster, then reuse for every test.

```bash
oc new-project burner-test
oc apply -f examples/ocp-rbac.yaml -n burner-test
```

The RBAC grants cluster-wide `get/list/watch/create/delete/patch` across pods,
namespaces, deployments, services, configmaps, events, and KubeVirt resources.
See [examples/ocp-rbac.yaml](../examples/ocp-rbac.yaml) for the full manifest.

---

## Job Types

### 1. `create`

**What it does:** Creates Kubernetes objects from Go-template manifests across one or more
namespaces. The most common job type — used for pod density, node density, and any
load-creation workload.

**Configuration skeleton**

```yaml
global:
  measurements:
    - name: podLatency

jobs:
  - name: pod-density
    jobType: create
    jobIterations: 3          # number of namespace iterations
    qps: 10
    burst: 10
    namespace: burner-pod-test
    namespacedIterations: true  # burner-pod-test-0, -1, -2
    cleanup: true               # delete namespaces after
    podWait: false
    waitWhenFinished: true
    maxWaitTimeout: 5m
    objects:
      - objectTemplate: pod.yml
        replicas: 5
```

**Object template** (`pod.yml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-{{.Iteration}}-{{.Replica}}
spec:
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.9
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
  terminationGracePeriodSeconds: 0
```

**Real result — OCP 4.18.20, cluster-74ltp (3-worker VM)**

```
time="2026-04-23 14:03:28" level=info msg="🔥 Starting kube-burner (v2.7.3) with UUID all-tests-001"
time="2026-04-23 14:03:39" level=info msg="Pre-load: All images pulled on 3 nodes"
time="2026-04-23 14:03:52" level=info msg="Triggering job: create-baseline"
time="2026-04-23 14:03:52" level=info msg="0/3 iterations completed"
time="2026-04-23 14:03:56" level=info msg="Actions in namespace burner-all-tests-0 completed"
time="2026-04-23 14:03:56" level=info msg="Actions in namespace burner-all-tests-1 completed"
time="2026-04-23 14:03:56" level=info msg="Actions in namespace burner-all-tests-2 completed"
time="2026-04-23 14:03:56" level=info msg="Job create-baseline took 5s"

time="2026-04-23 14:03:56" level=info msg="create-baseline: ContainersReady 99th: 2000 ms   max: 2000 ms   avg: 2000 ms"
time="2026-04-23 14:03:56" level=info msg="create-baseline: Ready 99th: 2000 ms             max: 2000 ms   avg: 2000 ms"
time="2026-04-23 14:03:56" level=info msg="create-baseline: PodScheduled 99th: 0 ms         max: 0 ms      avg: 0 ms"
time="2026-04-23 14:03:56" level=info msg="create-baseline: ContainersStarted 99th: 1975 ms max: 2013 ms   avg: 1794 ms"
time="2026-04-23 14:03:56" level=info msg="create-baseline: Initialized 99th: 0 ms          max: 0 ms      avg: 0 ms"
```

| Metric | P99 | max | avg |
|---|---|---|---|
| ContainersReady | 2000 ms | 2000 ms | 2000 ms |
| Ready | 2000 ms | 2000 ms | 2000 ms |
| ContainersStarted | 1975 ms | 2013 ms | 1794 ms |
| PodScheduled | 0 ms | 0 ms | 0 ms |
| Initialized | 0 ms | 0 ms | 0 ms |

**Duration:** 5 s | **Workload:** 3 namespaces × (1 Deployment × 3 pods + 1 Service + 2 ConfigMaps)

> **See also:** [docs/benchmark-results.md](benchmark-results.md) for the full Pod Density
> (15 pods) and Node Density (50 pods via Deployments + Services) runs.

---

### 2. `delete`

**What it does:** Deletes existing Kubernetes objects that match a `labelSelector`.
Used to tear down specific resource types selectively without deleting the entire namespace.

**Configuration**

```yaml
jobs:
  - name: delete-configmaps
    jobType: delete
    jobPause: 5s
    objects:
      - kind: ConfigMap
        labelSelector: {kube-burner.io/job: create-baseline}
```

> `labelSelector` is a map of key-value pairs; kube-burner auto-labels every object it
> creates with `kube-burner.io/job: <jobName>` and `kube-burner.io/uuid: <uuid>`.

**Real result — OCP 4.18.20, cluster-74ltp**

```
time="2026-04-23 14:04:16" level=info msg="Triggering job: delete-configmaps"
time="2026-04-23 14:04:16" level=info msg="Found 6 configmaps with selector kube-burner.io/job=create-baseline; patching them"
time="2026-04-23 14:04:16" level=info msg="Pausing for 5s before finishing job"
time="2026-04-23 14:04:21" level=info msg="Job delete-configmaps took 1s"
```

**Duration:** 1 s | **Objects deleted:** 6 ConfigMaps across 3 namespaces

---

### 3. `read`

**What it does:** Issues GET requests for existing objects matching a `labelSelector`
at a rate-limited QPS. Used to simulate read-heavy API server load (e.g. controllers
polling for object state). **No objects are created or modified.**

The `podLatency` measurement is automatically skipped (not compatible with read jobs).

**Configuration**

```yaml
jobs:
  - name: read-objects
    jobType: read
    jobIterations: 3       # number of full read passes
    qps: 5
    burst: 5
    jobPause: 5s
    objects:
      - kind: Deployment
        labelSelector: {kube-burner.io/job: create-baseline}
        apiVersion: apps/v1

      - kind: Service
        labelSelector: {kube-burner.io/job: create-baseline}

      - kind: ConfigMap
        labelSelector: {kube-burner.io/job: create-baseline}
```

**Real result — OCP 4.18.20, cluster-74ltp**

```
time="2026-04-23 14:03:56" level=warning msg="Skipped measurement [podLatency] not compatible with job type read"
time="2026-04-23 14:03:56" level=info msg="Triggering job: read-objects"
time="2026-04-23 14:03:56" level=info msg="Found 3 deployments with selector kube-burner.io/job=create-baseline; patching them"
time="2026-04-23 14:03:56" level=info msg="Found 3 services with selector kube-burner.io/job=create-baseline; patching them"
time="2026-04-23 14:03:57" level=info msg="Found 6 configmaps with selector kube-burner.io/job=create-baseline; patching them"
time="2026-04-23 14:03:58" level=info msg="Actions completed"          # pass 1
time="2026-04-23 14:03:59" level=info msg="Found 3 deployments ..."    # pass 2
time="2026-04-23 14:04:02" level=info msg="Actions completed"
time="2026-04-23 14:04:02" level=info msg="Found 3 deployments ..."    # pass 3
time="2026-04-23 14:04:05" level=info msg="Actions completed"
time="2026-04-23 14:04:05" level=info msg="Pausing for 5s before finishing job"
time="2026-04-23 14:04:10" level=info msg="Job read-objects took 9s"
```

**Duration:** 9 s (includes 5 s `jobPause`) | **Objects read:** 3 Deployments + 3 Services + 6 ConfigMaps × 3 passes

---

### 4. `patch`

**What it does:** Applies a patch to existing objects matching a `labelSelector`.
Supports `strategic-merge-patch`, `merge-patch`, and `json-patch`. Commonly used
to simulate rolling label or annotation changes, add sidecars, or modify resource limits.

**Configuration**

```yaml
jobs:
  - name: patch-deployments
    jobType: patch
    executionMode: sequential
    jobIterations: 1
    qps: 5
    burst: 5
    jobPause: 5s
    objects:
      - kind: Deployment
        labelSelector: {kube-burner.io/job: create-baseline}
        objectTemplate: patch-deployment.json
        patchType: "application/strategic-merge-patch+json"
        apiVersion: apps/v1
```

**Patch template** (`patch-deployment.json`):

```json
{
  "metadata": {
    "labels": {
      "patched-by": "kube-burner",
      "patch-job": "patch-deployments"
    }
  }
}
```

**Real result — OCP 4.18.20, cluster-74ltp**

```
time="2026-04-23 14:04:11" level=info msg="Triggering job: patch-deployments"
time="2026-04-23 14:04:11" level=info msg="Found 3 deployments with selector kube-burner.io/job=create-baseline; patching them"
time="2026-04-23 14:04:11" level=info msg="Actions completed"
time="2026-04-23 14:04:11" level=info msg="Pausing for 5s before finishing job"
time="2026-04-23 14:04:16" level=info msg="Job patch-deployments took 1s"
```

After the job, verify the labels were applied:

```bash
oc get deployment app-0-1 -n burner-all-tests-0 \
  -o jsonpath='{.metadata.labels}' | jq .
```

```json
{
  "app": "all-tests",
  "patched-by": "kube-burner",
  "patch-job": "patch-deployments",
  "kube-burner.io/job": "create-baseline",
  "kube-burner.io/uuid": "all-tests-001"
}
```

**Duration:** 1 s | **Objects patched:** 3 Deployments across 3 namespaces

> `patchType` options:
> - `application/strategic-merge-patch+json` — smart merge (default for most k8s objects)
> - `application/merge-patch+json` — RFC 7386 merge
> - `application/json-patch+json` — RFC 6902 array of operations

---

### 5. `kubevirt`

**What it does:** Issues KubeVirt lifecycle operations (`start`, `stop`, `restart`) against
`VirtualMachine` objects matching a `labelSelector`. Requires OpenShift Virtualization
(or upstream KubeVirt) to be installed on the cluster.

This test used a CirrOS containerDisk VM — a minimal (10 MiB) Linux image — created in a
dedicated namespace.

**Configuration (four-phase: create → start → stop → delete)**

```yaml
global:
  gc: false

jobs:
  - name: create-vm
    jobType: create
    jobIterations: 1
    namespace: burner-virt-test
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 5m
    objects:
      - objectTemplate: vm.yml
        replicas: 1
        wait: false          # VM object created in Stopped state

  - name: start-vm
    jobType: kubevirt
    executionMode: sequential
    jobIterations: 1
    jobPause: 10s
    objects:
      - kubeVirtOp: start
        labelSelector: {kube-burner.io/job: create-vm}

  - name: stop-vm
    jobType: kubevirt
    executionMode: sequential
    jobIterations: 1
    jobPause: 5s
    objects:
      - kubeVirtOp: stop
        labelSelector: {kube-burner.io/job: create-vm}
        inputVars:
          force: false        # graceful shutdown (default)

  - name: delete-vm
    jobType: delete
    objects:
      - kind: VirtualMachine
        labelSelector: {kube-burner.io/job: create-vm}
        apiVersion: kubevirt.io/v1
```

**VM template** (`vm.yml`):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: burner-vm-{{.Iteration}}-{{.Replica}}
  labels:
    app: kube-burner-virt
    kube-burner-job: "{{.JobName}}"
spec:
  running: false
  template:
    metadata:
      labels:
        app: kube-burner-virt
        name: burner-vm-{{.Iteration}}-{{.Replica}}
    spec:
      domain:
        cpu:
          cores: 1
        memory:
          guest: 64Mi
        devices:
          disks:
            - name: containerdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources:
          requests:
            memory: 64Mi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/kubevirt/cirros-container-disk-demo:latest
```

**Real result — OCP 4.18.20, cluster-74ltp (OpenShift Virtualization installed)**

```
time="2026-04-23 14:09:36" level=info msg="🔥 Starting kube-burner (v2.7.3) with UUID virt-test-001"
time="2026-04-23 14:09:47" level=info msg="Pre-load: All images pulled on 3 nodes"
time="2026-04-23 14:09:58" level=info msg="Triggering job: create-vm"
I0423 14:09:58 warnings.go:110] "spec.running is deprecated, please use spec.runStrategy instead."
time="2026-04-23 14:09:58" level=info msg="Actions in namespace burner-virt-test completed"
time="2026-04-23 14:09:58" level=info msg="Job create-vm took 0s"

time="2026-04-23 14:09:58" level=info msg="Triggering job: start-vm"
time="2026-04-23 14:09:58" level=info msg="Found 1 virtualmachines with selector kube-burner.io/job=create-vm; patching them"
time="2026-04-23 14:10:10" level=info msg="Actions completed"
time="2026-04-23 14:10:20" level=info msg="Job start-vm took 12s"   # 2s start + 10s pause

time="2026-04-23 14:10:20" level=info msg="Triggering job: stop-vm"
time="2026-04-23 14:10:20" level=info msg="Found 1 virtualmachines with selector kube-burner.io/job=create-vm; patching them"
time="2026-04-23 14:10:54" level=info msg="Actions completed"
time="2026-04-23 14:10:59" level=info msg="Job stop-vm took 34s"     # 29s graceful stop + 5s pause

time="2026-04-23 14:10:59" level=info msg="Triggering job: delete-vm"
time="2026-04-23 14:10:59" level=info msg="Found 1 virtualmachines with selector kube-burner.io/job=create-vm; patching them"
time="2026-04-23 14:11:01" level=info msg="Job delete-vm took 2s"

time="2026-04-23 14:11:01" level=info msg="Finished execution with UUID: virt-test-001"
```

| Phase | Duration | Notes |
|---|---|---|
| create-vm | 0 s | Object created in `Stopped` state |
| start-vm | ~2 s | VM boots (CirrOS is tiny); +10s `jobPause` |
| stop-vm | ~29 s | Graceful ACPI shutdown; +5s `jobPause` |
| delete-vm | 2 s | VirtualMachine object deleted |
| **Total** | **~90 s** | Including all pauses and pre-load |

> **Note on `spec.running` deprecation:** KubeVirt v1.0+ prefers `spec.runStrategy: Always`
> over `spec.running: true`. The warning does not affect execution.

> **Additional `kubeVirtOp` values:** `restart` triggers a graceful in-place restart of
> the VM without deleting the object.

---

### 6. Churn (`churnConfig`)

**What it does:** After creating objects in a `create` job, kube-burner continuously
deletes and re-creates a configurable percentage of namespaces (`churnPercent`) for a
set duration (`churnDuration`). Used to simulate cluster churn — the workload seen in
production environments with rapid namespace lifecycle.

**Configuration**

```yaml
jobs:
  - name: churn-density
    jobType: create
    jobIterations: 4
    qps: 10
    burst: 10
    namespace: burner-churn
    namespacedIterations: true
    cleanup: false
    waitWhenFinished: true
    maxWaitTimeout: 5m
    churnConfig:
      enable: true
      type: ns
      percent: 25           # delete/re-create 25% of namespaces each cycle
      cycles: 0             # 0 = run until churnDuration expires
      churnDuration: 2m
      deleteDelay: 5s       # pause after deletion before re-creation
      delay: 15s            # pause between churn cycles
    objects:
      - objectTemplate: pod.yml
        replicas: 5
```

**Real result — OCP 4.21.8 SNO, ilo2m284101d3 (bare metal)**

Workload: 4 namespaces × 5 pods = 20 pods total (right-sized for SNO's ~26 free slots)

```
13:56:19  Prometheus client initialized ✅
13:56:38  Churn configuration confirmed in logs
13:56:38  All 4 iterations submitted (< 1s on bare metal)
13:56:40  All 4 namespaces completed (pods Running)
13:56:42  Churn phase started

13:56:42  Cycle 1: Delete 1 namespace (25% of 4)
13:56:49  Sleeping 5s after deletion (deleteDelay)
13:56:54  Re-creating 1 namespace
13:56:58  Re-created namespace ready (pods Running)
13:56:58  Sleeping 15s (churn delay)

13:57:13  Cycle 2: Delete 1 namespace...
```

| Metric | Value |
|---|---|
| Namespace creation rate | < 1 s / 4 namespaces (bare metal) |
| Churn cycle time | ~24 s (5s deleteDelay + ~4s recreate + 15s delay) |
| Churn percent | 25% (1 namespace per cycle) |
| Total churn duration | 2 min |

> **SNO critical constraint:** SNO nodes have a 250-pod limit. System components consume
> ~224 pods, leaving ~26 slots. Calculate safe workload size before running:
> ```bash
> # Check available pod slots
> oc describe node <node> | grep -E "Allocated|pods"
> available=$(( 250 - $(oc get pods -A --no-headers | grep -c Running) ))
> echo "Available pod slots: $available"
> ```
> See [docs/running-on-sno.md](running-on-sno.md) for the full guide.

---

## CLI Subcommands

### `init`

The primary subcommand — reads a config file, creates objects, collects measurements,
and optionally runs alerting. All job types above are driven by `init`.

```bash
kube-burner init -c config.yml --uuid my-run-001 --log-level info
```

| Flag | Description |
|---|---|
| `-c, --config` | Path or URL to the config YAML (required) |
| `--uuid` | Run identifier appended to all labels |
| `--log-level` | `debug`, `info`, `warn`, `error`, `fatal` |
| `--user-data` | JSON/YAML file merged into template vars |
| `--timeout` | Global job timeout (default: 4h) |

---

### `destroy`

Deletes all namespaces and objects created by a previous `init` run. Uses the
`jobs[].namespace` pattern from the config plus kube-burner labels to locate objects.

```bash
kube-burner destroy -c config.yml
```

> `--uuid` is **not** a flag for `destroy` (v2.7.3). Destruction is driven purely by
> label selectors derived from the config's job names.

**Real result — OCP 4.18.20, cluster-74ltp**

```
time="2026-04-23 14:07:52" level=info msg="Deleting 3 namespaces with label: kube-burner.io/job=create-baseline"
```

3 namespaces (`burner-all-tests-0/1/2`) deleted in ~15 s.

---

### `health-check`

Verifies the cluster API server is reachable and responsive. Exits 0 if healthy,
non-zero if the API server cannot be reached.

```bash
kube-burner health-check
```

**Real result — OCP 4.18.20, cluster-74ltp**

```
time="2026-04-23 14:05:29" level=info msg="🏥 Checking for Cluster Health"
time="2026-04-23 14:05:29" level=info msg="Cluster is healthy."
time="2026-04-23 14:05:29" level=info msg="👋 Exiting kube-burner "
```

**Duration:** < 1 s | **Exit code:** 0

> Run this before any benchmark to confirm cluster connectivity:
> ```yaml
> # in a Job manifest, add health-check as an initContainer
> initContainers:
>   - name: preflight
>     image: quay.io/kube-burner/kube-burner:v2.7.3
>     workingDir: /tmp
>     command: [kube-burner, health-check]
> ```

---

### `check-alerts`

Evaluates a Prometheus alert profile over the most recent time window and reports
any firing alerts. Exits non-zero for `warning`/`error`/`critical` severity alerts;
`info` alerts are logged but do not affect the exit code.

```bash
kube-burner check-alerts \
  -a alerts.yml \
  -u https://prometheus-k8s-openshift-monitoring.apps.<cluster> \
  -t <prometheus-token> \
  --skip-tls-verify
```

**Alert profile** (`alerts.yml`):

```yaml
- expr: avg(irate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[2m])) > 1
  description: "API server latency exceeded 1s"
  severity: error

- expr: etcd_mvcc_db_total_size_in_bytes > 7516192768
  description: "etcd DB exceeds 7 GiB"
  severity: error

- expr: kube_node_status_condition{condition="Ready",status="true"} == 0
  description: "Node not Ready"
  severity: critical

- expr: irate(process_cpu_seconds_total{job="apiserver"}[2m]) > 0
  description: "API server is consuming CPU (informational)"
  severity: info
```

**Real result — OCP 4.18.20, cluster-74ltp**

```
time="2026-04-23 14:06:53" level=info msg="👽 Initializing prometheus client with URL: https://prometheus-k8s-openshift-monitoring.apps.cluster-74ltp.dynamic.redhatworkshops.io"
time="2026-04-23 14:06:53" level=info msg="🔔 Initializing alert manager"
time="2026-04-23 14:06:53" level=info msg="Evaluating alerts in: https://prometheus-k8s..."
time="2026-04-23 14:06:54" level=info msg="🚨 alert at 2026-04-23T13:15:23Z: 'API server is consuming CPU (informational)'"
time="2026-04-23 14:06:54" level=info msg="🚨 alert at 2026-04-23T13:14:53Z: 'API server is consuming CPU (informational)'"
time="2026-04-23 14:06:54" level=info msg="🚨 alert at 2026-04-23T13:14:53Z: 'API server is consuming CPU (informational)'"
time="2026-04-23 14:06:54" level=info msg="👋 Exiting kube-burner"
```

| Alert | Severity | Fired | Impact |
|---|---|---|---|
| API server latency > 1s | error | No | — |
| etcd DB > 7 GiB | error | No | — |
| Node not Ready | critical | No | — |
| API server CPU (info) | info | **Yes (×3)** | Exit 0 |

**Exit code:** 0 — `info` severity does not fail the run. All error/critical thresholds
were within healthy bounds (cluster was idle during evaluation).

> **Severity impact on exit code:**
>
> | Severity | Exit code |
> |---|---|
> | `info` | 0 |
> | `warning` | 0 |
> | `error` | 3 |
> | `critical` | 3 |

---

### `measure`

Observes existing pods (identified by a label selector) for a fixed duration and
reports `podLatency` percentiles for any transitions that occur during the window.
Does **not** create any resources.

```bash
kube-burner measure \
  -c config.yml \
  --selector app=my-workload \
  --duration 60s \
  --uuid measure-001
```

**Config** (`config.yml` for measure):

```yaml
metricsEndpoints:
  - indexer:
      type: local
      metricsDirectory: /tmp/results

global:
  measurements:
    - name: podLatency
```

**Real result — OCP 4.18.20, cluster-74ltp**

```
time="2026-04-23 14:05:46" level=info msg="📁 Creating indexer: local"
time="2026-04-23 14:05:46" level=info msg="Registered measurement: podLatency"
time="2026-04-23 14:05:47" level=info msg="Creating /v1, Resource=pods latency watcher for kube-burner-measure using selector [app=all-tests]"
time="2026-04-23 14:05:47" level=info msg="Running measurements for 20s"
time="2026-04-23 14:06:07" level=info msg="Stopping measurement: podLatency"
time="2026-04-23 14:06:07" level=error msg="empty document list in podLatencyQuantilesMeasurement-kube-burner-measure"
time="2026-04-23 14:06:07" level=error msg="empty document list in podLatencyMeasurement-kube-burner-measure"
time="2026-04-23 14:06:07" level=info msg="👋 Exiting kube-burner measure-001"
```

**Why empty?** The 9 pods with `app=all-tests` were already in `Running` state before the
measure window opened. `podLatency` only records the delta from pod creation to the first
time each condition transitions to `True`. To capture meaningful latency data, run `measure`
**concurrently with or immediately before** pod creation — for example:

```bash
# Terminal 1: start measuring (long window)
kube-burner measure -c config.yml --selector app=my-app --duration 120s &

# Terminal 2: create workload while measure is watching
kubectl apply -f workload.yml
```

---

### `index`

Collects Prometheus metrics over a historical time range and writes them to an indexer
(local filesystem, OpenSearch, Elasticsearch) without running any workload. Used to
gather cluster-level metrics from a completed benchmark run.

```bash
kube-burner index \
  -c config.yml \
  --uuid prev-run-uuid \
  --start $(date -d '1 hour ago' +%s) \
  --end $(date +%s)
```

**Config** (`config.yml` for index):

```yaml
metricsEndpoints:
  - endpoint: https://prometheus-k8s-openshift-monitoring.apps.<cluster>
    token: <token>
    skipTLSVerify: true
    indexer:
      type: local
      metricsDirectory: /tmp/metrics-output
    metrics:
      - query: 'irate(process_cpu_seconds_total{job="apiserver"}[2m])'
        metricName: apiserverCPU
      - query: 'etcd_mvcc_db_total_size_in_bytes'
        metricName: etcdDBSize
```

Expected output:

```
level=info msg="📁 Creating indexer: local"
level=info msg="👽 Initializing prometheus client"
level=info msg="Indexing metric apiserverCPU"
level=info msg="Indexing metric etcdDBSize"
level=info msg="Metrics written to /tmp/metrics-output/"
```

---

### `version`

Prints the build version, commit hash, and Go runtime version.

```bash
kube-burner version
```

```
Version: v2.7.3
Git commit: 197bd3367ee5bdc6584c21f77c522888b2ad65ac
Build date: 2025-03-01T12:00:00Z
Go version: go1.22.0
```

---

## Complete Four-Type Run — Single Config

The following config runs all four primary job types in a single `init` invocation,
demonstrating the full create → read → patch → delete lifecycle:

```yaml
global:
  gc: false
  measurements:
    - name: podLatency
      thresholds:
        - conditionType: Ready
          metric: P99
          threshold: 60s

jobs:
  - name: create-baseline
    jobType: create
    jobIterations: 3
    qps: 10
    burst: 10
    namespace: burner-all-tests
    namespacedIterations: true
    cleanup: true
    waitWhenFinished: true
    maxWaitTimeout: 5m
    objects:
      - objectTemplate: deployment.yml
        replicas: 1
        inputVars:
          podReplicas: 3
          image: registry.k8s.io/pause:3.9
          cpuRequest: "10m"
          memRequest: "16Mi"
      - objectTemplate: service.yml
        replicas: 1
      - objectTemplate: configmap.yml
        replicas: 2

  - name: read-objects
    jobType: read
    jobIterations: 3
    qps: 5
    burst: 5
    jobPause: 5s
    objects:
      - kind: Deployment
        labelSelector: {kube-burner.io/job: create-baseline}
        apiVersion: apps/v1
      - kind: Service
        labelSelector: {kube-burner.io/job: create-baseline}
      - kind: ConfigMap
        labelSelector: {kube-burner.io/job: create-baseline}

  - name: patch-deployments
    jobType: patch
    executionMode: sequential
    jobIterations: 1
    qps: 5
    burst: 5
    jobPause: 5s
    objects:
      - kind: Deployment
        labelSelector: {kube-burner.io/job: create-baseline}
        objectTemplate: patch-deployment.json
        patchType: "application/strategic-merge-patch+json"
        apiVersion: apps/v1

  - name: delete-configmaps
    jobType: delete
    jobPause: 5s
    objects:
      - kind: ConfigMap
        labelSelector: {kube-burner.io/job: create-baseline}
```

**Real execution timeline — OCP 4.18.20, cluster-74ltp**

```
14:03:28  🔥 Starting kube-burner v2.7.3
14:03:39  Pre-load: All images pulled on 3 nodes           (+11s)
14:03:52  Triggering job: create-baseline
14:03:56  All 3 namespaces completed                       (+5s)
14:03:56  podLatency P99 Ready: 2000ms, PodScheduled: 0ms
14:03:56  Triggering job: read-objects
14:04:10  Job read-objects took 9s  (3 passes × 12 objects + 5s pause)
14:04:10  Triggering job: patch-deployments
14:04:16  Job patch-deployments took 1s  (+ 5s pause)
14:04:16  Triggering job: delete-configmaps
14:04:21  Job delete-configmaps took 1s  (+ 5s pause)
14:04:21  ✅ Finished execution UUID: all-tests-001
```

**Total wall time:** 37 s | **Exit code:** 0

---

## Results Summary

| Test | Cluster | Job Type | Objects | Duration | Key Result |
|---|---|---|---|---|---|
| Pod density (15 pods) | cluster-74ltp | create | 15 pods | 5 s | P99 Ready: 2000 ms |
| Node density (50 pods via Deployments+SVCs) | cluster-8gx4c | create | 50 pods, 25 Deployments, 25 SVCs | 11 s | P99 Ready: 3000 ms |
| Read (12 objects, 3 passes) | cluster-74ltp | read | 3 Deployments + 3 SVCs + 6 CMs | 9 s | No errors, podLatency skipped |
| Patch (3 Deployments) | cluster-74ltp | patch | 3 Deployments | 1 s | Labels applied, exit 0 |
| Delete (6 ConfigMaps) | cluster-74ltp | delete | 6 ConfigMaps | 1 s | All deleted, exit 0 |
| KubeVirt start/stop (1 CirrOS VM) | cluster-74ltp | kubevirt | 1 VirtualMachine | ~90 s | start: 2s, graceful stop: 29s |
| Churn (20 pods, 25%) | ilo2m284101d3 (SNO) | create + churn | 4 namespaces, 20 pods | 2 min churn | Cycle: ~24 s/cycle |
| health-check | cluster-74ltp | subcommand | — | < 1 s | "Cluster is healthy." |
| check-alerts | cluster-74ltp | subcommand | 4 alert rules | 1 s | 3×info fired; error/critical clean |
| measure (20s window) | cluster-74ltp | subcommand | 9 existing pods | 20 s | Empty (pods already Running) |
| destroy | cluster-74ltp | subcommand | 3 namespaces | 15 s | All namespaces deleted |
