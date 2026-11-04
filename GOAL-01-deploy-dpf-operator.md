# GOAL-01 — Deploy `dpf-operator` through OPI

**Status:** T-clean + Argo OK on dh2 (2026-11-04) — **next: T2** (OPI dpu-operator)  
**Owner:** OPI (lab)  
**Lab host:** `dh2`  
**Code in this workspace:**
- OPI operator source: `dpu-operator/`
- NVIDIA companion adapter: `opi-nvidia-dpf-adapter/`
**Created:** 2026-11-03  
**Updated:** 2026-11-04

---

## Goal (one sentence)

On the **host** Kubernetes cluster, apply one OPI `DpuOperatorConfig` so
the NVIDIA adapter’s LCM **Helm-installs** NVIDIA `dpf-operator` **v26.4.0**.

**PASS:** LCM action `installed`, `dpf-operator-system` Deployment Ready, DPF
CRDs appear — driven by OPI, not by a pre-existing lab install.

---

## Lab inventory — dh2 (2026-11-04)

| Already present | Keep or remove? |
|---|---|
| `kube-system` (k3s) | **KEEP** |
| `cert-manager` | **KEEP** (T1 prereq) |
| Full stack in `dpf-operator-system` (DPF + Argo + NFD + Kamaji + …) | **REMOVE** for a true fresh install |
| `opi-nvidia-dpf-adapter-system` | **REMOVE** (old intern image; redeploy ours after cleanup) |
| `opi-dpu-tenant` | **REMOVE** (tenant leftover from prior DPF) |
| `openshift-dpu-operator` | absent today — install later in **T2** |

### Should you clean up first?

**Yes — for your goal.** If DPF is already running, OPI cannot prove
“deploy `dpf-operator`”; LCM would only detect/adopt.

**But do not wipe the whole machine / k3s / cert-manager.**

Do a **targeted** teardown (**T-clean** below), reinstall Argo (and other
DPF Helm prereqs) **outside** the old DPF namespace, then T2 → T3 → T4.

---

## T-clean — targeted remove (do this before T2)

Run on `dh2` as root (or with working `kubectl` / `helm`).

### T-clean.0 — Snapshot (paste into Results)

```bash
helm list -A
kubectl get ns
kubectl get dpuoperatorconfig -A 2>/dev/null || true
kubectl get crd | grep -E 'dpu\.nvidia|dpuoperator|dataprocessingunit|servicefunction' || true
```

### T-clean.1 — Remove old NVIDIA adapter

```bash
cd /path/to/opi-nvidia-dpf-adapter   # on the machine that has the repo
make undeploy
# if make undeploy is not available from dh2, from any workstation with kubeconfig:
#   kubectl delete ns opi-nvidia-dpf-adapter-system --wait=true
```

**Expect:** namespace `opi-nvidia-dpf-adapter-system` gone.

### T-clean.2 — Remove OPI tenant leftover

```bash
kubectl delete ns opi-dpu-tenant --wait=true
```

**Expect:** namespace gone (ignore NotFound).

### T-clean.3 — Remove existing DPF (and everything currently in that ns)

On this lab, Argo/NFD/Kamaji live **inside** `dpf-operator-system`, so
removing DPF also removes those pods. That is expected; you reinstall
prereqs in T1 after cleanup.

```bash
# See release name(s)
helm list -n dpf-operator-system

# Typical release name from NVIDIA docs / our pin:
helm uninstall dpf-operator -n dpf-operator-system --wait || true

# If other releases remain in that ns, uninstall them too:
# helm list -n dpf-operator-system
# helm uninstall <name> -n dpf-operator-system --wait

# Delete leftover namespace / CRDs only after helm uninstall
kubectl delete ns dpf-operator-system --wait=true || true
```

**Optional harder clean** (only if CRDs/CRs block a later install — ask
before running if unsure):

```bash
# List DPF CRDs (do not delete yet unless install fails later)
kubectl get crd | grep '\.nvidia\.com$'
```

**Expect after T-clean.3**

```bash
kubectl get ns | grep -E 'dpf-operator|opi-nvidia|opi-dpu-tenant' || echo "cleaned"
kubectl get deploy -A | grep -i dpf || echo "no dpf deploys"
```

- Those namespaces gone  
- No `dpf-operator-controller-manager`  
- **`cert-manager` and `kube-system` still healthy**

#### If `kubectl delete ns dpf-operator-system` hangs (Terminating)

Helm left CRDs (and often CRs) behind with `helm.sh/resource-policy: keep`.
The namespace stays `Terminating` until those in-namespace objects are gone
or their finalizers are cleared.

**1. Confirm stuck**

```bash
kubectl get ns dpf-operator-system -o yaml | head -40
# look for: status.phase: Terminating
```

**2. See what still exists in the ns**

```bash
kubectl api-resources --verbs=list --namespaced -o name \
  | while read r; do
      kubectl get -n dpf-operator-system "$r" -o name 2>/dev/null
    done
```

**3. Delete common leftover CRs (ignore NotFound)**

```bash
# DPF / Kamaji leftovers that often block ns delete
kubectl delete dpucluster,dpu,dpudevice,dpuset,dpuservice,dpuservicechain \
  --all -n dpf-operator-system --timeout=60s 2>/dev/null || true
kubectl delete applications.argoproj.io,appprojects.argoproj.io \
  --all -n dpf-operator-system --timeout=60s 2>/dev/null || true
kubectl delete datastore --all -n dpf-operator-system --timeout=60s 2>/dev/null || true
```

**4. If still Terminating — strip finalizers on stuck objects**

```bash
# Example for one kind; repeat for whatever step 2 listed
for kind in dpu dpucluster dpuservice datastore application; do
  for name in $(kubectl get "$kind" -n dpf-operator-system -o name 2>/dev/null); do
    kubectl patch "$name" -n dpf-operator-system --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  done
done
```

**5. Last resort — clear namespace finalizers**

Only after objects are gone or patched:

```bash
kubectl get ns dpf-operator-system -o json \
  | jq '.spec.finalizers=[]' \
  | kubectl replace --raw /api/v1/namespaces/dpf-operator-system/finalize -f -
```

(`jq` required.) Then:

```bash
kubectl get ns dpf-operator-system || echo "namespace gone"
```

**6. CRDs may still remain** (Helm keep policy). That is OK for now;
a later `helm install` of `dpf-operator` usually adopts/updates them.
Do **not** mass-delete all `*.nvidia.com` CRDs unless a later install fails.
### T-clean.4 — Reinstall Argo CD (prereq again)

Argo was inside the deleted ns, so put it back **before** OPI installs DPF.
Prefer a dedicated namespace (not `dpf-operator-system`).

**If Helm errors with** `meta.helm.sh/release-namespace` must equal
`argocd` but current value is `dpf-operator-system`: old Argo CRDs were
kept by Helm policy. **Do not keep deleting the CRD** if it reappears
with the same `CREATED AT` — it is stuck / ownership-blocked.

**Preferred fix — re-home CRD ownership to the new release:**

```bash
for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
  kubectl get crd "$crd" >/dev/null 2>&1 || continue
  kubectl annotate crd "$crd" \
    meta.helm.sh/release-name=argo-cd \
    meta.helm.sh/release-namespace=argocd \
    --overwrite
  kubectl label crd "$crd" app.kubernetes.io/managed-by=Helm --overwrite
done

helm upgrade --install argo-cd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 9.4.1 \
  --wait
```

If your Helm is new enough, you can also add `--take-ownership`.

**If CRD shows `deletionTimestamp` and Applications still listed** (common on
dh2 after DPF teardown) — delete Applications first; they block CRD removal:

```bash
kubectl get applications.argoproj.io -A
# force-remove finalizers + delete every Application
kubectl get applications.argoproj.io -A -o json \
  | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read ns name; do
      kubectl patch applications.argoproj.io "$name" -n "$ns" --type=json \
        -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
      kubectl delete applications.argoproj.io "$name" -n "$ns" --wait=false 2>/dev/null || true
    done
kubectl get appprojects.argoproj.io -A -o name 2>/dev/null \
  | while read r; do kubectl delete "$r" --wait=false 2>/dev/null || true; done

# after Applications are gone, finish CRD delete
kubectl patch crd applications.argoproj.io --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io --wait=false 2>/dev/null || true
kubectl get crd applications.argoproj.io 2>/dev/null || echo "argo CRDs gone"
```

Then:

```bash
helm upgrade --install argo-cd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 9.4.1 \
  --wait
kubectl get crd applications.argoproj.io
kubectl get pods -n argocd
```

Confirm cert-manager still OK:

```bash
kubectl get pods -n cert-manager
kubectl get crd certificates.cert-manager.io
```

**Then continue with T2 → T3 → T4** in this file (skip T0; T1 is now
cert-manager keep + Argo reinstall above).

---

## What you have (general)

- 1 physical server with an NVIDIA DPU (BlueField) — lab host **dh2**.
- Prior intern/lab install left DPF + old adapter; clean those first.

---

## Host vs DPU (read once)

| Place | For GOAL-01 |
|---|---|
| **Host** (x86) | Install **one** Kubernetes here. All of T0–T4 run on this cluster. |
| **DPU** (ARM on the card) | **Do nothing.** No K8s on the DPU for this goal. |

“Fix prereqs” always means: finish the failed **host-cluster** gate below,
then continue. It never means “install Kubernetes on the DPU”.

---

## Tools you need on the machine that talks to the cluster

- `kubectl` (or `oc`) pointed at the **host** cluster  
- `helm` v3  
- Docker or Podman (to build/push images)  
- Go 1.22+ (for `dpu-operator` `task` helpers)  
- A container registry the **cluster nodes can pull from**  
  (local registry, quay.io, ghcr.io, etc.)

Set kubeconfig for the rest of this doc:

```bash
export KUBECONFIG=/path/to/host-cluster.kubeconfig
kubectl get nodes   # must work before anything else
```

---

## Steps

### T0 — Host Kubernetes only

**Do**

1. Install or reuse **one** Kubernetes on the **host** (k3s / kubeadm / lab
   cluster — whatever you already use). Prefer **Kubernetes 1.36.x**
   (adapter pin).
2. Confirm:

```bash
kubectl get nodes
kubectl version
```

**Expect**

- At least one node `Ready`
- Server version ideally `v1.36.x`

**Stop if:** `kubectl` fails or no Ready node. Do not continue.

**Results → paste under Results / T0**

---

### T1 — Install DPF prerequisites (cert-manager + Argo CD)

NVIDIA DPF requires these **before** `dpf-operator`. Our adapter only
**checks** them; it will not install them.

#### T1a — cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.19.3 \
  --set crds.enabled=true \
  --wait
```

**Expect**

```bash
kubectl get crd certificates.cert-manager.io
kubectl get pods -n cert-manager
```

- CRD exists  
- cert-manager pods Running  

#### T1b — Argo CD

Minimal install (enough for the CRD the adapter checks). For production
DPF values see
[DPF 26.4 Helm prerequisites](https://networking-docs.nvidia.com/dpf/26.4.0/helm-prerequisites).

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argo-cd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 9.4.1 \
  --wait
```

**Expect**

```bash
kubectl get crd applications.argoproj.io
kubectl get pods -n argocd
```

- CRD exists  
- Argo pods Running (or at least CRD present; adapter gates on the CRD)

**Stop if:** either CRD is `NotFound`. Fix T1 before T2.

**Optional check that DPF is not already installed**

```bash
kubectl get ns dpf-operator-system 2>/dev/null || echo "no dpf-operator-system yet (good for fresh install)"
```

If the namespace / Deployment already exists from a prior manual Helm
install, GOAL-01 may report `unmanaged` instead of a fresh install —
note that in Results.

**Results → paste under Results / T1**

---

### T2 — Deploy OPI `dpu-operator` (concrete how-to)

This installs the **OPI** operator + CRDs on the **host** cluster.
Source in this workspace: `dpu-operator/`.

You need:
- `task` (Taskfile) — https://taskfile.dev  
  or use the repo helper: `go run tools/task/task.go …`
- A registry the cluster can pull from

#### T2.1 — One-time: point deploy at your host kubeconfig

Upstream `task` defaults to `/root/kubeconfig.ocpcluster`. Override it:

```bash
cd dpu-operator

# Example: use your current kubeconfig as the "host" kubeconfig for task
export KUBECONFIG_HOST="${KUBECONFIG:-$HOME/.kube/config}"
# optional: copy for clarity
# cp "$KUBECONFIG_HOST" /tmp/kubeconfig.host
# export KUBECONFIG_HOST=/tmp/kubeconfig.host
```

#### T2.2 — Registry + build images

```bash
cd dpu-operator

# REQUIRED: registry reachable from cluster nodes (change me)
export REGISTRY=quay.io/<your-org>   # or local registry IP:port

# Install task if needed (pick one)
#   go install github.com/go-task/task/v3/cmd/task@latest
#   or: go run ./tools/task/task.go <target>   # uses repo-bundled runner

task build-image-all
```

**Expect:** images built locally (no error). They are not on the cluster yet.

#### T2.3 — Deploy operator (single host cluster)

Because you have **one server / one cluster**, use the **1-cluster**
upstream + cert-manager profile (matches T1):

```bash
cd dpu-operator
export REGISTRY=quay.io/<your-org>
export KUBECONFIG_HOST="${KUBECONFIG:-$HOME/.kube/config}"

# Pushes images and applies manifests to the host cluster only
task deploy-upstream-certmanager-1c
```

What this does (in plain language):
- Builds/pushes operator images to `$REGISTRY`
- Applies OPI CRDs + controller into namespace `openshift-dpu-operator`
- Waits until `dpu-operator-controller-manager` is Available

**Do not** apply `examples/config.yaml` yet. That creates
`DpuOperatorConfig`; we do that in **T4** with NVIDIA annotations.

#### T2.4 — Verify

```bash
kubectl get crd dpuoperatorconfigs.config.openshift.io
kubectl get crd dataprocessingunits.config.openshift.io
kubectl get crd servicefunctionchains.config.openshift.io
kubectl get deploy,pods -n openshift-dpu-operator
```

**Expect**

- Those three CRDs exist  
- `dpu-operator-controller-manager` Deployment Available  
- Controller pod Running  

**Stop if:** ImagePullBackOff (registry/auth), CrashLoop, or CRDs missing.

**If `task` is painful**, say so in Results — we can switch you to a
minimal `make`/kustomize-only CRD+manager path next iteration. For now
`task deploy-upstream-certmanager-1c` is the supported 1-cluster path
from upstream README.

**Results → paste under Results / T2**

---

### T3 — Deploy NVIDIA companion adapter

This is **not** inside `dpu-operator`. It is
`opi-nvidia-dpf-adapter/` (the clean tree we prepared).

```bash
cd opi-nvidia-dpf-adapter

# Same idea: registry the cluster can pull
export IMG=<your-registry>/opi-nvidia-dpf-adapter:goal01

make docker-build docker-push IMG=$IMG
make deploy IMG=$IMG
```

Verify:

```bash
kubectl get deploy,pods -n opi-nvidia-dpf-adapter-system
kubectl logs -n opi-nvidia-dpf-adapter-system \
  deploy/opi-nvidia-dpf-adapter-controller-manager -c manager --tail=80
```

**Expect**

- Pods Running (manager; often 2 replicas with leader election)  
- Logs mention Lifecycle Manager / no crash loop  
- This pod must reach `https://helm.ngc.nvidia.com` (chart pull)

**Stop if:** CrashLoop / ImagePullBackOff / no manager logs.

**Results → paste under Results / T3**

---

### T4 — Apply OPI CR that triggers DPF install (the goal)

Apply **one** `DpuOperatorConfig`. Use annotations so it works even if
the CRD has no `spec.vendor` field yet:

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

Wait 2–5 minutes, then:

```bash
kubectl get dpuoperatorconfig dpu-operator-config -o yaml
kubectl get ns dpf-operator-system
kubectl get deploy -n dpf-operator-system
kubectl get pods -n dpf-operator-system
kubectl get crd | grep provisioning.dpu.nvidia.com
kubectl logs -n opi-nvidia-dpf-adapter-system \
  deploy/opi-nvidia-dpf-adapter-controller-manager -c manager --tail=100 \
  | grep -iE 'ensure|helm|install|VendorOperator|Blocked|unmanaged|error' || true
```

**Expect (PASS)**

| Check | Want |
|---|---|
| `dpf-operator-system` namespace | exists |
| Deployment in that ns | Ready (e.g. `dpf-operator-controller-manager`) |
| CRDs | `dpus.provisioning.dpu.nvidia.com` (and related) present |
| Conditions on `DpuOperatorConfig` | `VendorOperatorSupported=True`; Ready progressing |
| Adapter logs | `installed` / `adopted` / `noop` — **not** stuck on `Blocked` |

**Common non-PASS outcomes**

| Symptom | Meaning | What to do |
|---|---|---|
| `Blocked` / missing argo-cd or cert-manager | T1 incomplete | Fix T1, wait for reconcile |
| `unmanaged` | DPF already installed by plain Helm | Note in Results; we may adopt or clean |
| Helm / NGC errors | Controller cannot pull chart | Fix egress / NGC from adapter pod |
| Apply rejected on CR | CRD schema mismatch | Paste full error |

**Results → paste under Results / T4 + Verdict**

---

## Out of scope for GOAL-01

- Installing Kubernetes on the DPU  
- Labeling nodes / Intel-Marvell VSP daemons beyond what deploy created  
- Applying `DataProcessingUnit` or `ServiceFunctionChain`  
- Proving BlueField traffic / provisioning `Ready`

---

## Results log (fill this in when you return)

### Meta

- Date / time:
- Lab host / cluster name:
- `KUBECONFIG` path used:
- `REGISTRY` / `IMG` used:

### T0

```text
# kubectl get nodes
# kubectl version
```

### T1

```text
# kubectl get crd certificates.cert-manager.io applications.argoproj.io
# kubectl get pods -n cert-manager
# kubectl get pods -n argocd
# optional: kubectl get ns dpf-operator-system
```

### T2

```text
# commands you actually ran (task target, REGISTRY, KUBECONFIG_HOST)
# kubectl get crd dpuoperatorconfigs.config.openshift.io
# kubectl get deploy,pods -n openshift-dpu-operator
# errors if any
```

### T3

```text
# IMG=...
# kubectl get deploy,pods -n opi-nvidia-dpf-adapter-system
# manager logs (tail) if useful
```

### T4

```text
# kubectl get dpuoperatorconfig dpu-operator-config -o yaml
#   (especially status.conditions)
# kubectl get deploy,pods -n dpf-operator-system
# kubectl get crd | grep provisioning.dpu.nvidia.com
# relevant adapter log lines
```

### Verdict

- [ ] PASS — `dpf-operator` present via OPI path  
- [ ] BLOCKED — prereqs (T1)  
- [ ] UNMANAGED — pre-existing Helm release  
- [ ] FAIL — other  

Notes:

```text

```
