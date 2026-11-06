# GOAL-02 — Observe OPI ↔ DPF (Read before Create)

**Lab host:** `dh2`  
**Depends on:** GOAL-01 PASS (dpf-operator via LCM; Vendor* True; hardware VSP Ready)  
**Where you are:** Docs + sample + `goal02-observe.sh` ready. Sync adapter (incl. `config/samples/dataprocessingunit-bf2-lab.yaml`) to dh2, then run **T1** or:

```bash
cd ~/opi-dpu-operator-with-nvidia/working-directory   # or copy goal02-observe.sh
chmod +x goal02-observe.sh
ADAPTER_DIR=~/opi-nvidia-dpf-adapter ./goal02-observe.sh
# paste goal02-results.txt into Results below
```

---

## Goal

Prove the **Read / Observe** path before any OPI→DPF Create:

1. Apply one OPI `DataProcessingUnit` that honestly declares **BlueField-2** on node `dh2`.
2. Let the NVIDIA VSP stamp hardware identity annotations (serial, PCI, product).
3. Confirm translator status (`DPFHardwareCompatible`, `DPFReady`) with honest BF2 reasons.
4. Read existing DPF inventory and correlate it to the OPI object.
5. Confirm the adapter emits **zero** new `DPUDevice` / `DPUFlavor` / `BFB` / `DPU`.

**Create (emit SSA of DPF children) is Goal-03 — out of scope here.**

### PASS

| Check | Want |
|---|---|
| OPI `DataProcessingUnit` `dh2-bluefield-2` | Exists; `spec.dpuProductName=BlueField-2`; `spec.nodeName=dh2` |
| VSP annotations | `provisioning.dpu.nvidia.com/serial-number`, `pci-address`, `discovery.opiproject.org/product-name` (expect BlueField-2) |
| OPI `Ready` | True when hardware healthy (VSP / daemon path) |
| `DPFHardwareCompatible` | False / `UnsupportedHardware` (BF2 ≠ BF3 Create profile) |
| `DPFReady` | False with BF2 / non-Create reason (not Create success) |
| DPF inventory | Readable; correlated by name/serial/node |
| Adapter Create | **No** new owned DPF children from this DPU |

---

## Baseline (from Goal-01)

```bash
kubectl get dpuoperatorconfig dpu-operator-config -o yaml | sed -n '/status:/,$p'
# Want VendorOperatorSupported/Ready + VendorDPUReady True

kubectl get pods -n opi-nvidia-dpf-adapter-system
# Want managers Running; nvidia-vsp 1/1 (hardware overlay)

kubectl get nodes
# Want dh2 Ready
```

**Stop if:** Goal-01 Vendor gates regress or VSP is mock `2/2`.

---

## T1 — Read existing DPF inventory (no OPI apply yet)

```bash
kubectl -n dpf-operator-system get dpu,dpudevice,dpuflavor,bfb -o wide
kubectl -n dpf-operator-system get dpu -o yaml 2>/dev/null | head -80 || true
```

Paste into Results. Note names, phases, serials — this is the “before” snapshot for Create detection.

---

## T2 — Apply OPI DataProcessingUnit (BF2 lab sample)

```bash
cd ~/opi-nvidia-dpf-adapter
kubectl apply -f config/samples/dataprocessingunit-bf2-lab.yaml
kubectl get dataprocessingunit dh2-bluefield-2 -o yaml
```

Sample content (must match lab):

- `metadata.name: dh2-bluefield-2`
- `spec.dpuProductName: BlueField-2`
- `spec.nodeName: dh2`
- `spec.isDpuSide: false`

**Do not** apply `config/samples/dataprocessingunit.yaml` (BF3 / `kind-worker`) on dh2.

---

## T3 — VSP annotations + Ready

Wait ~30s for the hardware VSP annotator, then:

```bash
kubectl get dataprocessingunit dh2-bluefield-2 -o yaml | sed -n '1,80p'
kubectl get dataprocessingunit dh2-bluefield-2 -o jsonpath='{.metadata.annotations}{"\n"}'
kubectl get dataprocessingunit dh2-bluefield-2 -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason} {.message}{"\n"}{end}'

kubectl -n opi-nvidia-dpf-adapter-system logs -l app.kubernetes.io/component=vsp -c vsp --tail=80
```

**Want:**

- Annotations include serial-number, pci-address, product-name ≈ `BlueField-2`
- `Ready=True` (or progressing toward True) when the card is healthy
- `DPFHardwareCompatible=False` reason `UnsupportedHardware` (or equivalent BF2 message)
- `DPFReady` not claiming AllChildrenReady / Create success

**Stop if:** No annotations after several minutes — check VSP pod, node label `hardware.opiproject.org/profile=nvidia-bluefield`, and `spec.nodeName=dh2`.

---

## T4 — Confirm no Create (emit)

Mapping emit is gated on BlueField-3. On BF2 there must be **no new** adapter-owned children.

```bash
# After snapshot vs T1 — no new objects from this DPU
kubectl -n dpf-operator-system get dpu,dpudevice,dpuflavor,bfb -o wide

# Labels / ownerRefs that would indicate adapter emit (should be empty for this source)
kubectl -n dpf-operator-system get dpu,dpudevice,dpuflavor,bfb \
  -l translation.opi.nvidia.com/source-name=dh2-bluefield-2 -o wide 2>/dev/null || true
kubectl get dpudevice,dpuflavor,bfb,dpu -A \
  -o jsonpath='{range .items[*]}{.kind}/{.metadata.namespace}/{.metadata.name} owner={.metadata.ownerReferences[*].name}{"\n"}{end}' 2>/dev/null | head -40
```

**PASS when:** Inventory matches T1 (or only DPF-native churn unrelated to adapter emit). No SSA Create from this OPI DPU.

---

## T5 — Correlate OPI ↔ DPF (Read)

```bash
# OPI side
kubectl get dataprocessingunit dh2-bluefield-2 \
  -o jsonpath='name={.metadata.name} node={.spec.nodeName} product={.spec.dpuProductName} serial={.metadata.annotations.provisioning\.dpu\.nvidia\.com/serial-number} pci={.metadata.annotations.provisioning\.dpu\.nvidia\.com/pci-address} observed={.metadata.annotations.discovery\.opiproject\.org/product-name}{"\n"}'

# DPF side (whatever still exists after Goal-01)
kubectl -n dpf-operator-system get dpu -o wide
```

Document the correlation (same node / serial if DPF still has an object; or “DPF DPU absent/Deleting — Observe still valid via VSP + status”).

---

## Final gate

| Check | Result |
|---|---|
| OPI DPU applied (BF2 / dh2) | |
| VSP annotations present | |
| Ready / DPFHardwareCompatible / DPFReady honest | |
| No adapter Create emit | |
| DPF inventory read + correlated | |

---

## Out of scope (Goal-03+)

- Changing mapping `when:` to allow BF2 Create
- Emitting `DPUDevice` / `DPUFlavor` / `BFB` / `DPU`
- `ServiceFunctionChain` Create
- Host `mlxfwreset` / reboot unless Observe finds a Goal-01 regression

---

## Results log

### Meta

- Date / time: 2026-11-06 (docs/sample/script landed; lab execute pending on dh2)
- Adapter IMG / VSP overlay: goal01-fix3 / hardware-vsp (from Goal-01)
- OPI DPU name: `dh2-bluefield-2`
- Agent note: workstation cannot resolve `dh2` / no local `kubectl` — run `goal02-observe.sh` on the lab host and paste output here.

### T1 — DPF inventory before

```text
# paste from goal02-results.txt (T1 section) or kubectl get …
```

### T2 — Apply OPI DPU

```text
# paste
```

### T3 — Annotations + conditions

```text
# paste
```

### T4 — No Create

```text
# paste
```

### T5 — Correlation

```text
# paste
```

### Verdict

- [ ] PASS — Observe gates met; no Create
- [ ] FAIL — describe
- [ ] PENDING — lab paste from `goal02-observe.sh` (agent has no API to dh2)

```text
Deliverables complete: runbook, BF2 sample, user-guide M2, observe script.
Execute on dh2: sync tree → ./goal02-observe.sh → paste goal02-results.txt.
```
