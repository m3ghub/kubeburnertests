# Test 08: Delete Workload — The Controlled Cleanup Test

> **Difficulty:** ⭐ Beginner  
> **Time to run:** ~5 minutes  
> **What it does:** Deletes large numbers of Kubernetes resources in a controlled way to measure deletion speed and ensure garbage collection is working correctly

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 🗑️

Imagine after a big birthday party, you have to clean up — take down 50 balloons, fold 50 napkins, stack 50 chairs. The question is: *how fast can you clean up without dropping anything or forgetting something?*

The **Delete** workload does exactly this for Kubernetes. It creates resources and then deletes them at high speed, measuring:
- How fast the API server processes delete requests
- How fast pods terminate (their containers get the stop signal)
- Whether all resources are truly gone (no orphaned objects left behind)

---

## What does it measure?

| Metric | What it means |
|---|---|
| **Delete throughput** | How many objects deleted per second |
| **Pod termination time** | How long until the pod container actually stops |
| **Namespace cleanup time** | How long until an entire namespace is gone |

---

## How it works

```
Phase 1 — Create:   🟢🟢🟢🟢🟢🟢🟢🟢🟢🟢  (10 Deployments)

Phase 2 — Delete:
  DELETE Deployment-1 ──► Pod starts Terminating ──► Container stops ──► Pod gone ✅
  DELETE Deployment-2 ──► Pod starts Terminating ──► Container stops ──► Pod gone ✅
  DELETE Deployment-3 ──► Pod starts Terminating ──► Container stops ──► Pod gone ✅
  ...all at once, as fast as possible...

Phase 3 — Measure:
  ✅ All pods gone?  Yes!
  ⏱️  How long did it take?  3.2 seconds for 10 Deployments
```

---

## Before you start ✅

- [ ] kube-burner installed
- [ ] Logged in as cluster-admin
- [ ] RBAC applied
- [ ] ~5 minutes available

---

## Step-by-step guide

### Step 1 — Create the namespace

> **Do this first — every other step depends on it.**

```bash
oc new-project burner-delete-test
```

You should see:
```
Now using project "burner-delete-test" on server "https://api.<your-cluster>:6443"
```

> **OpenShift only:** Never use `kube-` at the start of the name — it is reserved by the system and will be rejected.

---

### Step 2 — Set up RBAC

Every test needs a `ServiceAccount`, `ClusterRole`, and `ClusterRoleBinding`. Run all three commands — they are safe to re-run if any already exist.

**2a — Create the ServiceAccount in this namespace:**

```bash
oc create serviceaccount kube-burner -n burner-delete-test 2>/dev/null || true
```

**2b — Apply the ClusterRole and ClusterRoleBinding (once per cluster, inline — no local file needed):**

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-burner
rules:
  - apiGroups: [""]
    resources: [namespaces, pods, services, endpoints, configmaps, secrets, nodes, events, replicationcontrollers, serviceaccounts]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [apps]
    resources: [deployments, replicasets, statefulsets, daemonsets]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [batch]
    resources: [jobs]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies, ingresses]
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
    namespace: burner-delete-test
EOF
```

**2c — Add this namespace to the ClusterRoleBinding:**

```bash
oc patch clusterrolebinding kube-burner \
  --type=json \
  -p='[{"op":"add","path":"/subjects/-","value":{"kind":"ServiceAccount","name":"kube-burner","namespace":"burner-delete-test"}}]' 2>/dev/null || true
```

> The `|| true` at the end means this command will not fail if the namespace is already listed. It is safe to run every time.

**Verify all three are in place before continuing:**

```bash
oc get serviceaccount kube-burner -n burner-delete-test
oc get clusterrole kube-burner
oc get clusterrolebinding kube-burner -o jsonpath='{.subjects[*].namespace}'
```

The last command should include `burner-delete-test` in the output.

---

### Step 3 — Create config files

Create `delete-config.yml`:

```bash
cat > /tmp/delete-config.yml << 'EOF'
global:
  gc: false
  measurements:
    - name: podLatency

jobs:
  - name: delete-setup
    namespace: burner-delete-test
    jobType: create
    jobIterations: 1
    qps: 20
    burst: 20
    objects:
      - objectTemplate: deployment.yml
        replicas: 10
    waitWhenFinished: true
    podWait: true
    maxWaitTimeout: 5m

  - name: delete-workload
    namespace: burner-delete-test
    jobType: delete
    qps: 20
    burst: 20
    objects:
      - kind: Deployment
        apiVersion: apps/v1
        labelSelector:
          app: kube-burner
EOF
```

Create `deployment.yml`:

```bash
cat > /tmp/deployment.yml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: burner-dep-{{.Iteration}}-{{.Replica}}
  labels:
    app: kube-burner
spec:
  replicas: 1
  selector:
    matchLabels:
      name: burner-dep-{{.Iteration}}-{{.Replica}}
  template:
    metadata:
      labels:
        name: burner-dep-{{.Iteration}}-{{.Replica}}
        app: kube-burner
    spec:
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 1m
              memory: 10Mi
EOF
```

---

### Step 4 — Package into a ConfigMap

```bash
oc create configmap delete-config \
  --from-file=config.yml=/tmp/delete-config.yml \
  --from-file=deployment.yml=/tmp/deployment.yml \
  -n burner-delete-test
```

---

### Step 5 — Run the test!

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-delete
  namespace: burner-delete-test
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=delete-001]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: delete-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Step 6 — Watch the test run

```bash
oc get pods -n burner-delete-test -w
```

You will see the kube-burner Job pod move through these states:

```
NAME              READY   STATUS    RESTARTS   AGE
kb-delete-27qrg   1/1     Running     0         26s
kb-delete-27qrg   0/1     Completed   0         40s
kb-delete-27qrg   0/1     Completed   0         42s
```

- **Running** — kube-burner is actively creating and then deleting resources inside the namespace
- **Completed** — the test finished successfully; all jobs (create + delete) are done

> **Note:** You will NOT see the workload pods go `Terminating` here — `oc get pods -w` is watching the *Job pod* itself, not the short-lived workload pods. The workload pods are created and destroyed too quickly to catch with a watch. To see the deletion in real-time as it happens, open a second terminal and run:
> ```bash
> oc get pods -n burner-delete-test --watch
> ```
> before you trigger the Job (Step 5).

---

### Step 7 — Read results

```bash
oc logs -f job/kb-delete -n burner-delete-test
```

```
time="..." level=info msg="Triggering job: delete-setup (create)"
time="..." level=info msg="delete-setup: 10/10 pods ready"
time="..." level=info msg="Triggering job: delete-workload (delete)"
time="..." level=info msg="Deleting 10 Deployments in burner-delete-test"
time="..." level=info msg="delete-workload: all 10 objects deleted in 2800ms"
time="..." level=info msg="Finished execution. UUID: delete-001"
```

**Good deletion time:**
- Under **5 seconds** for 10 Deployments on a healthy cluster

---

### Step 8 — Verify everything is gone

```bash
oc get all -n burner-delete-test
# Should only show the kube-burner Job pod itself
```

---

### Step 9 — Clean up

```bash
oc delete job kb-delete -n burner-delete-test
oc delete configmap delete-config -n burner-delete-test
oc delete project burner-delete-test
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `namespaces "burner-delete-test" not found` when creating ConfigMap | You must run `oc new-project burner-delete-test` **before** the `oc create configmap` command |
| `serviceaccount "kube-burner" not found` in Job events | The ServiceAccount only exists in the namespace where RBAC was first applied. Run `oc create serviceaccount kube-burner -n burner-delete-test` |
| `cannot create resource "namespaces"` — authorization error | The `ClusterRoleBinding` points to the original namespace's SA. Patch it to add the new one: `oc patch clusterrolebinding kube-burner --type=json -p='[{"op":"add","path":"/subjects/-","value":{"kind":"ServiceAccount","name":"kube-burner","namespace":"burner-delete-test"}}]'` |
| Pods stuck in `Terminating` | Check for `finalizers` on the pod: `oc patch pod <name> -p '{"metadata":{"finalizers":[]}}' --type=merge` |
| Delete takes very long | Kubernetes default `terminationGracePeriodSeconds` is 30s — set it to 1s in the deployment template for testing |
| Some objects not deleted | Check label selectors — they must exactly match the labels on the created objects |

---

*Next test: [09 — KubeVirt Density](09-kubevirt-density.md) — create virtual machines inside Kubernetes*
