# Test 09d: Windows Server 2022 KubeVirt Density — The VMware Migration Test

> **Difficulty:** ⭐⭐⭐⭐ Advanced  
> **Time to run:** ~45 minutes  
> **What it does:** Creates, boots, and deletes Windows Server 2022 Virtual Machines using OpenShift Virtualization — the single most powerful answer to "but can it run Windows?"  
> **Requires:** OpenShift Virtualization 4.x, `win2k22` golden PVC in `openshift-virtualization-os-images` (`Ready: True`), storage class with 150Gi+ free  
> **Companion test:** RHEL baseline first — run [Test 09b](09b-rhel-density.md) before this. Windows is harder.

> **⚡ Pre-flight required:** See **[00-preflight.md](00-preflight.md)** — Checks 1–6 all apply.

> **STIG / quota-enforced clusters:** Use the quota-safe Job variant in Step 9. See [CONCERN-013](../../concerns/CONCERN-013-stig-resource-quota.md).

> ⚠️ **Golden image required:** This test cannot run if the `win2k22` PVC is not imported in `openshift-virtualization-os-images`. See the Pre-flight section below. The error from [CONCERN-007](../../concerns/CONCERN-007-windows-golden-image-missing.md) applies here.

---

![Diagram](../../diagrams/tests/png/09d-windows-density.png)


## What is this test? 🪟

Every VMware migration conversation eventually hits the same wall:  
*"We understand Linux containers. But our estate is 70% Windows. Can OpenShift actually run Windows Server?"*

This test is the live answer. Three Windows Server 2022 VMs boot simultaneously on OpenShift Virtualization while you watch. The boot takes 3–8 minutes — that is not a bug, that is Windows being Windows. But the cluster handles it, the VMs come up, and the customer sees it happen in real time on the console they just installed.

**What to say:** *"That is Windows Server 2022. SQL Server runs on this. Active Directory runs on this. IIS runs on this. Same OS, same licences you already own — running on OpenShift."*

---

## What does it measure?

| Metric | What it means |
|---|---|
| **VMIRunning P99** | Time until 99th percentile Windows VM reached Running state |
| **VMReady P99** | Time until VM passed readiness check |
| **PVC clone time** | Time for CDI to clone the 50Gi Windows disk per VM |
| **Platform stability** | Whether the cluster stays healthy while Windows VMs boot |

---

## How it works

```
PVC Clone           Windows Boot         Ready              Delete
──────────          ──────────           ──────────         ──────────
CDI clones          Windows Server       VM passes          All VMs and
win2k22 golden      2022 boots           readiness          50Gi PVCs
PVC → new 50Gi      BIOS → Kernel        check              removed
PVC per VM          → Desktop            ✅ Running          ✅ Done
                    (3–8 minutes)
```

---

## Pre-flight — Windows golden image

**Check first — this test is blocked if the image is not ready:**

```bash
oc get datasource win2k22 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True
```

```bash
oc get pvc win2k22 -n openshift-virtualization-os-images
# Expected: STATUS = Bound
```

If either check fails, the `win2k22` golden image is not imported. See [CONCERN-007](../../concerns/CONCERN-007-windows-golden-image-missing.md) for remediation options. This test cannot run until the image is ready — there is no fallback.

**Check available storage (need 150Gi+ free for 3 VMs × 50Gi):**

```bash
oc get storageclass
# Note the default storage class, then check its capacity via the storage dashboard
```

---

## Before you start — open these browser tabs

| Tab | Where to go | What you will watch |
|---|---|---|
| **Tab 1** | Web terminal | Commands |
| **Tab 2** | Virtualization → VirtualMachines | Windows VMs appearing and booting |
| **Tab 3** | Storage → PersistentVolumeClaims | 50Gi PVCs being cloned |
| **Tab 4** | Observe → Dashboards → KubeVirt | Memory and CPU during Windows boot |

---

## Step 1 — Open the web terminal

```bash
oc whoami
```

---

## Step 2 — Verify the Windows golden image

```bash
oc get datasource win2k22 -n openshift-virtualization-os-images
# READY column must show: True

oc get pvc win2k22 -n openshift-virtualization-os-images
# STATUS must show: Bound
```

If either check fails — stop here. The test cannot run. See [CONCERN-007](../../concerns/CONCERN-007-windows-golden-image-missing.md).

---

## Step 3 — Create the project

```bash
oc new-project burner-windows-density
```

---

## Step 4 — Create the Service Account

```bash
oc create serviceaccount kube-burner -n burner-windows-density
```

---

## Step 5 — Apply RBAC

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-burner
rules:
  - apiGroups: [""]
    resources: [namespaces, pods, services, endpoints, configmaps, secrets, nodes, events,
                replicationcontrollers, serviceaccounts, persistentvolumeclaims]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [apps]
    resources: [deployments, replicasets, statefulsets, daemonsets]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [batch]
    resources: [jobs]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [kubevirt.io]
    resources: [virtualmachines, virtualmachineinstances]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [subresources.kubevirt.io]
    resources: [virtualmachines/start, virtualmachines/stop]
    verbs: [update]
  - apiGroups: [cdi.kubevirt.io]
    resources: [datavolumes, datasources]
    verbs: [get, list, watch, create, delete, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-burner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-burner
subjects:
  - kind: ServiceAccount
    name: kube-burner
    namespace: burner-windows-density
EOF
```

---

## Step 6 — Create the config files

**File 1 — Windows Server 2022 VM template**

```bash
**Option A — Download from repo (recommended):**

```bash
BASE="https://raw.githubusercontent.com/m3ghub/kubeburnertests/main/docs/tests/files/09d-windows-density"

curl --fail -sL "${BASE}/windows-density-vm.yml" -o /tmp/windows-density-vm.yml
curl --fail -sL "${BASE}/windows-density-config.yml" -o /tmp/windows-density-config.yml
```

Verify:

```bash
head -2 /tmp/windows-density-vm.yml   # must start with: apiVersion: kubevirt.io/v1 or global:
head -2 /tmp/windows-density-config.yml   # must start with: apiVersion: kubevirt.io/v1 or global:
```

<details>
<summary><strong>Option B — Paste manually (air-gapped / private cluster)</strong></summary>

cat > /tmp/windows-density-vm.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win-vm-{{.Iteration}}-{{.Replica}}
  labels:
    app: kube-burner-windows
    kube-burner-job: create-windows-vms
spec:
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: win-disk-{{.Iteration}}-{{.Replica}}
      spec:
        source:
          pvc:
            namespace: openshift-virtualization-os-images
            name: win2k22
        storage:
          storageClassName: ""       # Leave blank for cluster default
          accessModes:
            - ReadWriteOnce          # Windows does not support ReadWriteMany
          resources:
            requests:
              storage: 50Gi
  template:
    metadata:
      labels:
        app: kube-burner-windows
        kube-burner-job: create-windows-vms
    spec:
      domain:
        cpu:
          cores: 2
        resources:
          requests:
            memory: 4Gi
        features:
          acpi: {}
          apic: {}
          hyperv:
            relaxed: {}
            spinlocks:
              spinlocks: 8191
            vapic: {}
        clock:
          utc: {}
          timer:
            hpet:
              present: false
            pit:
              tickPolicy: delay
            rtc:
              tickPolicy: catchup
            hyperv: {}
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: sata
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: win-disk-{{.Iteration}}-{{.Replica}}
EOF
```

> **Why `ReadWriteOnce` for Windows?** The Windows NTFS filesystem does not support concurrent write access from multiple nodes. `ReadWriteOnce` is required. This also means Windows VMs **cannot live migrate** — they must be stopped and restarted on a new node.

> **Why `bus: sata` instead of `virtio`?** Windows Server 2022 does not include VirtIO drivers by default. SATA is recognised natively by Windows. For better disk performance, inject the VirtIO driver ISO — but that is out of scope for this density test.

---

**File 2 — Main config**

```bash
cat > /tmp/windows-density-config.yml << 'EOF'
global:
  gc: false
  measurements:
    - name: vmiLatency

jobs:
  # ============================================================
  # PHASE 1: CREATE — 3 Windows Server 2022 VMs, 4Gi each
  # PVC clone from win2k22 takes 5–15 minutes per VM
  # Windows boot after clone: 3–8 minutes
  # Total time budget: 30–45 minutes
  # ============================================================
  - name: create-windows-vms
    namespace: burner-windows-density
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    qps: 2
    burst: 2
    objects:
      - objectTemplate: /config/windows-density-vm.yml
        replicas: 3
    waitWhenFinished: true
    maxWaitTimeout: 45m
    jobPause: 120s

  # ============================================================
  # PHASE 2: DELETE — remove all Windows VMs and their PVCs
  # ============================================================
  - name: delete-windows-vms
    namespace: burner-windows-density
    jobType: delete
    qps: 2
    burst: 2
    objects:
      - kind: VirtualMachine
        apiVersion: kubevirt.io/v1
        labelSelector:
          kube-burner-job: create-windows-vms
EOF
```

> **Why `qps: 2`?** Cloning a 50Gi Windows PVC is storage-intensive. Running 3 simultaneously already demands ~150Gi of throughput from your storage class. Limiting to 2 concurrent operations prevents CDI from overwhelming the storage backend.

> **Why `maxWaitTimeout: 45m`?** Windows takes 3–8 minutes to boot after a 5–15 minute PVC clone. 45 minutes provides enough headroom for the full pipeline on most clusters.

> **Why `jobPause: 120s`?** Gives 2 minutes of viewing time after all VMs reach Running — enough to show the customer the console and explain what they're looking at.

---

## Step 6b — Verify both files

```bash
ls -lh /tmp/windows-density-vm.yml /tmp/windows-density-config.yml
```

---

## Step 7 — Package into a ConfigMap

```bash
</details>

oc create configmap windows-density-config \
  --from-file=config.yml=/tmp/windows-density-config.yml \
  --from-file=windows-density-vm.yml=/tmp/windows-density-vm.yml \
  -n burner-windows-density
```

---

## Step 8 — Switch to Tab 2 and Tab 3

Before launching, go to:
- **Tab 2:** Virtualization → VirtualMachines → namespace `burner-windows-density`
- **Tab 3:** Storage → PersistentVolumeClaims → namespace `burner-windows-density`

You will watch PVCs clone and VMs boot in real time. **This is the moment** — three Windows Server 2022 VMs coming up on OpenShift, visible in the same console your ops team uses.

---

## Step 9 — Launch the test

**Standard version:**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-windows-density
  namespace: burner-windows-density
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: kube-burner
      restartPolicy: Never
      initContainers:
        - name: copy-config
          image: quay.io/kube-burner/kube-burner:v2.6.1
          command: [sh, -c, "cp /config-src/* /config/"]
          volumeMounts:
            - {name: config-src, mountPath: /config-src}
            - {name: workdir,    mountPath: /config}
      containers:
        - name: kube-burner
          image: quay.io/kube-burner/kube-burner:v2.6.1
          workingDir: /config
          command: [kube-burner, init, -c, /config/config.yml, --uuid=windows-density-001]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: windows-density-config
        - name: workdir
          emptyDir: {}
EOF
```

**Quota-safe version (STIG-hardened clusters):**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-windows-density
  namespace: burner-windows-density
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: kube-burner
      restartPolicy: Never
      initContainers:
        - name: copy-config
          image: quay.io/kube-burner/kube-burner:v2.6.1
          command: [sh, -c, "cp /config-src/* /config/"]
          resources:
            requests:
              memory: 64Mi
              cpu: 100m
            limits:
              memory: 128Mi
              cpu: 200m
          volumeMounts:
            - {name: config-src, mountPath: /config-src}
            - {name: workdir,    mountPath: /config}
      containers:
        - name: kube-burner
          image: quay.io/kube-burner/kube-burner:v2.6.1
          workingDir: /config
          command: [kube-burner, init, -c, /config/config.yml, --uuid=windows-density-001]
          resources:
            requests:
              memory: 128Mi
              cpu: 100m
            limits:
              memory: 256Mi
              cpu: 500m
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: windows-density-config
        - name: workdir
          emptyDir: {}
EOF
```

---

## Step 10 — Watch the PVC clones (Tab 3)

Three 50Gi PVCs will appear and clone from `win2k22`. This takes **5–15 minutes** per VM depending on storage throughput.

```bash
# Watch clone progress
watch "oc get datavolume -n burner-windows-density"
# Wait for PHASE: Succeeded on all three before VMs boot
```

---

## Step 11 — Watch Windows boot (Tab 2)

After PVC clones complete, VMs transition to `Starting`. Windows Server 2022 takes **3–8 minutes** to boot. This is normal.

```bash
watch "oc get vm -n burner-windows-density"
```

**Customer talking point:** *"Windows Server 2022. Three instances. They started simultaneously. We're watching the cluster schedule, provision, and boot them — fully automated, no manual steps."*

---

## Step 12 — Stream the results

```bash
oc logs -f job/kb-windows-density -n burner-windows-density
```

Expected output at completion:

```
level=info msg="create-windows-vms: VMIRunning 99th: 480000 ms  max: 520000 ms  avg: 465000 ms"
level=info msg="create-windows-vms: VMReady 99th: 495000 ms  max: 535000 ms  avg: 478000 ms"
```

**Typical Windows Server 2022 boot time (VMIRunning P99): 400–600 seconds** (7–10 minutes) total pipeline (clone + boot).

---

## Step 13 — OS comparison table

| OS | Test | VMIRunning P99 | RAM/VM | Storage/VM |
|---|---|---|---|---|
| CirrOS | 09 | ~17s | 128Mi | 0 |
| RHEL 9 | 09b | ~145s | 2Gi | 30Gi |
| Windows Server 2022 | **09d** | ~480s | 4Gi | 50Gi |

This table is your answer to "how does Windows compare to Linux on OpenShift Virtualization?"

---

## Step 14 — Clean up

```bash
oc delete job kb-windows-density -n burner-windows-density
oc delete configmap windows-density-config -n burner-windows-density
oc delete project burner-windows-density
```

> **Storage note:** Each Windows PVC is 50Gi. Confirm all 3 PVCs are gone after project deletion: `oc get pvc -n burner-windows-density` should return nothing.

---

## Troubleshooting

| Problem | What to check | Fix |
|---|---|---|
| `win2k22 not found` | Golden image not imported | See [CONCERN-007](../../concerns/CONCERN-007-windows-golden-image-missing.md) — cluster admin must import it |
| PVC stuck in `ImportInProgress` > 20 min | Storage throughput too low for 50Gi clone | Check CDI importer logs; try with `replicas: 1` first |
| VMs stuck in `Starting` > 15 min | Windows still booting | Normal for slow storage; check `oc describe vmi -n burner-windows-density` |
| `failed quota: must specify memory` | STIG ResourceQuota enforced | Use the quota-safe Job variant in Step 9 |
| `permission denied` on DataVolume | CDI RBAC missing | Confirm Step 5 added `cdi.kubevirt.io` rules |
| Windows VMs not live-migratable | `ReadWriteOnce` access mode | This is expected — Windows requires RWO |

---

## What good results look like

| Metric | Good | Investigate |
|---|---|---|
| PVC clone time | 5–15 min per VM | > 30 min per VM |
| VMIRunning P99 | 400–600 seconds | > 900 seconds |
| All 3 VMs reach Running | Yes | Any VM stuck > 20 min after clone completes |
| Storage reclaimed after delete | Yes | PVCs remaining after project deleted |

---

*Previous: [Test 09c — RHEL 9 Escalation](09c-rhel-density-escalation.md) | Next: [Test 09e — Windows Density Escalation](09e-windows-density-escalation.md) | Production scale: [Test 24 — Windows Fleet Density](24-vm-density-windows.md)*
