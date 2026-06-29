# Kube-Burner Explained

<div align="center">

[![kube-burner](https://img.shields.io/badge/kube--burner-v2.7.3-EE0000?style=for-the-badge&logo=kubernetes&logoColor=white)](https://github.com/kube-burner/kube-burner)
[![OpenShift](https://img.shields.io/badge/OpenShift-4.12+-EE0000?style=for-the-badge&logo=redhat&logoColor=white)](https://www.openshift.com)
[![Tests](https://img.shields.io/badge/Tests-40-blue?style=for-the-badge&logo=checkmarx&logoColor=white)](#individual-test-guides)
[![Virtualization](https://img.shields.io/badge/OpenShift%20Virtualization-KubeVirt-orange?style=for-the-badge&logo=linux&logoColor=white)](https://www.redhat.com/en/technologies/cloud-computing/openshift/virtualization)
[![License](https://img.shields.io/badge/License-Apache%202.0-green?style=for-the-badge)](https://www.apache.org/licenses/LICENSE-2.0)

```
 ██╗  ██╗██╗   ██╗██████╗ ███████╗      ██████╗ ██╗   ██╗██████╗ ███╗   ██╗███████╗██████╗
 ██║ ██╔╝██║   ██║██╔══██╗██╔════╝      ██╔══██╗██║   ██║██╔══██╗████╗  ██║██╔════╝██╔══██╗
 █████╔╝ ██║   ██║██████╔╝█████╗  █████╗██████╔╝██║   ██║██████╔╝██╔██╗ ██║█████╗  ██████╔╝
 ██╔═██╗ ██║   ██║██╔══██╗██╔══╝  ╚════╝██╔══██╗██║   ██║██╔══██╗██║╚██╗██║██╔══╝  ██╔══██╗
 ██║  ██╗╚██████╔╝██████╔╝███████╗      ██████╔╝╚██████╔╝██║  ██║██║ ╚████║███████╗██║  ██║
 ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝      ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝
```

**25 battle-tested performance benchmarks for Kubernetes and OpenShift Virtualization**  
*From first pod to 500 VMs — live-tested on Red Hat OCP 4.18 and 4.21*

</div>

---

> **You do not need to install anything on your laptop.**  
> Every test in this project runs kube-burner as an in-cluster Kubernetes Job.  
> Open your OpenShift web console → click **`>_`** → paste and run.

---

## Table of Contents

- [What is Kube-Burner?](#what-is-kube-burner)
- [Quick Start — 4 checks to confirm you are ready](#quick-start)
- [Installation Guide](#installation-guide)
- [Where Do Metrics Go?](#where-do-metrics-go)

- [Individual Test Guides — All 25 Tests](#individual-test-guides)
  - [Core Kubernetes (01–12)](#core-kubernetes-tests-0112)
  - [Generic VM / Virtualization (13–17)](#generic-virtualization-tests-1317)
  - [OCP-Optimized Tests (18–22)](#ocp-optimized-tests-1822)
  - [Real-OS VM Fleet Tests (23–25)](#real-os-vm-fleet-tests-2325-new)
- [OS Fleet Test Details](#os-fleet-test-details)
- [VM Escalation Ladder](#vm-escalation-ladder)
- [Diagrams](#diagrams)
- [Project Structure](#project-structure)
- [References](#references)

---

## What is Kube-Burner?

Kube-Burner is a Kubernetes performance and scale test orchestration tool written in Go.  
It uses the official `client-go` library to hammer your cluster with real workloads and capture precise latency measurements.

**What it can do:**

| Capability | Description |
|---|---|
| Create resources at scale | Pods, Deployments, VMs, Routes — any Kubernetes object |
| Delete and patch at high rate | Measure cleanup speed and write amplification |
| Measure latency percentiles | P50/P95/P99 for pod scheduling, VM boot, service readiness |
| Record Prometheus metrics | Snapshot etcd, API server, scheduler, kubelet during the test |
| Index results | Local JSON files, OpenSearch, or Elasticsearch |
| Auto-escalate | Run sequential rounds of increasing load until the cluster shows pressure |
| VM fleet testing | CirrOS, RHEL 9, Windows Server 2022, and mixed fleets |

**Why it matters for customer demos:**  
Every test in this project shows the OpenShift console reacting in real time. You can point at the Virtualization tab, the Metrics dashboard, and the Nodes screen while kube-burner runs — no black-box mystery, just measurable proof.

---

## Quick Start

Open the OpenShift web console. Click the **`>_`** terminal icon.

### Check 1 — You are logged in

```bash
oc whoami
```

Expected: your username. If `Unauthorized` — log in to the console first.

---

### Check 2 — Cluster nodes are Ready

```bash
oc get nodes --no-headers | awk '{print $1, $2}'
```

Expected: each node shows `Ready`. If empty — cluster is unreachable.

---

### Check 3 — quay.io image is reachable (the image ALL tests use)

Pulling a container image takes time — never just 10 seconds. Run the check, then watch the status loop until it finishes:

```bash
# Step A: delete any leftover test pod from a previous run
kubectl delete pod pull-test -n default 2>/dev/null || true

# Step B: create the test pod (note: -n default goes BEFORE the -- separator)
kubectl run pull-test \
  -n default \
  --image=quay.io/kube-burner/kube-burner:v2.7.3 \
  --restart=Never \
  --command -- kube-burner version
```

```bash
# Step C: watch the status — run this every 15 seconds until you see Succeeded or Failed
kubectl get pod pull-test -n default
```

Keep running Step C until the STATUS column shows `Completed` or `Error`. Pulling the image the first time takes **1–3 minutes** on most clusters.

```bash
# Step D: once the pod is no longer Pending/ContainerCreating, check the result
kubectl logs pull-test -n default | grep -i version
```

**Good output:**
```
Version: v2.7.3
```

**If you see `ImagePullBackOff` or `ErrImagePull`:**
```bash
# Get the exact error message
kubectl describe pod pull-test -n default | grep -A 5 "Events:"
```

This tells you exactly what is blocking the pull. Common causes:

| What you see | What it means | Fix |
|---|---|---|
| `unauthorized: access to the requested resource is not authorized` | quay.io is reachable but the image requires auth | Contact cluster admin — pull secret may be needed |
| `dial tcp: lookup quay.io: no such host` | quay.io DNS not resolvable from the cluster | No internet access from cluster — tests cannot pull images |
| `net/http: request canceled` | Network timeout pulling from quay.io | Cluster egress is slow or blocked — try again |
| `Succeeded` but no log output | Pod ran too fast and was garbage collected | Normal — image was already cached, tests will work |

```bash
# Step E: clean up
kubectl delete pod pull-test -n default 2>/dev/null || true
```

---

### Check 4 — OpenShift Virtualization is installed (VM tests only)

```bash
oc get hyperconverged -A
```

Expected: a row showing `PHASE: Deployed`. If empty — VM tests (09, 13–17, 20, 22–25) are not available on this cluster.

---

### All checks passing — you are ready

| Check | Good output | Problem |
|---|---|---|
| `oc whoami` | Your username | `Unauthorized` — log in first |
| `oc get nodes` | Each node `Ready` | Empty — cluster unreachable |
| `kubectl logs pull-test -n default \| grep -i version` | `Version: v2.7.3` | See image pull troubleshooting above |
| `oc get hyperconverged` | `PHASE: Deployed` | Empty — VM tests unavailable |

---

## Installation Guide

**For OpenShift (recommended):** No local install needed. Every test runs as an in-cluster Job.

| Format | File |
|---|---|
| **Markdown** | [`docs/installation/markdown/installation-guide.md`](docs/installation/markdown/installation-guide.md) |
| **Google Docs** | [`docs/installation/google-docs/installation-guide.html`](docs/installation/google-docs/installation-guide.html) |
| **Plain Text** | [`docs/installation/text/installation-guide.txt`](docs/installation/text/installation-guide.txt) |

**For local binary (optional, macOS/Linux):**

```bash
curl -Ls https://raw.githubusercontent.com/kube-burner/kube-burner/refs/heads/main/hack/install.sh | sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
kube-burner version
```

---

## Where Do Metrics Go?

A question every customer asks: *"Where do the numbers actually go?"*

### 1. OpenShift Observe tab (live, during the test)

The fastest way to see what is happening:

```
Observe → Metrics → paste a PromQL query:

# VMs currently Running
kubevirt_vmi_phase_count{phase="Running"}

# virt-controller memory (watch for leaks)
process_resident_memory_bytes{pod=~"virt-controller.*"}

# API server request rate
rate(apiserver_request_total[1m])

# etcd write throughput
rate(etcd_mvcc_put_total[1m])
```

Observe → Dashboards → **KubeVirt / Infrastructure Resources / Top Consumers**  
→ select Memory or CPU to see per-node consumption in real time.

### 2. kube-burner local JSON output (after the test)

When kube-burner completes, it writes JSON result files to `collected-metrics/<uuid>/` inside the Job pod. To retrieve them:

```bash
# Get the pod name
POD=$(kubectl get pod -n <namespace> -l job-name=<job-name> -o jsonpath='{.items[0].metadata.name}')

# Copy the results out
kubectl cp $POD:/config/collected-metrics ./my-results -n <namespace>

# View the latency summary
cat ./my-results/*/podLatency.json | python3 -m json.tool
cat ./my-results/*/vmiLatency.json | python3 -m json.tool
```

### 3. OpenSearch / Elasticsearch (production use)

For long-term storage and cross-run comparison, configure the indexer in your kube-burner config:

```yaml
global:
  indexerConfig:
    type: opensearch
    servers: ["https://my-opensearch-host:9200"]
    defaultIndex: kube-burner
    insecureSkipVerify: true
```

### 4. Grafana dashboard (if configured)

Red Hat performance engineering maintains Grafana dashboards for kube-burner results. If your team has Grafana connected to OpenSearch, you can import the dashboards from:  
[github.com/cloud-bulldozer/performance-dashboards](https://github.com/cloud-bulldozer/performance-dashboards)

### 5. The log output (simplest)

The last lines of `kubectl logs -f job/<name>` always print the latency summary:

```
INFO vmiLatency:
INFO   P50:  32s
INFO   P95:  55s
INFO   P99:  78s    ← this is the number to quote
INFO Finished execution. UUID: vmi-density-1714523400
```

Screenshot or copy this — it is the headline number for the customer.

---

## Individual Test Guides

**25 tests — all in one flat directory. No subdirectories.**

| Format | Location |
|---|---|
| **Markdown** | [`docs/tests/markdown/`](docs/tests/markdown/) — all 25 `.md` files |
| **Google Docs** | [`docs/tests/google-docs/`](docs/tests/google-docs/) — import HTML into Google Docs |
| **Plain Text** | [`docs/tests/text/`](docs/tests/text/) — copy/paste from any terminal |

All steps use **copy-paste ready code blocks** — every command is in a fenced block so your team can paste directly from GitHub into the web terminal.

---

### Core Kubernetes Tests (01–12)

| # | Test | Difficulty | Time | What it does |
|---|---|---|---|---|
| 01 | [Pod Density](docs/tests/markdown/01-pod-density.md) | ⭐ Beginner | 5 min | Creates N pods at once, measures how fast each reaches Ready |
| 02 | [Node Density](docs/tests/markdown/02-node-density.md) | ⭐ Beginner | 8 min | Fills each worker node to its pod capacity |
| 03 | [Cluster Density](docs/tests/markdown/03-cluster-density.md) | ⭐⭐ Intermediate | 15 min | N namespaces each with pods, services, ConfigMaps |
| 04 | [Cluster Density v2](docs/tests/markdown/04-cluster-density-v2.md) | ⭐⭐ Intermediate | 20 min | Like v1 + NetworkPolicies and Secrets |
| 05 | [Churn](docs/tests/markdown/05-churn.md) | ⭐⭐ Intermediate | 15 min | Continuous create/delete cycles — tests control-plane under change |
| 06 | [Read Workload](docs/tests/markdown/06-read.md) | ⭐ Beginner | 5 min | Bulk GET/LIST — tests API server read performance |
| 07 | [Patch Workload](docs/tests/markdown/07-patch.md) | ⭐⭐ Intermediate | 8 min | Bulk PATCH — tests write amplification and etcd throughput |
| 08 | [Delete Workload](docs/tests/markdown/08-delete.md) | ⭐ Beginner | 5 min | Bulk DELETE — tests GC controller cleanup speed |
| 09 | [KubeVirt Density](docs/tests/markdown/09-kubevirt-density.md) | ⭐⭐⭐ Advanced | 20 min | Creates CirrOS VMs, boots all at once — baseline virt test |
| 09b | [RHEL 9 Density](docs/tests/markdown/09b-rhel-density.md) | ⭐⭐⭐⭐ Advanced | 25–45 min | RHEL 9 VM density via DataSource smart-clone — real OS boot latency baseline |
| 09c | [RHEL 9 Density Escalation](docs/tests/markdown/09c-rhel-density-escalation.md) | ⭐⭐⭐⭐⭐ Expert | 60–120 min | Set It and Forget It: 4 automated RHEL 9 density rounds — finds RHEL ceiling |
| 09d | [Windows Server 2022 Density](docs/tests/markdown/09d-windows-density.md) | ⭐⭐⭐⭐ Advanced | 30–60 min | Windows Server 2022 density from golden PVC — VMware migration demo test |
| 09e | [Windows Server 2022 Density Escalation](docs/tests/markdown/09e-windows-density-escalation.md) | ⭐⭐⭐⭐⭐ Expert | 60–180 min | Set It and Forget It: 3 automated Windows density rounds — finds Windows ceiling |
| 10 | [Health Check](docs/tests/markdown/10-health-check.md) | ⭐ Beginner | 1 min | Confirms cluster is reachable — **run this first** |
| 11 | [Check Alerts](docs/tests/markdown/11-check-alerts.md) | ⭐⭐ Intermediate | 2 min | Queries Prometheus for any firing alerts |
| 12 | [Index Metrics](docs/tests/markdown/12-index.md) | ⭐⭐ Intermediate | 3 min | Captures a metrics baseline snapshot |

---

### Generic Virtualization Tests (13–17)

Requires OpenShift Virtualization. All use CirrOS containerDisk (fast, small, no auth required).

| # | Test | Difficulty | Time | What it does |
|---|---|---|---|---|
| 13 | [VM Live Migration](docs/tests/markdown/13-vm-live-migration.md) | ⭐⭐⭐⭐ Expert | 30 min | Moves running VMs between nodes — zero downtime |
| 14 | [VM Density Scaling](docs/tests/markdown/14-vm-density-scaling.md) | ⭐⭐⭐⭐ Expert | 30–90 min | Escalating VM counts to find the cluster ceiling — includes [Auto-Escalation: Set It and Forget It](docs/tests/markdown/14-vm-density-scaling.md#auto-escalation--set-it-and-forget-it) |
| 15 | [VM Churn](docs/tests/markdown/15-vm-churn.md) | ⭐⭐⭐⭐ Expert | 20–60 min | Continuously creates and destroys VMs — endurance test |
| 15b | [VM Churn — RHEL9](docs/tests/markdown/15b-vm-churn-rhel.md) | ⭐⭐⭐⭐ Expert | 30–90 min | RHEL 9 VM create/delete churn cycles — real-OS endurance test |
| 15c | [VM Churn — Windows Server](docs/tests/markdown/15c-vm-churn-windows.md) | ⭐⭐⭐⭐⭐ Expert | 60–180 min | Windows Server 2022 churn cycles — VMware migration stress test |
| 16 | [VM Pause/Unpause Storm](docs/tests/markdown/16-vm-pause-unpause.md) | ⭐⭐⭐ Advanced | 15 min | Pause/unpause all VMs simultaneously — QEMU state stress |
| 17 | [VM Hot-plug Storage](docs/tests/markdown/17-vm-hotplug-storage.md) | ⭐⭐⭐⭐ Expert | 25 min | Attaches and detaches PVCs to running VMs |

---

### OCP-Optimized Tests (18–22)

OpenShift-tuned workloads using standard `kube-burner` with OCP-specific configs. No separate binary needed.

| # | Test | Difficulty | Time | What it does |
|---|---|---|---|---|
| 18 | [OCP Node Density](docs/tests/markdown/18-ocp-node-density.md) | ⭐⭐⭐ Intermediate | 10 min | Pod-per-node benchmark matching Red Hat's internal OCP validation |
| 19 | [OCP Cluster Density v2](docs/tests/markdown/19-ocp-cluster-density-v2.md) | ⭐⭐⭐⭐ Advanced | 20–40 min | N namespaces each with Deployment + Route + NetworkPolicy + Secrets |
| 20 | [OCP VMI Density](docs/tests/markdown/20-ocp-vmi-density.md) | ⭐⭐⭐⭐ Advanced | 15–20 min | N VMs boot simultaneously — the flagship virt scale test |
| 21 | [OCP Web Burner](docs/tests/markdown/21-ocp-web-burner.md) | ⭐⭐⭐⭐ Advanced | 20–30 min | Production web-app density: TLS Routes + HPA + sidecar + NetworkPolicy |
| 22 | [OCP VMI Density + Churn](docs/tests/markdown/22-ocp-vmi-density-churn.md) | ⭐⭐⭐⭐⭐ Expert | 30–60 min | VMI density + continuous churn cycles — the ultimate soak test |

---

### Real-OS VM Fleet Tests (23–25) 🆕

**Replaces CirrOS with real operating systems.** Shows customers what their actual workloads look like.

| # | Test | Difficulty | Time | What it does |
|---|---|---|---|---|
| 23 | [RHEL 9 VM Fleet](docs/tests/markdown/23-vm-density-rhel.md) | ⭐⭐⭐⭐ Advanced | 20–40 min | All VMs run RHEL 9 — enterprise Linux boot time benchmark |
| 24 | [Windows Server VM Fleet](docs/tests/markdown/24-vm-density-windows.md) | ⭐⭐⭐⭐ Advanced | 30–60 min | All VMs run Windows Server 2022 — VMware migration demo test |
| 25 | [Mixed Fleet (70% Windows / 30% RHEL)](docs/tests/markdown/25-vm-density-mixed.md) | ⭐⭐⭐⭐⭐ Expert | 40–90 min | Mixed enterprise fleet — 70% Windows + 30% RHEL simultaneously |

---

## OS Fleet Test Details

### Why real operating systems matter

CirrOS boots in ~5 seconds. Windows takes 3–8 minutes. RHEL takes 30–90 seconds. If you show a customer that OpenShift can boot 20 Windows VMs simultaneously, that is far more compelling than "look, 20 tiny 5MB VMs booted fast."

| OS | Image | Boot time P99 | RAM per VM | CPUs per VM | Best for showing |
|---|---|---|---|---|---|
| CirrOS | `quay.io/kubevirt/cirros-registry-disk-demo:latest` | 15–30 s | 512 Mi | 1 | Maximum density, quick demo |
| RHEL 9 | `quay.io/containerdisks/rhel9:9.0` | 60–120 s | 2 Gi | 1 | Enterprise Linux workloads, databases |
| Windows Server 2022 | OCP golden image `win2k22` | 3–8 min | 4 Gi | 2 | VMware migration, Windows apps |
| Mixed (70/30) | Both above | 3–8 min (gated by Windows) | Varies | Varies | Realistic enterprise environment |

### Pre-flight for RHEL test

```bash
# Step A: clean up any leftover pod
kubectl delete pod rhel-pull-test -n default 2>/dev/null || true

# Step B: create the pod (-n default goes BEFORE the -- separator)
kubectl run rhel-pull-test \
  -n default \
  --image=quay.io/containerdisks/rhel9:9.0 \
  --restart=Never \
  --command -- true

# Step C: run every 15-30 seconds until STATUS shows Completed or Error
kubectl get pod rhel-pull-test -n default

# Step D: clean up
kubectl delete pod rhel-pull-test -n default 2>/dev/null || true
```

### Pre-flight for Windows test

```bash
# Check if the OCP golden image exists
oc get datavolume win2k22 -n openshift-virtualization-os-images 2>/dev/null || \
  echo "Windows golden image not found — see Test 24 for import instructions"
```

---

## VM Escalation Ladder

Use this table when planning any VM density test. Start at the left — escalate right until the cluster shows pressure.

| Round | CirrOS VMs | RHEL VMs | Windows VMs | Mixed VMs | RAM needed (approx) |
|---|---|---|---|---|---|
| Warm-up | 2 | 2 | 2 | 2W + 0R | 1 Gi |
| Starter | 5 | 5 | 3 | 3W + 2R | 12 Gi |
| Medium | 10 | 8 | 5 | 7W + 3R | 25 Gi |
| Heavy | 20 | 15 | 8 | 14W + 6R | 50 Gi |
| Stress | 50 | 25 | 10 | 21W + 9R | 80 Gi |
| Maximum | 100+ | 50+ | 15+ | 35W + 15R | 120+ Gi |

**When to stop escalating:**
- VMs stuck in `Scheduling` for more than 5 minutes
- virt-controller RSS growing > 10 MB per round
- P99 boot time exceeds 10 minutes
- Worker nodes showing > 90% memory pressure

---

## Diagrams

Open `.drawio` files at [app.diagrams.net](https://app.diagrams.net) · Open `.excalidraw` at [excalidraw.com](https://excalidraw.com)

| Diagram | Format | What it shows |
|---|---|---|
| [`architecture.drawio`](docs/diagrams/architecture.drawio) | draw.io | kube-burner → API server → scheduler → kubelets → Prometheus flow |
| [`lifecycle.drawio`](docs/diagrams/lifecycle.drawio) | draw.io | All 9 phases of `init` with real timings |
| [`decision-tree.drawio`](docs/diagrams/decision-tree.drawio) | draw.io | Which test should I run? |
| [`install.drawio`](docs/diagrams/install.drawio) | draw.io | 5-step installation flow |
| [`install.excalidraw`](docs/diagrams/install.excalidraw) | Excalidraw | Same — with key warnings |
| [`uninstall.drawio`](docs/diagrams/uninstall.drawio) | draw.io | Full cleanup procedures |
| [`uninstall.excalidraw`](docs/diagrams/uninstall.excalidraw) | Excalidraw | Same — with verify-clean commands |
| [`churn-timeline.excalidraw`](docs/diagrams/churn-timeline.excalidraw) | Excalidraw | Live SNO churn Gantt timeline |
| [`virt-tests-overview.excalidraw`](docs/diagrams/virt-tests-overview.excalidraw) | Excalidraw | All VM tests overview |
| [`ocp-customer-demo-flow.excalidraw`](docs/diagrams/ocp-customer-demo-flow.excalidraw) | Excalidraw | 4-act customer demo map |
| [`tests/01-22.excalidraw`](docs/diagrams/tests/) | Excalidraw | Per-test flow diagrams (22 files) |
| [`tests/01-22.drawio`](docs/diagrams/tests/) | draw.io | Per-test flow diagrams (22 files) |
| [`tests/23-25.excalidraw`](docs/diagrams/tests/) | Excalidraw | Real-OS fleet test diagrams (3 files) |
| [`tests/23-25.drawio`](docs/diagrams/tests/) | draw.io | Real-OS fleet test diagrams (3 files) |

---

## Project Structure

```
kube-burner-project/
├── README.md                          ← you are here
├── docs/
│   ├── installation/
│   │   ├── markdown/installation-guide.md
│   │   ├── google-docs/installation-guide.html
│   │   └── text/installation-guide.txt
│   ├── tests/
│   │   ├── README.md                  ← full test index with recommended order
│   │   ├── markdown/                  ← 25 × .md files (all tests, flat directory)
│   │   │   ├── 01-pod-density.md
│   │   │   ├── ...
│   │   │   ├── 22-ocp-vmi-density-churn.md
│   │   │   ├── 23-vm-density-rhel.md      🆕
│   │   │   ├── 24-vm-density-windows.md   🆕
│   │   │   └── 25-vm-density-mixed.md     🆕
│   │   ├── google-docs/               ← 25 × .html (Google Docs compatible)
│   │   └── text/                      ← 25 × .txt (plain text)
│   ├── diagrams/
│   │   ├── architecture.drawio
│   │   ├── lifecycle.drawio
│   │   ├── decision-tree.drawio
│   │   ├── install.drawio + install.excalidraw
│   │   ├── uninstall.drawio + uninstall.excalidraw
│   │   ├── churn-timeline.excalidraw
│   │   ├── virt-tests-overview.excalidraw
│   │   ├── ocp-customer-demo-flow.excalidraw
│   │   └── tests/                     ← 25 × .excalidraw + 25 × .drawio
│   ├── all-tests-guide.md
│   ├── benchmark-results.md
│   ├── customer-demo-guide.md
│   └── test-viewers-guide.md
└── examples/
    ├── workloads/
    └── metrics/
```

---

## References

- [Official kube-burner Documentation](https://kube-burner.github.io/kube-burner/latest/)
- [GitHub Repository](https://github.com/kube-burner/kube-burner)
- [Releases (binary downloads)](https://github.com/kube-burner/kube-burner/releases)
- [Container Images (Quay.io)](https://quay.io/repository/kube-burner/kube-burner)
- [containerdisks.io — RHEL and other OS container disks](https://containerdisks.io)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [Red Hat Blog: Introducing kube-burner](https://www.redhat.com/en/blog/introducing-kube-burner-a-tool-to-burn-down-kubernetes-and-openshift)
- [All Tests Step-by-Step](docs/all-tests-guide.md)
- [Customer Demo Guide](docs/customer-demo-guide.md)
- [Test Viewer's Guide](docs/test-viewers-guide.md)
