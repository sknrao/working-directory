# GOAL-02 — Observe OPI ↔ DPF (Read before Create)

**Lab hosts:** `dh2` (BF-2, Observe-only) · **`dh5` (BF-3, active)**  
**Depends on:** GOAL-01 LCM core (VendorOperatorSupported/Ready); hardware VSP recommended  
**Where you are:** dh2 Goal-02 PASS (BF-2). On **dh5** use BF-3 sample / script default.

```bash
# dh5 (default when hostname is dh5):
ADAPTER_DIR=~/opi-nvidia-dpf-adapter ./goal02-observe.sh
# or force:
DPU_PROFILE=bf3 ADAPTER_DIR=~/opi-nvidia-dpf-adapter ./goal02-observe.sh
# dh2:
DPU_PROFILE=bf2 ADAPTER_DIR=~/opi-nvidia-dpf-adapter ./goal02-observe.sh
```

**BF-3 note:** mapping emit requires matching BlueField-3 — so dh5 Observe may **Create** DPF children once VSP stamps product-name. That overlaps [GOAL-03](GOAL-03-create-dpu.md); T4 in the script reports inventory either way.

---

## Goal

Prove the **Read / Observe** path (VSP + status + inventory correlation).

- **`dh2` / BF-2:** Observe **before** Create — emit must stay off.
- **`dh5` / BF-3:** Observe still required; Create emit is **allowed** (Goal-03 overlap). Do **not** fail Goal-02 because owned DPF children exist. Do **not** require DPF `OPERATIONAL=True` (runtime/dataplane; separate from Observe).

### PASS — BF-2 (`dh2`)

| Check | Want |
|---|---|
| OPI `DataProcessingUnit` `dh2-bluefield-2` | Exists; `BlueField-2`; `nodeName=dh2` |
| VSP annotations | serial, PCI, product-name ≈ BlueField-2 |
| `DPFHardwareCompatible` | False / `UnsupportedHardware` |
| `DPFReady` | Not Create success |
| Adapter Create | **No** owned DPF children for this source |

### PASS — BF-3 (`dh5`)

| Check | Want |
|---|---|
| OPI `DataProcessingUnit` `dh5-bluefield-3` | Exists; `BlueField-3`; `nodeName=dh5` |
| VSP annotations | serial, PCI, product-name ≈ BlueField-3 |
| `DPFHardwareCompatible` | True / supported |
| `DPFReady` | True / `AllChildrenReady` when DPF `DPU` phase=`Ready` |
| Correlation | Owned DPF objects labeled/ownerRef’d to this OPI DPU |
| `OPERATIONAL` | **Out of scope** for Goal-02 |

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

- Date / time: 2026-11-06T10:34:04Z (clean rerun; prior 10:27Z had Deleting junk)
- Adapter IMG / VSP overlay: goal01-fix3 / hardware-vsp
- OPI DPU name: `dh2-bluefield-2`

### T1 — DPF inventory before

```text
only dpuflavor/dpf-default-flavor (12d leftover)
no dpu / bfb / dpudevice
VendorDPUReady=Unknown ("no NVIDIA DPU objects observed")
```

### T2 — Apply OPI DPU

```text
dataprocessingunit/dh2-bluefield-2 created (BlueField-2, node=dh2)
```

### T3 — Annotations + conditions

```text
product=BlueField-2 serial=MT2321XZ0KVX pci=0000-0f-00 bfb-url stamped
DPFReady=False/UnsupportedHardware
DPFHardwareCompatible=False/UnsupportedHardware
Ready: ABSENT (expected — hardware VSP without opi-daemon handshake)
VSP: stamped hardware identity serial=MT2321XZ0KVX product=BlueField-2 pci=0000:0f:00.0
```

### T4 — No Create

```text
PASS — still only pre-existing dpuflavor; no new DPU/BFB/DPUDevice
```

### T5 — Correlation

```text
OPI fully identified lab card; no live DPF DPU to pair (clean) — Observe does not require one
```

### Verdict

- [x] PASS — Observe on BF2 (VSP + status + no Create), clean inventory
- [ ] FAIL

```text
dh2 Goal-02 PASS. Goal-01 on dh2 = LCM/Helm + VSP; VendorDPUReady Unknown with no DPU is honest.
Next: Goal-01→02→03 on dh5 (BF-3).
```
