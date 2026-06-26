# Test 17: VM Hot-plug Storage — Attaching and Detaching Disks on Running VMs

> **Difficulty:** ⭐⭐⭐⭐ Expert  
> **Time to run:** ~25 minutes  
> **What it does:** Creates running VMs, then hot-plugs (attaches) and hot-unplugs (detaches) PersistentVolumeClaims while the VMs continue running — testing the CDI storage operator and virtio-scsi hot-attach path  
> **Requires:** OpenShift Virtualization (KubeVirt) installed, a StorageClass that supports dynamic provisioning

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 💾🔌🖥️

Imagine adding a USB drive to a computer that is already running — without restarting it. The computer detects the new drive, mounts it, and you can immediately use it.

That is **hot-plug storage** for virtual machines.

With OpenShift Virtualization, you can attach a new disk (backed by a PersistentVolumeClaim) to a running VM, and the VM will detect it as a new block device immediately. No reboot required.

The **VM Hot-plug Storage** test:
1. Creates several running VMs
2. Creates PersistentVolumeClaims (PVCs) for the disks
3. Uses kube-burner's `add-volume` operation to attach each PVC to a running VM
4. Waits for the attachment to complete
5. Uses `remove-volume` to detach the disk while the VM is still running
6. Cleans up

This tests the **Containerized Data Importer (CDI)** operator, the **virtio-scsi** driver path, and the **virt-handler** hot-attach implementation simultaneously.

---

## Why does hot-plug storage matter? 🤔

In production, hot-plug storage is used for:

- **Expanding VM storage** without downtime (attach new data disk)
- **Backup workflows** — attach a backup PVC, run backup agent, detach
- **Data migration** — attach a source PVC, copy data, detach
- **Ephemeral scratch disks** — attach scratch space for temporary operations

If hot-plug fails or is slow at scale, all of these production workflows break. This test validates that the storage attach/detach path can handle concurrent operations across many VMs without timing out or corrupting state.

---

## How hot-plug storage works

```
RUNNING VM                          STORAGE OPERATION
──────────────────────              ────────────────────────────
OS running                          1. kube-burner triggers add-volume
virtio-scsi controller              2. CDI creates attachment pod
  looking for new devices           3. PVC mounted to attachment pod
                                    4. virtio-scsi hot-plug signal sent
                                    ↓
VM detects new /dev/sdb  ◄──────── 5. Block device visible inside VM
OS auto-mounts (if enabled)         
                                    6. kube-burner triggers remove-volume
VM /dev/sdb disappears   ◄──────── 7. virtio-scsi hot-unplug signal sent
                                    8. Attachment pod removed
```

---

## What does it measure?

| Metric | What it means |
|---|---|
| **Volume attach time** | Time from `add-volume` command to device visible in VMI status |
| **Volume detach time** | Time from `remove-volume` command to device removed from VMI status |
| **PVC provision time** | How fast the StorageClass creates the backing volumes |
| **Concurrent attachment throughput** | How many VMs can receive volumes simultaneously |
| **CDI operator response time** | How fast CDI processes attachment requests |

---

## Before you start ✅

- [ ] kube-burner installed
- [ ] Logged in as cluster-admin
- [ ] OpenShift Virtualization installed
- [ ] A StorageClass that supports `ReadWriteMany` **or** `ReadWriteOnce` (check below)

Check available storage classes:

```bash
oc get storageclass
```

Look for a StorageClass with `VOLUMEBINDINGMODE` = `Immediate` — these work best for hot-plug. On OpenShift with ODF or LVM Storage:

```bash
oc get storageclass | grep -E "(ocs|lvms|thin|ceph)"
```

---

## Step-by-step guide

### Step 1 — Create namespace and RBAC

```bash
oc new-project burner-hotplug
```

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-burner
  namespace: burner-hotplug
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-burner-virt
rules:
  - apiGroups: [""]
    resources: [namespaces, pods, services, configmaps, secrets, nodes, events,
                 serviceaccounts, persistentvolumeclaims, persistentvolumes]
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
    resources:
      - virtualmachines/start
      - virtualmachines/stop
      - virtualmachines/addvolume
      - virtualmachines/removevolume
    verbs: [update]
  - apiGroups: [cdi.kubevirt.io]
    resources: [datavolumes]
    verbs: [get, list, watch, create, delete, update, patch]
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
    namespace: burner-hotplug
EOF
```

---

### Step 2 — Create PVCs for hot-plug

Before running kube-burner, create the PVCs that will be attached. Hot-plug requires pre-provisioned PVCs.

```bash
# Create 4 PVCs (one per VM we will create)
for i in 1 2 3 4; do
  oc apply -f - <<PVEOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hotplug-pvc-${i}
  namespace: burner-hotplug
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
PVEOF
done
```

Wait for PVCs to be bound:

```bash
oc wait pvc --all -n burner-hotplug --for=condition=Bound --timeout=120s
```

---

### Step 3 — Create config files

Create `vm-hotplug-config.yml`:

```yaml
global:
  gc: true
  measurements: []

jobs:
  # Phase 1: Create and start VMs
  - name: create-vms
    jobType: create
    namespace: burner-hotplug
    namespacedIterations: false
    jobIterations: 1
    qps: 5
    burst: 5
    waitWhenFinished: false
    objects:
      - objectTemplate: vm-hotplug-template.yml
        replicas: 4
        wait: false
        inputVars:
          memory: 128Mi

  - name: start-vms
    jobType: kubevirt
    executionMode: parallel
    jobPause: 60s               # Wait for VMs to fully boot
    objects:
      - kubeVirtOp: start
        labelSelector: {kube-burner.io/job: create-vms}

  # Phase 2: Hot-plug a volume to each VM
  - name: add-volumes
    jobType: kubevirt
    executionMode: sequential   # Attach one at a time — cleaner for demo
    jobPause: 15s
    objects:
      - kubeVirtOp: add-volume
        labelSelector: {kube-burner.io/job: create-vms}
        inputVars:
          volumeName: hotplug-pvc-{{.Replica}}
          diskType: disk

  # Phase 3: Remove the volumes (hot-unplug)
  - name: remove-volumes
    jobType: kubevirt
    executionMode: sequential
    jobPause: 10s
    objects:
      - kubeVirtOp: remove-volume
        labelSelector: {kube-burner.io/job: create-vms}
        inputVars:
          volumeName: hotplug-pvc-{{.Replica}}

  # Phase 4: Stop all VMs
  - name: stop-vms
    jobType: kubevirt
    executionMode: parallel
    objects:
      - kubeVirtOp: stop
        labelSelector: {kube-burner.io/job: create-vms}
        inputVars:
          force: false
```

Create `vm-hotplug-template.yml`:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: hotplug-vm-{{.Iteration}}-{{.Replica}}
  labels:
    app: burner-hotplug
spec:
  running: false
  template:
    metadata:
      labels:
        app: burner-hotplug
        replica: "{{.Replica}}"
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

### Step 4 — Package into a ConfigMap

```bash
oc create configmap vm-hotplug-config \
  --from-file=config.yml=vm-hotplug-config.yml \
  --from-file=vm-hotplug-template.yml=vm-hotplug-template.yml \
  -n burner-hotplug
```

---

### Step 5 — Run the test

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-hotplug
  namespace: burner-hotplug
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=hotplug-001]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: vm-hotplug-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Step 6 — Watch volumes attach and detach

```bash
# Watch the VMI status — look for volumes appearing and disappearing
watch "oc get vmi -n burner-hotplug -o json | jq '.items[].status.volumeStatus'"
```

Alternatively, describe a VMI to see attached volumes:

```bash
oc describe vmi hotplug-vm-1-1 -n burner-hotplug | grep -A 20 "Volume Status"
```

You should see entries like:
```
hotplug-pvc-1   HotplugVolumeAttached    Volume is attached and ready to use
```

---

### Step 7 — Verify inside the VM (optional)

To confirm the disk is truly visible inside the VM:

```bash
# Get the VMI name
VMI=$(oc get vmi -n burner-hotplug -o jsonpath='{.items[0].metadata.name}')

# Connect to the VM console
virtctl console ${VMI} -n burner-hotplug
# Login: cirros / gocubsgo
# Then:
# $ lsblk
# You should see sdb listed (the hot-plugged disk)
```

---

### Step 8 — Push harder (concurrent hot-plug)

For maximum stress, switch to `parallel` execution mode for the attach/detach phases:

```yaml
- name: add-volumes
  jobType: kubevirt
  executionMode: parallel    # Attach to ALL VMs simultaneously
  ...
- name: remove-volumes
  jobType: kubevirt
  executionMode: parallel    # Detach from ALL VMs simultaneously
  ...
```

And increase VM count to 20:

```yaml
objects:
  - objectTemplate: vm-hotplug-template.yml
    replicas: 20
```

Create 20 PVCs in the preparation step. At 20 concurrent attachments, the CDI operator and virtio-scsi path are under significant concurrent load.

---

### Step 9 — Clean up

```bash
oc delete job kb-hotplug -n burner-hotplug 2>/dev/null || true
# Delete PVCs
for i in 1 2 3 4; do oc delete pvc hotplug-pvc-${i} -n burner-hotplug; done
oc delete project burner-hotplug
oc delete clusterrole kube-burner-virt
oc delete clusterrolebinding kube-burner-virt
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| PVC stuck in `Pending` | No StorageClass can provision it — check `oc describe pvc hotplug-pvc-1 -n burner-hotplug` |
| `add-volume` fails with `volumeName not found` | PVC must exist and be `Bound` before attaching |
| Volume shows `HotplugVolumeMounted` but not `HotplugVolumeAttached` | This is an intermediate state — wait; may take 30–60s for full attachment |
| `forbidden: virtualmachines/addvolume` | Add `addvolume` and `removevolume` to the ClusterRole subresources (see Step 1) |
| Storage class doesn't support hot-plug | Try `oc-virtctl addvolume` manually first to confirm your StorageClass supports it |
| VM crashes after attaching volume | Known issue with some containerDisk configurations — use a proper boot disk |

---

*You have completed all 5 advanced virtualization tests. Return to [Test 09 — KubeVirt Density](09-kubevirt-density.md) to compare baseline results, or start from [Test 13 — VM Live Migration](13-vm-live-migration.md) to walk through the full virt test series in order.*
