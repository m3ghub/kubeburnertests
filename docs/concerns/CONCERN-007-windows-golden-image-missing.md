# CONCERN-007 — Windows golden image (`win2k22`) missing or not ready

**Applies to:** `09d-windows-density`, `09e-windows-density-escalation`, and any other test that clones a Windows Server VM from the `win2k22` `DataSource`/PVC in the `openshift-virtualization-os-images` namespace.

## What this means

These tests do not create a Windows VM from scratch — they clone a pre-imported "golden image" PVC. There is no fallback: if the golden image isn't imported and `Ready`, the test cannot run at all.

## How to check

```bash
oc get datasource win2k22 -n openshift-virtualization-os-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True

oc get pvc win2k22 -n openshift-virtualization-os-images
# Expected: STATUS = Bound
```

If either command returns nothing, `False`, or a `STATUS` other than `Bound`, the golden image is missing or still importing.

## Why it happens

- The image was never imported on this cluster (most common on freshly-installed clusters or new OpenShift Virtualization installs).
- The import is still in progress — a Windows Server ISO/qcow2 import can take 10–30+ minutes depending on storage throughput.
- The importer pod failed (registry pull error, insufficient storage, or a storage class that doesn't support the required access mode).
- The `DataSource` was deleted or renamed by another team sharing the cluster.

## Remediation

1. **Check for an in-progress import first** (don't re-trigger one unnecessarily):

   ```bash
   oc get pvc win2k22 -n openshift-virtualization-os-images -w
   oc get pods -n openshift-virtualization-os-images | grep importer
   ```

2. **If no import exists**, ask your cluster admin to import a Windows Server 2022 image as a `DataSource` named `win2k22` in `openshift-virtualization-os-images`, either via:
   - the OpenShift web console (**Virtualization → Bootable volumes → Add volume**), or
   - a `DataVolume`/`DataImportCron` manifest pointing at a licensed Windows Server 2022 ISO or qcow2 source your organization is authorized to distribute.

3. **If an import is stuck or failed**, check the importer pod logs:

   ```bash
   oc logs -n openshift-virtualization-os-images -l cdi.kubevirt.io/importer
   ```

   Common fixes: free up storage on the underlying storage class, confirm outbound network access to the image source, and confirm the storage class supports the access mode CDI requested (usually `ReadWriteOnce` for Windows).

4. **Once `Ready: True` and the PVC is `Bound`**, re-run the pre-flight check above before starting the test.

## Related

- [09d-windows-density.md](../tests/markdown/09d-windows-density.md)
- [09e-windows-density-escalation.md](../tests/markdown/09e-windows-density-escalation.md)
- [00-preflight.md](../tests/markdown/00-preflight.md)
