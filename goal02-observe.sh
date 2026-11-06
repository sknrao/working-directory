#!/usr/bin/env bash
# GOAL-02 Observe — run on dh2 after syncing opi-nvidia-dpf-adapter.
# Captures T1–T5 into ./goal02-results.txt (cwd).
set -euo pipefail

OUT="${OUT:-./goal02-results.txt}"
ADAPTER_DIR="${ADAPTER_DIR:-$HOME/opi-nvidia-dpf-adapter}"
SAMPLE="$ADAPTER_DIR/config/samples/dataprocessingunit-bf2-lab.yaml"

{
  echo "=== GOAL-02 Observe $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "host=$(hostname) kubeconfig=${KUBECONFIG:-default}"
  echo

  echo "=== Baseline Goal-01 ==="
  kubectl get dpuoperatorconfig dpu-operator-config -o yaml | sed -n '/status:/,$p' || true
  kubectl get pods -n opi-nvidia-dpf-adapter-system || true
  kubectl get nodes || true
  echo

  echo "=== T1 DPF inventory before ==="
  kubectl -n dpf-operator-system get dpu,dpudevice,dpuflavor,bfb -o wide || true
  echo

  echo "=== T2 Apply OPI DPU ==="
  if [[ ! -f "$SAMPLE" ]]; then
    echo "MISSING sample: $SAMPLE"
    echo "Sync adapter tree that contains dataprocessingunit-bf2-lab.yaml"
    exit 1
  fi
  kubectl apply -f "$SAMPLE"
  kubectl get dataprocessingunit dh2-bluefield-2 -o yaml
  echo

  echo "=== T3 wait for VSP annotations ==="
  sleep 20
  kubectl get dataprocessingunit dh2-bluefield-2 -o jsonpath='{.metadata.annotations}{"\n"}' || true
  kubectl get dataprocessingunit dh2-bluefield-2 \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason} {.message}{"\n"}{end}' || true
  kubectl -n opi-nvidia-dpf-adapter-system logs -l app.kubernetes.io/component=vsp -c vsp --tail=80 || true
  echo

  echo "=== T4 no Create ==="
  kubectl -n dpf-operator-system get dpu,dpudevice,dpuflavor,bfb -o wide || true
  kubectl get dpu,dpudevice,dpuflavor,bfb -A \
    -l translation.opi.nvidia.com/source-name=dh2-bluefield-2 -o wide 2>/dev/null || true
  echo

  echo "=== T5 correlate ==="
  kubectl get dataprocessingunit dh2-bluefield-2 \
    -o jsonpath='name={.metadata.name} node={.spec.nodeName} product={.spec.dpuProductName} serial={.metadata.annotations.provisioning\.dpu\.nvidia\.com/serial-number} pci={.metadata.annotations.provisioning\.dpu\.nvidia\.com/pci-address} observed={.metadata.annotations.discovery\.opiproject\.org/product-name}{"\n"}' || true
  kubectl -n dpf-operator-system get dpu -o wide || true
  echo
  echo "=== done ==="
} | tee "$OUT"

echo "Wrote $OUT"
