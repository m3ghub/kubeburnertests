# Test 09b: RHEL 9 KubeVirt Density — Real OS Virtual Machine Lifecycle

> **Difficulty:** ⭐⭐⭐ Advanced  
> **Time to run:** ~30 minutes  
> **What it does:** Creates, starts, and deletes RHEL 9 Virtual Machines using OpenShift Virtualization — measures real-OS VM boot latency and lifecycle performance  
> **Requires:** OpenShift Virtualization 4.x, `rhel9` DataSource ready in `openshift-virtualization-os-images`, storage class that supports dynamic provisioning  
> **Companion test:** This is the RHEL 9 variant of [Test 09](09-kubevirt-density.md). Run Test 09 first to confirm your cluster can boot VMs, then use this test to establish your RHEL baseline.

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable and your environment is ready — see **[00-preflight.md](00-preflight.md)** (Checks 1–6 all apply).

> **STIG / quota-enforced clusters:** If your cluster enforces a `ResourceQuota`, use the quota-safe Job variant in Step 9. Run `oc get resourcequota -n burner-rhel-density` to check. See [CONCERN-013](../../concerns/CONCERN-013-stig-resource-quota.md).

---

![Diagram](../../diagrams/tests/png/09b-rhel-density.png)


## What is this test? 🖥️🐧

[Test 09](09-kubevirt-density.md) uses CirrOS — a 5 MB toy OS that boots in 15 seconds. That is great for measuring raw scheduling speed, but it tells you nothing about real workload performance.

This test runs the **identical lifecycle** (create → boot → delete, measure P99 latency) using **RHEL 9** — the same OS running your production applications. The difference shows you:

- **How long a RHEL 9 VM actually takes to boot** on your cluster (60–120 seconds is normal)
- **Whether your storage can clone the golden image fast enough** under load
- **Whether your cluster has the capacity** to run multiple real-OS VMs simultaneously

This is the benchmark your virtualisation team cares about — not CirrOS toy numbers, but real RHEL boot times.

---

## What does it measure?

| Metric | What it means |
|---|---|
| **VMIRunning P99** | How long until the 99th percentile RHEL VM reached Running state |
| **VMReady P99** | How long until the VM passed its readiness check |
| **PVC clone time** | How fast CDI cloned the RHEL golden image per VM (visible in DataVolume events) |
| **Storage throughput** | I/O pressure on the storage class during simultaneous PVC cloning |

---

## How it works

```
PVC Clone          Boot               Ready              Delete
──────────         ──────────         ──────────         ──────────
CDI clones         RHEL 9 VM          VM passes          All VMs and
rhel9 golden       boots from         readiness          PVCs removed
PVC → new 30Gi     cloned disk        check              from cluster
PVC per VM         (60–120s)          ✅ Running          ✅ Done
```

---

## Before you start — open these browser tabs

| Tab | Where to go | What you will watch |
|---|---|---|
| **Tab 1** | Web terminal | Commands |
| **Tab 2** | Virtualization → VirtualMachines | VMs appearing and changing state |
| **Tab 3** | Storage → PersistentVolumeClaims | PVCs being cloned from RHEL golden image |
| **Tab 4** | Observe → Dashboards → KubeVirt / Infrastructure Resources | CPU, memory, storage I/O |

---

## Pre-flight checklist

- [ ] Logged into OpenShift web console
- [ ] OpenShift Virtualization installed (`oc get hyperconverged -A`)
- [ ] `rhel9` DataSource is `Ready: True` in `openshift-virtualization-os-images`
- [ ] Storage class supports dynamic provisioning and at least 90Gi free (3 VMs × 30Gi)
- [ ] At least 2 worker nodes with ~6Gi free RAM (3 VMs × 2Gi)
- [ ] ~30 minutes free

**Verify the RHEL golden image is ready:**

```bash
oc get datasource rhel9 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True
```

If it returns `False` or nothing — the golden image is not imported. Ask your cluster administrator to enable the RHEL 9 golden image import via the OpenShift Virtualization operator.

---

## Step-by-step guide

---

### Step 1 — Open the web terminal

Click the **`>_` icon** in the top-right of the OpenShift console. Confirm you are logged in:

```bash
oc whoami
```

---

### Step 2 — Verify OpenShift Virtualization is installed

```bash
oc get hyperconverged -A
```

Expected output shows `kubevirt-hyperconverged` in `openshift-cnv` namespace. If nothing returns, stop and install OpenShift Virtualization first.

---

### Step 3 — Verify the RHEL 9 golden image

```bash
oc get datasource rhel9 -n openshift-virtualization-os-images
```

The `READY` column must show `True`. If it shows `False`:

```bash
oc describe datasource rhel9 -n openshift-virtualization-os-images
# Look at the Conditions section for the reason
```

---

### Step 4 — Create the project

```bash
oc new-project burner-rhel-density
```

---

### Step 5 — Create the Service Account

```bash
oc create serviceaccount kube-burner -n burner-rhel-density
```

---

### Step 6 — Apply permissions (RBAC)

RHEL VMs need CDI (Containerized Data Importer) permissions in addition to the standard KubeVirt permissions — CDI manages the PVC clone from the golden image.

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
    namespace: burner-rhel-density
EOF
```

> **Note the addition vs Test 09:** The `cdi.kubevirt.io` apiGroup is required for DataVolume operations. Without it, the PVC clone from the RHEL golden image is rejected with a permission error.

---

### Step 7 — Create the config files

**File 1 — RHEL 9 VM template**

```bash
**Option A — Download from repo (recommended):**

```bash
BASE="https://raw.githubusercontent.com/m3ghub/kubeburnertests/main/docs/tests/files/09b-rhel-density"

curl --fail -sL "${BASE}/rhel-density-vm.yml" -o /tmp/rhel-density-vm.yml
curl --fail -sL "${BASE}/rhel-density-config.yml" -o /tmp/rhel-density-config.yml
```

Verify:

```bash
head -2 /tmp/rhel-density-vm.yml   # must start with: apiVersion: kubevirt.io/v1 or global:
head -2 /tmp/rhel-density-config.yml   # must start with: apiVersion: kubevirt.io/v1 or global:
```

<details>
<summary><strong>Option B — Paste manually (air-gapped / private cluster)</strong></summary>

cat > /tmp/rhel-density-vm.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: rhel-vm-{{.Iteration}}-{{.Replica}}
  labels:
    app: kube-burner-rhel
    kube-burner-job: create-rhel-vms
spec:
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: rhel-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: rhel9
          namespace: openshift-virtualization-os-images
        storage:
          storageClassName: ""       # Leave blank to use cluster default
          accessModes:
            - ReadWriteMany          # ReadWriteMany enables live migration
          resources:
            requests:
              storage: 30Gi
  template:
    metadata:
      labels:
        app: kube-burner-rhel
        kube-burner-job: create-rhel-vms
    spec:
      domain:
        cpu:
          cores: 1
        resources:
          requests:
            memory: 2Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: rhel-disk-{{.Iteration}}-{{.Replica}}
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: rhel-vm-{{.Iteration}}-{{.Replica}}
              user: cloud-user
              password: redhat123
              chpasswd:
                expire: false
              ssh_pwauth: true
EOF
```

> **`storageClassName: ""`** — leave blank to use your cluster's default storage class. To use a specific class, replace `""` with the class name from `oc get storageclass`.

---

**File 2 — Main config**

```bash
cat > /tmp/rhel-density-config.yml << 'EOF'
global:
  gc: false
  measurements:
    - name: vmiLatency

jobs:
  # ============================================================
  # PHASE 1: CREATE — 3 RHEL 9 VMs, 2Gi each
  # PVC clone from golden image takes 2–5 minutes before boot
  # VMIRunning P99 target: < 180s on healthy cluster
  # ============================================================
  - name: create-rhel-vms
    namespace: burner-rhel-density
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    qps: 3
    burst: 3
    objects:
      - objectTemplate: /config/rhel-density-vm.yml
        replicas: 3
    waitWhenFinished: true
    maxWaitTimeout: 20m
    jobPause: 60s

  # ============================================================
  # PHASE 2: DELETE — remove all RHEL VMs and their PVCs
  # ============================================================
  - name: delete-rhel-vms
    namespace: burner-rhel-density
    jobType: delete
    qps: 3
    burst: 3
    objects:
      - kind: VirtualMachine
        apiVersion: kubevirt.io/v1
        labelSelector:
          kube-burner-job: create-rhel-vms
EOF
```

> **Why `qps: 3` instead of 5?** Each RHEL VM triggers a 30Gi PVC clone from the golden image. Launching too many simultaneously can overload the CDI importer and the storage backend. 3 concurrent clones is a safe starting point.

> **Why `maxWaitTimeout: 20m`?** RHEL 9 takes 60–120 seconds to boot after the PVC clone completes. The clone itself takes 2–5 minutes. 20 minutes gives the full pipeline enough headroom on a healthy cluster.

---

### Step 7b — Verify both files

```bash
ls -lh /tmp/rhel-density-vm.yml /tmp/rhel-density-config.yml
```

Both must show non-zero sizes before continuing.

---

### Step 8 — Package into a ConfigMap

```bash
</details>

oc create configmap rhel-density-config \
  --from-file=config.yml=/tmp/rhel-density-config.yml \
  --from-file=rhel-density-vm.yml=/tmp/rhel-density-vm.yml \
  -n burner-rhel-density
```

---

### Step 9 — Launch the test

**Standard version:**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-rhel-density
  namespace: burner-rhel-density
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=rhel-density-001]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: rhel-density-config
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
  name: kb-rhel-density
  namespace: burner-rhel-density
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=rhel-density-001]
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
            name: rhel-density-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Step 10 — Watch the PVC clones (Tab 3)

Switch to **Storage → PersistentVolumeClaims** in the console, filtered to `burner-rhel-density`.

You will see 3 PVCs appear. Their status cycles:

| PVC status | Meaning |
|---|---|
| `Pending` | CDI waiting to start import |
| `Bound` (with DataVolume `ImportInProgress`) | Cloning from golden image |
| `Bound` (DataVolume `Succeeded`) | Clone complete — VM can now boot |

**This is what to show a customer here:** *"Each of these PVCs is a full 30Gi RHEL 9 disk being cloned from the golden master image — on-demand, in parallel, with no manual intervention."*

---

### Step 11 — Watch the VMs boot (Tab 2)

Switch to **Virtualization → VirtualMachines**, namespace `burner-rhel-density`.

VMs appear after their PVC clone completes. State progression:

`Stopped` → `Starting` → `Running` ✅

RHEL 9 typically takes **60–120 seconds** to boot after the disk is ready. This is normal — you are watching a full operating system boot, not a container start.

---

### Step 12 — Stream the live results

```bash
oc logs -f job/kb-rhel-density -n burner-rhel-density
```

Look for lines like:

```
level=info msg="create-rhel-vms: VMIRunning 99th: 145000 ms  max: 162000 ms  avg: 138000 ms"
level=info msg="create-rhel-vms: VMReady 99th: 148000 ms  max: 165000 ms  avg: 141000 ms"
```

**Typical RHEL 9 boot time (VMIRunning P99): 120–180 seconds** on a healthy cluster with fast storage.  
If your VMs take longer than 300 seconds, check storage class throughput and CDI importer logs.

---

### Step 13 — Compare against CirrOS baseline

| Metric | CirrOS (Test 09) | RHEL 9 (Test 09b) | Ratio |
|---|---|---|---|
| VMIRunning P99 | ~17s | ~145s | ~8× slower |
| VMReady P99 | ~17s | ~150s | ~9× slower |
| RAM per VM | 128Mi | 2Gi | 16× more |
| Storage per VM | 0 | 30Gi | — |

This comparison is the answer to: *"How much slower is a real OS vs a toy benchmark?"*

---

### Step 14 — Clean up

```bash
oc delete job kb-rhel-density -n burner-rhel-density
oc delete configmap rhel-density-config -n burner-rhel-density
oc delete project burner-rhel-density
```

> **Note:** Deleting the project also deletes the 3 × 30Gi PVCs. Confirm storage is reclaimed with `oc get pvc -n burner-rhel-density` (should return nothing after the project is deleted).

---

## Troubleshooting

| Problem | What to check | Fix |
|---|---|---|
| `datasource rhel9 not found` | Golden image not imported | Ask cluster admin to enable RHEL 9 golden image in OCP Virt operator |
| `DataVolume stuck in ImportInProgress` | Storage class too slow or capacity issue | Check CDI importer logs: `oc logs -n openshift-cnv -l app=containerized-data-importer` |
| VMs stuck in `Starting` > 5 min | Golden image clone still in progress | Check `oc get datavolume -n burner-rhel-density` — wait for `PHASE: Succeeded` |
| `permission denied` on DataVolume | CDI RBAC not applied | Confirm Step 6 added `cdi.kubevirt.io` rules to the ClusterRole |
| `failed quota: must specify memory` | STIG ResourceQuota enforced | Use the quota-safe Job variant in Step 9 |
| PVCs not cleaning up after delete | PVC reclaim policy is `Retain` | Manually delete: `oc delete pvc --all -n burner-rhel-density` |

---

## What good results look like

| Metric | Good | Investigate |
|---|---|---|
| PVC clone time per VM | 2–5 minutes | > 10 minutes |
| VMIRunning P99 | 120–180 seconds | > 300 seconds |
| All VMs reach Running | Yes | Any VM stuck in `Starting` > 10 min |
| Storage reclaimed after delete | Yes | PVCs remaining after project deleted |

---

*Next: [Test 09c — RHEL 9 Density Escalation](09c-rhel-density-escalation.md) | Compare with: [Test 09 — CirrOS Density](09-kubevirt-density.md) | Production scale: [Test 23 — RHEL Fleet Density](23-vm-density-rhel.md)*
