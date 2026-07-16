# Test 05: Churn — The Revolving Door Test

> **Difficulty:** ⭐⭐ Intermediate  
> **Time to run:** ~10–20 minutes (configurable)  
> **What it does:** Creates resources, deletes them, then creates them again — over and over — to test cluster stability under constant change

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 🔄

Imagine a busy hotel with a revolving door. Guests check in, stay a while, check out — and new guests immediately fill the same rooms. The hotel is **always full**, but the people inside keep changing.

That is exactly what the **Churn** test does to your cluster. It:
1. Creates pods (guests check in)
2. Waits a while (guests stay)
3. Deletes them (guests check out)
4. Creates fresh ones (new guests arrive)
5. Repeats many times

This tests whether your cluster stays **healthy and stable** under constant change — because real production clusters always have apps starting and stopping.

---

## What does it measure?

| Metric | What it means |
|---|---|
| **Pod latency** | How fast new pods start each churn cycle |
| **Stability** | Does latency get worse after many cycles? |
| **Resource cleanup** | Are old resources fully removed before new ones start? |
| **API server health** | Can it handle thousands of creates and deletes over time? |

---

## How it works

```
Timeline view:

  t=0    CREATE ──► 🟢🟢🟢🟢🟢  (50 pods running)
         │
  t=30s  WAIT   ──► 🟢🟢🟢🟢🟢  (still running)
         │
  t=60s  DELETE ──► ❌❌❌❌❌  (pods deleted)
         │
  t=90s  CREATE ──► 🟢🟢🟢🟢🟢  (fresh pods — cycle 2)
         │
  t=120s WAIT   ──► 🟢🟢🟢🟢🟢
         │
  t=150s DELETE ──► ❌❌❌❌❌
         │
  t=180s CREATE ──► 🟢🟢🟢🟢🟢  (fresh pods — cycle 3)
         │
         ... repeats for N churn cycles ...

  The churn percentage controls what fraction gets deleted each cycle.
  churnPercent: 10 = delete and replace 10% of pods per cycle
```

---

## Before you start ✅

- [ ] kube-burner installed
- [ ] Logged in as cluster-admin
- [ ] RBAC applied
- [ ] For SNO: calculate free pod slots first (Section 5 of installation guide)
- [ ] ~15 minutes available

> **SNO Important:** Churn is especially useful on Single Node OpenShift to test
> the scheduler under the 250-pod limit. But start with `replicas: 10` to be safe.

---

## Step-by-step guide

### Step 1 — Create the namespace

> **Do this first — every other step depends on it.**

```bash
oc new-project burner-churn
```

You should see:
```
Now using project "burner-churn" on server "https://api.<your-cluster>:6443"
```

> **OpenShift only:** Never use `kube-` at the start of the name — it is reserved by the system and will be rejected.

---

### Step 2 — Set up RBAC

Every test needs a `ServiceAccount`, `ClusterRole`, and `ClusterRoleBinding`. Run all three commands — they are safe to re-run if any already exist.

**2a — Create the ServiceAccount in this namespace:**

```bash
oc create serviceaccount kube-burner -n burner-churn 2>/dev/null || true
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
    namespace: burner-churn
EOF
```

**2c — Add this namespace to the ClusterRoleBinding:**

```bash
oc patch clusterrolebinding kube-burner \
  --type=json \
  -p='[{"op":"add","path":"/subjects/-","value":{"kind":"ServiceAccount","name":"kube-burner","namespace":"burner-churn"}}]' 2>/dev/null || true
```

> The `|| true` at the end means this command will not fail if the namespace is already listed. It is safe to run every time.

**Verify all three are in place before continuing:**

```bash
oc get serviceaccount kube-burner -n burner-churn
oc get clusterrole kube-burner
oc get clusterrolebinding kube-burner -o jsonpath='{.subjects[*].namespace}'
```

The last command should include `burner-churn` in the output.

---

### Step 3 — Create the config files

Create `churn-config.yml`:

```bash
cat > /tmp/churn-config.yml << 'EOF'
global:
  gc: true
  measurements:
    - name: podLatency

jobs:
  - name: churn-density
    namespace: burner-churn
    jobType: create
    jobIterations: 1
    qps: 20
    burst: 20
    objects:
      - objectTemplate: pod.yml
        replicas: 20
    waitWhenFinished: true
    podWait: true
    maxWaitTimeout: 5m
    churnConfig:
      duration: 2m
      percent: 20
EOF
```

Create `pod.yml`:

```bash
cat > /tmp/pod.yml << 'EOF'
kind: Pod
apiVersion: v1
metadata:
  name: churn-pod-{{.Iteration}}-{{.Replica}}
  labels:
    app: kube-burner-churn
spec:
  containers:
    - name: pause
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
oc create configmap churn-config \
  --from-file=config.yml=/tmp/churn-config.yml \
  --from-file=pod.yml=/tmp/pod.yml \
  -n burner-churn
```

---

### Step 5 — Run the test!

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-churn
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=churn-001]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: churn-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Security — DISA STIG-hardened job manifest

If your cluster enforces DISA STIG hardening (e.g. the `restricted-v2` SCC, a compliance-operator profile, or an admission policy requiring non-root containers and no Linux capabilities), the Step 5 job manifest above may fail admission. Use this hardened variant instead — it adds a pod-level `securityContext` (non-root, `RuntimeDefault` seccomp profile) plus container-level `securityContext` (no privilege escalation, all capabilities dropped) on both the init container and the `kube-burner` container:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-churn
  namespace: burner-churn
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: kube-burner
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      restartPolicy: Never
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=churn-001]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: churn-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Step 6 — Watch the test run

```bash
oc get pods -n burner-churn -w
```

You will see the kube-burner Job pod move through these states:

```
NAME            READY   STATUS    RESTARTS   AGE
kb-churn-xxxxx  1/1     Running     0         15s
kb-churn-xxxxx  0/1     Completed   0         2m10s
```

- **Running** — kube-burner is creating pods, waiting, churning (deleting and recreating) them in cycles
- **Completed** — all churn cycles finished successfully

> **Tip:** To watch the actual workload pods churning in real-time, open a **second terminal** and run:
> ```bash
> watch "oc get pods -n burner-churn --no-headers | awk '{print \$3}' | sort | uniq -c"
> ```
> You will see pod counts shift between `Running`, `Terminating`, and `ContainerCreating` as each churn cycle fires.

In your first terminal, stream the logs:

```bash
oc logs -f job/kb-churn -n burner-churn
```

---

### Step 7 — Read the results

Look for churn cycle entries in the log:

```
time="..." level=info msg="Starting churn cycle 1 — deleting 4/20 pods"
time="..." level=info msg="churn-density: Ready 99th: 1800ms  (cycle 1)"
time="..." level=info msg="Starting churn cycle 2 — deleting 4/20 pods"
time="..." level=info msg="churn-density: Ready 99th: 1900ms  (cycle 2)"
time="..." level=info msg="Starting churn cycle 3 — deleting 4/20 pods"
time="..." level=info msg="churn-density: Ready 99th: 2100ms  (cycle 3)"
time="..." level=info msg="Finished execution. UUID: churn-001"
```

**What to look for:**  
The 99th-percentile should stay roughly **flat** across all cycles. If it keeps going up, the cluster is degrading under load — that's important information!

| Cycle | 99th Ready (example good cluster) | 99th Ready (struggling cluster) |
|---|---|---|
| 1 | 1800ms ✅ | 2000ms |
| 2 | 1900ms ✅ | 3500ms |
| 3 | 2000ms ✅ | 6000ms ⚠️ |

---

### Step 8 — Clean up

```bash
oc delete job kb-churn -n burner-churn
oc delete configmap churn-config -n burner-churn
oc delete project burner-churn
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `field enable not found in type config.rawChurn` (or `type`, `period`) | Remove those fields — only `duration` and `percent` are valid in `churnConfig` for v2.7.3 |
| Pods never come back after deletion | Check scheduler logs; node may be full |
| `Too many pods` on SNO | Reduce `replicas` to 10, `percent` to 10 |
| Latency grows each cycle | Cluster has a memory leak or garbage collection issue |
| Churn ends too quickly | Increase `duration` from `2m` to `10m` |

---

## Try it yourself — challenge 🏆

1. Change `percent: 20` to `percent: 50` — delete half the pods each cycle! Is the cluster OK?
2. Change `period: 30s` to `period: 10s` — churn much faster! What happens to latency?
3. Watch `oc top nodes` during churning — does CPU spike on each cycle?

---

*Next test: [06 — Read Workload](06-read.md) — test the API server under read-only load*
