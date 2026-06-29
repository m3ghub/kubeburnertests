# Test 13a — VM Live Migration Escalation (Set It and Forget It)

**Category:** OpenShift Virtualization — Live Migration  
**Namespace:** `burner-migration-escalation`  
**Escalation:** 2 → 4 → 8 → 16 → 32 VMs  
**Duration:** ~45–90 min  
**Difficulty:** ⭐⭐⭐⭐ Expert

## What this test does

Automatically runs 5 escalating rounds of live migration. Each round: creates VMs → starts them → migrates all VMs simultaneously → stops them → deletes them. Tests the `virt-migration-controller` under progressively increasing parallel migration load.

| Round | VMs | Migration Pause | Max Wait |
|-------|-----|-----------------|----------|
| 1 | 2 | 120 s | 20 min |
| 2 | 4 | 180 s | 20 min |
| 3 | 8 | 300 s | 20 min |
| 4 | 16 | 480 s | 20 min |
| 5 | 32 | 600 s | 20 min |

---

## Prerequisites

- OpenShift cluster with OpenShift Virtualization installed
- At least 2 worker nodes (live migration requires a target node)
- `oc` CLI logged in with cluster-admin
- Check migration policy: `oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].spec.configuration.migrations}'`

---

## Step 1 — Namespace and RBAC

```bash
oc new-project burner-migration-escalation

oc create serviceaccount kube-burner -n burner-migration-escalation

oc create clusterrole kube-burner-virt \
  --verb=get,list,watch,create,delete,patch,update \
  --resource=virtualmachines,virtualmachineinstances,virtualmachineinstancemigrations,pods,namespaces,configmaps,jobs,events

oc create clusterrolebinding kube-burner-virt-mig-escalation \
  --clusterrole=kube-burner-virt \
  --serviceaccount=burner-migration-escalation:kube-burner
```

---

## Step 2 — Download config files

**Option A — Download from repo**

```bash
BASE="https://raw.githubusercontent.com/m3ghub/kubeburnertests/main/docs/tests/files/13a-vm-live-migration-escalation"

curl -fsSL "$BASE/migration-escalation-config.yml" -o /tmp/migration-escalation-config.yml
curl -fsSL "$BASE/vm-template.yml"                 -o /tmp/vm-template.yml
```

<details>
<summary>Option B — Manual paste</summary>

Create `/tmp/vm-template.yml`:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: mig-esc-{{.Iteration}}-{{.Replica}}
  labels:
    app: migration-escalation
spec:
  running: false
  template:
    metadata:
      labels:
        app: migration-escalation
    spec:
      domain:
        cpu:
          cores: 1
        resources:
          requests:
            memory: 128Mi
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

For the full config, see the downloaded file or the [repo](https://github.com/m3ghub/kubeburnertests/blob/main/docs/tests/files/13a-vm-live-migration-escalation/migration-escalation-config.yml).

</details>

---

## Step 3 — Package into ConfigMap

```bash
oc create configmap migration-escalation-config \
  --from-file=config.yml=/tmp/migration-escalation-config.yml \
  --from-file=vm-template.yml=/tmp/vm-template.yml \
  -n burner-migration-escalation
```

---

## Step 4 — Launch the job

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-mig-escalation
  namespace: burner-migration-escalation
spec:
  template:
    spec:
      serviceAccountName: kube-burner
      initContainers:
        - name: copy-config
          image: busybox
          command: ["sh","-c","cp /configmap/* /config/"]
          volumeMounts:
            - name: configmap-vol
              mountPath: /configmap
            - name: config-vol
              mountPath: /config
      containers:
        - name: kube-burner
          image: quay.io/kube-burner/kube-burner:v2.7.3
          command:
            - kube-burner
            - init
            - -c
            - /config/config.yml
            - --uuid
            - mig-escalation-001
          volumeMounts:
            - name: config-vol
              mountPath: /config
      volumes:
        - name: configmap-vol
          configMap:
            name: migration-escalation-config
        - name: config-vol
          emptyDir: {}
      restartPolicy: Never
EOF
```

---

## Step 5 — Monitor

```bash
# Watch job pod
oc get pods -n burner-migration-escalation -w

# Stream logs
oc logs -f job/kb-mig-escalation -n burner-migration-escalation

# Watch active migrations
watch -n5 'oc get vmim -n burner-migration-escalation'
```

**Expected log output per round:**

```
time="..." level=info msg="Triggering job: r01-create" ...
time="..." level=info msg="Triggering job: r01-start" ...
time="..." level=info msg="Triggering job: r01-migrate" ...
time="..." level=info msg="Triggering job: r01-stop" ...
time="..." level=info msg="Triggering job: r01-delete" ...
```

---

## Force-stop a stuck or failing round

```bash
oc delete job kb-mig-escalation -n burner-migration-escalation

# Stop running VMs first to allow deletion
oc get vm -n burner-migration-escalation -o name | xargs -I{} oc patch {} \
  -n burner-migration-escalation --type=merge -p '{"spec":{"running":false}}'

oc delete vm -l app=migration-escalation -n burner-migration-escalation --wait=false

# Cancel any in-flight migrations
oc delete vmim --all -n burner-migration-escalation
```

---

## Cleanup

```bash
oc delete job kb-mig-escalation -n burner-migration-escalation 2>/dev/null || true
oc delete configmap migration-escalation-config -n burner-migration-escalation 2>/dev/null || true
oc get vm -n burner-migration-escalation -o name | xargs -I{} oc patch {} \
  -n burner-migration-escalation --type=merge -p '{"spec":{"running":false}}'
oc delete vm -l app=migration-escalation -n burner-migration-escalation --wait=false 2>/dev/null || true
oc delete project burner-migration-escalation
oc delete clusterrole kube-burner-virt
oc delete clusterrolebinding kube-burner-virt-mig-escalation
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Migration `Pending` forever | Only 1 worker node | Need 2+ nodes; check `oc get nodes` |
| Migration `Failed` | VM memory too large for target | Reduce memory or check node capacity |
| Job pod `Error` | YAML issue | `oc describe configmap migration-escalation-config` |
| VMs won't delete | Still `Running` | Stop VMs first, then delete |

---

## Related tests

- [13-vm-live-migration.md](13-vm-live-migration.md) — Single-shot migration test
- [09a-kubevirt-density-escalation.md](09a-kubevirt-density-escalation.md) — CirrOS density escalation
