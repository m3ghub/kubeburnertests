# Test 13: VM Live Migration — Moving Running Computers Without Interruption

> **Difficulty:** ⭐⭐⭐⭐ Expert  
> **Time to run:** ~30 minutes  
> **What it does:** Starts multiple VMs and then live-migrates them to different nodes while they continue running — the hardest operation in OpenShift Virtualization  
> **Requires:** OpenShift Virtualization (KubeVirt) installed, at least **2 worker nodes**

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 🚚🖥️

Imagine you are moving furniture while people are still sitting on it — that is what live migration does for virtual machines.

**Live migration** moves a running VM from one physical server (node) to another without:
- Shutting down the VM
- Interrupting applications running inside the VM
- Losing network connections

This is one of the most demanding operations a virtualisation platform can perform. It requires:
- **Copying the VM's entire memory** to the destination node while the VM keeps running
- **Synchronising memory changes** in real-time during the copy
- **Cutting over** at exactly the right moment so no packets are lost

The **VM Live Migration** test runs many VMs simultaneously and then migrates all of them, measuring:
- How long each migration takes
- Whether any VMs fail to migrate
- Whether the cluster API server stays responsive under the migration traffic load

---

## Why does this matter? 🤔

Live migration is used in production for:
- **Node maintenance** — drain a node without downtime (`oc adm drain`)
- **Load balancing** — move VMs off overloaded nodes
- **Firmware/kernel upgrades** — evacuate nodes to apply updates
- **Disaster recovery** — pre-emptively move VMs away from a failing node

If your cluster cannot live-migrate VMs reliably, your maintenance windows become VM downtime windows. This test finds out before that happens in production.

---

## What does it measure?

| Metric | What it means |
|---|---|
| **Migration start time** | How fast KubeVirt starts the migration process |
| **Memory copy phase duration** | How long it takes to copy VM RAM to the destination node |
| **Total migration time** | Wall-clock time from trigger to completion |
| **Concurrent migration throughput** | How many migrations per minute the cluster can sustain |
| **Migration failure rate** | Percentage of migrations that fail or abort |

---

## How live migration works

```
NODE A (source)                    NODE B (destination)
─────────────────                  ─────────────────────
 Running VM                         Empty slot reserved
   │                                        │
   │── 1. Copy all memory pages ──────────►│
   │                                        │
   │── 2. Track dirty pages (still running)─►│
   │                                        │
   │── 3. Copy dirty pages (delta) ─────►  │
   │                                        │
   │── 4. Final dirty pages (tiny) ──────► │
   │                                        │
   ╳  (old VM process ends)         VM resumes here ✅
                                    Same IP, same state
```

---

## Before you start ✅

- [ ] kube-burner installed
- [ ] Logged in as cluster-admin
- [ ] OpenShift Virtualization installed
- [ ] **At least 2 worker nodes** — migration requires a destination node
- [ ] Nodes have shared storage OR `LiveMigrationPolicy` set to allow post-copy

Check available worker nodes:

```bash
oc get nodes -l node-role.kubernetes.io/worker
```

You need at least 2 with `Ready` status.

Check that live migration is enabled:

```bash
oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].spec.configuration.developerConfiguration}'
```

---

## Step-by-step guide

### Step 1 — Create namespace and RBAC

```bash
oc new-project burner-migration
```

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-burner
  namespace: burner-migration
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
    resources: [virtualmachines, virtualmachineinstances, virtualmachineinstancemigrations]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [subresources.kubevirt.io]
    resources: [virtualmachines/start, virtualmachines/stop, virtualmachines/migrate]
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
    namespace: burner-migration
EOF
```

---

### Step 2 — Create config files

Create `migration-config.yml`:

```yaml
global:
  gc: true
  measurements: []

jobs:
  # Phase 1: Create VMs (stopped)
  - name: create-vms
    jobType: create
    namespace: burner-migration
    jobIterations: 1
    qps: 5
    burst: 5
    waitWhenFinished: false
    objects:
      - objectTemplate: vm-template.yml
        replicas: 4
        wait: false
        inputVars:
          memory: 128Mi

  # Phase 2: Start all VMs (wait for Running state)
  - name: start-vms
    jobType: kubevirt
    executionMode: parallel
    jobPause: 60s          # Give VMs time to fully boot before migrating
    objects:
      - kubeVirtOp: start
        labelSelector: {kube-burner.io/job: create-vms}

  # Phase 3: Live-migrate all running VMs
  - name: migrate-vms
    jobType: kubevirt
    executionMode: sequential   # Migrate one at a time (safer, more measurable)
    jobPause: 30s
    objects:
      - kubeVirtOp: migrate
        labelSelector: {kube-burner.io/job: create-vms}

  # Phase 4: Stop all VMs after migration
  - name: stop-vms
    jobType: kubevirt
    executionMode: parallel
    objects:
      - kubeVirtOp: stop
        labelSelector: {kube-burner.io/job: create-vms}
        inputVars:
          force: false
```

Create `vm-template.yml`:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: migrate-vm-{{.Iteration}}-{{.Replica}}
  labels:
    app: burner-migration
spec:
  running: false
  template:
    metadata:
      labels:
        app: burner-migration
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

---

### Step 3 — Package into a ConfigMap

```bash
oc create configmap migration-config \
  --from-file=config.yml=migration-config.yml \
  --from-file=vm-template.yml=vm-template.yml \
  -n burner-migration
```

---

### Step 4 — Run the test

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-migration
  namespace: burner-migration
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=migration-001]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: migration-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Step 5 — Watch migrations happen in real time

In a separate terminal, watch the migration objects:

```bash
# Watch VirtualMachineInstanceMigration objects as they are created and completed
watch "oc get vmim -n burner-migration"
```

You will see migration objects appear as kube-burner triggers them:

```
NAME                        PHASE       VMI
virt-launcher-migrate-0-1   Running     migrate-vm-1-1
virt-launcher-migrate-0-2   Succeeded   migrate-vm-1-2
```

Also check which node each VM moved to:

```bash
oc get vmi -n burner-migration -o wide
```

The `NODE` column should change as each migration completes.

---

### Step 6 — Read the results

```bash
oc logs -f job/kb-migration -n burner-migration
```

**What to look for:**
- `migrate-vms` phase duration — total time to migrate all VMs
- Any `migration failed` or `migration aborted` messages
- Whether subsequent phases (`stop-vms`) complete cleanly

---

### Step 7 — Push harder (scale up)

Once the basic test works, increase VM count to find the limit:

```bash
# Edit ConfigMap to increase replicas to 10
oc edit configmap migration-config -n burner-migration
# Change replicas: 4 → replicas: 10

# Re-run
oc delete job kb-migration -n burner-migration
cat <<'EOF' | oc apply -f -
... (same job YAML as Step 4)
EOF
```

**Escalation ladder:**
- 4 VMs → confirm migration works
- 8 VMs → test parallel migration pressure
- 16 VMs → approaching most 3-node cluster limits
- 32 VMs → pushing the ceiling — expect longer migration queues

The migration controller limits concurrent migrations by default to 5 cluster-wide. Adjust via:

```bash
oc edit hyperconverged -n openshift-cnv
# Set: spec.configuration.migrationConfiguration.parallelMigrationsPerCluster: 10
```

---

### Step 8 — Clean up

```bash
oc delete job kb-migration -n burner-migration
oc delete configmap migration-config -n burner-migration
oc delete project burner-migration
oc delete clusterrole kube-burner-virt
oc delete clusterrolebinding kube-burner-virt
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `VirtualMachineInstanceMigration` stuck in `Pending` | Only 1 worker node — migration requires a destination node |
| Migration `Aborted` immediately | LiveMigration policy may require shared storage; check `oc get kubevirt -n openshift-cnv` |
| VMs never reach `Running` before migration | Increase `jobPause` in `start-vms` phase to allow more boot time |
| `migrate` operation times out | Increase VM memory — larger VMs take longer to migrate; or increase parallelMigrationsPerCluster |
| `forbidden: VirtualMachineInstanceMigrations` | Add `virtualmachineinstancemigrations` to the ClusterRole (see RBAC in Step 1) |

---

*Next test: [14 — VM Density Scaling](14-vm-density-scaling.md) — find exactly how many VMs your cluster can handle*
