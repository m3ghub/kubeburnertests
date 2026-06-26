# Test 22C: OCP VMI High-Density Multi-OS Churn

> **Difficulty:** ⭐⭐⭐⭐⭐ Expert — Production Scale  
> **Time to run:** 60–120 minutes  
> **What it does:** Same 4-round progressive structure as Test 22B, but with 10× the VM density — 6 / 16 / 40 / 80 total VMs per round — turning up the heat to production-scale load across two operating systems and two resource profiles  
> **Requires:** OpenShift Virtualization 4.x, 6+ worker nodes, RHEL9 and Fedora DataSources ready, ~400 Gi free storage  
> **Binary:** `kube-burner` v2.7.3 — runs as an in-cluster Job, nothing to install locally

> **⚡ Run Test 22B first:** This test uses the same structure as 22B. Complete 22B successfully so you know the cluster handles the base workload before pushing it to production scale.

---

## What is this test?

Test 22C is the same 4-round progressive design as Test 22B — same OS types, same resource profiles per VM, same churn structure. The only change is the number of VMs per round:

| | 22B (warm-up) | 22C (production scale) |
|---|---|---|
| Round 1 (cirros) | 6 VMs | 6 VMs |
| Round 2 (RHEL9) | 4 VMs | **16 VMs** |
| Round 3 (RHEL9 + Fedora) | 3 + 3 = 6 VMs | **20 + 20 = 40 VMs** |
| Round 4 (RHEL9 + Fedora heavy) | 4 + 4 = 8 VMs | **40 + 40 = 80 VMs** |

This is intentionally hard. At peak (Round 4), the cluster must run 80 VMs simultaneously — each requesting 2 vCPU and 4 Gi RAM — and churn them in batches of 40.

**Resource demand at peak (Round 4):**

| Resource | Per VM | Total (80 VMs) |
|---|---|---|
| vCPU | 2 | 160 vCPU |
| RAM | 4 Gi | 320 Gi |
| Storage | 30 Gi | 2.4 Ti |

**What this proves to a customer:** *"We didn't just run a handful of VMs and call it a day. We ran 80 virtual machines across two operating systems, cycled them out and back twice, and the cluster came out the other side with boot times within 20% of the baseline, no stuck VMs, and a virt-controller memory footprint that returned to near where it started. That is what a production-ready OpenShift Virtualization cluster looks like."*

---

## Round breakdown

| Round | OS | VMs | vCPU each | RAM each | Churn cycles | Approximate duration |
|---|---|---|---|---|---|---|
| R01 | cirros | 6 | 1 | 512Mi | 3 | ~5 minutes |
| R02 | RHEL9 | 16 | 1 | 2Gi | 3 | ~25 minutes |
| R03 | RHEL9 + Fedora | 20 + 20 = 40 | 1 | 2Gi | 3 | ~40 minutes |
| R04 | RHEL9 + Fedora | 40 + 40 = 80 | 2 | 4Gi | 2 | ~50 minutes |

---

## What it measures

| Metric | What it means |
|---|---|
| **VMIRunning P99** | Time from VM creation to Running state across the full fleet |
| **VMReady P99** | Time to full readiness including cloud-init at scale |
| **virt-controller RSS** | Memory footprint under sustained load — watch for drift between rounds |
| **Delete duration** | Time to remove 20 or 40 VMs at once — tests the cleanup pipeline at scale |
| **Scheduler latency** | How long before pods are placed — visible as gap between creation and VMIRunning |
| **Stuck VM count** | Must always be zero — any stuck VM at this scale is a critical finding |

---

## Before you start — open these browser tabs

| Tab | Where | What you watch |
|---|---|---|
| **Tab 1** | Console (terminal) | Streaming kube-burner logs — watch job transitions |
| **Tab 2** | Virtualization → VirtualMachines | VM count climbing to 40, then 80 — and falling during churn |
| **Tab 3** | Observe → Metrics | `process_resident_memory_bytes{pod=~"virt-controller.*"}` |
| **Tab 4** | Observe → Metrics | `kubevirt_vmi_phase_count{phase="Running"}` |
| **Tab 5** | Observe → Metrics | `rate(process_cpu_seconds_total{pod=~"virt-handler.*"}[2m]) * 1000` |

---

## Pre-flight checklist

- [ ] Test 22B completed successfully
- [ ] Logged into the OpenShift web console
- [ ] OpenShift Virtualization installed (`oc get hyperconverged -A`)
- [ ] Cluster-admin permissions
- [ ] RHEL9 DataSource ready: `oc get datasource rhel9 -n openshift-virtualization-os-images`
- [ ] Fedora DataSource ready: `oc get datasource fedora -n openshift-virtualization-os-images`
- [ ] At least 6 worker nodes
- [ ] ~400 Gi free storage for PVC clones (80 VMs × 30 Gi each at peak, spread across rounds)
- [ ] ~320 Gi free RAM across workers (80 VMs × 4 Gi at peak)

> **Storage note:** PVC clones are created and deleted per churn cycle. Peak concurrent storage is one full round at a time — not 80 VMs × 30 Gi all at once — but provision conservatively.

---

## Step-by-step guide

---

### Step 1 — Verify the cluster

```bash
oc whoami
oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l
oc get hyperconverged -A
oc get datasource rhel9 fedora -n openshift-virtualization-os-images
```

Also check allocatable RAM per node to estimate headroom:

```bash
oc get nodes -l node-role.kubernetes.io/worker \
  -o custom-columns='NODE:.metadata.name,RAM:.status.allocatable.memory'
```

---

### Step 2 — Create the project and RBAC

```bash
oc new-project burner-test22c
oc create serviceaccount kube-burner -n burner-test22c
```

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-burner-test22c
rules:
  - apiGroups: [""]
    resources: [namespaces, pods, services, endpoints, configmaps, secrets, nodes, events, serviceaccounts]
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
  - apiGroups: [cdi.kubevirt.io]
    resources: [datavolumes, datasources, dataimportcrons]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods, nodes]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-burner-test22c
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-burner-test22c
subjects:
  - kind: ServiceAccount
    name: kube-burner
    namespace: burner-test22c
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-burner-test22c-monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
  - kind: ServiceAccount
    name: kube-burner
    namespace: burner-test22c
EOF
```

```bash
oc get serviceaccount kube-burner -n burner-test22c
oc get clusterrole kube-burner-test22c
oc get clusterrolebinding kube-burner-test22c kube-burner-test22c-monitoring
```

---

### Step 3 — Write the 6 VM template files

These are identical in structure to 22B. The only difference is the `app: test22c-churn` label and the VM name prefix. Replica counts live in the config file, not in the templates.

**File 1 — `vm-r1-cirros.yml`**

```bash
cat > /tmp/vm-r1-cirros.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r1-cirros-{{.Iteration}}-{{.Replica}}
  labels:
    app: test22c-churn
    round: r01
    os: cirros
spec:
  running: true
  template:
    metadata:
      labels:
        app: test22c-churn
        round: r01
        os: cirros
    spec:
      domain:
        cpu:
          cores: 1
        resources:
          requests:
            memory: 512Mi
        devices:
          disks:
            - name: containerdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/kubevirt/cirros-registry-disk-demo:latest
EOF
```

**File 2 — `vm-r2-rhel9.yml`**

```bash
cat > /tmp/vm-r2-rhel9.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r2-rhel9-{{.Iteration}}-{{.Replica}}
  labels:
    app: test22c-churn
    round: r02
    os: rhel9
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: r2-rhel9-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: rhel9
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    metadata:
      labels:
        app: test22c-churn
        round: r02
        os: rhel9
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
            name: r2-rhel9-disk-{{.Iteration}}-{{.Replica}}
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: r2-rhel9-{{.Iteration}}-{{.Replica}}
EOF
```

**File 3 — `vm-r3-rhel9.yml`**

```bash
cat > /tmp/vm-r3-rhel9.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r3-rhel9-{{.Iteration}}-{{.Replica}}
  labels:
    app: test22c-churn
    round: r03
    os: rhel9
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: r3-rhel9-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: rhel9
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    metadata:
      labels:
        app: test22c-churn
        round: r03
        os: rhel9
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
            name: r3-rhel9-disk-{{.Iteration}}-{{.Replica}}
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: r3-rhel9-{{.Iteration}}-{{.Replica}}
EOF
```

**File 4 — `vm-r3-fedora.yml`**

```bash
cat > /tmp/vm-r3-fedora.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r3-fedora-{{.Iteration}}-{{.Replica}}
  labels:
    app: test22c-churn
    round: r03
    os: fedora
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: r3-fedora-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: fedora
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    metadata:
      labels:
        app: test22c-churn
        round: r03
        os: fedora
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
            name: r3-fedora-disk-{{.Iteration}}-{{.Replica}}
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: r3-fedora-{{.Iteration}}-{{.Replica}}
EOF
```

**File 5 — `vm-r4-rhel9.yml`**

```bash
cat > /tmp/vm-r4-rhel9.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r4-rhel9-{{.Iteration}}-{{.Replica}}
  labels:
    app: test22c-churn
    round: r04
    os: rhel9
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: r4-rhel9-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: rhel9
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    metadata:
      labels:
        app: test22c-churn
        round: r04
        os: rhel9
    spec:
      domain:
        cpu:
          cores: 2
        resources:
          requests:
            memory: 4Gi
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
            name: r4-rhel9-disk-{{.Iteration}}-{{.Replica}}
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: r4-rhel9-{{.Iteration}}-{{.Replica}}
EOF
```

**File 6 — `vm-r4-fedora.yml`**

```bash
cat > /tmp/vm-r4-fedora.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r4-fedora-{{.Iteration}}-{{.Replica}}
  labels:
    app: test22c-churn
    round: r04
    os: fedora
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: r4-fedora-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: fedora
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    metadata:
      labels:
        app: test22c-churn
        round: r04
        os: fedora
    spec:
      domain:
        cpu:
          cores: 2
        resources:
          requests:
            memory: 4Gi
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
            name: r4-fedora-disk-{{.Iteration}}-{{.Replica}}
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: r4-fedora-{{.Iteration}}-{{.Replica}}
EOF
```

---

### Step 4 — Get the main config file

**Option A — Download from repo (recommended):**

```bash
BASE="https://raw.githubusercontent.com/m3ghub/kubeburnertests/main/docs/tests/files/22c-ocp-vmi-high-density-churn"

curl --fail -sL "${BASE}/test22c-churn-config.yml" -o /tmp/test22c-churn-config.yml
```

Verify (must not print `404` or `<!DOCTYPE`):

```bash
head -3 /tmp/test22c-churn-config.yml
# Expected:
# global:
#   gc: false
```

<details>
<summary><strong>Option B — Paste manually (air-gapped / private repo)</strong></summary>

```bash
cat > /tmp/test22c-churn-config.yml << 'EOF'
global:
  gc: false
  measurements:
    - name: vmiLatency

jobs:
  # ============================================================
  # ROUND 1: CirrOS only — 6 VMs, 1vCPU/512Mi, 3 churn cycles
  # Same as 22B: containerDisk baseline, warms up control plane
  # Confirms image cache and scheduler are ready before real OS
  # ============================================================
  - name: r01-cre-cirros
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 10m
    objects:
      - objectTemplate: vm-r1-cirros.yml
        replicas: 6

  - name: r01-c1-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r01-cre-cirros

  - name: r01-c1-cre
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 10m
    objects:
      - objectTemplate: vm-r1-cirros.yml
        replicas: 6

  - name: r01-c2-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r01-c1-cre

  - name: r01-c2-cre
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 10m
    objects:
      - objectTemplate: vm-r1-cirros.yml
        replicas: 6

  - name: r01-c3-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r01-c2-cre

  - name: r01-c3-cre
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 10m
    objects:
      - objectTemplate: vm-r1-cirros.yml
        replicas: 6

  - name: r01-final-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          round: r01

  # ============================================================
  # ROUND 2: RHEL9 only — 16 VMs, 1vCPU/2Gi, 3 churn cycles
  # 4x the density of 22B Round 2 — PVC clone pressure begins
  # CDI controller load visible; memory graphs step up sharply
  # ============================================================
  - name: r02-cre-rhel9
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 30m
    objects:
      - objectTemplate: vm-r2-rhel9.yml
        replicas: 16

  - name: r02-c1-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r02-cre-rhel9

  - name: r02-c1-cre
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 30m
    objects:
      - objectTemplate: vm-r2-rhel9.yml
        replicas: 16

  - name: r02-c2-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r02-c1-cre

  - name: r02-c2-cre
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 30m
    objects:
      - objectTemplate: vm-r2-rhel9.yml
        replicas: 16

  - name: r02-c3-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r02-c2-cre

  - name: r02-c3-cre
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 30m
    objects:
      - objectTemplate: vm-r2-rhel9.yml
        replicas: 16

  - name: r02-final-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          round: r02

  # ============================================================
  # ROUND 3: RHEL9 + Fedora mixed — 20+20=40 VMs, 1vCPU/2Gi, 3 cycles
  # Mixed OS at scale: CDI handles 40 concurrent PVC clones
  # Dashboards clearly moving; both OS rows visible in console
  # ============================================================
  - name: r03-cre-rhel9
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: false
    maxWaitTimeout: 45m
    objects:
      - objectTemplate: vm-r3-rhel9.yml
        replicas: 20

  - name: r03-cre-fedora
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 45m
    objects:
      - objectTemplate: vm-r3-fedora.yml
        replicas: 20

  - name: r03-c1-del-rhel9
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r03-cre-rhel9

  - name: r03-c1-cre-rhel9
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: false
    maxWaitTimeout: 45m
    objects:
      - objectTemplate: vm-r3-rhel9.yml
        replicas: 20

  - name: r03-c1-del-fedora
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r03-cre-fedora

  - name: r03-c1-cre-fedora
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 45m
    objects:
      - objectTemplate: vm-r3-fedora.yml
        replicas: 20

  - name: r03-c2-del-rhel9
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r03-c1-cre-rhel9

  - name: r03-c2-cre-rhel9
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: false
    maxWaitTimeout: 45m
    objects:
      - objectTemplate: vm-r3-rhel9.yml
        replicas: 20

  - name: r03-c2-del-fedora
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r03-c1-cre-fedora

  - name: r03-c2-cre-fedora
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 45m
    objects:
      - objectTemplate: vm-r3-fedora.yml
        replicas: 20

  - name: r03-c3-del-rhel9
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r03-c2-cre-rhel9

  - name: r03-c3-cre-rhel9
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: false
    maxWaitTimeout: 45m
    objects:
      - objectTemplate: vm-r3-rhel9.yml
        replicas: 20

  - name: r03-c3-del-fedora
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r03-c2-cre-fedora

  - name: r03-c3-cre-fedora
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 45m
    objects:
      - objectTemplate: vm-r3-fedora.yml
        replicas: 20

  - name: r03-final-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          round: r03

  # ============================================================
  # ROUND 4: RHEL9 + Fedora heavy — 40+40=80 VMs, 2vCPU/4Gi, 2 cycles
  # Maximum pressure: 80 VMs total, ~320Gi RAM, 160 vCPU requested
  # Full production-scale wall test — this IS the ceiling probe
  # ============================================================
  - name: r04-cre-rhel9
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: false
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r4-rhel9.yml
        replicas: 40

  - name: r04-cre-fedora
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r4-fedora.yml
        replicas: 40

  - name: r04-c1-del-rhel9
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r04-cre-rhel9

  - name: r04-c1-cre-rhel9
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: false
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r4-rhel9.yml
        replicas: 40

  - name: r04-c1-del-fedora
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r04-cre-fedora

  - name: r04-c1-cre-fedora
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r4-fedora.yml
        replicas: 40

  - name: r04-c2-del-rhel9
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r04-c1-cre-rhel9

  - name: r04-c2-cre-rhel9
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: false
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r4-rhel9.yml
        replicas: 40

  - name: r04-c2-del-fedora
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r04-c1-cre-fedora

  - name: r04-c2-cre-fedora
    namespace: burner-test22c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r4-fedora.yml
        replicas: 40

  - name: r04-final-del
    namespace: burner-test22c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          app: test22c-churn
EOF
```

</details>

---

### Step 5 — Verify all 7 files exist

```bash
ls -lh /tmp/test22c-churn-config.yml \
        /tmp/vm-r1-cirros.yml \
        /tmp/vm-r2-rhel9.yml \
        /tmp/vm-r3-rhel9.yml \
        /tmp/vm-r3-fedora.yml \
        /tmp/vm-r4-rhel9.yml \
        /tmp/vm-r4-fedora.yml
```

All 7 must show non-zero file sizes before continuing.

---

### Step 6 — Create the ConfigMap

```bash
oc create configmap test22c-churn-config \
  --from-file=config.yml=/tmp/test22c-churn-config.yml \
  --from-file=vm-r1-cirros.yml=/tmp/vm-r1-cirros.yml \
  --from-file=vm-r2-rhel9.yml=/tmp/vm-r2-rhel9.yml \
  --from-file=vm-r3-rhel9.yml=/tmp/vm-r3-rhel9.yml \
  --from-file=vm-r3-fedora.yml=/tmp/vm-r3-fedora.yml \
  --from-file=vm-r4-rhel9.yml=/tmp/vm-r4-rhel9.yml \
  --from-file=vm-r4-fedora.yml=/tmp/vm-r4-fedora.yml \
  -n burner-test22c

oc get configmap test22c-churn-config -n burner-test22c
```

Expected: `configmap/test22c-churn-config created` with `DATA: 7`.

---

### Step 7 — Switch to Tab 2

Go to **Virtualization → VirtualMachines**, filter to `burner-test22c`. What you'll see is visually different from 22B — the VM count climbs much higher before the churn cycles start dropping it:

- **R01:** 6 VMs — same as 22B, fast cirros baseline
- **R02:** 16 VMs — first real jump, all RHEL9, PVC clones for each
- **R03:** VM count climbs to 40 — 20 RHEL9 and 20 Fedora visible simultaneously. The mix makes the list visually diverse.
- **R04:** VM count reaches 80 — the screen fills up. When churn starts, batches of 40 vanish and reappear.

---

### Step 8 — Set up Observe queries

Open **Observe → Metrics** now so baseline is captured from the start of the run.

```
# virt-controller memory — should plateau under load and recover after each round
process_resident_memory_bytes{pod=~"virt-controller.*"}
```

```
# Running VM count — shows the sawtooth pattern of each churn cycle
kubevirt_vmi_phase_count{phase="Running"}
```

```
# virt-handler CPU per node — spikes during each batch delete+recreate
rate(process_cpu_seconds_total{pod=~"virt-handler.*"}[2m]) * 1000
```

```
# CDI controller — watch for clone queue pressure during R03 and R04
rate(process_cpu_seconds_total{pod=~"cdi-deployment.*"}[2m]) * 1000
```

> **The CDI query is new for 22C.** At 40–80 PVC clones running simultaneously, CDI will become visible in the metrics. In 22B the clone count was low enough that CDI was barely measurable.

---

### Step 9 — Launch the kube-burner job

```bash
UUID="test22c-$(date +%s)"
echo "UUID: $UUID"

cat << JOBYAML | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-test22c-churn
  namespace: burner-test22c
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: kube-burner
      restartPolicy: Never
      initContainers:
        - name: copy-config
          image: quay.io/kube-burner/kube-burner:v2.7.3
          command: [sh, -c, "cp /config-src/* /config/"]
          volumeMounts:
            - {name: config-src, mountPath: /config-src}
            - {name: workdir,    mountPath: /config}
      containers:
        - name: kube-burner
          image: quay.io/kube-burner/kube-burner:v2.7.3
          workingDir: /config
          command: [kube-burner, init, -c, /config/config.yml, --uuid=${UUID}]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: test22c-churn-config
        - name: workdir
          emptyDir: {}
JOBYAML
```

---

### Step 10 — Stream logs

```bash
oc get pod -n burner-test22c -w
```

Wait for `Running`, then stream:

```bash
oc logs -f job/kb-test22c-churn -n burner-test22c
```

Each round transition is clearly logged:

```
INFO Triggering job: r01-cre-cirros        ← Round 1: 6 cirros
INFO Job r01-cre-cirros took 24s
...
INFO Triggering job: r02-cre-rhel9         ← Round 2: 16 RHEL9
INFO Job r02-cre-rhel9 took ~8m
...
INFO Triggering job: r03-cre-rhel9         ← Round 3: 40 mixed
INFO Triggering job: r03-cre-fedora
...
INFO Triggering job: r04-cre-rhel9         ← Round 4: 80 heavy
INFO Triggering job: r04-cre-fedora
INFO VMIRunning P99=...
INFO Finished execution with UUID: test22c-...
```

---

### Step 11 — What to say at each phase

**During R01 (6 cirros):**
*"Same control-plane warm-up as Test 22B. Six cirros VMs, three cycles. Fast and clean — establishes the baseline."*

**During R02 (16 RHEL9 appearing):**
*"Now we're at 16 real RHEL9 VMs, each cloning a 30 Gi disk. That's 480 Gi of clone operations running in parallel. Watch Tab 2 as they all try to reach Running state at the same time."*

**During R03 (count climbing to 40):**
*"Two operating systems, 40 VMs total. In Tab 4 you can see the Running count reaching 40 and then dropping by 20 when we start a churn cycle. Watch the CDI query in Tab 5 — at this scale the clone controller becomes visible in the metrics."*

**During R04 (count reaching 80):**
*"This is the full wall test. 80 VMs, 160 vCPU, 320 Gi RAM. When churn starts, 40 VMs disappear and 40 new ones have to clone their disks and boot. Watch virt-controller RSS in Tab 3 — if it plateaus and returns to near-baseline after R04, the memory management is solid under production-scale load."*

---

### Step 12 — What good looks like

| Metric | Healthy | Investigate |
|---|---|---|
| R01 VMIRunning P99 | < 30s | > 60s |
| R02 VMIRunning P99 | < 90s | > 5 minutes |
| R03 VMIRunning P99 | < 120s | > 8 minutes |
| R04 VMIRunning P99 | < 180s | > 12 minutes |
| virt-controller RSS at R04 peak | < 400 MiB | > 800 MiB |
| virt-controller RSS post-test | Returns toward baseline | Keeps climbing |
| Stuck VMs | 0 at end of any round | Any |
| Final VM count | 0 | Any remaining |

> **Why thresholds are higher than 22B:** At 16–80 VMs, CDI clone queue depth and scheduler pack time both increase. Boot times scaling with fleet size is expected — what matters is that they scale gracefully, not exponentially.

---

### Step 13 — Clean up

```bash
oc delete job kb-test22c-churn -n burner-test22c 2>/dev/null || true
oc delete vm -l app=test22c-churn -n burner-test22c 2>/dev/null || true
oc delete configmap test22c-churn-config -n burner-test22c 2>/dev/null || true
oc delete project burner-test22c
oc delete clusterrole kube-burner-test22c 2>/dev/null || true
oc delete clusterrolebinding kube-burner-test22c kube-burner-test22c-monitoring 2>/dev/null || true
```

Verify clean:

```bash
oc get projects | grep burner-test22c
oc get vm -A 2>/dev/null | grep test22c
# Both should return nothing
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| R04 VMs stuck in Pending | Insufficient RAM — reduce R04 replicas from 40 to 20 in the config, or verify node headroom with `oc describe node` |
| R03/R04 VMIRunning timeout | CDI clone queue is saturated — check `oc get datavolumes -A` for stuck clones |
| R02 taking > 30 minutes | RHEL9 golden image not cached on nodes — first run is always slower; subsequent rounds benefit from caching |
| `no space left on device` | Storage class is full — `oc get pvc -A` to audit usage, reduce replicas |
| ConfigMap already exists on rerun | `oc delete configmap test22c-churn-config -n burner-test22c` then recreate |
| `serviceaccount "kube-burner" not found` | Re-run Step 2 |
| R04 never completes | `maxWaitTimeout: 60m` is the hard limit — if your cluster is undersized for 80 VMs, R04 will time out. Reduce replicas. |

---

## How 22B and 22C fit together

| | 22B | 22C |
|---|---|---|
| Purpose | Prove the structure works; warm up the cluster | Push to production-scale density |
| Total VMs per run | 6 / 6 / 6 / 8 | **6 / 16 / 40 / 80** |
| Duration | 20–30 min | 60–120 min |
| Cluster size | 3+ workers | **6+ workers** |
| CDI visible in metrics? | No | **Yes** |
| Customer narrative | "The foundation is solid" | "Production-scale — and it held" |

*Test 22C follows Test 22B. Together they form the complete progressive churn sequence: 22B confirms structure, 22C confirms scale.*
