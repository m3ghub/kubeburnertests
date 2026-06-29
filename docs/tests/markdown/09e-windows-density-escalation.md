# Test 09e: Windows Server 2022 Density Escalation — Set It and Forget It

> **Difficulty:** ⭐⭐⭐⭐⭐ Expert  
> **Time to run:** 4–8 hours (3 rounds unattended)  
> **What it does:** Automatically escalates through 3 rounds of increasing Windows Server 2022 VM density — find your cluster's Windows VM ceiling  
> **Requires:** OpenShift Virtualization 4.x, `win2k22` golden PVC `Ready: True`, 500Gi+ free storage  
> **Companion test:** Run [Test 09d](09d-windows-density.md) first to confirm Windows VMs boot successfully. This test is the escalation.

> **⚡ Pre-flight required:** See **[00-preflight.md](00-preflight.md)** — Checks 1–6 all apply.

> **STIG / quota-enforced clusters:** Use the quota-safe Job variant in Step 5. See [CONCERN-013](../../concerns/CONCERN-013-stig-resource-quota.md).

> ⚠️ **Golden image required:** `win2k22` PVC must be `Ready: True`. See [CONCERN-007](../../concerns/CONCERN-007-windows-golden-image-missing.md).

---

![Diagram](../../diagrams/tests/png/09e-windows-density-escalation.png)


## What this test does

Runs 3 sequential rounds of increasing Windows Server 2022 VM density. Each round creates VMs, waits for all to reach Running, records latency, deletes them and their PVCs, then advances automatically.

```
Round 1:  3 Windows VMs  →  all Running  →  delete  →  next
Round 2:  5 Windows VMs  →  all Running  →  delete  →  next
Round 3:  8 Windows VMs  →  all Running  →  delete  →  done
```

> **Why only 3 rounds and smaller numbers than RHEL?**  
> Windows VMs are 4Gi RAM and 50Gi storage each. Round 3 alone requires 32Gi RAM and 400Gi storage. Escalating further than 8 VMs is only practical on large clusters (6+ workers). Adjust `replicas` in the config to match your cluster capacity.

---

## Round summary

| Round | VMs | RAM needed | Storage needed | Timeout | Typical time |
|---|---|---|---|---|---|
| 1 | 3 | ~12 Gi | ~150 Gi | 60m | ~25 min |
| 2 | 5 | ~20 Gi | ~250 Gi | 90m | ~45 min |
| 3 | 8 | ~32 Gi | ~400 Gi | 120m | ~70 min |

> **Storage is the hard limit.** 8 Windows VMs = 400Gi of PVC clones. Check your storage class capacity and throughput before running Round 3.

---

## Before you start

```bash
# Confirm Windows golden image is ready
oc get datasource win2k22 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True

# Check available RAM on workers (need ~32Gi free for Round 3)
oc adm top nodes -l node-role.kubernetes.io/worker

# Check storage availability
oc get storageclass
```

---

## Step 1 — Create the project and RBAC

```bash
oc new-project burner-windows-escalation
oc create serviceaccount kube-burner -n burner-windows-escalation

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
    namespace: burner-windows-escalation
EOF
```

---

## Step 2 — Create the VM template

```bash
**Option A — Download from repo (recommended):**

```bash
BASE="https://raw.githubusercontent.com/m3ghub/kubeburnertests/main/docs/tests/files/09e-windows-density-escalation"

curl --fail -sL "${BASE}/windows-escalation-vm.yml" -o /tmp/windows-escalation-vm.yml
curl --fail -sL "${BASE}/windows-escalation-config.yml" -o /tmp/windows-escalation-config.yml
```

Verify:

```bash
head -2 /tmp/windows-escalation-vm.yml   # must start with: apiVersion: kubevirt.io/v1 or global:
head -2 /tmp/windows-escalation-config.yml   # must start with: apiVersion: kubevirt.io/v1 or global:
```

<details>
<summary><strong>Option B — Paste manually (air-gapped / private cluster)</strong></summary>

cat > /tmp/windows-escalation-vm.yml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win-vm-{{.Iteration}}-{{.Replica}}
  labels:
    app: kube-burner-windows
    kube-burner-job: "{{.JobName}}"
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
          storageClassName: ""
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 50Gi
  template:
    metadata:
      labels:
        app: kube-burner-windows
        kube-burner-job: "{{.JobName}}"
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

---

## Step 3 — Create the escalation config

```bash
cat > /tmp/windows-escalation-config.yml << 'EOF'
global:
  gc: false
  measurements:
    - name: vmiLatency

jobs:
  # ─────────────────────────────────────────
  # ROUND 1 — 3 Windows VMs  (~150Gi storage)
  # ─────────────────────────────────────────
  - name: windows-round1-create
    namespace: burner-windows-escalation
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    qps: 2
    burst: 2
    objects:
      - objectTemplate: /config/windows-escalation-vm.yml
        replicas: 3
    waitWhenFinished: true
    maxWaitTimeout: 60m
    jobPause: 60s

  - name: windows-round1-delete
    namespace: burner-windows-escalation
    jobType: delete
    qps: 2
    burst: 2
    objects:
      - kind: VirtualMachine
        apiVersion: kubevirt.io/v1
        labelSelector:
          kube-burner-job: windows-round1-create
    jobPause: 120s

  # ─────────────────────────────────────────
  # ROUND 2 — 5 Windows VMs  (~250Gi storage)
  # ─────────────────────────────────────────
  - name: windows-round2-create
    namespace: burner-windows-escalation
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    qps: 2
    burst: 2
    objects:
      - objectTemplate: /config/windows-escalation-vm.yml
        replicas: 5
    waitWhenFinished: true
    maxWaitTimeout: 90m
    jobPause: 60s

  - name: windows-round2-delete
    namespace: burner-windows-escalation
    jobType: delete
    qps: 2
    burst: 2
    objects:
      - kind: VirtualMachine
        apiVersion: kubevirt.io/v1
        labelSelector:
          kube-burner-job: windows-round2-create
    jobPause: 120s

  # ─────────────────────────────────────────
  # ROUND 3 — 8 Windows VMs  (~400Gi storage)
  # Only run if cluster has 32Gi+ free RAM and 400Gi+ free storage
  # ─────────────────────────────────────────
  - name: windows-round3-create
    namespace: burner-windows-escalation
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    qps: 2
    burst: 2
    objects:
      - objectTemplate: /config/windows-escalation-vm.yml
        replicas: 8
    waitWhenFinished: true
    maxWaitTimeout: 120m
    jobPause: 60s

  - name: windows-round3-delete
    namespace: burner-windows-escalation
    jobType: delete
    qps: 2
    burst: 2
    objects:
      - kind: VirtualMachine
        apiVersion: kubevirt.io/v1
        labelSelector:
          kube-burner-job: windows-round3-create
EOF
```

---

## Step 4 — Package into a ConfigMap

```bash
</details>

oc create configmap windows-escalation-config \
  --from-file=config.yml=/tmp/windows-escalation-config.yml \
  --from-file=windows-escalation-vm.yml=/tmp/windows-escalation-vm.yml \
  -n burner-windows-escalation
```

---

## Step 5 — Launch

**Standard version:**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-windows-escalation
  namespace: burner-windows-escalation
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=windows-escalation-001]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: windows-escalation-config
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
  name: kb-windows-escalation
  namespace: burner-windows-escalation
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=windows-escalation-001]
          resources:
            requests:
              memory: 256Mi
              cpu: 200m
            limits:
              memory: 512Mi
              cpu: 1000m
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: windows-escalation-config
        - name: workdir
          emptyDir: {}
EOF
```

---

## Step 6 — Monitor (walk away)

```bash
# Watch overall job progress
oc logs -f job/kb-windows-escalation -n burner-windows-escalation

# In a second terminal — watch PVC clones
watch "oc get datavolume -n burner-windows-escalation"

# Watch VMs
watch "oc get vm -n burner-windows-escalation"
```

This test runs for 4–8 hours. It is designed to be started and left running.

---

## Step 7 — Results

Expected final log output:

```
level=info msg="windows-round1-create: VMIRunning 99th: 480000 ms  max: 520000 ms  avg: 465000 ms"
level=info msg="windows-round2-create: VMIRunning 99th: 510000 ms  max: 560000 ms  avg: 490000 ms"
level=info msg="windows-round3-create: VMIRunning 99th: 580000 ms  max: 640000 ms  avg: 550000 ms"
level=info msg="Finished execution with UUID: windows-escalation-001"
```

If a round times out, the previous round's count is your Windows VM ceiling on this cluster.

---

## Step 8 — Clean up

```bash
oc delete job kb-windows-escalation -n burner-windows-escalation
oc delete configmap windows-escalation-config -n burner-windows-escalation
oc delete project burner-windows-escalation
```

---

## Full OS density ladder

| Test | OS | VMs | Purpose |
|---|---|---|---|
| [09](09-kubevirt-density.md) | CirrOS | 3 | Baseline |
| [09a](09a-kubevirt-density-escalation.md) | CirrOS | 5→100 | CirrOS ceiling |
| [09b](09b-rhel-density.md) | RHEL 9 | 3 | RHEL baseline |
| [09c](09c-rhel-density-escalation.md) | RHEL 9 | 3→15 | RHEL ceiling |
| [09d](09d-windows-density.md) | Windows 2022 | 3 | Windows baseline |
| **09e** (this test) | Windows 2022 | 3→8 | Windows ceiling |
| [24](24-vm-density-windows.md) | Windows 2022 | fleet | Production fleet |

---

*Previous: [Test 09d — Windows Density](09d-windows-density.md) | Production scale: [Test 24 — Windows Fleet](24-vm-density-windows.md)*
