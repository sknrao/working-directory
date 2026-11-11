# GOAL-03 — Create OPI DPU → DPF Ready

**Lab host:** `dh5` (BlueField-**3**)  
**Depends on:** GOAL-01 LCM (`VendorOperatorSupported` / `VendorOperatorReady`), GOAL-02 Observe concepts, **Kamaji installed**, lab Argo/`br-dpu`  
**User guide:** `opi-nvidia-dpf-adapter/docs/user-guide-milestone-03-create.md`

```bash
# After Kamaji cutover + BF-3 sample applied:
kubectl -n dpf-operator-system get dpucluster,dpu,bfb -o wide
kubectl get dataprocessingunit dh5-bluefield-3 -o yaml | sed -n '/status:/,$p'
```

---

## Goal

OPI Create → adapter-owned DPF children → DPF `DPU` `phase=Ready` → OPI
`DPFReady=True` / `AllChildrenReady` with `DPFHardwareCompatible=True`.

Lab profile uses a **Kamaji-backed `DPUCluster`** (not static-on-host-k3s).
DPU kubelet joins the Kamaji tenant control plane.

### PASS

| Check | Want |
|---|---|
| Kamaji CRD + pods | `tenantcontrolplanes.kamaji.clastix.io`; pods in `kamaji-system` |
| `DPFOperatorConfig` | `kamajiClusterManager.disable=false`, static disabled |
| `DPUCluster` `dpu-cluster-1` | `type=kamaji`, Ready |
| OPI `dh5-bluefield-3` | Exists; BF-3; owned DPF children |
| DPF `DPU` | `phase=Ready` |
| OPI `DPFReady` | `True` / `AllChildrenReady` |
| `DPFHardwareCompatible` | `True` |

### Non-goals

| Item | Note |
|---|---|
| `OPERATIONAL=True` | Dataplane / L2 / `br-comm-ch`; park until host↔DPU path works |
| BF-2 Create | Observe-only; Create profile is BF-3 |
| kind/CI Kamaji-only | kind profile may keep Kamaji disabled |

---

## Prerequisites

1. **Milestone 1** healthy (`VendorOperator*` True; hardware VSP).
2. **Milestone 2** Observe concepts (VSP annotations, inventory correlation).
3. **Kamaji** — `make lab-kamaji` from `opi-nvidia-dpf-adapter/`.
4. Host join-surface / Argo apps-in-any-namespace still useful for host tooling
   (`make lab-k3s-join-surface`); DPU join is Kamaji after cutover.
5. OOB / `br-dpu` as required for provisioning.

If this host still has a **static** `DPUCluster`, follow the cutover in
[M1](../opi-nvidia-dpf-adapter/docs/user-guide-milestone-01-dpf-bringup.md)
(static → Kamaji) **before** expecting Create against Kamaji.

---

## Procedure

### T0 — Kamaji + cluster CR

```bash
cd ~/opi-nvidia-dpf-adapter   # or your checkout
make lab-kamaji

kubectl -n dpf-operator-system get dpfoperatorconfig dpfoperatorconfig \
  -o jsonpath='{.spec.kamajiClusterManager.disable}{" static="}{.spec.staticClusterManager.disable}{"\n"}'
# want: false static=true  — patch if an older CR still disables Kamaji

# Cutover if static cluster remains (delete OPI DPU first):
# kubectl delete dataprocessingunit dh5-bluefield-3 --ignore-not-found
# kubectl -n dpf-operator-system delete dpucluster dpu-cluster-1 --ignore-not-found
# kubectl -n dpf-operator-system delete secret dpu-cluster-1-admin-kubeconfig --ignore-not-found

kubectl apply -f config/samples/dpucluster-kamaji-lab.yaml
kubectl -n dpf-operator-system get dpucluster dpu-cluster-1 -o wide
```

### T1 — Apply BF-3 OPI sample

```bash
kubectl apply -f config/samples/dataprocessingunit-bf3-lab.yaml
kubectl get dataprocessingunit dh5-bluefield-3
```

### T2 — Watch provisioning

```bash
kubectl -n dpf-operator-system get dpu,bfb,dpudevice -o wide -w
# Phases: BFB → OS Installing → Rebooting → DPU Cluster Config → Ready
# Host may reboot for SLR / NVCONFIG; re-attach and continue.
```

### T3 — Correlate owned objects

```bash
kubectl -n dpf-operator-system get dpu,bfb,dpuflavor,dpudevice \
  -l translation.opi.nvidia.com/source-name=dh5-bluefield-3 -o wide
```

### T4 — PASS gates

```bash
kubectl -n dpf-operator-system get dpu -o wide
# Want phase=Ready

kubectl get dataprocessingunit dh5-bluefield-3 \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
# Want DPFReady=True/AllChildrenReady, DPFHardwareCompatible=True
```

---

## Results

Paste command outputs here as you run.

| Gate | Result | Notes |
|---|---|---|
| T0 Kamaji + DPUCluster | | |
| T1 OPI apply | | |
| T2 DPF Ready | | |
| T3 Correlation | | |
| T4 OPI DPFReady | | |

---

## Related

| Doc | Role |
|---|---|
| [GOAL-01-deploy-dpf-operator.md](GOAL-01-deploy-dpf-operator.md) | LCM / Helm bring-up |
| [GOAL-02-observe-dpu.md](GOAL-02-observe-dpu.md) | Observe before / alongside Create |
| [../opi-nvidia-dpf-adapter/docs/user-guide-milestone-03-create.md](../opi-nvidia-dpf-adapter/docs/user-guide-milestone-03-create.md) | Short Create user guide |
| [../opi-nvidia-dpf-adapter/docs/user-guide-milestone-01-dpf-bringup.md](../opi-nvidia-dpf-adapter/docs/user-guide-milestone-01-dpf-bringup.md) | Kamaji install + static→Kamaji cutover |
