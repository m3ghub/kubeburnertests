# Kube-Burner Test Guides

**25 tests** across three tracks — generic kube-burner (01–17), OCP-optimized (18–22), and real-OS VM fleet tests (23–25).

## How to find the guide you need

| Folder | Format | Open with |
|---|---|---|
| [`markdown/`](markdown/) | Markdown (`.md`) | GitHub, VS Code, any Markdown viewer — all 25 tests in one flat directory |
| [`google-docs/`](google-docs/) | HTML (`.html`) | Import into Google Docs: File → Open → Upload |
| [`text/`](text/) | Plain text (`.txt`) | Any text editor, terminal |

---

## Track 1 — Generic kube-burner (tests 01–17)

Uses the `kube-burner` binary with YAML config files. Works on any Kubernetes or OpenShift cluster.

### Core Kubernetes tests (01–12)

| # | Test | Difficulty | Time | What it does |
|---|---|---|---|---|
| 01 | [Pod Density](markdown/01-pod-density.md) | ⭐ Beginner | 5 min | Creates many pods and measures how fast they start |
| 02 | [Node Density](markdown/02-node-density.md) | ⭐ Beginner | 8 min | Creates Deployments+Services per node |
| 03 | [Cluster Density](markdown/03-cluster-density.md) | ⭐⭐ Intermediate | 15 min | Builds full app stacks across many namespaces |
| 04 | [Cluster Density v2](markdown/04-cluster-density-v2.md) | ⭐⭐ Intermediate | 20 min | Like v1 but adds NetworkPolicies and more workloads |
| 05 | [Churn](markdown/05-churn.md) | ⭐⭐ Intermediate | 15 min | Repeatedly creates and deletes resources |
| 06 | [Read Workload](markdown/06-read.md) | ⭐ Beginner | 5 min | Reads existing resources at high speed |
| 07 | [Patch Workload](markdown/07-patch.md) | ⭐⭐ Intermediate | 8 min | Updates existing resources at high speed |
| 08 | [Delete Workload](markdown/08-delete.md) | ⭐ Beginner | 5 min | Deletes resources and measures cleanup speed |
| 09 | [KubeVirt Density](markdown/09-kubevirt-density.md) | ⭐⭐⭐ Advanced | 20 min | Creates and manages Virtual Machines (baseline virt test) |
| 10 | [Health Check](markdown/10-health-check.md) | ⭐ Beginner | 1 min | Quick cluster health verification — **start here!** |
| 11 | [Check Alerts](markdown/11-check-alerts.md) | ⭐⭐ Intermediate | 2 min | Verifies Prometheus alert thresholds not breached |
| 12 | [Index Metrics](markdown/12-index.md) | ⭐⭐ Intermediate | 3 min | Saves Prometheus metrics for long-term comparison |

### Advanced virtualization tests (13–17) — OpenShift Virtualization required

| # | Test | Difficulty | Time | What it does |
|---|---|---|---|---|
| 13 | [VM Live Migration](markdown/13-vm-live-migration.md) | ⭐⭐⭐⭐ Expert | 30 min | Migrates running VMs between nodes without downtime |
| 14 | [VM Density Scaling](markdown/14-vm-density-scaling.md) | ⭐⭐⭐⭐ Expert | 30–90 min | Finds the maximum VM count your cluster can handle |
| 15 | [VM Churn](markdown/15-vm-churn.md) | ⭐⭐⭐⭐ Expert | 20–60 min | Continuously creates and destroys VMs to test endurance |
| 16 | [VM Pause/Unpause Storm](markdown/16-vm-pause-unpause.md) | ⭐⭐⭐ Advanced | 15 min | Freezes and thaws VMs at scale to test QEMU state handling |
| 17 | [VM Hot-plug Storage](markdown/17-vm-hotplug-storage.md) | ⭐⭐⭐⭐ Expert | 25 min | Attaches and detaches disks to running VMs at scale |

---

## Track 2 — OCP-optimized tests (tests 18–22)

Uses standard `kube-burner` v2.7.3 configured with OpenShift-optimized workloads. All tests run as in-cluster Jobs — no separate binary needed.
Tests 20 and 22 require OpenShift Virtualization.

| # | Test | Difficulty | Time | What it does |
|---|---|---|---|---|
| 18 | [OCP Node Density](markdown/18-ocp-node-density.md) | ⭐⭐⭐ Intermediate | 10 min | Pod density using Red Hat production benchmark parameters |
| 19 | [OCP Cluster Density v2](markdown/19-ocp-cluster-density-v2.md) | ⭐⭐⭐⭐ Advanced | 20–40 min | N namespaces: Deployments + Routes + NetworkPolicy + Secrets |
| 20 | [OCP VMI Density](markdown/20-ocp-vmi-density.md) | ⭐⭐⭐⭐ Advanced | 15–20 min | N VMIs per node — flagship OpenShift Virtualization scale test |
| 21 | [OCP Web Burner](markdown/21-ocp-web-burner.md) | ⭐⭐⭐⭐ Advanced | 20–30 min | Production web-app density: TLS Routes + HPA + sidecar containers |
| 22 | [OCP VMI Density + Churn](markdown/22-ocp-vmi-density-churn.md) | ⭐⭐⭐⭐⭐ Expert | 30–60 min | VMI density + continuous churn cycles — soak/endurance test |

---

## Track 3 — Real-OS VM Fleet Tests (tests 23–25) 🆕

**Replaces CirrOS with real enterprise operating systems.** These tests show customers what their actual workloads look like — RHEL for Linux, Windows Server for Microsoft workloads, and a mixed fleet for the most realistic enterprise environment demo.

All tests require OpenShift Virtualization and use the same in-cluster Job pattern.

| # | Test | Difficulty | Time | What it does |
|---|---|---|---|---|
| 23 | [RHEL 9 VM Fleet](markdown/23-vm-density-rhel.md) | ⭐⭐⭐⭐ Advanced | 20–40 min | N RHEL 9 VMs boot simultaneously — enterprise Linux workload benchmark |
| 24 | [Windows Server VM Fleet](markdown/24-vm-density-windows.md) | ⭐⭐⭐⭐ Advanced | 30–60 min | N Windows Server 2022 VMs — the VMware migration demo test |
| 25 | [Mixed Fleet (70% Win / 30% RHEL)](markdown/25-vm-density-mixed.md) | ⭐⭐⭐⭐⭐ Expert | 40–90 min | 70% Windows + 30% RHEL simultaneously — the most realistic enterprise demo |

### OS comparison table

| OS | Image | Boot P99 | RAM/VM | CPUs/VM | Best for |
|---|---|---|---|---|---|
| CirrOS | `quay.io/kubevirt/cirros-registry-disk-demo:latest` | 15–30 s | 512 Mi | 1 | Maximum density, quick demo |
| RHEL 9 | `quay.io/containerdisks/rhel9:9.0` | 60–120 s | 2 Gi | 1 | Enterprise Linux, databases |
| Windows 2022 | OCP golden image `win2k22` | 3–8 min | 4 Gi | 2 | VMware migration, Windows apps |
| Mixed (70/30) | Both above | 3–8 min | Varies | Varies | Realistic enterprise environment |

---

## Virtualization test progression (Tests 09, 13–17, 20, 22–25)

Run these in order to build from baseline to maximum stress on OpenShift Virtualization:

```
Test 09  → KubeVirt Density          — baseline: create/start/stop/delete (CirrOS)
Test 16  → VM Pause/Unpause Storm    — QEMU freeze/thaw under load
Test 13  → VM Live Migration         — zero-downtime node-to-node move
Test 15  → VM Churn                  — endurance: continuous create/destroy
Test 14  → VM Density Scaling        — find the ceiling (auto-escalation available)
Test 17  → VM Hot-plug Storage       — attach/detach PVCs on running VMs
Test 20  → OCP VMI Density           — scale test with full metrics collection
Test 22  → OCP VMI Density + Churn   — ultimate endurance soak test
Test 23  → RHEL 9 VM Fleet           — enterprise Linux OS density benchmark
Test 24  → Windows Server VM Fleet   — VMware migration demo with real Windows
Test 25  → Mixed Fleet (70/30)       — most realistic enterprise environment
```

---

## Recommended order for first-time users

```
1. Health Check (Test 10)    — confirm cluster is reachable
2. Pod Density (Test 01)     — first real benchmark
3. Node Density (Test 02)    — test node capacity
4. Churn (Test 05)           — cluster under constant change
5. Check Alerts (Test 11)    — verify nothing went wrong
```

For OpenShift clusters (no virtualization):
```
6.  OCP Node Density (Test 18)          — OCP-tuned pod density
7.  OCP Cluster Density v2 (Test 19)    — full production workload simulation
8.  OCP Web Burner (Test 21)            — realistic multi-app density
```

For OpenShift Virtualization clusters, continue with:
```
9.  KubeVirt Density (Test 09)          — baseline VM test (CirrOS)
10. VM Pause/Unpause Storm (Test 16)    — QEMU state test
11. VM Live Migration (Test 13)         — production migration path
12. VM Churn (Test 15)                  — endurance test
13. VM Density Scaling (Test 14)        — find the ceiling
14. VM Hot-plug Storage (Test 17)       — storage attach/detach
15. OCP VMI Density (Test 20)           — OCP-scale virt benchmark
16. OCP VMI Density + Churn (Test 22)   — ultimate soak test
17. RHEL 9 VM Fleet (Test 23)           — enterprise Linux fleet benchmark
18. Windows Server VM Fleet (Test 24)   — VMware migration demo
19. Mixed Fleet 70/30 (Test 25)         — the ultimate enterprise environment demo
```
