# Kube-Burner Quickstart Guide

This guide walks you through installing kube-burner, connecting to a Kubernetes cluster, and running your first benchmark in under 10 minutes.

---

## Prerequisites

Before starting, ensure you have:

- [ ] A running Kubernetes cluster (minikube, kind, OpenShift, EKS, GKE, etc.)
- [ ] `kubectl` installed and configured (`kubectl get nodes` returns results)
- [ ] `curl` available in your shell

---

## Step 1: Install Kube-Burner

### macOS (Apple Silicon / Intel)

```bash
curl -Ls https://raw.githubusercontent.com/kube-burner/kube-burner/refs/heads/main/hack/install.sh | sh
```

The binary is placed in `~/.local/bin/`. Add it to your PATH permanently:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Verify Installation

```bash
kube-burner version
```

Expected output:
```
Version: 2.x.x
Git Commit: ...
Build Date: ...
Go Version: ...
```

---

## Step 2: Verify Cluster Connectivity

Kube-burner uses your kubeconfig automatically:

```bash
# Check your active context
kubectl config current-context

# Confirm nodes are reachable
kubectl get nodes
```

Run kube-burner's built-in health check:

```bash
kube-burner health-check
```

A healthy cluster outputs something like:
```
INFO Cluster is healthy
INFO All nodes are in Ready state
```

---

## Step 3: Create Your First Workload Config

Create a file called `first-benchmark.yml` in your project directory:

```yaml
global:
  gc: true              # Delete all created resources when done
  gcMetrics: false

jobs:
  - name: create-pods
    jobType: create
    jobIterations: 5           # Create 5 sets of objects
    qps: 10                    # 10 API requests per second
    burst: 10
    namespace: kb-quickstart
    namespacedIterations: false # Use a single shared namespace
    podWait: true              # Wait for each pod to be Running
    waitWhenFinished: true
    objects:
      - objectTemplate: pod.yml
        replicas: 2            # 2 pods per iteration = 10 pods total
```

Now create the pod template file `pod.yml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: quickstart-pod-{{.Iteration}}-{{.Replica}}
  labels:
    app: kube-burner-quickstart
    iteration: "{{.Iteration}}"
spec:
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.9
      resources:
        requests:
          cpu: "10m"
          memory: "16Mi"
        limits:
          cpu: "50m"
          memory: "32Mi"
  terminationGracePeriodSeconds: 0
```

---

## Step 4: Run the Benchmark

```bash
kube-burner init -c first-benchmark.yml
```

You will see output like:

```
INFO[0000] Starting kube-burner with UUID: a3f7b2c1-...
INFO[0000] Job: create-pods | Namespace: kb-quickstart
INFO[0001] Creating object 1 of 10 (Pod)...
...
INFO[0012] All pods in namespace kb-quickstart are Running
INFO[0013] Garbage collecting created resources...
INFO[0014] Benchmark completed successfully
```

### Run with a Custom UUID

UUIDs help you correlate benchmark runs across different systems:

```bash
kube-burner init -c first-benchmark.yml --uuid my-first-run-001
```

### Override Config Values at Runtime

Use `--set` to tweak values without editing the file:

```bash
kube-burner init -c first-benchmark.yml \
  --set global.gc=false \
  --set jobs.0.jobIterations=20 \
  --set jobs.0.qps=20
```

---

## Step 5: Inspect Results

### Check What Was Created

With `gc: false`, you can inspect the objects:

```bash
kubectl get pods -n kb-quickstart -l app=kube-burner-quickstart
```

### View Benchmark Metrics (Local Indexer)

To store results to disk, add an indexer to your config:

```yaml
metricsEndpoints:
  - indexer:
      type: local
      metricsDirectory: ./results
```

After the run:
```bash
ls ./results/
# jobSummary.json  podLatency-summary.json  ...
```

---

## Step 6: Clean Up

If you ran with `gc: false`, destroy the resources manually:

```bash
kube-burner destroy -c first-benchmark.yml
```

Or delete the namespace directly:

```bash
kubectl delete namespace kb-quickstart
```

---

## Next Steps

| Topic | File |
|---|---|
| Full configuration reference | [`docs/configuration.md`](configuration.md) |
| Metrics and Prometheus integration | [`docs/measurements.md`](measurements.md) |
| Alert profiles | [`docs/alerting.md`](alerting.md) |
| Example workloads | [`examples/workloads/`](../examples/workloads/) |

### Try a More Complex Workload

Run the upstream pod-density example:

```bash
kube-burner init -c https://raw.githubusercontent.com/kube-burner/kube-burner/master/examples/workloads/kubelet-density/kubelet-density.yml
```

### Measure Pod Scheduling Latency

Add measurements to your config to capture latency:

```yaml
global:
  gc: true
  measurements:
    - name: podLatency
      thresholds:
        - conditionType: Ready
          metric: P99
          threshold: 10s
```

If P99 pod readiness exceeds 10 seconds, kube-burner exits with code `4`.

---

## Troubleshooting

### `command not found: kube-burner`

Ensure `~/.local/bin` is on your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Permission errors creating objects

Verify your kubeconfig grants sufficient RBAC permissions:

```bash
kubectl auth can-i create pods --all-namespaces
kubectl auth can-i create namespaces
```

### Benchmark times out

Increase the global timeout:

```bash
kube-burner init -c first-benchmark.yml --timeout 2h
```

Or reduce workload size with `--set jobs.0.jobIterations=2`.

### Pods stuck in `Pending`

Your cluster may not have enough capacity. Check node resources:

```bash
kubectl describe nodes | grep -A 5 "Allocated resources"
```
