# GOAL-01 — Deploy `dpf-operator` through OPI

**Status:** ready to try  
**Owner:** OPI (lab)  
**Code tree:** `opi-nvidia-dpf-adapter/` (clean tree; not `*-experiment`)  
**Created:** 2026-11-03

---

## Goal

On the **host** Kubernetes cluster, applying one OPI `DpuOperatorConfig`
causes the companion adapter’s LCM to **Helm-install** NVIDIA
`dpf-operator` **v26.4.0** into `dpf-operator-system`.

Success = namespace + Deployment + DPF CRDs present, driven by the OPI CR
(not by you running `helm install dpf-operator` yourself).

---

## What you have / assumptions

- 1 physical server with an NVIDIA DPU (BlueField).
- You may or may not already have Kubernetes on the **host**.
- **DPU-side Kubernetes is NOT required for this goal.**
- First-time lab pass is fine; do not skip gates.

---

## Architecture (this goal only)

| Place | Needed now? |
|---|---|
| Host x86 — one Kubernetes cluster | **Yes** — everything runs here |
| DPU ARM — Kubernetes / tenant cluster | **No** — later goals |

Prerequisites = things that must already exist **on the host cluster**
before the adapter will install DPF. The adapter **checks** them; it does
**not** install cert-manager or Argo CD for you.

---

## Steps and expectations

### T0 — Host Kubernetes only

**Do:** Ensure one Kubernetes cluster on the **host** (not on the DPU).

```bash
kubectl get nodes
kubectl version
```

**Expect**

- ≥1 node `Ready`
- Prefer Kubernetes **v1.36.x** (adapter pin)

**Stop if:** no cluster / no Ready node.

---

### T1 — DPF prerequisites on the host cluster

**Do:** Install **cert-manager** and **Argo CD** on that same cluster  
(see [DPF 26.4 Helm prerequisites](https://networking-docs.nvidia.com/dpf/26.4.0/helm-prerequisites) if you need exact charts).

```bash
kubectl get crd certificates.cert-manager.io
kubectl get crd applications.argoproj.io
```

**Expect:** both CRDs exist (not `NotFound`).

**Stop if:** either missing → LCM will report `Blocked` and skip install.  
“Fix prereqs” means finish T1, then continue — not “install K8s on the DPU”.

---

### T2 — Deploy OPI `dpu-operator`

**Do:** Install OPI CRDs + operator on the host cluster.

```bash
kubectl get crd dpuoperatorconfigs.config.openshift.io
kubectl get pods -A | grep -i dpu
```

**Expect:** CRD exists; OPI operator pods Running.

---

### T3 — Deploy `opi-nvidia-dpf-adapter`

**Do** (machine with Docker + push access to a registry the cluster can pull):

```bash
cd opi-nvidia-dpf-adapter
export IMG=<your-registry>/opi-nvidia-dpf-adapter:goal01
make docker-build docker-push IMG=$IMG
make deploy IMG=$IMG
```

```bash
kubectl get deploy,pods -n opi-nvidia-dpf-adapter-system
kubectl logs -n opi-nvidia-dpf-adapter-system deploy/opi-nvidia-dpf-adapter-controller-manager -c manager --tail=50
```

**Expect:** Deployment Available; pods Running; no CrashLoop.  
Controller must reach NGC (`helm.ngc.nvidia.com`) to pull the chart.

---

### T4 — Apply enablement CR (the actual first goal)

**Do:** Prefer annotation-only form (works even if CRD lacks `spec.vendor`):

```bash
kubectl apply -f - <<'EOF'
apiVersion: config.openshift.io/v1
kind: DpuOperatorConfig
metadata:
  name: dpu-operator-config
  annotations:
    lifecycle.opi.nvidia.com/vendor: nvidia
    lifecycle.opi.nvidia.com/vendor-operator-version: v26.4.0
spec:
  logLevel: 2
EOF
```

(Optional alternate if CRD has `spec.vendor`:  
`kubectl apply -f opi-nvidia-dpf-adapter/config/samples/dpuoperatorconfig-nvidia.yaml`)

**Expect within a few minutes:**

```bash
kubectl get dpuoperatorconfig dpu-operator-config -o yaml
kubectl get ns dpf-operator-system
kubectl get deploy -n dpf-operator-system
kubectl get crd | grep provisioning.dpu.nvidia.com
```

| Result | Meaning |
|---|---|
| `dpf-operator-system` + Deployment Ready + DPF CRDs | **GOAL-01 PASS** |
| Conditions `Blocked` / missing argo or cert-manager | Back to T1 |
| Logs/status `unmanaged` | DPF already installed outside adapter — note it below |
| Helm / NGC errors in adapter logs | Network from controller pod to NGC |

---

### Out of scope for GOAL-01

- Kubernetes on the DPU  
- `DataProcessingUnit` / `ServiceFunctionChain` CRs  
- Traffic / provisioning Ready on the BlueField  

---

## Results log (paste here when you return)

### Run date

- Date / time:
- Lab host / cluster name:
- Who ran it:

### T0

```text
# paste: kubectl get nodes
# paste: kubectl version (client + server)
```

### T1

```text
# paste: kubectl get crd certificates.cert-manager.io applications.argoproj.io
```

### T2

```text
# paste: CRD + OPI pod status
```

### T3

```text
# paste: IMG=...
# paste: deploy/pods in opi-nvidia-dpf-adapter-system
# paste: last ~50 manager log lines if useful
```

### T4

```text
# paste: kubectl get dpuoperatorconfig dpu-operator-config -o yaml  (status.conditions especially)
# paste: kubectl get deploy -n dpf-operator-system
# paste: kubectl get crd | grep provisioning.dpu.nvidia.com
```

### Verdict

- [ ] PASS — `dpf-operator` present via OPI path  
- [ ] BLOCKED — prereqs  
- [ ] UNMANAGED — pre-existing Helm release  
- [ ] FAIL — other (describe below)

Notes:

```text

```
