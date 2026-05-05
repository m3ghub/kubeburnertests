# Kube-Burner Configuration Reference

All kube-burner behavior is driven by a YAML configuration file passed via the `-c` flag. This document covers every section and option in detail.

---

## Table of Contents

- [File Templating](#file-templating)
- [Global Section](#global-section)
- [Deletion Strategies](#deletion-strategies)
- [Jobs Section](#jobs-section)
  - [Incremental Load](#incremental-load)
  - [Watchers](#watchers)
  - [Objects](#objects)
  - [Wait Options](#wait-options)
  - [Hooks](#hooks)
  - [Default Labels](#default-labels)
  - [Multi-Document YAML Templates](#multi-document-yaml-templates)
- [Job Types](#job-types)
  - [create](#create)
  - [delete](#delete)
  - [read](#read)
  - [patch](#patch)
  - [kubevirt](#kubevirt)
- [Execution Modes](#execution-modes)
- [Churning Jobs](#churning-jobs)
- [Injected Variables](#injected-variables)
- [Template Functions](#template-functions)
- [RunOnce](#runonce)
- [MetricsClosing](#metricsclosing)

---

## File Templating

Configuration files support [Go template](https://pkg.go.dev/text/template) syntax. Template inputs come from:

1. A `--user-data` file (YAML or JSON)
2. Environment variables (these **take precedence** over user-data when a key matches)

**Example — conditional indexer config:**

```yaml
metricsEndpoints:
{{ if .OS_INDEXING }}
  - prometheusURL: http://localhost:9090
    indexer:
      type: opensearch
      esServers: ["{{ .ES_SERVER }}"]
      defaultIndex: {{ .ES_INDEX }}
{{ end }}
{{ if .LOCAL_INDEXING }}
  - prometheusURL: http://localhost:9090
    indexer:
      type: local
      metricsDirectory: {{ .METRICS_FOLDER }}
{{ end }}
```

This is especially useful for injecting secrets (tokens, passwords) without hard-coding them.

---

## Global Section

Defines settings that apply across all jobs.

| Option | Description | Type | Default |
|---|---|---|---|
| `measurements` | List of measurement configurations | List | `[]` |
| `requestTimeout` | Timeout for client-go API requests | Duration | `60s` |
| `gc` | Garbage-collect (delete) namespaces after all jobs finish | Boolean | `false` |
| `gcMetrics` | Collect metrics during garbage collection | Boolean | `false` |
| `waitWhenFinished` | Wait for all pods/jobs to be running/completed after all jobs finish | Boolean | `false` |
| `clusterHealth` | Assert all nodes are in `Ready` state before starting | Boolean | `false` |
| `timeout` | Global benchmark timeout. Returns exit code `2` on expiry | Duration | `4h` |
| `functionTemplates` | List of Go template function files to load at runtime | List | `[]` |
| `deletionStrategy` | How to delete resources: `default` or `gvr` | String | `default` |

> **Note:** `Global.waitWhenFinished` and `Job.gc` are **mutually exclusive**.

**Kubernetes cluster connection order:**
1. `KUBECONFIG` environment variable
2. `$HOME/.kube/config`
3. In-cluster config (when running inside a pod)

### Function Template Example

Define reusable template blocks in separate `.tpl` files:

**`envs.tpl`:**
```
{{- define "env_func" -}}
{{- range $i := until $.n }}
{{- printf "- name: ENVVAR%d_%s\n  value: %s" (add $i 1) $.name $.envVar | nindent $.indent }}
{{- end }}
{{- end }}
```

**`config.yml`:**
```yaml
global:
  functionTemplates:
    - envs.tpl
```

**`deployment.yml` (usage):**
```
env:
{{- template "env_func" (dict "name" .name "envVar" .envVar "n" 4 "indent" 8) }}
```

---

## Deletion Strategies

### `default` (default)
- Deletes all namespaced resources created by kube-burner
- Deletes the namespaces themselves (cascading child deletion)
- Deletes any cluster-scoped objects created by kube-burner

### `gvr`
- Deletes namespaced resources individually via GVR-based deletion
- Then deletes their parent namespaces
- Finally, deletes cluster-scoped objects

---

## Jobs Section

A list of jobs to execute. Each job has its own lifecycle, namespace, and object set.

| Option | Description | Type | Default |
|---|---|---|---|
| `name` | Job name (used in labels) | String | `""` |
| `jobType` | Type of job: `create`, `delete`, `read`, `patch`, `kubevirt` | String | `create` |
| `jobIterations` | Number of times to execute the job loop | Integer | `1` |
| `namespace` | Base namespace name | String | `""` |
| `namespacedIterations` | Create a separate namespace per iteration | Boolean | `true` |
| `iterationsPerNamespace` | Max iterations in a single namespace | Integer | `1` |
| `cleanup` | Delete existing namespaces from a prior run before starting | Boolean | `true` |
| `podWait` | Wait for pods to be running before each next iteration | Boolean | `false` |
| `waitWhenFinished` | Wait for all pods/jobs to be ready after all iterations complete | Boolean | `true` |
| `maxWaitTimeout` | Maximum wait timeout per namespace | Duration | `4h` |
| `jobIterationDelay` | Pause between each iteration (and between deletes) | Duration | `0s` |
| `jobPause` | Pause after completing all iterations of this job | Duration | `0s` |
| `beforeCleanup` | Shell script to run before workload is deleted | String | `""` |
| `gc` | Garbage-collect this job's resources after it finishes | Boolean | `false` |
| `qps` | Rate limit for object creation (queries per second) | Integer | `0` (unlimited) |
| `burst` | Maximum burst for API throttle | Integer | `0` |
| `objects` | List of object templates to create | List | `[]` |
| `watchers` | List of Kubernetes watchers to create | List | `[]` |
| `verifyObjects` | Verify object count after each job | Boolean | `true` |
| `errorOnVerify` | Exit code 1 if object count verification fails | Boolean | `true` |
| `skipIndexing` | Skip metric indexing for this job | Boolean | `false` |
| `preLoadImages` | Pre-pull all images via a DaemonSet before the job starts | Boolean | `true` |
| `preLoadPeriod` | Max time to wait for the preload DaemonSet to become ready | Duration | `10m` |
| `preloadNodeLabels` | Node selector labels for preload resources | Object | `{}` |
| `namespaceLabels` | Custom labels to add to namespaces created by this job | Object | `{}` |
| `namespaceAnnotations` | Custom annotations for created namespaces | Object | `{}` |
| `churnConfig` | Churn configuration (create jobs only) | Object | `{}` |
| `defaultMissingKeysWithZero` | Suppress errors on missing template keys | Boolean | `false` |
| `executionMode` | Object processing mode: `parallel` or `sequential` (patch/kubevirt only) | String | varies |
| `objectDelay` | Pause between each object within a job | Duration | `0s` |
| `objectWait` | Wait for each object before processing the next (not for create jobs) | Boolean | `false` |
| `metricsAggregate` | Merge metrics for this job with the next job | Boolean | `false` |
| `metricsClosing` | When to stop metrics collection: `afterJob`, `afterJobPause`, `afterMeasurements` | String | `afterJobPause` |
| `hooks` | List of hooks to run at job lifecycle stages | List | `[]` |
| `incrementalLoad` | Enables gradual iteration scaling | Object | `{}` |

---

### Incremental Load

Gradually ramps up job iterations from a start value to a target, with health checks between each step.

| Option | Description | Type | Default |
|---|---|---|---|
| `startIterations` | Starting iteration count | Integer | `jobIterations` |
| `totalIterations` | Target iteration count | Integer | `startIterations` |
| `stepDelay` | Wait between steps | Duration | `0s` |
| `pattern.type` | Growth pattern: `linear` or `exponential` | String | `linear` |
| `pattern.linear.minSteps` | Minimum number of linear steps | Integer | `0` |
| `pattern.linear.stepSize` | Fixed step size (iterations per step) | Integer | `1` |
| `pattern.exponential.base` | Multiplier per exponential step | Float | `2.0` |
| `pattern.exponential.maxIncrease` | Max tolerable jump per exponential step | Integer | `0` |
| `pattern.exponential.warmupSteps` | Initial linear steps before exponential growth | Integer | `0` |
| `healthCheckScript` | Optional shell script run after each step | String | `""` |

**Linear example** (`startIterations=10`, `totalIterations=50`, `stepSize=10`):
```
10 → 20 → 30 → 40 → 50
```

**Exponential example** (`startIterations=5`, `totalIterations=100`, `base=2`):
```
5 → 10 → 20 → 40 → 80 → 100 (capped)
```

---

### Watchers

Monitor Kubernetes resource events during the benchmark without affecting QPS/burst.

| Option | Description | Type | Default |
|---|---|---|---|
| `kind` | Resource kind to watch | String | `""` |
| `apiVersion` | API version of the resource | String | `""` |
| `labelSelector` | Watch only objects matching these labels | Object | `{}` |
| `replicas` | Number of watcher replicas | Integer | `1` |

---

### Objects

Defines the Kubernetes resources to create per job iteration.

| Option | Description | Type | Default |
|---|---|---|---|
| `objectTemplate` | Path or URL to a Go template YAML file | String | `""` |
| `replicas` | Number of this object to create per iteration | Integer | — |
| `inputVars` | Custom variables injected into the template | Object | `{}` |
| `wait` | Wait for the object to reach a ready state | Boolean | `true` |
| `waitOptions` | Override default readiness waiter behavior | Object | `{}` |
| `runOnce` | Only create/delete this object once for the entire job | Boolean | `false` |

**Objects with built-in waiters:**
StatefulSet, Deployment, DaemonSet, ReplicaSet, Job, Pod, ReplicationController, Build, BuildConfig, VirtualMachine, VirtualMachineInstance, VirtualMachineInstanceReplicaSet, PersistentVolumeClaim, VolumeSnapshot, DataVolume, DataSource

---

### Wait Options

Override the default readiness waiter for an object.

| Option | Description | Type | Default |
|---|---|---|---|
| `apiVersion` | API version to match for the wait | String | `""` |
| `kind` | Object kind to wait on (useful for child objects like Pods) | String | `""` |
| `labelSelector` | Wait only on objects matching these labels | Object | `{}` |
| `customStatusPaths` | List of `{key, value}` pairs to check using jq syntax | List | `[]` |

**Example — wait for pods of a Deployment:**
```yaml
objects:
  - objectTemplate: deployment.yml
    replicas: 3
    waitOptions:
      kind: Pod
      labelSelector: {kube-burner-label: abcd}
```

**Example — wait for custom status path:**
```yaml
objects:
  - objectTemplate: deployment.yml
    replicas: 1
    waitOptions:
      customStatusPaths:
        - key: '(.conditions.[] | select(.type == "Available")).status'
          value: "True"
```

---

### Hooks

Run external commands at specific stages of the job lifecycle.

| Option | Description | Type | Default |
|---|---|---|---|
| `cmd` | Command and arguments to execute | List | `[]` |
| `when` | Lifecycle stage to execute at (see table below) | String | `""` |
| `background` | Run the hook in the background (non-blocking) | Boolean | `false` |

**Supported hook stages:**

| Stage | When it runs |
|---|---|
| `beforeJobExecution` | Before any objects are created |
| `afterJobExecution` | After all objects are created (before churn) |
| `onEachIteration` | At the start of each iteration |
| `beforeChurn` | Before churn begins |
| `afterChurn` | After churn completes |
| `beforeCleanup` | Before cleanup/deletion |
| `afterCleanup` | After cleanup/deletion |
| `beforeGC` | Before garbage collection |
| `afterGC` | After garbage collection |

**Execution order within a stage:**
1. All `background: true` hooks start in parallel
2. `background: false` hooks run sequentially after
3. Background hooks are waited on before the next major phase

**Example:**
```yaml
hooks:
  - cmd: ["/scripts/monitor.sh"]
    when: beforeJobExecution
    background: true        # non-blocking monitoring

  - cmd: ["/scripts/setup.sh", "--mode=production"]
    when: beforeJobExecution
    background: false       # blocks until complete

  - cmd: ["/scripts/verify.sh"]
    when: afterCleanup
    background: false
```

---

### Default Labels

Every object kube-burner creates is automatically labeled with:

```
kube-burner.io/uuid=<uuid>
kube-burner.io/job=<jobName>
kube-burner.io/index=<iterationIndex>
```

These labels can be used in `delete` or `patch` job `labelSelector` fields to target objects from a prior job.

---

### Multi-Document YAML Templates

A single `objectTemplate` file can contain multiple Kubernetes resources separated by `---`. Each document is created separately but shares `replicas` and `inputVars`.

```yaml
# istio-combined.yml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: my-gateway-{{.Iteration}}
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts: ["*"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: my-virtualservice-{{.Iteration}}
spec:
  hosts: ["*"]
  gateways: [my-gateway-{{.Iteration}}]
  http:
    - route:
        - destination:
            host: my-service
            port:
              number: 80
```

---

## Job Types

### `create`

Default type. Creates all objects defined in the `objects` list.

- Iterates `jobIterations` times
- If a namespaced object has no `.metadata.namespace`, a new namespace named `<namespace>-<iteration>` is created

### `delete`

Deletes objects matching label selectors. The `objects` list uses this structure:

```yaml
objects:
  - kind: Deployment
    labelSelector: {kube-burner.io/job: my-job}
    apiVersion: apps/v1

  - kind: Secret
    labelSelector: {kube-burner.io/job: my-job}
```

Supported options: `waitForDeletion`, `name`, `qps`, `burst`, `jobPause`, `jobIterationDelay`

### `read`

Reads objects matching label selectors (same structure as `delete`).

Supported options: `name`, `qps`, `burst`, `jobPause`, `jobIterationDelay`, `jobIterations`

### `patch`

Patches objects using a template file:

```yaml
objects:
  - kind: Deployment
    labelSelector: {kube-burner.io/job: my-job}
    objectTemplate: templates/deployment_patch.json
    patchType: "application/strategic-merge-patch+json"
    apiVersion: apps/v1
```

**Valid patch types:**
- `application/json-patch+json`
- `application/merge-patch+json`
- `application/strategic-merge-patch+json`
- `application/apply-patch+yaml`

### `kubevirt`

Executes `virtctl` operations on VirtualMachines:

```yaml
objects:
  - kubeVirtOp: start
    labelSelector: {kube-burner.io/job: my-vms}
    inputVars:
      startPaused: false
```

**Supported operations:**

| Op | Description | Key `inputVars` |
|---|---|---|
| `start` | Start VMs | `startPaused` (bool, default `false`) |
| `stop` | Stop VMs | `force` (bool, default `false`) |
| `restart` | Restart VMs | `force` (bool, default `false`) |
| `pause` | Pause VMs | — |
| `unpause` | Unpause VMs | — |
| `migrate` | Live-migrate VMs | — |
| `add-volume` | Attach a volume | `volumeName` (required), `diskType`, `serial`, `cache`, `persist` |
| `remove-volume` | Detach a volume | `volumeName` (required), `persist` |

---

## Execution Modes

The `executionMode` field controls how objects are processed within a job (patch and kubevirt jobs only).

| Value | Behavior |
|---|---|
| `parallel` | Process all objects across all iterations concurrently |
| `sequential` | Process one object at a time with optional `objectDelay` between each |

**Per-job-type behavior:**

| Job Type | Default | User-Configurable? |
|---|---|---|
| `create` | N/A (ignored) | No |
| `patch` | `parallel` | Yes |
| `delete` | `sequential` (forced) | No |
| `read` | `sequential` (forced) | No |
| `kubevirt` | `sequential` | Yes |

---

## Churning Jobs

Churn is the cyclic deletion and re-creation of a subset of namespaces or objects, simulating real-world churn on a running cluster. Supported for `create` jobs only.

```yaml
jobs:
  - name: churning-job
    jobIterations: 100
    namespacedIterations: true
    namespace: churning
    churnConfig:
      percent: 20
      duration: 2h
      delay: 30s
    objects:
      - objectTemplate: deployment.yml
        replicas: 10
```

**Churn options:**

| Option | Description |
|---|---|
| `cycles` | Number of churn cycles to run |
| `percent` | Percentage of iterations to churn per cycle |
| `duration` | Total time to run churn |
| `delay` | Pause between churn periods |
| `deleteDelay` | Pause between deletion and re-creation (default: `0s`) |
| `mode` | `namespaces` (whole namespaces) or `objects` (individual objects) |

> Either `duration` or `cycles` (or both) must be set to enable churn.

**Disable churn on a specific object:**
```yaml
objects:
  - objectTemplate: deployment.yml
    replicas: 10
    churn: false    # this object is never churned
```

---

## Injected Variables

All object templates automatically receive these variables:

| Variable | Description |
|---|---|
| `{{.Iteration}}` | Current job iteration number |
| `{{.Replica}}` | Current replica number (resets to 1 per iteration) |
| `{{.JobName}}` | Name of the job |
| `{{.UUID}}` | Benchmark UUID |
| `{{.RunID}}` | Internal run ID for correlating metrics |

**Custom variables** are injected via `inputVars`:

```yaml
objects:
  - objectTemplate: service.yml
    replicas: 2
    inputVars:
      port: 80
      targetPort: 8080
```

**Template usage:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: sleep-app-{{.Iteration}}-{{.Replica}}
spec:
  ports:
    - port: "{{.port}}"
      targetPort: "{{.targetPort}}"
```

---

## Template Functions

In addition to standard Go template functions, kube-burner provides:

### Sprig Library

The full [Sprig](http://masterminds.github.io/sprig/) library is available — over 70 additional functions including math, strings, lists, dicts, encoding, and more.

### Built-in Extra Functions

| Function | Description |
|---|---|
| `Binomial` | Returns the binomial coefficient C(n, k) |
| `IndexToCombination` | Returns the combination corresponding to an index |
| `GetSubnet24` | Returns a /24 subnet |
| `GetIPAddress` | Returns N IP addresses from a pool per iteration |
| `ReadFile` | Returns the content of a file at a given path |

---

## RunOnce

Mark an object so it is created only once for the entire job, regardless of `jobIterations`.

```yaml
jobs:
  - name: cluster-density
    jobIterations: 100
    namespacedIterations: true
    namespace: cluster-density
    objects:
      - objectTemplate: clusterrole.yml
        replicas: 1
        runOnce: true          # Created once, not 100 times

      - objectTemplate: deployment.yml
        replicas: 10           # Created 100 × 10 = 1000 times
```

---

## MetricsClosing

Defines when Prometheus metric collection stops for a job.

| Value | Description |
|---|---|
| `afterJob` | Stop after the job completes |
| `afterJobPause` | Stop after the `jobPause` duration ends (default) |
| `afterMeasurements` | Stop after all measurements finish |
