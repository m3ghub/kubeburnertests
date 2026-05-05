#!/bin/bash
# Test 22B Live Monitor — streams a status snapshot every 30s to stdout
# Run alongside the churn job: oc logs -f job/kb-test22b-monitor -n burner-test22b

NS="burner-test22b"
CNV_NS="openshift-cnv"
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
PROM="https://thanos-querier.openshift-monitoring.svc.cluster.local:9091"

echo "============================================================"
echo "  TEST 22B PROGRESSIVE CHURN MONITOR"
echo "  Cluster: $(hostname -f 2>/dev/null || echo unknown)"
echo "  Started: $(date)"
echo "============================================================"
echo ""

while true; do
  TS=$(date '+%H:%M:%S')
  TOTAL=$(oc get vm -n $NS --no-headers 2>/dev/null | wc -l)
  RUNNING=$(oc get vm -n $NS --no-headers 2>/dev/null | awk '$2=="Running"' | wc -l)
  STARTING=$(oc get vm -n $NS --no-headers 2>/dev/null | awk '$2!="Running" && $2!=""' | wc -l)

  echo "┌─────────────────────────────────────── $TS ───┐"
  printf "│ VMs Total: %-4s  Running: %-4s  Starting/Other: %-4s │\n" "$TOTAL" "$RUNNING" "$STARTING"
  echo "│                                                      │"

  for OS in cirros rhel9 fedora; do
    COUNT=$(oc get vm -n $NS -l os=$OS --no-headers 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 0 ]; then
      RUN=$(oc get vm -n $NS -l os=$OS --no-headers 2>/dev/null | awk '$2=="Running"' | wc -l)
      printf "│   %-12s %3d VMs  (%d Running)                    │\n" "$OS:" "$COUNT" "$RUN"
    fi
  done

  echo "│                                                      │"
  echo "│  virt-controller RSS:                                │"

  VC_MEM=$(curl -sk -H "Authorization: Bearer $TOKEN" \
    "${PROM}/api/v1/query?query=process_resident_memory_bytes%7Bpod%3D~%22virt-controller.*%22%7D" \
    2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for r in d.get('data',{}).get('result',[]):
    mb=round(float(r['value'][1])/1024/1024,1)
    print(f\"  {r['metric'].get('pod','?')}: {mb} MiB\")
except: print('  unavailable')
")
  if [ -n "$VC_MEM" ]; then
    while IFS= read -r line; do
      printf "│  %-52s│\n" "$line"
    done <<< "$VC_MEM"
  else
    printf "│  %-52s│\n" "  unavailable"
  fi

  echo "│                                                      │"
  echo "│  virt-handler CPU (millicores):                      │"
  VH_CPU=$(oc top pod -n $CNV_NS -l kubevirt.io=virt-handler --no-headers 2>/dev/null | awk '{printf "  %s: %s\n", $1, $2}')
  if [ -n "$VH_CPU" ]; then
    while IFS= read -r line; do
      printf "│  %-52s│\n" "$line"
    done <<< "$VH_CPU"
  else
    printf "│  %-52s│\n" "  unavailable"
  fi

  echo "└──────────────────────────────────────────────────────┘"
  echo ""
  sleep 30
done
