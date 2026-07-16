# CONCERN-013 — `ResourceQuota` enforcement on STIG-hardened clusters

**Applies to:** `09b-rhel-density`, `09c-rhel-density-escalation`, `09d-windows-density`, `09e-windows-density-escalation`, and any other test namespace running on a cluster where DISA STIG hardening (or a similar compliance policy) enforces a `ResourceQuota`.

## What this means

Many STIG-hardened / compliance-locked OpenShift clusters automatically apply a `ResourceQuota` to every new namespace (often via a `Namespace` admission webhook or a compliance-operator policy). A default `ResourceQuota` typically requires **every** pod and container to declare both `requests` and `limits` for `cpu` and `memory`.

The standard kube-burner Job manifests in these tests only set `requests`/`limits` loosely (or not at all on every container). On a quota-enforced namespace, `oc apply` for the Job will fail with an error like:

```
Error from server (Forbidden): error when creating "STDIN": pods "kb-rhel-density-xxxxx" is forbidden:
failed quota: rhel-density-quota: must specify limits.cpu,limits.memory,requests.cpu,requests.memory
```

## How to check

```bash
oc get resourcequota -n <test-namespace>
oc describe resourcequota -n <test-namespace>
```

If a quota object exists, note which resources it requires (`requests.cpu`, `limits.memory`, etc.) — every container in the Job must explicitly set all of them.

## Remediation

Use the **quota-safe Job variant** documented in each affected test (see the "Quota-safe version (STIG-hardened clusters)" section in that test's own doc). It adds explicit `resources.requests`/`resources.limits` for both `cpu` and `memory` on every container and init container, sized conservatively enough to satisfy typical STIG default quotas while still letting kube-burner run.

If the quota-safe variant still fails:

1. Compare the quota's required resource names (`oc describe resourcequota`) against what the Job manifest sets — add any missing key.
2. If the quota also caps total namespace usage (e.g. `pods`, `count/jobs.batch`), you may need to reduce `replicas`/`jobIterations` in the test's workload config, or request a scoped quota exception for the test namespace from your cluster admin.
3. If your cluster enforces both `ResourceQuota` and Pod Security admission (`restricted-v2` SCC), also apply the [DISA STIG-hardened job manifest](../tests/markdown/09b-rhel-density.md) section in the same test doc — the two hardening concerns (resource quotas vs. Pod Security `securityContext`) are independent and may both be required together.

## Related

- [09b-rhel-density.md](../tests/markdown/09b-rhel-density.md)
- [09c-rhel-density-escalation.md](../tests/markdown/09c-rhel-density-escalation.md)
- [09d-windows-density.md](../tests/markdown/09d-windows-density.md)
- [09e-windows-density-escalation.md](../tests/markdown/09e-windows-density-escalation.md)
