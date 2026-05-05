# Alerting

Kube-burner supports Prometheus-based alert profiles that evaluate PromQL expressions over the benchmark's time range. When an `error` or `critical` severity alert fires, kube-burner returns exit code `3`.

---

## Alert Profile Format

An alert profile is a YAML list of alert definitions:

```yaml
- expr: <PromQL expression>
  description: "Human-readable description"
  severity: <info|warning|error|critical>
```

**Severity levels:**

| Severity | Behavior |
|---|---|
| `info` | Logged only, no effect on exit code |
| `warning` | Logged only, no effect on exit code |
| `error` | Causes exit code `3` |
| `critical` | Causes exit code `3` |

---

## Example Alert Profile

```yaml
# API server latency
- expr: avg(irate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[2m])) > 1
  description: "API server average request latency exceeded 1 second"
  severity: error

# etcd leader changes
- expr: increase(etcd_server_leader_changes_seen_total[10m]) > 0
  description: "etcd leader election occurred — potential instability"
  severity: warning

# Node not ready
- expr: kube_node_status_condition{condition="Ready",status="true"} == 0
  description: "One or more nodes are not Ready"
  severity: critical
```

---

## Embedding Alerts in a Benchmark Run

Reference an alert file from a `metricsEndpoints` entry:

```yaml
metricsEndpoints:
  - endpoint: http://localhost:9090
    token: <prometheus-token>
    metrics: [examples/metrics/metrics.yml]
    alerts: [examples/metrics/alerts.yml]
    indexer:
      type: local
      metricsDirectory: ./results
```

Alerts are automatically evaluated at the end of the benchmark run over the full time range.

---

## Evaluating Alerts Independently

Use the `check-alerts` subcommand to evaluate alerts over any time range without running a full benchmark:

```bash
kube-burner check-alerts \
  -a examples/metrics/alerts.yml \
  --start 1700000000 \
  --end 1700003600
```

`--start` and `--end` accept Unix epoch timestamps (seconds).

---

## Best Practices

- Use `warning` for metrics that are concerning but not blocking
- Use `error` for SLO violations you want to catch in CI
- Use `critical` only for conditions that indicate a broken cluster
- Tune thresholds based on your cluster's baseline performance
- Run `check-alerts` after every benchmark to trend alert history
