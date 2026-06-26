# Test 11: Check Alerts — Did Any Alarms Go Off?

> **Difficulty:** ⭐⭐ Intermediate  
> **Time to run:** ~2 minutes  
> **What it does:** Queries Prometheus to check whether any defined alert thresholds were breached during a benchmark run
> **Requires:** Prometheus running in the cluster (included with OpenShift by default)

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 🔔

Imagine your cluster is a building with a fire alarm system.  
**Check Alerts** is like checking the alarm panel after a fire drill — it asks:  
*"Did any alarms go off during the test? If so, which ones?"*

Kube-burner can define alert rules (thresholds) like:
- *"API server latency should never go above 1 second"*
- *"CPU usage should stay below 80%"*
- *"No pods should be stuck Pending for more than 5 minutes"*

After a benchmark, the `check-alerts` command checks whether any of these rules were violated. If they were, kube-burner **exits with code 3** so your CI pipeline knows something went wrong.

---

## What does it check?

```
  Prometheus ──► stores metrics from your cluster
       │
       │  kube-burner asks: "were any of my thresholds breached?"
       ▼
  Alert profile (alerts.yml)
  ┌─────────────────────────────────────────────────────────┐
  │  Rule 1: apiserver_request_duration_p99 < 1000ms  ✅   │
  │  Rule 2: node_cpu_utilisation < 0.8               ✅   │
  │  Rule 3: kubelet_running_pods < 250               ✅   │
  └─────────────────────────────────────────────────────────┘
       │
       ▼
  All rules pass ──► exit code 0 (success)
  Any rule fails ──► exit code 3 (threshold breached!)
```

---

## Before you start ✅

- [ ] kube-burner installed
- [ ] Logged in as cluster-admin
- [ ] RBAC applied
- [ ] Prometheus is running in the cluster (`oc get pods -n openshift-monitoring`)
- [ ] You have run a benchmark first (something to check alerts *about*)

### Find your Prometheus URL (OpenShift)

```bash
PROMETHEUS_URL=$(oc get route prometheus-k8s -n openshift-monitoring \
  -o jsonpath='{.spec.host}')
echo "https://${PROMETHEUS_URL}"
```

### Get a Prometheus token

```bash
PROMETHEUS_TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring)
echo $PROMETHEUS_TOKEN
```

---

## Step-by-step guide

### Step 1 — Create the namespace

> **Do this first — every other step depends on it.**

```bash
oc new-project burner-alerts
```

You should see:
```
Now using project "burner-alerts" on server "https://api.<your-cluster>:6443"
```

> **OpenShift only:** Never use `kube-` at the start of the name — it is reserved by the system and will be rejected.

### Step 2 — Set up RBAC

Every test needs a `ServiceAccount`, `ClusterRole`, and `ClusterRoleBinding`. Run all three commands — they are safe to re-run if any already exist.

**2a — Create the ServiceAccount in this namespace:**

```bash
oc create serviceaccount kube-burner -n burner-alerts \
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
    namespace: burner-alerts
EOF
```

**2c — Add this namespace to the ClusterRoleBinding:**

```bash
oc patch clusterrolebinding kube-burner \
  --type=json \
  -p='[{"op":"add","path":"/subjects/-","value":{"kind":"ServiceAccount","name":"kube-burner","namespace":"burner-alerts"}}]' 2>/dev/null || true
```

> The `|| true` at the end means this command will not fail if the namespace is already listed. It is safe to run every time.

**Verify all three are in place before continuing:**

```bash
oc get serviceaccount kube-burner -n burner-alerts
oc get clusterrole kube-burner
oc get clusterrolebinding kube-burner -o jsonpath='{.subjects[*].namespace}'
```

The last command should include `burner-alerts` in the output.

### Step 3 — Create your alert profile

Create `alerts.yml` — this defines what is "too slow" or "too hot":

```bash
cat > /tmp/alerts.yml << 'EOF'
# Alert profile for kube-burner check-alerts
# Each entry defines a Prometheus query and a threshold.
# If the query returns a value ABOVE the threshold, the alert fires.

alerts:
  - expr: |
      histogram_quantile(0.99,
        sum(rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH"}[2m])) by (le)
      ) * 1000
    description: "API server 99th percentile latency (ms) must be below 1000ms"
    severity: error
    threshold: 1000          # fail if 99th p latency > 1000ms

  - expr: |
      avg(
        100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)
      )
    description: "Average cluster CPU usage must be below 80%"
    severity: warning
    threshold: 80

  - expr: |
      sum(kubelet_running_pods)
    description: "Total running pods must be below 1000"
    severity: warning
    threshold: 1000
EOF
```

---

### Step 4 — Store the alert profile as a ConfigMap

```bash
oc create configmap alerts-config \
  --from-file=alerts.yml=/tmp/alerts.yml \
  -n burner-alerts
```

---

### Step 5 — Run the alert check

You need to know your Prometheus URL and token (found in the section above).

```bash
PROMETHEUS_URL=$(oc get route prometheus-k8s -n openshift-monitoring \
  -o jsonpath='{.spec.host}')
PROMETHEUS_TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring --duration=1h)

cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-check-alerts
  namespace: burner-alerts
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
            - check-alerts
            - -a
            - /config/alerts.yml
            - --prometheus-url=https://${PROMETHEUS_URL}
            - --token=${PROMETHEUS_TOKEN}
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: alerts-config
        - name: workdir
          emptyDir: {}
EOF
```

---

### Step 6 — Read the results

```bash
oc logs job/kb-check-alerts -n burner-alerts
```

**All alerts pass (healthy cluster):**

```
time="..." level=info msg="Checking alerts..."
time="..." level=info msg="[PASS] API server 99th percentile latency (ms): 342ms < 1000ms ✅"
time="..." level=info msg="[PASS] Average cluster CPU usage: 12% < 80% ✅"
time="..." level=info msg="[PASS] Total running pods: 187 < 1000 ✅"
time="..." level=info msg="All alerts passed."
```

**An alert fired:**

```
time="..." level=error msg="[FAIL] API server 99th percentile latency: 1450ms > 1000ms ❌"
time="..." level=error msg="Alert threshold breached. Exiting with code 3."
```

**Check the exit code:**

```bash
oc get pod -l job-name=kb-check-alerts -n burner-alerts \
  -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.exitCode}'
# 0 = all alerts passed ✅
# 3 = one or more thresholds breached ❌
```

---

### Step 7 — Clean up

```bash
oc delete job kb-check-alerts -n burner-alerts
oc delete configmap alerts-config -n burner-alerts
oc delete project burner-alerts
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `no such host prometheus-k8s` | Use `oc get routes -A` to find the real Prometheus route URL |
| `401 Unauthorized` | Token expired — create a new one with `oc create token` |
| `403 Forbidden` | The ServiceAccount needs `get` on `routes` — check RBAC |
| All alerts fire on a fresh cluster | Thresholds may be too tight — adjust values in `alerts.yml` |

---

*Next test: [12 — Index Metrics](12-index.md) — save your Prometheus data for later analysis*
