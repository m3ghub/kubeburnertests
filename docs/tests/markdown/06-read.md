# Test 06: Read Workload — The Library Test

> **Difficulty:** ⭐ Beginner  
> **Time to run:** ~5 minutes  
> **What it does:** Reads (lists and gets) existing cluster resources at high speed to test how well the API server handles read requests

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 📖

Imagine a library where thousands of students all arrive at the same time and start asking for books.  
They do NOT write or change anything — they just **read**.

The **Read** workload does the same thing to your Kubernetes API server.  
It sends many `LIST` and `GET` requests at high speed and measures how fast the API server responds.

This is important because in a real cluster, monitoring tools, operators, dashboards, and CI pipelines all constantly read cluster state. If reads are slow, everything feels slow.

---

## What does it measure?

| Metric | What it means |
|---|---|
| **API server read latency** | How fast `oc get pods` or `LIST` requests complete |
| **etcd read throughput** | How many objects/sec the database can serve |
| **Watch event lag** | How quickly watchers (like operators) get updates |

---

## How it works

```
kube-burner sends many read requests to the API server:

  kube-burner ──► GET /api/v1/namespaces/{ns}/pods          ──► API Server ──► etcd
  kube-burner ──► LIST /api/v1/namespaces/{ns}/deployments  ──► API Server ──► etcd
  kube-burner ──► GET /api/v1/namespaces/{ns}/services      ──► API Server ──► etcd
  kube-burner ──► LIST /api/v1/namespaces/{ns}/configmaps   ──► API Server ──► etcd

  All at high QPS (queries per second) — the API server must keep up!

  BEFORE this test: run pod-density or node-density to create real resources to read
  DURING this test: kube-burner reads those resources at high speed
  AFTER  this test: measure how long each read took (p50, p90, p99)
```

---

## Before you start ✅

- [ ] kube-burner installed
- [ ] Logged in as cluster-admin
- [ ] RBAC applied
- [ ] **Some resources already exist to read** — run pod-density first or use an existing namespace
- [ ] ~5 minutes available

---

## Step-by-step guide

### Step 1 — Create the namespace

> **Do this first — every other step depends on it.**

```bash
oc new-project burner-read-test
```

You should see:
```
Now using project "burner-read-test" on server "https://api.<your-cluster>:6443"
```

> **OpenShift only:** Never use `kube-` at the start of the name — it is reserved by the system and will be rejected.

Now create some pods inside it — these are the resources the Read test will read:

```bash
for i in $(seq 1 10); do
  oc run read-target-$i \
    --image=registry.k8s.io/pause:3.9 \
    --restart=Never \
    -n burner-read-test
done

# Verify pods exist before continuing
oc get pods -n burner-read-test
```

---

### Step 2 — Set up RBAC

Every test needs a `ServiceAccount`, `ClusterRole`, and `ClusterRoleBinding`. Run all three commands — they are safe to re-run if any already exist.

**2a — Create the ServiceAccount in this namespace:**

```bash
oc create serviceaccount kube-burner -n burner-read-test \
  --dry-run=client -o yaml | oc apply -f -
```

**2b — Apply the ClusterRole and ClusterRoleBinding (once per cluster):**

> These are applied inline below — no local file needed. Safe to re-run at any time.

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
  - apiGroups: [kubevirt.io]
    resources: [virtualmachines, virtualmachineinstances]
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
    namespace: burner-read-test
EOF
```

**2c — Add this namespace to the ClusterRoleBinding:**

```bash
oc patch clusterrolebinding kube-burner \
  --type=json \
  -p='[{"op":"add","path":"/subjects/-","value":{"kind":"ServiceAccount","name":"kube-burner","namespace":"burner-read-test"}}]' 2>/dev/null || true
```

> The `|| true` at the end means this command will not fail if the namespace is already listed. It is safe to run every time.

**Verify all three are in place before continuing:**

```bash
oc get serviceaccount kube-burner -n burner-read-test
oc get clusterrole kube-burner
oc get clusterrolebinding kube-burner -o jsonpath='{.subjects[*].namespace}'
```

The last command should include `burner-read-test` in the output.

---

### Step 3 — Create the config file

Create `read-config.yml`:

```bash
cat > /tmp/read-config.yml << 'EOF'
global:
  gc: false          # Don't delete the resources — we want to read them!
  measurements: []   # No pod latency measurement needed for a pure read test

jobs:
  - name: read-workload
    namespace: burner-read-test
    jobType: read
    jobIterations: 1
    qps: 20
    burst: 20
    objects:
      - kind: Pod
        apiVersion: v1
        labelSelector:
          matching: {}
EOF
```

---

### Step 4 — Package into a ConfigMap

```bash
oc create configmap read-config \
  --from-file=config.yml=/tmp/read-config.yml \
  -n burner-read-test
```

---

### Step 5 — Run the test!

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-read
  namespace: burner-read-test
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=read-001]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: read-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Step 6 — Stream logs

```bash
oc logs -f job/kb-read -n burner-read-test
```

Expected output:

```
time="..." level=info msg="Triggering job: read-workload"
time="..." level=info msg="Reading 10 pods in burner-read-test"
time="..." level=info msg="read-workload completed: 10 objects read in 120ms"
time="..." level=info msg="Finished execution. UUID: read-001"
```

**Good API server response time:**
- Under **200ms** for `LIST` of 10 objects on a healthy cluster

---

### Step 7 — Clean up

```bash
oc delete job kb-read -n burner-read-test
oc delete configmap read-config -n burner-read-test
oc delete project burner-read-test
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| No objects found to read | Create some resources first (Step 1) |
| Very slow response times | API server is overloaded or etcd is slow |
| `Forbidden` on list pods | Check RBAC includes `list` permission for pods |

---

*Next test: [07 — Patch Workload](07-patch.md) — update resources that already exist*
