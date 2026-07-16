# Test 15: VM Churn — Continuously Creating and Destroying Virtual Machines

> **Difficulty:** ⭐⭐⭐⭐ Expert  
> **Time to run:** 20–60 minutes (configurable duration)  
> **What it does:** Continuously creates VMs and then deletes them in a repeating cycle, hammering the virt-controller and API server with constant creation/deletion pressure  
> **Requires:** OpenShift Virtualization (KubeVirt) installed

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 🔄🖥️

Imagine a hotel that never closes — guests constantly checking in and checking out, 24 hours a day. The hotel's management system has to handle a never-ending stream of arrivals and departures without ever slowing down.

**VM Churn** does exactly this to your Kubernetes cluster. It creates a set of VMs, then after a short time deletes a percentage of them and recreates them from scratch — over and over again for the duration of the test.

This simulates production environments where:
- Automated VM pools are constantly scaled up/down
- CI/CD pipelines spin up VMs for test runs and destroy them when done
- Autoscalers respond to load changes by adding/removing VMs
- Rolling VM upgrades replace old VMs with new ones

---

## Why this is the most demanding virt test 🔥

Churn stresses the system in a way that static load does not:

| What churns | What it stresses |
|---|---|
| `VirtualMachine` object creation/deletion | API server write throughput |
| `VirtualMachineInstance` creation | virt-controller reconciliation loop |
| `virt-launcher` pod scheduling | Kubernetes scheduler + kubelet |
| Container image pulls (containerDisk) | Container runtime + image cache |
| Namespace cleanup | etcd compaction and GC |

The virt-controller must continuously reconcile desired state (VM spec) against actual state (VMI + pod). When thousands of these reconcile loops are triggered per minute, the controller's queue depth is the first thing to saturate.

---

## How churn works

```
Time ──────────────────────────────────────────────────────────►

Phase 1 (Create):   [VM1][VM2][VM3][VM4][VM5][VM6][VM7][VM8]
                    All VMs exist

Phase 2 (Churn):    DELETE 25%    CREATE 25%    DELETE 25%    ...
                    [VM1][VM2]       [VM9][VM10]
                    deleted         created

                    net result: always ~8 VMs, but 2 are replaced
                    each churn cycle

Duration:           Run for 30 minutes (or N cycles)
```

---

## What does it measure?

| Metric | What it means |
|---|---|
| **Churn cycle duration** | How long each delete+recreate cycle takes |
| **Pod scheduling latency (P99)** | How long new VM pods take to be scheduled under churn |
| **virt-controller queue depth** | Indirect — seen through slower cycle times |
| **API server error rate** | Whether the control plane starts rejecting requests under load |
| **Steady-state VM count** | Whether the target VM count is maintained throughout |

---

## Before you start ✅

- [ ] kube-burner installed
- [ ] Logged in as cluster-admin
- [ ] OpenShift Virtualization installed
- [ ] At least 1 worker node (churn works on single-node clusters)

---

## Step-by-step guide

### Step 1 — Create namespace and RBAC

```bash
oc new-project burner-churn
```

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-burner
  namespace: burner-churn
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-burner-virt
rules:
  - apiGroups: [""]
    resources: [namespaces, pods, services, configmaps, secrets, nodes, events, serviceaccounts]
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
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-burner-virt
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-burner-virt
subjects:
  - kind: ServiceAccount
    name: kube-burner
    namespace: burner-churn
EOF
```

---

### Step 2 — Create config files

Create `vm-churn-config.yml`:

```yaml
global:
  gc: true
  measurements:
    - name: podLatency
      thresholds:
        - conditionType: Ready
          metric: P99
          threshold: 300s

jobs:
  - name: vm-churn
    jobType: create
    namespace: burner-churn
    namespacedIterations: true
    iterationsPerNamespace: 4     # 4 VMs per namespace
    jobIterations: 2              # 2 namespaces = 8 total VMs
    qps: 5
    burst: 5
    podWait: false
    waitWhenFinished: true
    maxWaitTimeout: 10m
    objects:
      - objectTemplate: vm-churn-template.yml
        replicas: 4
        wait: false               # VMs are stopped initially
        inputVars:
          memory: 128Mi
    churnConfig:
      percent: 25                 # Churn 25% of namespaces per cycle
      duration: 20m               # Run churn for 20 minutes
      delay: 30s                  # 30 second pause between cycles
      deleteDelay: 5s             # Wait 5s between delete and recreate
      mode: namespaces            # Churn entire namespace groups
```

Create `vm-churn-template.yml`:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: churn-vm-{{.Iteration}}-{{.Replica}}
  labels:
    app: burner-churn
spec:
  running: true                   # Start immediately on creation
  template:
    metadata:
      labels:
        app: burner-churn
    spec:
      domain:
        resources:
          requests:
            memory: "{{.memory}}"
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
```

> **Key difference from Test 09:** `running: true` in the VM spec means VMs start automatically when created. This maximises pressure on the virt-controller since it handles both creation and startup in one operation.

---

### Step 3 — Package into a ConfigMap

```bash
oc create configmap vm-churn-config \
  --from-file=config.yml=vm-churn-config.yml \
  --from-file=vm-churn-template.yml=vm-churn-template.yml \
  -n burner-churn
```

---

### Step 4 — Run the test

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-vm-churn
  namespace: burner-churn
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
          command:
            - kube-burner
            - init
            - -c
            - /config/config.yml
            - --uuid=vm-churn-001
            - --timeout=2h
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: vm-churn-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Security — DISA STIG-hardened job manifest

If your cluster enforces DISA STIG hardening (e.g. the `restricted-v2` SCC, a compliance-operator profile, or an admission policy requiring non-root containers and no Linux capabilities), the Step 4 job manifest above may fail admission. Use this hardened variant instead — it adds a pod-level `securityContext` (non-root, `RuntimeDefault` seccomp profile) plus container-level `securityContext` (no privilege escalation, all capabilities dropped) on both the init container and the `kube-burner` container:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-vm-churn
  namespace: burner-churn
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
          command:
            - kube-burner
            - init
            - -c
            - /config/config.yml
            - --uuid=vm-churn-001
            - --timeout=2h
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: vm-churn-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Step 5 — Monitor the churn in real time

Open three terminals to watch different aspects:

**Terminal 1 — Watch VM state changes:**
```bash
watch "oc get vm -A | grep churn"
```

**Terminal 2 — Watch namespace creation/deletion:**
```bash
watch "oc get ns | grep churn"
```

**Terminal 3 — Watch kube-burner progress:**
```bash
oc logs -f job/kb-vm-churn -n burner-churn
```

You should see namespaces appearing and disappearing every ~30 seconds as churn cycles run.

---

### Step 6 — Push harder

**More VMs (heavier churn load):**
```yaml
jobIterations: 5              # 5 namespaces
iterationsPerNamespace: 8    # 8 VMs per namespace = 40 total
churnConfig:
  percent: 20                # 8 VMs churned per cycle
  duration: 30m
  delay: 20s
```

**Faster churn (shorter delay = more virt-controller pressure):**
```yaml
churnConfig:
  percent: 50                # Churn half the VMs per cycle
  duration: 30m
  delay: 5s                  # Only 5 second pause between cycles
  deleteDelay: 0s            # No wait between delete and recreate
```

**Maximum pressure:**
```yaml
jobIterations: 10
iterationsPerNamespace: 10   # 100 total VMs
churnConfig:
  percent: 30
  duration: 1h
  delay: 10s
  deleteDelay: 0s
```

---

### Step 7 — Signs the cluster is at its limit

| Observation | What it means |
|---|---|
| Churn cycles taking 5× longer than the `delay` | virt-controller queue is saturated |
| VMs stuck in `Scheduling` for >5 minutes | Scheduler is overwhelmed or nodes are full |
| `etcd` leader elections in cluster logs | etcd is under excessive write pressure |
| API server 429 errors in kube-burner logs | API server rate-limiting is engaged |
| Exit code `4` from kube-burner | P99 pod boot time exceeded the 300s threshold |
| kube-burner job OOMKilled | kube-burner itself is running out of memory tracking objects |

---

### Step 8 — Clean up

```bash
oc delete job kb-vm-churn -n burner-churn 2>/dev/null || true
oc delete project burner-churn
oc delete clusterrole kube-burner-virt
oc delete clusterrolebinding kube-burner-virt
# Also clean up any churn namespaces
oc get ns | grep churn | awk '{print $1}' | xargs oc delete ns 2>/dev/null || true
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| VMs never reach `Running` | Reduce replicas and churn percent — you may be overloading a small cluster |
| Churn cycles never complete | Reduce `percent` from 25 to 10 to create less work per cycle |
| Namespace deletion stuck | Force-delete: `oc delete ns <name> --force --grace-period=0` |
| CirrOS image pull fails | Use a locally mirrored image or pre-pull with a DaemonSet |
| kube-burner timeout | Increase `--timeout=2h` or reduce `duration` in churnConfig |

---

*Next test: [16 — VM Pause/Unpause Storm](16-vm-pause-unpause.md) — pause and unpause hundreds of VMs to test memory balloon and QEMU state handling*
