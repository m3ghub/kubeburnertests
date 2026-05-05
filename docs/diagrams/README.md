# Kube-Burner Diagrams

Eight diagrams covering architecture, test lifecycle, decision guidance, observed results, the full virtualization test suite, and the customer demo flow.

## Files

| File | Format | Open with | Contents |
|---|---|---|---|
| [`architecture.drawio`](architecture.drawio) | draw.io XML | [app.diagrams.net](https://app.diagrams.net) or VS Code draw.io extension | How kube-burner interacts with the cluster: API server, scheduler, kubelet, Prometheus, indexer, RBAC |
| [`lifecycle.drawio`](lifecycle.drawio) | draw.io XML | [app.diagrams.net](https://app.diagrams.net) or VS Code draw.io extension | All 9 phases of a `kube-burner init` run; multi-job sequencing with real timings |
| [`decision-tree.drawio`](decision-tree.drawio) | draw.io XML | [app.diagrams.net](https://app.diagrams.net) or VS Code draw.io extension | Decision tree: which jobType or subcommand to use; full job-type comparison matrix |
| [`vm-lifecycle.drawio`](vm-lifecycle.drawio) | draw.io XML | [app.diagrams.net](https://app.diagrams.net) or VS Code draw.io extension | Full KubeVirt VM state machine: all states (Stopped, Starting, Running, Paused, Migrating, Stopping) and every kube-burner operation that drives transitions |
| [`churn-timeline.excalidraw`](churn-timeline.excalidraw) | Excalidraw JSON | [excalidraw.com](https://excalidraw.com) or VS Code Excalidraw extension | Gantt timeline of the live SNO churn benchmark (OCP 4.21.8, 120s window) |
| [`job-types-comparison.excalidraw`](job-types-comparison.excalidraw) | Excalidraw JSON | [excalidraw.com](https://excalidraw.com) or VS Code Excalidraw extension | Card-per-job-type reference with real results; subcommand quick-ref; run tips |
| [`virt-tests-overview.excalidraw`](virt-tests-overview.excalidraw) | Excalidraw JSON | [excalidraw.com](https://excalidraw.com) or VS Code Excalidraw extension | Progression map for all 6 virtualization tests (09 + 13–17): difficulty cards, recommended run order, prerequisites |
| [`ocp-customer-demo-flow.excalidraw`](ocp-customer-demo-flow.excalidraw) | Excalidraw JSON | [excalidraw.com](https://excalidraw.com) or VS Code Excalidraw extension | 4-act customer demo map for kube-burner-ocp: control-plane → virt scale → lifecycle ops → push the limit; live terminal outputs; key PromQL queries |

## How to open

### draw.io (browser)
1. Go to [app.diagrams.net](https://app.diagrams.net)
2. **File → Open from → This device** → select the `.drawio` file

### draw.io (VS Code)
Install the [Draw.io Integration](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio) extension, then open any `.drawio` file directly.

### Excalidraw (browser)
1. Go to [excalidraw.com](https://excalidraw.com)
2. **Open** (top menu) → select the `.excalidraw` file

### Excalidraw (VS Code)
Install the [Excalidraw](https://marketplace.visualstudio.com/items?itemName=poilu.excalidraw) extension, then open any `.excalidraw` file directly.
