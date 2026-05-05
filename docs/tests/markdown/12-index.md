# Test 12: Index Metrics — Save Your Report Card

> **Difficulty:** ⭐⭐ Intermediate  
> **Time to run:** ~3 minutes  
> **What it does:** Collects metrics from Prometheus after a benchmark and saves them to an indexer (like Elasticsearch or a local file) so you can compare results over time
> **Requires:** Prometheus running in the cluster

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 📊

After a test at school, you get a report card showing your scores. You can look at it weeks later and compare: *"Did I get better at maths since last term?"*

**Index Metrics** is kube-burner's report card system.  
After a benchmark runs, it:
1. Queries Prometheus for the metrics you care about (CPU, memory, API latency, etc.)
2. Saves them to a storage system (Elasticsearch, OpenSearch, or a local JSON file)
3. Lets you compare results across different runs over time

Even without a full Elasticsearch setup, you can save results locally as JSON files — which is what this guide does.

---

## What does it collect?

The metrics are defined in a **metrics profile** YAML file. You can collect anything Prometheus tracks:

| Metric category | Example PromQL query |
|---|---|
| **API server latency** | `histogram_quantile(0.99, rate(apiserver_request_duration_seconds_bucket[5m]))` |
| **Node CPU usage** | `rate(node_cpu_seconds_total{mode!="idle"}[5m])` |
| **Node memory** | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` |
| **Scheduler latency** | `histogram_quantile(0.99, rate(scheduler_e2e_scheduling_duration_seconds_bucket[5m]))` |
| **etcd disk** | `rate(etcd_disk_wal_fsync_duration_seconds_sum[5m])` |

---

## How it works

```
  After benchmark runs:

  Prometheus ──► stores all metrics
      │
      │  kube-burner index -m metrics.yml
      ▼
  For each query in metrics.yml:
    ┌──────────────────────────────────────────────┐
    │  Query Prometheus  ──► get data points       │
    │  Add UUID + timestamp + run metadata         │
    │  Write to output (JSON file or ES/OpenSearch)│
    └──────────────────────────────────────────────┘
      │
      ▼
  Output: benchmark-results-<uuid>.json
  (Can also go to Elasticsearch for dashboards)
```

---

## Before you start ✅

- [ ] kube-burner installed
- [ ] Logged in as cluster-admin
- [ ] RBAC applied
- [ ] Prometheus running (`oc get pods -n openshift-monitoring | grep prometheus-k8s`)
- [ ] A benchmark has been run recently (gives Prometheus data to collect)

---

## Step-by-step guide

### Step 1 — Create the namespace

> **Do this first — every other step depends on it.**

```bash
oc new-project burner-index
```

You should see:
```
Now using project "burner-index" on server "https://api.<your-cluster>:6443"
```

> **OpenShift only:** Never use `kube-` at the start of the name — it is reserved by the system and will be rejected.

---

### Step 2 — Set up RBAC

Every test needs a `ServiceAccount`, `ClusterRole`, and `ClusterRoleBinding`. Run all three commands — they are safe to re-run if any already exist.

**2a — Create the ServiceAccount in this namespace:**

```bash
oc create serviceaccount kube-burner -n burner-index 2>/dev/null || true
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
    namespace: burner-index
EOF
```

**2c — Add this namespace to the ClusterRoleBinding:**

```bash
oc patch clusterrolebinding kube-burner \
  --type=json \
  -p='[{"op":"add","path":"/subjects/-","value":{"kind":"ServiceAccount","name":"kube-burner","namespace":"burner-index"}}]' 2>/dev/null || true
```

**Verify all three are in place before continuing:**

```bash
oc get serviceaccount kube-burner -n burner-index
oc get clusterrole kube-burner
oc get clusterrolebinding kube-burner -o jsonpath='{.subjects[*].namespace}'
```

The last command should include `burner-index` in the output.

### Step 3 — Create the metrics profile

Create `metrics.yml` — this is the list of Prometheus queries to run:

> **Important:** The `index` subcommand requires a **plain YAML list** (starting with `-`).
> Do NOT wrap it under a `metrics:` key — that causes a parse error.

```bash
cat > /tmp/metrics.yml << 'EOF'
- query: histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{verb!="WATCH"}[2m])) by (le))
  metricName: apiserver99thLatency

- query: irate(process_cpu_seconds_total{job=~"kube-apiserver|etcd"}[2m])
  metricName: controlPlaneCPU

- query: process_resident_memory_bytes{job=~"kube-apiserver|etcd"}
  metricName: controlPlaneMemory

- query: avg(rate(node_cpu_seconds_total{mode!="idle"}[2m])) by (instance)
  metricName: nodeCPUUsage

- query: avg(node_memory_MemAvailable_bytes) by (instance)
  metricName: nodeMemoryAvailable

- query: sum(kubelet_running_pods) by (node)
  metricName: runningPodsPerNode
EOF
```

---

### Step 4 — Store the metrics profile as a ConfigMap

```bash
oc create configmap index-config \
  --from-file=metrics.yml=metrics.yml \
  -n burner-index
```

---

### Step 5 — Run the indexer

You need your Prometheus URL and token:

```bash
PROMETHEUS_URL=$(oc get route prometheus-k8s -n openshift-monitoring \
  -o jsonpath='{.spec.host}')
PROMETHEUS_TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring --duration=1h)

cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-index
  namespace: burner-index
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
          command:
            - kube-burner
            - index
            - -m
            - /config/metrics.yml
            - --prometheus-url=https://${PROMETHEUS_URL}
            - --token=${PROMETHEUS_TOKEN}
            - --uuid=index-run-001
            - --start=$(date -d '1 hour ago' --utc +%s)
            - --end=$(date --utc +%s)
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: index-config
        - name: workdir
          emptyDir: {}
EOF
```

> **Note:** The `--start` and `--end` flags tell kube-burner the time window to query. Here we ask for the last 1 hour. Adjust to match when your benchmark ran.

---

### Step 6 — Read the output

```bash
oc logs job/kb-index -n burner-index
```

Expected output:

```
time="..." level=info msg="Indexing metric: apiserver99thLatency"
time="..." level=info msg="  → 42 data points collected"
time="..." level=info msg="Indexing metric: controlPlaneCPU"
time="..." level=info msg="  → 87 data points collected"
time="..." level=info msg="Indexing metric: nodeCPUUsage"
time="..." level=info msg="  → 156 data points collected"
time="..." level=info msg="Indexing metric: runningPodsPerNode"
time="..." level=info msg="  → 18 data points collected"
time="..." level=info msg="Indexing complete. UUID: index-run-001"
```

The data is now saved. In a full setup with Elasticsearch/OpenSearch, you would see it in Kibana/Grafana dashboards.

---

### Step 7 — Clean up

```bash
oc delete job kb-index -n burner-index
oc delete configmap index-config -n burner-index
oc delete project burner-index
```

---

## Sending results to Elasticsearch (optional)

If you have an Elasticsearch cluster, add the indexer config to your benchmark's `global` section:

```yaml
global:
  indexerConfig:
    type: elastic
    servers:
      - https://my-elasticsearch:9200
    defaultIndex: kube-burner
    username: elastic
    password: mypassword
```

This sends all metrics automatically as the benchmark runs — no separate `index` command needed.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `cannot unmarshal !!map into []prometheus.metricDefinition` | Your `metrics.yml` starts with `metrics:` — remove that wrapper, the file must be a plain list starting with `-` |
| `no such route prometheus-k8s` | Use `oc get routes -A \| grep prometheus` to find the real URL |
| `401 Unauthorized` | Token expired — recreate with `oc create token prometheus-k8s -n openshift-monitoring --duration=1h` |
| `0 data points` for a metric | Prometheus may not have that metric; check in the Prometheus UI |
| Very long index time | Shorten the time window with `--start` / `--end` |

---

*You have completed all 12 tests! Go back to the [Test Index](README.md) for a summary.*
