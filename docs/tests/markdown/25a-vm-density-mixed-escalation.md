# Test 25a — Mixed VM Fleet Density Escalation (Set It and Forget It)

**Category:** OpenShift Virtualization — Mixed Windows + RHEL Fleet  
**Namespace:** `burner-mixed-escalation`  
**Escalation:** 5 → 10 → 20 → 30 → 50 VMs (70% Windows / 30% RHEL)  
**Duration:** ~120–240 min  
**Difficulty:** ⭐⭐⭐⭐⭐ Expert

## What this test does

Automatically runs 5 escalating rounds with a mixed fleet of Windows Server 2022 and RHEL 9 VMs. Each round launches both OS types simultaneously, waits for all VMs to reach Running state, then deletes the entire fleet before the next round. Demonstrates real-world heterogeneous workload scheduling.

> **Time warning:** Each round requires cloning both Windows (60Gi each) and RHEL (30Gi each) PVCs. Round 5 clones ~2.3 Ti of storage. Allow 120 min per round on busy storage.

| Round | Windows VMs | RHEL VMs | Total | Max Wait |
|-------|-------------|----------|-------|----------|
| 1 | 3 | 2 | 5 | 120 min |
| 2 | 7 | 3 | 10 | 120 min |
| 3 | 14 | 6 | 20 | 120 min |
| 4 | 21 | 9 | 30 | 120 min |
| 5 | 35 | 15 | 50 | 120 min |

---

## Prerequisites

- OpenShift cluster with OpenShift Virtualization installed
- `oc` CLI logged in with cluster-admin
- Both golden images available:

```bash
oc get pvc win2k22 -n openshift-virtualization-os-images
oc get datasource rhel9 -n openshift-virtualization-os-images
```

- Sufficient capacity: Round 5 needs 35 × 8Gi (Windows) + 15 × 2Gi (RHEL) = 310 Gi RAM total.

---

## Step 1 — Namespace and RBAC

```bash
oc new-project burner-mixed-escalation

oc create serviceaccount kube-burner -n burner-mixed-escalation

oc create clusterrole kube-burner-virt \
  --verb=get,list,watch,create,delete,patch,update \
  --resource=virtualmachines,virtualmachineinstances,datavolumes,pods,namespaces,configmaps,jobs,events

oc create clusterrolebinding kube-burner-virt-mixed-escalation \
  --clusterrole=kube-burner-virt \
  --serviceaccount=burner-mixed-escalation:kube-burner
```

---

## Step 2 — Download config files

**Option A — Download from repo**

```bash
BASE="https://raw.githubusercontent.com/m3ghub/kubeburnertests/main/docs/tests/files/25a-vm-density-mixed-escalation"

curl -fsSL "$BASE/mixed-escalation-config.yml" -o /tmp/mixed-escalation-config.yml
curl -fsSL "$BASE/vm-template-windows.yml"      -o /tmp/vm-template-windows.yml
curl -fsSL "$BASE/vm-template-rhel.yml"         -o /tmp/vm-template-rhel.yml
```

<details>
<summary>Option B — Manual paste</summary>

For the VM templates and full config, see the [repo](https://github.com/m3ghub/kubeburnertests/tree/main/docs/tests/files/25a-vm-density-mixed-escalation/).

</details>

---

## Step 3 — Package into ConfigMap

```bash
oc create configmap mixed-escalation-config \
  --from-file=config.yml=/tmp/mixed-escalation-config.yml \
  --from-file=vm-template-windows.yml=/tmp/vm-template-windows.yml \
  --from-file=vm-template-rhel.yml=/tmp/vm-template-rhel.yml \
  -n burner-mixed-escalation
```

---

## Step 4 — Launch the job

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-mixed-escalation
  namespace: burner-mixed-escalation
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
            - mixed-escalation-001
          volumeMounts:
            - name: config-vol
              mountPath: /config
      volumes:
        - name: configmap-vol
          configMap:
            name: mixed-escalation-config
        - name: config-vol
          emptyDir: {}
      restartPolicy: Never
EOF
```

> **Re-run note:** Change `--uuid mixed-escalation-001` to a new unique value on each run.

---

## Security — DISA STIG-hardened job manifest

If your cluster enforces DISA STIG hardening (e.g. the `restricted-v2` SCC, a compliance-operator profile, or an admission policy requiring non-root containers and no Linux capabilities), the Step 4 job manifest above may fail admission. Use this hardened variant instead — it adds a pod-level `securityContext` (non-root, `RuntimeDefault` seccomp profile) plus container-level `securityContext` (no privilege escalation, all capabilities dropped) on both the init container and the `kube-burner` container:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-mixed-escalation
  namespace: burner-mixed-escalation
spec:
  template:
    spec:
      serviceAccountName: kube-burner
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: copy-config
          image: registry.redhat.io/ubi9/ubi-minimal:latest
          command: ["sh","-c","cp /configmap/* /config/"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
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
            - mixed-escalation-001
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config-vol
              mountPath: /config
      volumes:
        - name: configmap-vol
          configMap:
            name: mixed-escalation-config
        - name: config-vol
          emptyDir: {}
      restartPolicy: Never
EOF
```

> **Note:** The init container image was swapped from `busybox` to `registry.redhat.io/ubi9/ubi-minimal:latest` since STIG-locked registries typically only permit signed Red Hat UBI images.

---

## Step 5 — Monitor

```bash
# Watch job pod
oc get pods -n burner-mixed-escalation -w

# Stream logs
oc logs -f job/kb-mixed-escalation -n burner-mixed-escalation

# Watch DataVolumes (cloning is the bottleneck)
watch -n15 'oc get dv -n burner-mixed-escalation | grep -v Succeeded | wc -l && echo "DVs still cloning"'

# Watch VMs by OS type
watch -n15 'oc get vm -n burner-mixed-escalation -l vm-os=windows | wc -l && oc get vm -n burner-mixed-escalation -l vm-os=rhel | wc -l'
```

---

## Force-stop a stuck or failing round

```bash
oc delete job kb-mixed-escalation -n burner-mixed-escalation

oc delete vm -l app=mixed-fleet-escalation -n burner-mixed-escalation --wait=false

oc delete dv --all -n burner-mixed-escalation --wait=false

oc get vm,dv -n burner-mixed-escalation -w
```

---

## Cleanup

```bash
oc delete job kb-mixed-escalation -n burner-mixed-escalation 2>/dev/null || true
oc delete configmap mixed-escalation-config -n burner-mixed-escalation 2>/dev/null || true
oc delete vm -l app=mixed-fleet-escalation -n burner-mixed-escalation --wait=false 2>/dev/null || true
oc delete dv --all -n burner-mixed-escalation --wait=false 2>/dev/null || true
oc delete project burner-mixed-escalation
oc delete clusterrole kube-burner-virt
oc delete clusterrolebinding kube-burner-virt-mixed-escalation
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Windows DV stuck | PVC clone source `win2k22` missing | `oc get pvc -n openshift-virtualization-os-images` |
| RHEL DV stuck | `rhel9` DataSource not Ready | `oc get datasource rhel9 -n openshift-virtualization-os-images` |
| Scheduler pressure | Mixed large (8Gi) + small (2Gi) requests | Some Windows VMs may not schedule; reduce `replicas` |
| Delete round finds 0 VMs | Label selector issue | Ensure both templates have `app: mixed-fleet-escalation` |

---

## Related tests

- [25-vm-density-mixed.md](25-vm-density-mixed.md) — Single-shot mixed density
- [23a-vm-density-rhel-escalation.md](23a-vm-density-rhel-escalation.md) — RHEL-only escalation
- [24a-vm-density-windows-escalation.md](24a-vm-density-windows-escalation.md) — Windows-only escalation
- [22-ocp-vmi-density-churn.md](22-ocp-vmi-density-churn.md) — Mixed churn (Windows + RHEL)
