# Test 15C: VM Churn — Windows Server Variant

> **Difficulty:** ⭐⭐⭐⭐⭐ Expert  
> **Time to run:** 45–90 minutes  
> **What it does:** Runs 3 escalating rounds of VM churn using real Windows Server 2022 virtual machines cloned from the OpenShift golden image — the most demanding churn test due to Windows boot times and disk size  
> **Requires:** OpenShift Virtualization (KubeVirt) installed, Windows Server 2022 DataSource ready (`windows2k22`)  
> **Binary:** `kube-burner` v2.7.3 — runs as an in-cluster Job, nothing to install locally

> **⚡ Run Test 15 first:** This test builds on Test 15. Complete Test 15 successfully before running 15C.

---

## What is this test?

Windows Server VMs are the hardest type of virtual machine to churn:

- Each VM needs a **60–100 Gi disk clone** (compared to 30 Gi for RHEL9)
- Windows Server boot takes **3–5 minutes** (compared to 35–45 seconds for RHEL9)
- Windows requires **more CPU and RAM** per VM to boot and idle stably
- The `sysprep` / `cloudbase-init` first-boot process adds additional time after the OS kernel starts

Test 15C deliberately puts this pressure on your cluster in a continuous create-delete cycle, proving that your storage subsystem, virt-controller, and scheduler can handle the heaviest type of real-world VM workload without degrading.

The 3 rounds escalate:

| Round | VMs | vCPU | RAM each | Disk | Churn cycles | What it stresses |
|---|---|---|---|---|---|---|
| R01 | 2 | 2 | 4Gi | 60Gi | 2 | Baseline Windows — boot + clone pipeline |
| R02 | 3 | 2 | 4Gi | 60Gi | 2 | Parallel clones — storage throughput |
| R03 | 4 | 4 | 8Gi | 60Gi | 2 | Heavy Windows fleet — maximum virt pressure |

> **Why fewer VMs than RHEL9?** Windows VMs consume significantly more resources per instance. 4 heavy Windows VMs (4vCPU/8Gi each) is equivalent stress to 8+ RHEL9 VMs. Quality over quantity.

**What this proves:** *"We ran real Windows Server 2022 virtual machines through continuous create-and-destroy cycles. Every VM booted the full Windows OS from a cloned disk. The cluster held through three escalating rounds without stuck VMs, without storage timeouts, and without the virt-controller losing control. If you need to run Windows workloads on OpenShift Virtualisation, this cluster is ready."*

---

## What it measures

| Metric | What it means |
|---|---|
| **VMIRunning P99** | Time from VM creation to Running — includes 60Gi disk clone + full Windows boot |
| **VMReady P99** | Time to full readiness including cloudbase-init completion |
| **CDI clone duration** | How long each 60Gi DataVolume clone takes — key bottleneck |
| **virt-controller RSS** | Memory footprint — should stay flat between rounds |
| **Delete duration** | Time to fully remove Windows VMs and their PVCs |
| **Stuck VM count** | VMs that never reach Running (should always be zero) |

---

## Before you start — open these browser tabs

| Tab | Where | What you watch |
|---|---|---|
| **Tab 1** | Console (already open) | Terminal — streaming kube-burner logs |
| **Tab 2** | Virtualization → VirtualMachines | VM status — watch `Provisioning` → `Starting` → `Running` |
| **Tab 3** | Storage → PersistentVolumeClaims | 60Gi PVCs being cloned — filter by `burner-test15c` |
| **Tab 4** | Observe → Metrics | `process_resident_memory_bytes{pod=~"virt-controller.*"}` |

---

## Pre-flight checklist

- [ ] Test 15 completed successfully
- [ ] Logged into the OpenShift web console
- [ ] OpenShift Virtualization installed: `oc get hyperconverged -A` returns a result
- [ ] Cluster-admin permissions
- [ ] Windows Server 2022 DataSource ready:

```bash
oc get datasource windows2k22 -n openshift-virtualization-os-images
```

Must show `READY: True`. If not, the golden image has not finished importing.

- [ ] At least 3 worker nodes with ~32 Gi free RAM total (R03 needs 4 × 8Gi)
- [ ] At least 240 Gi free storage (4 VMs × 60 Gi per clone)

> **Storage check:** If your storage class is thin-provisioned (e.g., ODF/Ceph), the 240 Gi is a soft reservation. Run `oc get pv --sort-by=.spec.capacity.storage` to confirm available capacity before starting.

---

## Step-by-step guide

---

### Step 1 — Open the web terminal and verify the cluster

Click the **`>_` icon** in the top-right toolbar of the OpenShift console. Run:

```bash
oc whoami
oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l
oc get hyperconverged -A
oc get datasource windows2k22 -n openshift-virtualization-os-images
```

`windows2k22` must show `READY: True` before continuing.

---

### Step 2 — Create the project and RBAC

```bash
oc new-project burner-test15c
oc create serviceaccount kube-burner -n burner-test15c
```

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-burner-test15c
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
  name: kube-burner-test15c
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-burner-test15c
subjects:
  - kind: ServiceAccount
    name: kube-burner
    namespace: burner-test15c
EOF
```

Verify all objects exist:

```bash
oc get serviceaccount kube-burner -n burner-test15c
oc get clusterrole kube-burner-test15c
oc get clusterrolebinding kube-burner-test15c
```

---

### Step 3 — Write the 3 VM template files

Run each block one at a time — paste the full block including the `EOF` line.

**File 1 — `vm-r1-win2k22.yml` (Round 1: 2 VMs, 2vCPU/4Gi)**

```bash
cat > /tmp/vm-r1-win2k22.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r1-win2k22-{{.Iteration}}-{{.Replica}}
  labels:
    app: test15c-churn
    round: r01
    os: windows2k22
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: r1-win2k22-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: windows2k22
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 60Gi
  template:
    metadata:
      labels:
        app: test15c-churn
        round: r01
        os: windows2k22
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
                bus: sata
            - name: sysprep
              cdrom:
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
            name: r1-win2k22-disk-{{.Iteration}}-{{.Replica}}
        - name: sysprep
          sysprep:
            configMap:
              name: windows-sysprep
EOF
```

**File 2 — `vm-r2-win2k22.yml` (Round 2: 3 VMs, 2vCPU/4Gi)**

```bash
cat > /tmp/vm-r2-win2k22.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r2-win2k22-{{.Iteration}}-{{.Replica}}
  labels:
    app: test15c-churn
    round: r02
    os: windows2k22
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: r2-win2k22-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: windows2k22
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 60Gi
  template:
    metadata:
      labels:
        app: test15c-churn
        round: r02
        os: windows2k22
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
                bus: sata
            - name: sysprep
              cdrom:
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
            name: r2-win2k22-disk-{{.Iteration}}-{{.Replica}}
        - name: sysprep
          sysprep:
            configMap:
              name: windows-sysprep
EOF
```

**File 3 — `vm-r3-win2k22.yml` (Round 3: 4 VMs, 4vCPU/8Gi)**

```bash
cat > /tmp/vm-r3-win2k22.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: r3-win2k22-{{.Iteration}}-{{.Replica}}
  labels:
    app: test15c-churn
    round: r03
    os: windows2k22
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: r3-win2k22-disk-{{.Iteration}}-{{.Replica}}
      spec:
        sourceRef:
          kind: DataSource
          name: windows2k22
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 60Gi
  template:
    metadata:
      labels:
        app: test15c-churn
        round: r03
        os: windows2k22
    spec:
      domain:
        cpu:
          cores: 4
        resources:
          requests:
            memory: 8Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: sata
            - name: sysprep
              cdrom:
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
            name: r3-win2k22-disk-{{.Iteration}}-{{.Replica}}
        - name: sysprep
          sysprep:
            configMap:
              name: windows-sysprep
EOF
```

---

### Step 4 — Create the sysprep ConfigMap

Windows VMs need a `sysprep` ConfigMap with an `Autounattend.xml` file to automate the first-boot configuration. This is a minimal unattended setup:

```bash
cat > /tmp/Autounattend.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <ComputerName>win-vm</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>Redhat123!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
EOF

oc create configmap windows-sysprep \
  --from-file=Autounattend.xml=/tmp/Autounattend.xml \
  -n burner-test15c

oc get configmap windows-sysprep -n burner-test15c
```

---

### Step 5 — Write the kube-burner config file

```bash
cat > /tmp/test15c-churn-config.yml << 'EOF'
global:
  gc: false
  measurements:
    - name: vmiLatency

jobs:
  # ============================================================
  # ROUND 1: Windows 2022 — 2 VMs, 2vCPU/4Gi, 2 churn cycles
  # Baseline: 60Gi disk clone + full Windows boot sequence
  # Expect 3–5 minutes per VM to reach Running
  # ============================================================
  - name: r01-cre-win2k22
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 30m
    objects:
      - objectTemplate: vm-r1-win2k22.yml
        replicas: 2

  - name: r01-c1-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r01-cre-win2k22

  - name: r01-c1-cre
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 30m
    objects:
      - objectTemplate: vm-r1-win2k22.yml
        replicas: 2

  - name: r01-c2-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r01-c1-cre

  - name: r01-c2-cre
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 30m
    objects:
      - objectTemplate: vm-r1-win2k22.yml
        replicas: 2

  - name: r01-final-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          round: r01

  # ============================================================
  # ROUND 2: Windows 2022 — 3 VMs, 2vCPU/4Gi, 2 churn cycles
  # Parallel clones: 3 × 60Gi PVCs cloning simultaneously
  # Watch the Storage tab — this is where storage shows its limits
  # ============================================================
  - name: r02-cre-win2k22
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 40m
    objects:
      - objectTemplate: vm-r2-win2k22.yml
        replicas: 3

  - name: r02-c1-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r02-cre-win2k22

  - name: r02-c1-cre
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 40m
    objects:
      - objectTemplate: vm-r2-win2k22.yml
        replicas: 3

  - name: r02-c2-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r02-c1-cre

  - name: r02-c2-cre
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 40m
    objects:
      - objectTemplate: vm-r2-win2k22.yml
        replicas: 3

  - name: r02-final-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          round: r02

  # ============================================================
  # ROUND 3: Windows 2022 heavy — 4 VMs, 4vCPU/8Gi, 2 cycles
  # Maximum pressure: 32Gi RAM + 240Gi storage for the full fleet
  # This is a production-sized Windows VM deployment
  # ============================================================
  - name: r03-cre-win2k22
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r3-win2k22.yml
        replicas: 4

  - name: r03-c1-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r03-cre-win2k22

  - name: r03-c1-cre
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r3-win2k22.yml
        replicas: 4

  - name: r03-c2-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          kube-burner.io/job: r03-c1-cre

  - name: r03-c2-cre
    namespace: burner-test15c
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    waitWhenFinished: true
    maxWaitTimeout: 60m
    objects:
      - objectTemplate: vm-r3-win2k22.yml
        replicas: 4

  - name: r03-final-del
    namespace: burner-test15c
    jobType: delete
    waitForDeletion: true
    objects:
      - apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        labelSelector:
          app: test15c-churn
EOF
```

---

### Step 6 — Verify all 4 files exist

```bash
ls -lh /tmp/test15c-churn-config.yml \
        /tmp/vm-r1-win2k22.yml \
        /tmp/vm-r2-win2k22.yml \
        /tmp/vm-r3-win2k22.yml
```

All 4 must show non-zero file sizes before continuing.

---

### Step 7 — Create the ConfigMap

```bash
oc create configmap test15c-churn-config \
  --from-file=config.yml=/tmp/test15c-churn-config.yml \
  --from-file=vm-r1-win2k22.yml=/tmp/vm-r1-win2k22.yml \
  --from-file=vm-r2-win2k22.yml=/tmp/vm-r2-win2k22.yml \
  --from-file=vm-r3-win2k22.yml=/tmp/vm-r3-win2k22.yml \
  -n burner-test15c

oc get configmap test15c-churn-config -n burner-test15c
```

Expected: `configmap/test15c-churn-config created` with `DATA: 4`.

---

### Step 8 — Switch to Tab 2 and Tab 3

Go to **Virtualization → VirtualMachines** — filter by `burner-test15c`.

Go to **Storage → PersistentVolumeClaims** — filter by `burner-test15c`. This is the key tab for Windows tests — you will see the 60Gi PVCs appear and go through `Cloning` → `Bound` before the VMs can boot.

---

### Step 9 — Launch the kube-burner job

```bash
UUID="test15c-$(date +%s)"
echo "UUID: $UUID"

cat << JOBYAML | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-test15c-churn
  namespace: burner-test15c
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
            name: test15c-churn-config
        - name: workdir
          emptyDir: {}
JOBYAML
```

---

### Security — DISA STIG-hardened job manifest

If your cluster enforces DISA STIG hardening (e.g. the `restricted-v2` SCC, a compliance-operator profile, or an admission policy requiring non-root containers and no Linux capabilities), the Step 9 job manifest above may fail admission. Use this hardened variant instead — it adds a pod-level `securityContext` (non-root, `RuntimeDefault` seccomp profile) plus container-level `securityContext` (no privilege escalation, all capabilities dropped) on every container in the Job.

```bash
UUID="test15c-$(date +%s)"
echo "UUID: $UUID"

cat << JOBYAML | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-test15c-churn
  namespace: burner-test15c
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: kube-burner
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: copy-config
          image: quay.io/kube-burner/kube-burner:v2.7.3
          command: [sh, -c, "cp /config-src/* /config/"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - {name: config-src, mountPath: /config-src}
            - {name: workdir,    mountPath: /config}
      containers:
        - name: kube-burner
          image: quay.io/kube-burner/kube-burner:v2.7.3
          workingDir: /config
          command: [kube-burner, init, -c, /config/config.yml, --uuid=${UUID}]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: test15c-churn-config
        - name: workdir
          emptyDir: {}
JOBYAML
```

---

### Step 10 — Watch the pod start, then stream logs

```bash
oc get pod -n burner-test15c -w
```

Wait until the pod shows `Running`. Then stream logs:

```bash
oc logs -f job/kb-test15c-churn -n burner-test15c
```

You will see long pauses between job steps — this is normal. Windows VMs take 3–5 minutes to reach Running:

```
INFO Triggering job: r01-cre-win2k22   ← Round 1 starts (2 Windows VMs)
INFO Job r01-cre-win2k22 took 4m12s    ← Normal — disk clone + OS boot
INFO Triggering job: r01-c1-del
INFO Job r01-c1-del took 45s
INFO Triggering job: r01-c1-cre        ← Churn cycle 1 (second boot is faster — image cached)
INFO Job r01-c1-cre took 2m38s
...
INFO Triggering job: r02-cre-win2k22   ← Round 2 (3 VMs)
...
INFO Triggering job: r03-cre-win2k22   ← Round 3 (4 heavy VMs)
...
INFO Finished execution with UUID: test15c-...
```

> **Note:** Second and subsequent boots within the same round are faster because the container image cache on the nodes is warm. First-boot times (including cold CDI clone) are the meaningful benchmark number.

---

### Step 11 — What to say at each phase

**During R01 (2 Windows VMs, first boot):**
*"This is a real Windows Server 2022 VM cloning its disk and booting for the first time. Watch the PVC tab — you'll see a 60 Gi clone in progress. The 4-minute boot time is the CDI clone plus the full Windows kernel and cloudbase-init sequence."*

**During R01 churn cycles:**
*"Now the second round. The disk clone is much faster this time because the image data is cached on the storage nodes. That's why churn cycle 2 is 2 minutes instead of 4 — production workloads will see these warm-cache times in steady state."*

**During R02 (3 VMs simultaneously):**
*"Three Windows VMs cloning 60 Gi each at the same time. That's 180 Gi of storage I/O happening in parallel. Watch the PVC tab — you'll see all three in `Cloning` state simultaneously."*

**During R03 (4 heavy VMs):**
*"This is the peak — 4 Windows Server VMs with 4 vCPUs and 8 Gi of RAM each. That's 32 Gi of RAM and 240 Gi of storage committed to Windows workloads alone. If the cluster completes this round without stuck VMs, it is validated for production Windows virtualisation."*

---

### Step 12 — What good looks like

| Metric | Healthy | Investigate |
|---|---|---|
| R01 VMIRunning P99 (first boot) | < 6 minutes | > 15 minutes |
| R01 VMIRunning P99 (warm boot) | < 3 minutes | > 8 minutes |
| R02 VMIRunning P99 | < 8 minutes | > 20 minutes |
| R03 VMIRunning P99 | < 10 minutes | > 25 minutes |
| CDI clone time per 60Gi PVC | < 3 minutes | > 10 minutes |
| virt-controller RSS peak | < 400 MiB | > 800 MiB |
| Stuck VMs at end of any round | 0 | Any |
| Final VM count after test | 0 | Any remaining |

---

### Step 13 — Clean up

```bash
oc delete job kb-test15c-churn -n burner-test15c 2>/dev/null || true
oc delete vm -l app=test15c-churn -n burner-test15c 2>/dev/null || true
oc delete configmap test15c-churn-config windows-sysprep -n burner-test15c 2>/dev/null || true
oc delete project burner-test15c
oc delete clusterrole kube-burner-test15c 2>/dev/null || true
oc delete clusterrolebinding kube-burner-test15c 2>/dev/null || true
```

Verify clean:

```bash
oc get projects | grep burner-test15c
oc get vm -A 2>/dev/null | grep test15c
oc get pvc -A 2>/dev/null | grep test15c
# All three should return nothing
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `datasource "windows2k22" not found` | Golden image not imported — check `oc get datasource -n openshift-virtualization-os-images` for the correct name (may be `windows2k19`) |
| VMs stuck in `Provisioning` for > 15 minutes | CDI clone stalled — check `oc describe datavolume -n burner-test15c` for errors |
| VMs stuck in `Starting` for > 10 minutes | Windows boot hung — check `oc get vmi -n burner-test15c` and look for `Pending` VMIs |
| `Insufficient memory` scheduling error | R03 needs 32 Gi free RAM — reduce replicas from 4 to 2 |
| `configmap "windows-sysprep" not found` | Step 4 was skipped — create the sysprep ConfigMap before creating the VM ConfigMap |
| CDI clone takes > 10 minutes per PVC | Storage throughput bottleneck — check storage class and CDI config for concurrent clone limits |
| `serviceaccount "kube-burner" not found` | Re-run Step 2 — always create the SA before applying RBAC |
| ConfigMap already exists on rerun | `oc delete configmap test15c-churn-config -n burner-test15c` then recreate |

---

*Test 15C is the hardest VM churn test in this suite. Completing it confirms full production readiness for Windows Server workloads on OpenShift Virtualisation.*
