# Measurements

Kube-burner can capture latency and performance measurements during benchmark runs. Measurements are defined in the `global.measurements` section of your configuration file.

---

## Pod Latency (`podLatency`)

Tracks the time it takes for pods to transition through lifecycle phases after creation.

**Measured conditions:**

| Condition | Description |
|---|---|
| `Initialized` | All init containers have completed |
| `Ready` | The pod is ready to serve traffic |
| `PodScheduled` | The pod has been assigned to a node |
| `ContainersReady` | All containers are ready |

**Reported metrics per condition:**

- `P50`, `P95`, `P99` — percentile latencies
- `Max` — maximum observed latency

**Configuration:**

```yaml
global:
  measurements:
    - name: podLatency
      thresholds:
        - conditionType: Ready
          metric: P99
          threshold: 60s
        - conditionType: PodScheduled
          metric: P99
          threshold: 15s
```

If the measured value exceeds the threshold, kube-burner exits with code `4`.

---

## Service Latency (`serviceLatency`)

Measures the time from Service creation to the Service being reachable (endpoints populated).

```yaml
global:
  measurements:
    - name: serviceLatency
      thresholds:
        - metric: P99
          threshold: 5s
```

---

## Job Latency (`jobLatency`)

Tracks Kubernetes `Job` object completion latency from creation to `Completed` state.

```yaml
global:
  measurements:
    - name: jobLatency
      thresholds:
        - metric: P99
          threshold: 120s
```

---

## pprof Collection (`pprof`)

Collects Go pprof profiles from cluster components (e.g., kubelet, CRI-O) at a configured interval.

```yaml
global:
  measurements:
    - name: pprof
      pprofInterval: 60s
      pprofDirectory: ./pprof-data
      nodeAffinity:
        node-role.kubernetes.io/worker: ""
      pprofTargets:
        - name: kubelet-heap
          url: https://localhost:10250/debug/pprof/heap
        - name: crio-heap
          url: http://localhost/debug/pprof/heap
          unixSocketPath: /var/run/crio/crio.sock
```

---

## Using Measurements with the `measure` Subcommand

The `measure` subcommand lets you collect measurements **without running a workload** — it simply watches existing cluster resources in real time.

```bash
kube-burner measure -c measurements-config.yml --duration=30m --selector=app=myapp
```

**Example `measurements-config.yml`:**

```yaml
metricsEndpoints:
  - indexer:
      metricsDirectory: /tmp/kube-burner
      type: local

global:
  measurements:
    - name: podLatency
    - name: pprof
      pprofInterval: 60s
      pprofDirectory: pprof-data
      nodeAffinity:
        node-role.kubernetes.io/worker: ""
      pprofTargets:
        - name: kubelet-heap
          url: https://localhost:10250/debug/pprof/heap
```

---

## Threshold Exit Codes

When any measurement exceeds a configured threshold, kube-burner exits with code `4`. This can be used in CI/CD pipelines to fail a build if performance degrades.

```bash
kube-burner init -c benchmark.yml
if [ $? -eq 4 ]; then
  echo "Performance regression detected!"
  exit 1
fi
```
