#!/usr/bin/env bash
# GOAL-02 Observe — run on the lab host after syncing opi-nvidia-dpf-adapter.
# Captures T1–T5 into ./goal02-results.txt (cwd).
#
# Usage:
#   ADAPTER_DIR=~/opi-nvidia-dpf-adapter ./goal02-observe.sh
#   DPU_PROFILE=bf2 ./goal02-observe.sh          # dh2 BlueField-2
#   DPU_PROFILE=bf3 ./goal02-observe.sh          # dh5 BlueField-3 (default on host dh5)
set -euo pipefail

OUT="${OUT:-./goal02-results.txt}"
ADAPTER_DIR="${ADAPTER_DIR:-$HOME/opi-nvidia-dpf-adapter}"
HOST="$(hostname -s 2>/dev/null || hostname)"

# Default profile: bf3 on dh5, else bf2 (legacy dh2).
if [[ -z "${DPU_PROFILE:-}" ]]; then
  if [[ "$HOST" == "dh5" ]]; then
    DPU_PROFILE=bf3
  else
    DPU_PROFILE=bf2
  fi
fi

case "$DPU_PROFILE" in
  bf3|BF3|bluefield-3|BlueField-3)
    SAMPLE="$ADAPTER_DIR/config/samples/dataprocessingunit-bf3-lab.yaml"
    DPU_NAME=dh5-bluefield-3
    EXPECT_PRODUCT=BlueField-3
    CREATE_NOTE="BF-3 is Create-eligible once VSP stamps product-name=BlueField-3"
    ;;
  bf2|BF2|bluefield-2|BlueField-2)
    SAMPLE="$ADAPTER_DIR/config/samples/dataprocessingunit-bf2-lab.yaml"
    DPU_NAME=dh2-bluefield-2
    EXPECT_PRODUCT=BlueField-2
    CREATE_NOTE="BF-2 is observe-only (mapping emit when-gate requires BF-3)"
    ;;
  *)
    echo "Unknown DPU_PROFILE=$DPU_PROFILE (use bf2 or bf3)" >&2
    exit 1
    ;;
esac

{
  echo "=== GOAL-02 Observe $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "host=$HOST kubeconfig=${KUBECONFIG:-default}"
  echo "DPU_PROFILE=$DPU_PROFILE SAMPLE=$SAMPLE DPU_NAME=$DPU_NAME"
  echo "note: $CREATE_NOTE"
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
    echo "Sync adapter tree that contains $(basename "$SAMPLE")"
    exit 1
  fi
  kubectl apply -f "$SAMPLE"
  kubectl get dataprocessingunit "$DPU_NAME" -o yaml
  echo

  echo "=== T3 wait for VSP annotations ==="
  sleep 20
  kubectl get dataprocessingunit "$DPU_NAME" -o jsonpath='{.metadata.annotations}{"\n"}' || true
  kubectl get dataprocessingunit "$DPU_NAME" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason} {.message}{"\n"}{end}' || true
  kubectl -n opi-nvidia-dpf-adapter-system logs -l app.kubernetes.io/component=vsp -c vsp --tail=80 || true
  echo "expect product≈$EXPECT_PRODUCT (VSP discovery); hardware overlay recommended on lab BF"
  echo

  echo "=== T4 Create inventory (compare to T1) ==="
  kubectl -n dpf-operator-system get dpu,dpudevice,dpuflavor,bfb -o wide || true
  kubectl get dpu,dpudevice,dpuflavor,bfb -A \
    -l "translation.opi.nvidia.com/source-name=$DPU_NAME" -o wide 2>/dev/null || true
  echo "note: $CREATE_NOTE"
  if [[ "$EXPECT_PRODUCT" == "BlueField-2" ]]; then
    echo "PASS hint (BF-2): owned children labeled source-name=$DPU_NAME must be empty"
  else
    echo "PASS hint (BF-3): owned children are allowed; require DPFReady/Compatible + correlation in T5"
    echo "OPERATIONAL on DPF DPU is NOT a Goal-02 gate (dataplane/runtime)"
  fi
  echo

  echo "=== T5 correlate ==="
  kubectl get dataprocessingunit "$DPU_NAME" \
    -o jsonpath='name={.metadata.name} node={.spec.nodeName} product={.spec.dpuProductName} serial={.metadata.annotations.provisioning\.dpu\.nvidia\.com/serial-number} pci={.metadata.annotations.provisioning\.dpu\.nvidia\.com/pci-address} observed={.metadata.annotations.discovery\.opiproject\.org/product-name}{"\n"}' || true
  kubectl get dataprocessingunit "$DPU_NAME" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason} {.message}{"\n"}{end}' || true
  kubectl -n dpf-operator-system get dpu -o wide || true
  if [[ "$EXPECT_PRODUCT" == "BlueField-3" ]]; then
    kubectl -n dpf-operator-system get dpu "$DPU_NAME" \
      -o jsonpath='phase={.status.phase} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null || true
  fi
  echo
  echo "=== done ==="
} | tee "$OUT"

echo "Wrote $OUT"
