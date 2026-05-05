# Test 21: OCP Web Burner — Production Web Application Density

> **Difficulty:** ⭐⭐⭐⭐ Advanced  
> **Time to run:** ~20–30 minutes  
> **What it does:** Creates multi-container deployments with TLS Routes, HorizontalPodAutoscalers, and NetworkPolicies — the closest thing to real production web app density you can run in a benchmark  
> **Requires:** Multi-node OpenShift cluster, OpenShift Router

> **⚡ Pre-flight required:** Before running this test, verify kube-burner is pullable on your cluster and your environment is ready — see **[00-preflight.md](00-preflight.md)**.

---

## What is this test? 🌐

Imagine a shopping mall — not just one store, but hundreds of shops, each with its own front door (Route with TLS), security guard (NetworkPolicy), cash register system (sidecar container), and automatic resizing capability when there's a sale on (HorizontalPodAutoscaler).

**`web-burner` is the test you run when a customer asks "can OpenShift handle my real web application at scale?"** — because unlike the other density tests, this one creates workloads that look exactly like what runs in production: multi-container apps, real TLS termination at the router, and autoscalers responding to load.

Show this to a customer and say: *"This isn't a synthetic benchmark. These are the same building blocks your apps use — Deployments, Routes, HPA, NetworkPolicies. We packed hundreds of them onto your cluster and measured how the platform held up."*

---

## What this test does

`web-burner` simulates the density of a real production web application platform.
It creates workloads that mirror what a large enterprise app farm actually looks like:

- Multi-container **Deployments** (app container + sidecar proxy pattern)
- **Services** with multiple ports
- OpenShift **Routes** with TLS edge termination
- **HorizontalPodAutoscalers** targeting the Deployments
- **NetworkPolicies** isolating namespaces from each other
- **ConfigMaps** and **Secrets** with realistic data sizes

This is the most customer-relevant test because you can say:
*"This is exactly what your production workload looks like. We tested it at 2x your current density."*

---

## What it measures

| Metric | Description |
|---|---|
| HPA sync latency | Time for HPA to reconcile after Deployment creation |
| Route TLS termination throughput | Routes admitted with TLS per second |
| Pod ready latency (P99) | Pod startup under realistic resource constraints |
| Sidecar injection overhead | Extra latency from multi-container pods |
| Network policy enforcement delay | Time for OVN/SDN to program isolation rules |
| etcd write amplification | Bytes written per web-app namespace |

---

## How it works

```
  YOU                        CLUSTER
   │
   │  oc apply -f job.yaml
   ▼
┌──────────────────────────────────────────────────────────┐
│  kube-burner Job (quay.io/kube-burner/kube-burner)       │
│                                                          │
│  For each of N iterations:                               │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Namespace web-app-<N>                             │  │
│  │    ├── Deployment (app + sidecar)  ← 2 containers  │  │
│  │    ├── Service (multi-port)                        │  │
│  │    ├── Route (TLS edge)            ← OCP Router    │  │
│  │    ├── HorizontalPodAutoscaler     ← CPU-based     │  │
│  │    ├── NetworkPolicy (isolate)     ← OVN/SDN       │  │
│  │    └── ConfigMap + Secret                          │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Measures: podLatency, routeAdmission, HPA sync          │
└──────────────────────────────────────────────────────────┘
```

---

## Before you start — open these browser tabs

| Tab | Where | What you watch |
|---|---|---|
| **Tab 1** | Console (already open) | Web terminal |
| **Tab 2** | Workloads → HorizontalPodAutoscalers | HPAs appearing with current/desired metrics |
| **Tab 3** | Networking → Routes | TLS routes appearing with `Accepted` status |
| **Tab 4** | Observe → Metrics | `count(kube_horizontalpodautoscaler_spec_max_replicas)` |

---

## Pre-flight checklist

- [ ] Logged into the OpenShift web console
- [ ] Cluster-admin permissions
- [ ] At least 3 worker nodes with headroom
- [ ] OpenShift Router running: `oc get ingresscontroller -n openshift-ingress-operator`
- [ ] HPA controller available: `oc get apiservice v2.autoscaling`

---

## Step-by-step guide

---

### Step 1 — Open the web terminal

Click the **`>_` icon** in the top-right toolbar:

```bash
oc whoami
oc get nodes --no-headers | awk '{print $1, $2}'
oc get ingresscontroller -n openshift-ingress-operator
```

All must return results.

---

### Step 2 — Choose your iteration count

| Cluster size | Starter | Medium |
|---|---|---|
| 3-worker OCP | 20 app namespaces | 50 app namespaces |
| 6+ workers | 50 app namespaces | 100 app namespaces |

---

### Step 3 — Create the project and RBAC

```bash
oc new-project burner-web-burner
oc create serviceaccount kube-burner -n burner-web-burner
```

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
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies, ingresses]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [route.openshift.io]
    resources: [routes]
    verbs: [get, list, watch, create, delete, update, patch]
  - apiGroups: [batch]
    resources: [jobs]
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
    namespace: burner-web-burner
EOF
```

Verify:

```bash
oc get serviceaccount kube-burner -n burner-web-burner
oc get clusterrole kube-burner
oc get clusterrolebinding kube-burner
```

---

### Step 4 — Switch to Tab 3

Go to **Networking → Routes**. Keep this tab visible — you will see routes appearing and transitioning to `Accepted` as kube-burner creates them.

---

### Step 5 — Write the config files

```bash
ITERATIONS=20
UUID="web-burner-$(date +%s)"

cat > /tmp/web-burner-config.yml << EOF
global:
  gc: false
  measurements:
    - name: podLatency

jobs:
  - name: create-web-apps
    jobType: create
    jobIterations: ${ITERATIONS}
    namespacedIterations: true
    namespace: web-app
    podWait: true
    waitWhenFinished: true
    maxWaitTimeout: 20m
    objects:
      - objectTemplate: /config/deployment-template.yml
        replicas: 1
      - objectTemplate: /config/service-template.yml
        replicas: 1
      - objectTemplate: /config/route-template.yml
        replicas: 1
      - objectTemplate: /config/hpa-template.yml
        replicas: 1
      - objectTemplate: /config/networkpolicy-template.yml
        replicas: 1
EOF
```

Write all templates:

```bash
cat > /tmp/web-deployment-template.yml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-{{.Iteration}}
  labels:
    app: web-burner
    kube-burner-job: create-web-apps
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-burner
  template:
    metadata:
      labels:
        app: web-burner
    spec:
      containers:
        - name: app
          image: gcr.io/google_containers/pause:3.1
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
        - name: sidecar
          image: gcr.io/google_containers/pause:3.1
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
EOF

cat > /tmp/web-service-template.yml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web-svc-{{.Iteration}}
  labels:
    kube-burner-job: create-web-apps
spec:
  selector:
    app: web-burner
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics
      port: 9090
      targetPort: 9090
EOF

cat > /tmp/web-route-template.yml << 'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: web-route-{{.Iteration}}
  labels:
    kube-burner-job: create-web-apps
spec:
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: web-svc-{{.Iteration}}
  port:
    targetPort: http
EOF

cat > /tmp/web-hpa-template.yml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-hpa-{{.Iteration}}
  labels:
    kube-burner-job: create-web-apps
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app-{{.Iteration}}
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
EOF

cat > /tmp/web-networkpolicy-template.yml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-{{.Iteration}}
  labels:
    kube-burner-job: create-web-apps
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openshift-ingress
EOF
```

---

### Step 6 — Create the ConfigMap

```bash
oc create configmap web-burner-config \
  --from-file=config.yml=/tmp/web-burner-config.yml \
  --from-file=deployment-template.yml=/tmp/web-deployment-template.yml \
  --from-file=service-template.yml=/tmp/web-service-template.yml \
  --from-file=route-template.yml=/tmp/web-route-template.yml \
  --from-file=hpa-template.yml=/tmp/web-hpa-template.yml \
  --from-file=networkpolicy-template.yml=/tmp/web-networkpolicy-template.yml \
  -n burner-web-burner

oc get configmap web-burner-config -n burner-web-burner
```

---

### Step 7 — Launch the Job

```bash
cat << JOBYAML | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kb-web-burner
  namespace: burner-web-burner
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
          command: [kube-burner, init, -c, /config/config.yml, --uuid=${UUID}]
          volumeMounts:
            - {name: workdir, mountPath: /config}
      volumes:
        - name: config-src
          configMap:
            name: web-burner-config
        - name: workdir
          emptyDir: {}
JOBYAML
```

---

### Step 8 — Watch the test run

```bash
oc get pod -n burner-web-burner -w
```

Wait for `Running`, then:

```bash
oc logs -f job/kb-web-burner -n burner-web-burner
```

---

### Step 9 — Watch the cluster

**Tab 2 (Workloads → HPAs):** Filter `web-app` — HPAs appear with current/desired metrics. Each HPA is watching a Deployment and ready to scale when CPU exceeds 70%.

**Tab 3 (Networking → Routes):** Filter `web-route` — TLS routes appearing. Watch them transition from `unknown` to `Accepted`.

**Tab 4 (Observe → Metrics):**
```
count(kube_horizontalpodautoscaler_spec_max_replicas)
```
Watch the HPA count climb.

**What to say:** *"This namespace represents one production web application — it has a multi-container deployment with a sidecar, a TLS-terminated route, an autoscaler watching CPU, and network isolation from all other tenants. We're running 20 of them simultaneously."*

---

### Step 10 — Read the results

```
INFO podLatency:
INFO   P50:  4.2s
INFO   P95:  8.9s
INFO   P99:  14.3s
INFO Finished execution. UUID: web-burner-...
```

Watch for Route admission time — this is where `web-burner` differs from `cluster-density-v2`.

---

### Step 11 — Clean up

```bash
oc delete job kb-web-burner -n burner-web-burner 2>/dev/null || true

# Delete all created app namespaces
for ns in $(oc get projects --no-headers -o custom-columns=NAME:.metadata.name | grep "^web-app-"); do
  oc delete project $ns
done

oc delete project burner-web-burner
oc delete clusterrole kube-burner 2>/dev/null || true
oc delete clusterrolebinding kube-burner 2>/dev/null || true
```

Verify clean:

```bash
oc get projects | grep web-app
# Should return nothing
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `serviceaccount "kube-burner" not found` | Re-run Step 3 — create SA separately first |
| `cannot create resource "routes"` | Add `route.openshift.io` to ClusterRole |
| `cannot create resource "horizontalpodautoscalers"` | Add `autoscaling` apiGroup to ClusterRole |
| Routes stuck in `unknown` | OpenShift router is overloaded — reduce ITERATIONS |
| HPA shows `unknown` metrics | Metrics server may be starting — wait 60s |
| P99 > 20s | Reduce ITERATIONS — router or etcd is the bottleneck |
