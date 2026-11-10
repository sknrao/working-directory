# GOAL-01 — Deploy `dpf-operator` through OPI

**Hosts:**
- `dh2` (BlueField-**2**) — LCM/Helm + VSP proven; `VendorDPUReady` incomplete (DPF 26.4 does not support BF-2 Create). Parked.
- **`dh5` (BlueField-3 B3220) — active Goal-01.** P0–P4 largely PASS (2026-11-10); see gate note on **Kubernetes minor**.

**Where you are:** P0–P4 done on dh5. **Before / during T2:** confirm `kubectl version` **server** is **v1.36.x**. Client showed `v1.37.2+k3s1` — if the apiserver is also 1.37, LCM will `Blocked` at T4 until you install k3s **1.36.x** or bump the adapter pin. Then start **T2**.

Replace `<NODE>` with the Kubernetes node name (e.g. `dh5`).

---

## Goal

On the **host** Kubernetes cluster only:

1. Deploy OPI `dpu-operator` (CRDs + controller).
2. Deploy companion `opi-nvidia-dpf-adapter` (this repo’s clean tree).
3. Apply one `DpuOperatorConfig` so the adapter LCM **Helm-installs**
   NVIDIA `dpf-operator` **v26.4.0**.
4. Apply NVIDIA `DPFOperatorConfig`, stabilize VSP (hardware overlay), complete
   DPF-required host reset so Ready conditions are True.

**PASS:**

| Check | Want |
|---|---|
| `dpf-operator-system` + `dpf-operator-controller-manager` | Available |
| `dpf-provisioning-controller-manager` + `dpuservice-controller-manager` | Available |
| OPI `DpuOperatorConfig` conditions | `VendorOperatorSupported=True`, `VendorOperatorReady=True`, `VendorDPUReady=True` with live DPF `DPU` **phase=Ready** (not Deleting / Unknown) |
| Adapter pods | managers Running; `nvidia-vsp` Ready (no CrashLoop) |

**DPU-side Kubernetes is not required for GOAL-01.**  
DPF **v26.4** platform support is **BlueField-3** (e.g. B3240 / B3220 / B3210). BF-2 is Observe-only.

---

## Prerequisites — new host (BF-3) checklist

Run **all** of P0–P4 on the new server before T2. Stop at the first FAIL.

### P0 — Hardware / node identity

```bash
hostname
kubectl get nodes -o wide
kubectl get node <NODE> --show-labels

# BlueField present (vendor 15b3)
lspci -nn | grep -i 15b3 || echo "FAIL: no NVIDIA/Mellanox PCI device"

# Prefer function 0
lspci -nn -d 15b3: | head -20
```

| Check | Want (BF-3 Goal-01) |
|---|---|
| Card generation | **BlueField-3** (not BF-2) |
| Host | Bare metal worker or lab single-node; x86_64 |
| PCIe AUX power | Connected if the SKU requires it |
| High-speed ports | Cable/link up as required by your Host-Trusted layout |

**Stop if:** no `15b3` device, or card is BF-2 and you expected Create-capable Goal-01.

---

### P1 — Pre-req **software** (CLI / build tools)

Install on the machine that builds images and runs `kubectl`/`helm` (usually the lab host).

#### P1.1 — Verify (do not assume)

```bash
uname -a
kubectl version --client
helm version
git --version
go version
buildah --version
podman --version
docker version 2>/dev/null || true
jq --version
task --version || true
mst version 2>/dev/null || mst --version 2>/dev/null || true
mlxfwreset --version 2>/dev/null || true
mlxconfig --version 2>/dev/null || true
```

| Tool | Required? | Why |
|---|---|---|
| `kubectl` | **Yes** | Cluster API |
| `helm` **v3.5+** | **Yes** | Install cert-manager / Argo if missing; LCM uses Helm Go SDK for `dpf-operator` (CLI still needed for baseline) |
| `git` | **Yes** | Clone `dpu-operator` / adapter |
| `go` **1.26.x** (recommend 1.26.10) | **Yes** | Build OPI operator + adapter |
| `buildah` | **Yes** | OPI `dpu-operator` image build/push |
| `podman` | **Yes** | Build helpers / binfmt |
| `docker` **or** `CONTAINER_TOOL=podman` | **Yes** (T3) | Adapter `make docker-build` |
| `jq` | Recommended | Debug / JSONPath helpers |
| `task` | Recommended | OPI Taskfile; else `go run ./tools/task/task.go` |
| MFT: `mst`, `mlxfwreset`, `mlxconfig` | **Yes** for T5.4 SLR / NVCONFIG | Host System-Level Reset |

#### P1.2 — Install missing pieces (Ubuntu/Debian examples)

```bash
sudo apt-get update
sudo apt-get install -y git jq buildah podman curl ca-certificates

# Helm 3 (official script) — skip if helm version already v3.5+
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# kubectl — use distro package, k3s kubectl, or upstream release matching the cluster
kubectl version --client

# Go 1.26.10
curl -fsSL https://go.dev/dl/go1.26.10.linux-amd64.tar.gz -o /tmp/go.tgz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf /tmp/go.tgz
export PATH=/usr/local/go/bin:$PATH
echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc
go version

# task (optional)
go install github.com/go-task/task/v3/cmd/task@latest
export PATH="$(go env GOPATH)/bin:$PATH"
echo 'export PATH="$(go env GOPATH)/bin:$PATH"' >> ~/.bashrc
```

**MFT (NVIDIA Firmware Tools)** — install from NVIDIA Network Adapter Firmware Tools  
(DPF Host-Trusted docs: MFT **≥ 4.33.0-169**). After install:

```bash
sudo mst start
mst status -v
ls /dev/mst/
```

**Stop if:** `helm` missing/`<3.5`, `go` `<1.26`, or MFT missing when you need T5.4.

#### P1.3 — Cluster access + registry

```bash
export KUBECONFIG=$HOME/.kube/config
# or: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl get nodes
kubectl get ns

export REGISTRY=docker.io/<YOUR_DOCKERHUB_USER>
buildah login docker.io
buildah login --get-login docker.io
```

Make Hub repos **public**, or configure `imagePullSecrets`. Public is simplest for GOAL-01.

---

### P2 — Host **drivers / vendor software**

These are **host OS** packages/modules, not Kubernetes pods. Required for PCI discovery, NVCONFIG, and System-Level Reset.

```bash
# Kernel mlx5 / RDMA stack present?
lsmod | grep -E 'mlx5|ib_uverbs|ib_core' || echo "WARN: mlx5 modules not loaded"

# OFED / DOCA host stack (names vary by install)
ofed_info 2>/dev/null | head -5 || true
doca-info 2>/dev/null | head -5 || true
dpkg -l | grep -iE 'mlnx-ofed|doca|mft' | head -40 || true

# rshim: DPF Host-Trusted worker guidance often says rshim should NOT be installed
# on the worker (management via host-agent path). Check and note:
dpkg -l | grep -i rshim || echo "rshim package not installed (often OK for Host-Trusted workers)"
ls /dev/rshim* 2>/dev/null || echo "no /dev/rshim* (OK if not using rshim console)"

# Firmware / device query via MFT
sudo mst start
DEV=$(ls /dev/mst/*pciconf0 2>/dev/null | head -1)
echo "MST device=$DEV"
[[ -n "$DEV" ]] && sudo mlxconfig -d "$DEV" q | head -40
[[ -n "$DEV" ]] && sudo mlxfwreset -d "$DEV" q | head -40
```

| Component | Want | Notes |
|---|---|---|
| `mlx5_core` (or OFED equiv.) | Loaded / usable | Host driver for BlueField PCI functions |
| MFT (`mst` / `mlxconfig` / `mlxfwreset`) | Installed + `mst start` works | NVCONFIG + level-4 SLR |
| DOCA / BFB on DPU | DOCA **≥ 2.5** on card; DPF 26.4 matrix prefers supported BFB (e.g. 3.2 LTS / 3.4) | Flash/provision per NVIDIA docs if card is empty |
| `rshim` on worker | Usually **absent** for Host-Trusted workers | Control-plane-with-DPU NIC-mode uses different rules |
| Internet egress | Host can reach NGC Helm + image registries | LCM pulls `helm.ngc.nvidia.com/nvidia/doca` |

**Stop if:** no MST device, `mlxfwreset q` fails hard, or card has no usable firmware/BFB for DPF.

Official refs:
- [DPF 26.4 platform support](https://networking-docs.nvidia.com/dpf/26.4.0/platform-support)
- [Host Trusted prerequisites](https://networking-docs.nvidia.com/dpf/26.4.0/dpf-system-prerequisites-for-host-trusted)

---

### P3 — Cluster **apps / pods** (cert-manager, Argo CD, …)

LCM preflight **blocks** install without these CRDs (see adapter `docs/lcm-preflight-deps.md`).  
Install into dedicated namespaces — **not** into `dpf-operator-system`.

#### P3.1 — Required APIs and pods

```bash
kubectl get crd applications.argoproj.io certificates.cert-manager.io
kubectl get ns argocd cert-manager
kubectl get pods -n cert-manager
kubectl get pods -n argocd
helm list -A
kubectl version
```

| App | Namespace | Want |
|---|---|---|
| **cert-manager** | `cert-manager` | CRD `certificates.cert-manager.io`; webhook + controller pods Running |
| **Argo CD** | **`argocd`** | CRD `applications.argoproj.io`; server + repo-server + application-controller Running |
| **Node Feature Discovery (NFD)** | e.g. `node-feature-discovery` | CRD `nodefeaturerules.nfd.k8s-sigs.io` (`NodeFeatureRule`) — **required** for `dpf-operator` Helm manifest (`dpu-detection-rule`). Missing → `VendorOperatorReady=Degraded` |
| Kubernetes | — | Adapter pin: minor **v1.36.x** (lab used `v1.36.4+k3s1`). DPF docs also list a wider range — **this adapter blocks non-1.36**. |
| Kamaji | — | **Not** required for GOAL-01 Host-Trusted / `installViaHostAgent` with kamaji disabled |

#### P3.2 — Install if missing (examples)

**cert-manager** (pick a current stable chart; example):

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --set crds.enabled=true --wait
kubectl get pods -n cert-manager
```

**Argo CD** into namespace **`argocd`**:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argo-cd argo/argo-cd -n argocd --wait
kubectl get pods -n argocd
kubectl get crd applications.argoproj.io
```

**Node Feature Discovery** (needed before LCM can Helm-install `dpf-operator`):

```bash
helm repo add nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts
helm repo update
helm upgrade --install node-feature-discovery nfd/node-feature-discovery \
  --namespace node-feature-discovery --create-namespace --wait
kubectl get crd nodefeaturerules.nfd.k8s-sigs.io
kubectl get pods -n node-feature-discovery
```

**Do not** install `dpf-operator` with Helm yourself — that is the LCM’s job in T4.

#### P3.3 — Gate

```bash
kubectl get crd applications.argoproj.io certificates.cert-manager.io
kubectl get pods -n argocd
kubectl get pods -n cert-manager
# All required pods Running; CRDs present
```

**Stop if:** either CRD missing or pods CrashLoop / Pending.

---

### P4 — Clean slate (GOAL-01 namespaces / releases)

```bash
kubectl get ns | grep -E 'dpf-operator|opi-nvidia|opi-dpu-tenant' || echo "cleaned"
helm list -A | grep -E 'dpf-operator|node-feature|kamaji|maintenance' || echo "no dpf-ish releases"
kubectl get dpu,dpudevice,dpuflavor,bfb -A 2>/dev/null || true
```

| Item | Want |
|---|---|
| `dpf-operator-system` | absent **or** empty of conflicting Helm release you do not own |
| `opi-nvidia-dpf-adapter-system` | absent before first deploy (or intentional redeploy) |
| Leftover DPF `DPU`/`BFB` `Deleting` | none (clear finalizers if stuck — see dh2 Appendix) |

If dirty, clean before T2 (Appendix A pattern). Do not start T2 on a half-deleted DPF namespace.

---

### Prerequisite summary gate

| # | Area | PASS when |
|---|---|---|
| P0 | Hardware | BF-3 visible (`lspci` 15b3); node Ready |
| P1 | Software | `kubectl`, `helm≥3.5`, `go≥1.26`, buildah/podman, MFT |
| P2 | Drivers / vendor | `mst start` + device; mlx5/OFED usable; egress to NGC |
| P3 | Apps / pods | cert-manager + Argo in `argocd` Running + CRDs |
| P4 | Clean slate | no conflicting dpf/adapter leftovers |

Only then continue to **T2**.

---

### dh2 reference (already done — do not re-baseline blindly)

On **dh2**, P3/P4 were completed earlier (Argo in `argocd`, cert-manager present). Goal-01 there is **PARTIAL** (LCM OK; BF-2 cannot honestly finish Create/`VendorDPUReady` phase Ready). Use dh2 only for LCM/Observe regression; use **dh5** for full BF-3 Goal-01.

---

## T2 — Clone and deploy OPI `dpu-operator`

### T2.1 — Get the source on dh2

```bash
cd ~
# If not already cloned:
git clone https://github.com/opiproject/dpu-operator.git
cd dpu-operator

# Submodules are ON by default in taskfile (SUBMODULES=true)
git submodule update --init --recursive
```

**Expect:** `~/dpu-operator` exists; `taskfile.yaml` present.

### T2.2 — Set registry + kubeconfig (do not skip)

**Do not edit `taskfile.yaml`.** Leave upstream defaults as-is.

Upstream hardcodes `KUBECONFIG_HOST: "/root/kubeconfig.ocpcluster"`. Override it only when you **run** Task, by appending `KUBECONFIG_HOST=…` to the command (T2.4). That is a Task CLI override, not a file change.

| Setting | How to set | Edit taskfile? |
|---|---|---|
| `REGISTRY` | `export REGISTRY=docker.io/<user>` in the shell (taskfile reads this env) | **No** |
| `KUBECONFIG_HOST` | Pass on the task command: `task … KUBECONFIG_HOST=/path/to/kubeconfig` | **No** |
| `KUBECONFIG` (kubectl) | `export KUBECONFIG=/path/to/kubeconfig` for your own kubectl | **No** |

If `REGISTRY` is unset, Task defaults to `hostname:5000` (wrong for Docker Hub).

```bash
cd ~/dpu-operator

export PATH=/usr/local/go/bin:$(go env GOPATH)/bin:$PATH

# 1) Docker Hub registry (shell export is enough for REGISTRY)
export REGISTRY=docker.io/<YOUR_DOCKERHUB_USER>

# 2) Remember the real kubeconfig path for later task CLI + kubectl
#    Common on k3s: /etc/rancher/k3s/k3s.yaml
#    Or whatever file already works for: kubectl get nodes
HOST_KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG="$HOST_KUBECONFIG"

# Confirm BEFORE build/deploy
echo "REGISTRY=$REGISTRY"
echo "HOST_KUBECONFIG=$HOST_KUBECONFIG"
test -f "$HOST_KUBECONFIG" || { echo "MISSING kubeconfig file"; exit 1; }
kubectl --kubeconfig "$HOST_KUBECONFIG" get nodes
buildah login --get-login docker.io
```

You still only **export** here. The `KUBECONFIG_HOST=…` override is applied in **T2.4** on the task line — still without touching `taskfile.yaml`.

### T2.3 — Build and push images (skip if Hub already has them)

`deploy-1c` does **not** build images; it pulls `$REGISTRY/…:dev`.

**Reuse (preferred on a second host like dh5):** if you already pushed from dh2
(`docker.io/<user>/dpu-operator:dev`, `dpu-daemon:dev`, …), **skip**
`build-image-all` and go to T2.4 with the same `REGISTRY`.

**Build only when Hub is missing those tags:**

```bash
cd ~/dpu-operator
export REGISTRY=docker.io/<YOUR_DOCKERHUB_USER>

task build-image-all
# OR without task binary:
# go run ./tools/task/task.go build-image-all
```

What this does: compiles binaries, `buildah` builds images, `buildah manifest push` to `docker://$REGISTRY/…:dev`.

**Expect:** exit 0. First run can take a long time.

**Known fail on some Ubuntu hosts:**
`bind mounts cannot have any filesystem-specific options applied` during
`buildah build … -v …:/go:z` — runc rejects the SELinux `:z` flag. That is a
**local build tooling** issue, not a cluster failure. Workaround: build/push on
a host where buildah works (e.g. dh2), or fix/remove the `:z` volume opt in the
Task helper; then deploy on the target with the same `REGISTRY`.

**Stop if:** missing `buildah`/`podman`/Go — return to tools checklist.  
**Stop if:** push Unauthorized — `buildah login docker.io` again.  
**Stop if:** qemu/binfmt / sudo prompts — grant sudo; re-run.

### T2.4 — Deploy (single host cluster + cert-manager profile)

**Do not edit `taskfile.yaml`.** Pass overrides on the CLI.

#### Critical: pass `DEPLOY_PROFILE` yourself

Upstream wrapper `deploy-upstream-certmanager-1c` is supposed to set
`DEPLOY_PROFILE=upstream-certmanager`, but Task often still runs nested
`deploy-prep` / webhook steps with the **default** `openshift`.

**Proof you hit this bug** (from a failed run):

```text
task: [deploy-prep] if [ "openshift" = "upstream-certmanager" ]; then
```

If you see `"openshift"` there, the wrong manifests were applied. On k3s
that leaves the manager pod waiting for Secret `webhook-server-cert`
(OpenShift serving-cert never creates it) → **ContainerCreating** until
the 300s wait times out.

#### Correct command (use this)

```bash
cd ~/dpu-operator
export REGISTRY=docker.io/<YOUR_DOCKERHUB_USER>
HOST_KUBECONFIG="${KUBECONFIG:-/home/sridhar/.kube/config}"   # use the path that works for you
export KUBECONFIG="$HOST_KUBECONFIG"

# BOTH overrides on the CLI — required on k3s / non-OpenShift
task deploy-1c \
  KUBECONFIG_HOST="$HOST_KUBECONFIG" \
  DEPLOY_PROFILE=upstream-certmanager
```

Equivalent (also OK if you pass the profile explicitly):

```bash
task deploy-upstream-certmanager-1c \
  KUBECONFIG_HOST="$HOST_KUBECONFIG" \
  DEPLOY_PROFILE=upstream-certmanager
```

**While it runs, you must see this in deploy-prep output:**

```text
if [ "upstream-certmanager" = "upstream-certmanager" ]; then
```

If it still prints `"openshift" = "upstream-certmanager"`, stop (Ctrl-C) —
the profile override did not take effect.

What a good deploy does:
- Copies `config/dev/kustomization-upstream-certmanager.yaml` → `bin/`
- Creates cert-manager `Certificate` / `Issuer` so Secret `webhook-server-cert` exists
- Applies manifests into `openshift-dpu-operator`
- Waits for `dpu-operator-controller-manager` Available

**Do NOT** run `kubectl apply -f examples/config.yaml` yet.  
That creates `DpuOperatorConfig`; we do that in **T4** with NVIDIA annotations.

#### If you already failed once (ContainerCreating / wait timeout)

Diagnose (paste into Results if unsure):

```bash
kubectl -n openshift-dpu-operator get pods -o wide
kubectl -n openshift-dpu-operator describe pod -l control-plane=controller-manager | tail -80
kubectl -n openshift-dpu-operator get secret,certificate,issuer
kubectl get validatingwebhookconfiguration dpu-operator-validating-webhook-configuration -o yaml | head -40
```

Typical bad describe line: `MountVolume.SetUp failed … secret "webhook-server-cert" not found`.

Recover, then re-run the **correct** command above:

```bash
cd ~/dpu-operator
export REGISTRY=docker.io/<YOUR_DOCKERHUB_USER>
HOST_KUBECONFIG="${KUBECONFIG:-/home/sridhar/.kube/config}"

# Clean with the SAME profile you will deploy
task undeploy-1c KUBECONFIG_HOST="$HOST_KUBECONFIG"

# If CRDs stuck Terminating from the failed run:
kubectl get crd | grep config.openshift.io || true
# Only if a CRD shows Terminating for a long time:
# kubectl patch crd <name> --type=merge -p '{"metadata":{"finalizers":[]}}'

task deploy-1c \
  KUBECONFIG_HOST="$HOST_KUBECONFIG" \
  DEPLOY_PROFILE=upstream-certmanager
```

### T2.5 — Verify T2 (trust the cluster, not only the task exit code)

```bash
kubectl get ns openshift-dpu-operator
kubectl get crd dpuoperatorconfigs.config.openshift.io
kubectl get crd dataprocessingunits.config.openshift.io
kubectl get crd servicefunctionchains.config.openshift.io
kubectl get deploy,pods -n openshift-dpu-operator -o wide
# Secret is named webhook-server-cert; Certificate/Issuer use different names:
kubectl -n openshift-dpu-operator get certificate,issuer
kubectl -n openshift-dpu-operator get secret webhook-server-cert
kubectl -n openshift-dpu-operator get deploy dpu-operator-controller-manager
```

**Do not** use `kubectl get certificate,issuer,secret webhook-server-cert` —
that applies the name `webhook-server-cert` to **all** kinds. Issuer/Certificate
are typically `dpu-operator-selfsigned-issuer` / `dpu-operator-serving-cert`;
only the **Secret** is `webhook-server-cert`. `NotFound` on Certificate/Issuer
under that name is expected and **not** a failure.

**Expect**

- Namespace `openshift-dpu-operator` exists  
- CRDs `dpuoperatorconfigs`, `dataprocessingunits`, `servicefunctionchains` exist (DPU CRDs may briefly show Terminating from undeploy; they should settle)  
- Deployment **Available**; current manager pod **Running / Ready**  
- `Certificate`/`Issuer` listed; Secret `webhook-server-cert` present  

#### Known flake: task exits 1 but deploy is fine

After cert sync the task restarts the Deployment, then runs:

```text
kubectl … wait --for=condition=ready pod --all
```

If an **old** ReplicaSet pod disappears mid-wait, kubectl can print:

```text
Error from server (NotFound): pods "dpu-operator-controller-manager-….…" not found
task: Failed to run task "deploy-1c": exit status 1
```

even when the **new** pod is Ready and `wait --for=condition=Available deployment/…` already succeeded.

**Treat as PASS when all of these are true:**

1. Log showed `"upstream-certmanager" = "upstream-certmanager"`
2. `deployment … successfully rolled out` / Available condition met
3. Current pod Ready (your `describe` showed Ready=True)
4. `certificate` Ready and `webhook-server-cert` exists

Do **not** re-run undeploy/deploy just because of that NotFound flake. Continue to **T3**.

**Common failures**

| Symptom | Cause | Fix |
|---|---|---|
| Task exit 1 + `pods "…-oldhash-…" not found` after rollout success | Wait race on terminating old pod | Verify with T2.5 commands; if Ready → **PASS**, go to T3 |
| `ContainerCreating` + wait timeout; log shows `"openshift" = "upstream-certmanager"` | `DEPLOY_PROFILE` stayed `openshift` | Re-run with `DEPLOY_PROFILE=upstream-certmanager` on the **task CLI** (see T2.4). Do not edit taskfile. |
| `secret "webhook-server-cert" not found` | Wrong profile / no Certificate | Same as above; confirm `kubectl get certificate,issuer -n openshift-dpu-operator` |
| `ImagePullBackOff` | Hub private / wrong `REGISTRY` / nodes can’t pull | Public repo or pull secret; check image name on Hub |
| `Unauthorized` on push | Not logged in to Hub | `buildah login docker.io` |
| Looks for `/root/kubeconfig.ocpcluster` | Task var not overridden | Pass `KUBECONFIG_HOST="$HOST_KUBECONFIG"` on the **task CLI** |
| Push to `hostname:5000` | `REGISTRY` unset | `export REGISTRY=docker.io/<user>` before `build-image-all` |
| `task: command not found` | PATH | Install task or use `go run ./tools/task/task.go …` |

**Paste Results / T2 if you want a record, then continue to T3.**

---

## T3 — Deploy `opi-nvidia-dpf-adapter` (clean tree)

This is a **different** repo/directory from `dpu-operator`.

### T3.1 — Source on dh2

```bash
cd ~
# If you already have it from earlier lab work, use that tree ONLY if it is
# the cleaned opi-nvidia-dpf-adapter with SDKHelmClient.
# Prefer syncing from your workstation workspace:
#   opi-nvidia-dpf-adapter/  (NOT opi-nvidia-dpf-adapter-experiment)

ls ~/opi-nvidia-dpf-adapter/pkg/lifecycle/sdk_helm_client.go \
  && echo "good — has SDKHelmClient" \
  || echo "MISSING sdk_helm_client.go — copy/sync the clean tree before continuing"
```

If the file is missing, copy the clean `opi-nvidia-dpf-adapter` from your
laptop/workspace onto dh2 before building.

### T3.2 — Confirm Go + container tool for adapter

Adapter `go.mod`: `go 1.26.0` + `toolchain go1.26.10`.  
If you installed Go 1.26.10 in the tools checklist, you are done.

```bash
go version   # need 1.26.x (prefer 1.26.10)

# Adapter Makefile defaults CONTAINER_TOOL=docker
docker version
# If docker is missing but podman works:
#   export CONTAINER_TOOL=podman
#   podman version
```

**Stop if:** Go is older than 1.26 — install 1.26.10 from the tools checklist before building.  
**Stop if:** neither docker nor podman can build/push.

### T3.3 — Build, push, deploy

```bash
cd ~/opi-nvidia-dpf-adapter
export PATH=/usr/local/go/bin:$(go env GOPATH)/bin:$PATH

export IMG=docker.io/<YOUR_DOCKERHUB_USER>/opi-nvidia-dpf-adapter:goal01
# If using podman instead of docker:
# export CONTAINER_TOOL=podman

# Login for the tool that will push
docker login docker.io
# OR: podman login docker.io

make docker-build docker-push IMG=$IMG
make deploy IMG=$IMG
```

### T3.4 — Verify T3

```bash
kubectl get deploy,pods -n opi-nvidia-dpf-adapter-system -o wide
kubectl get crd dpuoperatorconfigs.config.openshift.io \
  dataprocessingunits.config.openshift.io \
  servicefunctionchains.config.openshift.io
kubectl logs -n opi-nvidia-dpf-adapter-system \
  deploy/opi-nvidia-dpf-adapter-controller-manager -c manager --tail=80
```

**Expect**

- Deployment Available; manager + nvidia-vsp pods Running (no CrashLoop)
- CRD `dpuoperatorconfigs` present (required for T4)
- Logs may mention Lifecycle / controller start

#### Watch errors for DataProcessingUnit / ServiceFunctionChain

If logs repeat:

```text
Failed to watch … Kind=DataProcessingUnit … could not find the requested resource
Failed to watch … Kind=ServiceFunctionChain … could not find the requested resource
```

that means those two CRDs are missing or still Terminating (common after `undeploy` raced apply). The adapter retries the watches.

**For GOAL-01 / T4 (install `dpf-operator`):** you do **not** need to fix DPU/SFC first, as long as:

```bash
kubectl get crd dpuoperatorconfigs.config.openshift.io
kubectl api-resources | grep -i dpuoperatorconfig
```

both work. T4 only creates a `DpuOperatorConfig`.

**Optional (quiet the logs / restore T2 completeness):** re-apply OPI CRDs from the `dpu-operator` tree without undeploying the controller:

```bash
cd ~/dpu-operator
HOST_KUBECONFIG="${KUBECONFIG:-/home/sridhar/.kube/config}"
bin/kustomize build bin | KUBECONFIG="$HOST_KUBECONFIG" kubectl apply -f -
# or only CRDs if bin/ is still the upstream-certmanager build from T2:
kubectl apply -f config/crd/bases/
kubectl get crd dataprocessingunits.config.openshift.io servicefunctionchains.config.openshift.io
```

Then wait ~30s; those Failed to watch lines should stop. If a CRD is stuck Terminating, clear finalizers only on that CRD, then re-apply.

**Stop if:** ImagePullBackOff / CrashLoop / manager not Ready / `dpuoperatorconfigs` CRD missing.

---

## T4 — Apply enablement CR (triggers DPF install)

### T4.0 — Fresh cluster: seed NVIDIA `DPU` CRD first (required)

On **dh2**, leftover `*.dpu.nvidia.com` CRDs from earlier Helm installs let the
adapter start. On a **clean** host (dh5), those CRDs are absent.

`goal01-fix3` Lifecycle Manager **hard-watches** `DPU.provisioning.dpu.nvidia.com`.
If that CRD is missing, the manager eventually exits:

```text
Failed to run manager … timed out waiting for cache to be synced … Kind=DPU
```

→ CrashLoop → **no** `EnsureInstalled` → no `dpf-operator-system`.
Chicken-and-egg: LCM cannot Helm-install the chart that would create the CRD.

**Before** applying `DpuOperatorConfig` on a clean cluster:

```bash
cd ~/opi-nvidia-dpf-adapter
# Minimal: DPU kind only (enough for LCM watch to sync)
kubectl apply -f test/e2e/crds/dpf/provisioning.dpu.nvidia.com_dpus.yaml
# Safer: all vendored DPF CRDs (Helm will adopt/upgrade later)
kubectl apply -f test/e2e/crds/dpf/

kubectl get crd dpus.provisioning.dpu.nvidia.com
kubectl -n opi-nvidia-dpf-adapter-system rollout restart deploy/opi-nvidia-dpf-adapter-controller-manager
kubectl -n opi-nvidia-dpf-adapter-system rollout status deploy/opi-nvidia-dpf-adapter-controller-manager --timeout=120s
# Want: managers Running, no CrashLoop from DPU cache sync
```

Then continue with the enablement CR below.

On this lab’s OPI CRD, **`spec.vendor` is not a field** (strict decoding rejects it). Use annotations only:

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

(`opi-nvidia-dpf-adapter/config/samples/dpuoperatorconfig-nvidia.yaml` also has `spec.vendor`; that is for a newer CRD shape — do **not** use it on this cluster.)

Wait 2–5 minutes:

```bash
kubectl get dpuoperatorconfig dpu-operator-config -o yaml
kubectl get ns dpf-operator-system
kubectl get deploy,pods -n dpf-operator-system
kubectl get crd | grep provisioning.dpu.nvidia.com
kubectl logs -n opi-nvidia-dpf-adapter-system \
  deploy/opi-nvidia-dpf-adapter-controller-manager -c manager --tail=120 \
  | grep -iE 'ensure|helm|install|VendorOperator|Blocked|unmanaged|error' || true
```

**PASS**

| Check | Want |
|---|---|
| Namespace `dpf-operator-system` | exists |
| `dpf-operator` controller Deployment | Ready |
| DPF CRDs | present |
| Adapter logs | `ensure installed` / `installed` (fresh) |
| Conditions | `VendorOperatorSupported` present; not stuck with only OPI `Ready=FinalizerAdded` |

#### Deadlock bug (hit on dh2 2026-11-05) — rebuild required

Symptoms matched exactly:
- K8s `v1.36.4+k3s1` OK; lease holder is a manager pod
- CR has `lifecycle.opi.nvidia.com/cleanup` finalizer
- **No** `VendorOperatorSupported` / no `ensure installed` log
- No `dpf-operator-system`
- Leader logs only DPU/SFC watch noise

**Cause:** `HelmInstaller.Ensure` holds `defaultReleaseLocks`, then `SDKHelmClient.Install` tried to take the same mutex → permanent hang (same class of bug already documented on `ClaimRelease`).

#### Fix 1 — deadlock (done on `:goal01-fix1`)

`SDKHelmClient` must not re-acquire `defaultReleaseLocks` (nested mutex hang).

#### Fix 2 — Helm cache path in code (`:goal01-fix2`) — done if image already that tag

Code uses `/tmp/helm/…` instead of `/home/nonroot/.cache/helm`.

#### Fix 3 — writable Helm volume (done if emptyDir `helm-cache` is mounted)

#### Fix 4 — Helm installer RBAC (**no image rebuild**)

```text
cannot get resource "serviceaccounts" in API group "" in the namespace "dpf-operator-system"
```

Chart locate/install runs; SA lacks rights to create chart objects. Add
`config/rbac/helm_installer_role.yaml` + binding.

**Immediate on dh2** — chart also needs NFD (`nodefeaturerules.nfd.k8s-sigs.io`) and more.
Replace the narrow role with full installer rights (avoids one-forbidden-resource-at-a-time):

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: opi-nvidia-dpf-adapter-helm-installer-role
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
- nonResourceURLs: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: opi-nvidia-dpf-adapter-helm-installer-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: opi-nvidia-dpf-adapter-helm-installer-role
subjects:
- kind: ServiceAccount
  name: opi-nvidia-dpf-adapter-controller-manager
  namespace: opi-nvidia-dpf-adapter-system
EOF

kubectl annotate dpuoperatorconfig dpu-operator-config \
  lifecycle.opi.nvidia.com/reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite

# Wait 2–5 min
kubectl get dpuoperatorconfig dpu-operator-config -o yaml | sed -n '/status:/,$p'
kubectl get deploy,pods -n dpf-operator-system
```

VSP `CrashLoopBackOff` is **out of scope for GOAL-01** — managers Running is enough.

Also confirm host can reach the chart repo (image has no shell/curl):

```bash
curl -sI https://helm.ngc.nvidia.com/nvidia/doca/ | head -20
helm pull dpf-operator --repo https://helm.ngc.nvidia.com/nvidia/doca --version v26.4.0 --destination /tmp
```

#### If after 5–10 min (on a **fixed** image): no `dpf-operator-system`, and CR status only has OPI `Ready` / `FinalizerAdded`

That means the adapter **started** reconcile (finalizer `lifecycle.opi.nvidia.com/cleanup` is present) but has **not** finished EnsureInstalled / status update. Do **not** re-apply the CR yet. Run **all** of these and paste Results:

```bash
# 1) Cluster minor — LCM requires Kubernetes minor v1.36 (v1.36.x+k3s OK)
kubectl version

# 2) Which manager pod is leader? (2 replicas; only leader runs LCM)
kubectl -n opi-nvidia-dpf-adapter-system get lease
kubectl -n opi-nvidia-dpf-adapter-system get pods -l control-plane=controller-manager

# 3) Logs from BOTH manager pods (do not rely on `deploy/…` — that picks one pod)
for p in $(kubectl -n opi-nvidia-dpf-adapter-system get pods -l control-plane=controller-manager -o name); do
  echo "===== $p ====="
  kubectl -n opi-nvidia-dpf-adapter-system logs "$p" -c manager --tail=200 \
    | grep -iE 'lifecycle|ensure installed|helm|VendorOperator|Blocked|ngc|install|leader|error|fail' || true
done

# 4) Can the adapter reach NVIDIA NGC Helm?
kubectl -n opi-nvidia-dpf-adapter-system exec deploy/opi-nvidia-dpf-adapter-controller-manager -c manager -- \
  sh -c 'command -v wget >/dev/null && wget -S -O /dev/null https://helm.ngc.nvidia.com/nvidia/doca/ 2>&1 | head -40 || command -v curl >/dev/null && curl -sI https://helm.ngc.nvidia.com/nvidia/doca/ | head -20 || echo "no wget/curl in image"'

# 5) Any Helm release / leftover secrets yet?
kubectl get ns dpf-operator-system 2>/dev/null || echo "no dpf-operator-system"
helm list -n dpf-operator-system 2>/dev/null || true
kubectl get secrets -A | grep -i 'sh.helm.release' | grep -i dpf || echo "no dpf helm secrets"
```

**How to read it**

| Observation | Meaning | Action |
|---|---|---|
| `VendorOperatorSupported=False` reason `Blocked`, message about Kubernetes minor | Cluster is not v1.36.x | Stop — GOAL-01 LCM pin requires 1.36; paste `kubectl version` |
| `Blocked` missing cert-manager / argo-cd | Preflight | Fix Argo/cert-manager CRDs (baseline) |
| Leader logs show Helm/NGC / timeout / dial errors | Chart pull failing | Fix egress/DNS/proxy to `helm.ngc.nvidia.com` |
| Leader logs silent after finalizer; no `ensure installed` | Likely stuck inside Helm Ensure | Check NGC reachability; wait or restart **leader** pod once |
| Only non-leader logs inspected | Misleading | Always use the `for p in …` loop above |
| Leftover `*.provisioning.dpu.nvidia.com` CRDs, no namespace | Old lab CRDs (Helm keep) | OK for GOAL-01; LCM should still fresh-install the release |

**If `Blocked`:** Argo/cert-manager CRDs missing — return to baseline.  
**If Helm/NGC errors:** egress from adapter pod to NGC.  
**If apply rejected `spec.vendor`:** omit that field (annotations only).

---

## T5 — Stabilize Ready conditions (VendorOperatorReady, VendorDPUReady, VSP)

Do these **in order**. Sync the latest `opi-nvidia-dpf-adapter` tree to dh2 first
(sample YAML, Argo fallback fix, hardware-vsp image pin).

### T5.1 — Apply singleton `DPFOperatorConfig` (sibling controllers)

NVIDIA only deploys `dpf-provisioning-controller-manager` and
`dpuservice-controller-manager` **after** this CR exists.

**If apply warns `currently being deleted`:** do **not** wait on rollout.
Unstick first:

```bash
kubectl -n dpf-operator-system get dpfoperatorconfig dpfoperatorconfig -o yaml | head -40
# If deletionTimestamp is set:
kubectl -n dpf-operator-system patch dpfoperatorconfig dpfoperatorconfig \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n dpf-operator-system delete dpfoperatorconfig dpfoperatorconfig --ignore-not-found --wait=false
# Wait until gone:
kubectl -n dpf-operator-system get dpfoperatorconfig
```

Then apply (sample or inline — must include `provisioningController`):

```bash
kubectl apply -f ~/opi-nvidia-dpf-adapter/config/samples/dpfoperatorconfig-lab.yaml
# Or:
kubectl apply -f - <<'EOF'
apiVersion: operator.dpu.nvidia.com/v1alpha1
kind: DPFOperatorConfig
metadata:
  name: dpfoperatorconfig
  namespace: dpf-operator-system
spec:
  overrides:
    argoCDNamespace: argocd
  provisioningController:
    dmsTimeout: 900
    installInterface:
      installViaHostAgent: {}
  staticClusterManager:
    disable: true
  kamajiClusterManager:
    disable: true
EOF
```

Confirm the object is **not** terminating:

```bash
kubectl -n dpf-operator-system get dpfoperatorconfig dpfoperatorconfig -o jsonpath='{.metadata.deletionTimestamp}{" finalizers="}{.metadata.finalizers}{"\n"}'
kubectl -n dpf-operator-system get dpfoperatorconfig -o wide
```

Argo must reconcile Applications in `dpf-operator-system`. If Apps stay
OutOfSync / error, ensure Argo’s `application.namespaces` includes that NS.

Then wait (only after a live, non-deleting config):

```bash
kubectl get deploy -n dpf-operator-system
kubectl rollout status -n dpf-operator-system \
  deploy/dpf-provisioning-controller-manager \
  deploy/dpuservice-controller-manager --timeout=300s
kubectl get deploy,pods -n dpf-operator-system
```

**T5.1 PASS when:** `dpf-provisioning-controller-manager` and
`dpuservice-controller-manager` are **Available**.

**Do not block** on `DPFOperatorConfig` `Ready=False` / `PHASE=Pending`.
Operator logs often show DPUServices (multus, flannel, …) “not ready” until
DPU provisioning advances — that is separate from the LCM sibling-Deploy gate.
`kamaji-etcd-defrag-job` stuck in ContainerCreating can be ignored for GOAL-01.

### T5.2 — Redeploy adapter with Argo fallback fix (`:goal01-fix3`)

Code treats `argocd/argo-cd-argocd-server` as a valid Argo prerequisite
([`pkg/lifecycle/status.go`](../opi-nvidia-dpf-adapter/pkg/lifecycle/status.go)).

**Shell env (new terminal):**

```bash
export PATH=/usr/local/go/bin:$(go env GOPATH)/bin:$PATH
export KUBECONFIG=/home/sridhar/.kube/config
export IMG=docker.io/sknrao/opi-nvidia-dpf-adapter:goal01-fix3
docker login docker.io
```

```bash
cd ~/opi-nvidia-dpf-adapter
grep -n 'argo-cd-argocd-server' pkg/lifecycle/status.go
# Must list argocd fallbacks. If missing: sync tree from workstation.

make docker-build docker-push IMG=$IMG
make deploy IMG=$IMG
# helm-cache emptyDir + helm-installer ClusterRole ship in config/manager + config/rbac

kubectl -n opi-nvidia-dpf-adapter-system rollout status \
  deploy/opi-nvidia-dpf-adapter-controller-manager
kubectl -n opi-nvidia-dpf-adapter-system get deploy \
  opi-nvidia-dpf-adapter-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# must print …:goal01-fix3
```

Nudge LCM and check conditions:

```bash
kubectl annotate dpuoperatorconfig dpu-operator-config \
  lifecycle.opi.nvidia.com/reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite
sleep 15
kubectl get dpuoperatorconfig dpu-operator-config -o yaml | sed -n '/status:/,$p'
```

**T5.2 PASS when:** `VendorOperatorReady` is `True` / `Ready`
(message like `DPF CRDs, controllers, and prerequisites are healthy`).
`VendorDPUReady=Rebooting` is expected until T5.4.

### T5.3 — Fix VSP CrashLoop (hardware overlay)

Default `make deploy` VSP is kind/mock (**2 containers**: `vsp` + `opi-daemon`).
Lab BlueField needs the hardware overlay (**1 container**: `vsp` only).

**Important (dh2 facts):**
- System `kustomize` may be missing — use **`./bin/kustomize`** from the adapter repo
  (or `kubectl apply -k`).
- Mock `opi-daemon` CrashLoops if OPI `DataProcessingUnit` / `ServiceFunctionChain`
  CRDs were deleted during earlier undeploy races — re-apply them **before** or with
  the overlay.
- `kubectl label … not labeled` with the label still showing in `--show-labels` means
  the value was **already set** (success).

```bash
# 0) Restore OPI DPU/SFC CRDs (required if api-resources lacks DataProcessingUnit)
kubectl apply -f ~/dpu-operator/config/crd/bases/
kubectl api-resources | grep -E 'dataprocessingunit|servicefunctionchain'

# 1) Optional: see current failure mode
kubectl -n opi-nvidia-dpf-adapter-system get pods -l app.kubernetes.io/component=vsp -o wide
kubectl -n opi-nvidia-dpf-adapter-system logs -l app.kubernetes.io/component=vsp -c vsp --tail=40 || true
kubectl -n opi-nvidia-dpf-adapter-system logs -l app.kubernetes.io/component=vsp -c opi-daemon --tail=40 || true

# 2) Node label required by overlay nodeSelector
kubectl label node dh2 hardware.opiproject.org/profile=nvidia-bluefield --overwrite
kubectl get node dh2 --show-labels | tr ',' '\n' | grep hardware.opiproject

# 3) Apply hardware VSP (pin must match T5.2 IMG = goal01-fix3)
cd ~/opi-nvidia-dpf-adapter
grep -A2 'newName:' config/overlays/hardware-vsp/kustomization.yaml
./bin/kustomize build config/overlays/hardware-vsp | kubectl apply -f -
# Fallback if ./bin/kustomize missing:
#   kubectl apply -k config/overlays/hardware-vsp

# 4) Force new pod and verify 1/1 + containers=vsp only
kubectl -n opi-nvidia-dpf-adapter-system delete pod -l app.kubernetes.io/component=vsp --wait=false
kubectl -n opi-nvidia-dpf-adapter-system rollout status ds/opi-nvidia-dpf-adapter-nvidia-vsp --timeout=180s
kubectl -n opi-nvidia-dpf-adapter-system get pods -l app.kubernetes.io/component=vsp -o wide
kubectl -n opi-nvidia-dpf-adapter-system get pod -l app.kubernetes.io/component=vsp \
  -o jsonpath='{range .items[*]}{.metadata.name}{" containers="}{.spec.containers[*].name}{"\n"}{end}'
```

**T5.3 PASS when:**
- Pod `1/1 Running` (not `2/2` — that is still mock)
- `containers=vsp` only
- Image tag `goal01-fix3`

**Stop if:** CrashLoop after overlay — `kubectl describe` + `lspci -nn | grep 15b3`; confirm `/sys` hostPath.

### T5.4 — `VendorDPUReady` (optional for GOAL-01 if you refuse host reset)

**What this step is**

DPF wrote firmware NVCONFIG changes (`LAG_RESOURCE_ALLOCATION`, `NUM_OF_VFS`, …)
onto the BlueField. Those take effect only after a **System-Level Reset (SLR)**.
The OPI adapter **observes** that and sets `VendorDPUReady=False/Rebooting`.
It **never** runs the reset for you.

**What you do *not* do**

- No `kubectl apply` / annotate / patch will flip `VendorDPUReady` to True.
- Do **not** delete the DPU CR or fake status — DPF will recreate / re-stall.

**What you *do* (only if you accept a host outage)**

1. **Inspect** (safe — read-only):

```bash
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 -o yaml | tee /tmp/dpu-before-reset.yaml
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 \
  -o jsonpath='phase={.status.phase} method={.status.agentStatus.rebootMethod} rebootPhase={.status.rebootStatus.phase}{"\n"}'
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 \
  -o jsonpath='powerCycleAnn={.metadata.annotations.provisioning\.dpu\.nvidia\.com/host-power-cycle-required}{"\n"}'
# Pending NVCONFIG (what DPF wants applied):
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 \
  -o jsonpath='{.status.agentStatus.lastObservedPendingNvconfig}{"\n"}'
```

2. **Decide which reset path DPF asked for**

| Signal on DPU object | Meaning | Action |
|---|---|---|
| annotation `host-power-cycle-required=true` | Cold power cycle | Full power off/on of the server (worst for k3s) |
| `rebootMethod=SystemLevelReset` and no power-cycle ann | NVIDIA SLR | Prefer `mlxfwreset` warm path below; plain `reboot` is the fallback |
| `rebootMethod=FirmwareReset` | Firmware / PCI reset | `mlxfwreset` at the level DPF/host-agent documents |

3. **If you proceed — NVIDIA SLR (NIC-mode style warm path, preferred over blind `reboot`)**

On **dh2**, as root, with MFT tools installed (`mst` / `mlxfwreset`):

```bash
# Find the BlueField MST device
mst start
ls /dev/mst/
# Example device name — use yours from ls:
DEV=/dev/mst/mt41686_pciconf0   # adjust

# Query supported reset levels
mlxfwreset -d "$DEV" q

# System-level reset (level 4) — this restarts host drivers / PCI and
# typically takes the host OS down briefly (same risk class as reboot).
mlxfwreset -d "$DEV" -y -l 4 r
```

If `mlxfwreset` is missing or reports Not Supported for level 4, the NVIDIA
fallback for SystemLevelReset is a normal host `reboot`.

**k3s risk (why you may refuse):** dh2 is a single-node k3s control plane.
Any SLR / reboot drops the API until the node is back. Usually k3s returns
cleanly if the disk is healthy; there is no guarantee from this runbook.
Have console/BMC access before you start.

4. **After the node is back**

```bash
kubectl get nodes
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 -o wide
# Want: phase Ready (or rebootStatus.phase=Succeeded), not Rebooting

kubectl annotate dpuoperatorconfig dpu-operator-config \
  lifecycle.opi.nvidia.com/reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite
sleep 20
kubectl get dpuoperatorconfig dpu-operator-config -o yaml | sed -n '/status:/,$p'
```

**T5.4 PASS:** `VendorDPUReady=True` / `Ready`.

**T5.4 DEFER (allowed for GOAL-01 if you will not reset):** keep
`VendorDPUReady=False/Rebooting`, save `/tmp/dpu-before-reset.yaml`, and treat
GOAL-01 success as **Helm/LCM path proven** (`VendorOperatorSupported` +
`VendorOperatorReady` + VSP Ready). Do **not** patch the condition True.

### T5.5 — Final gate

```bash
kubectl get dpuoperatorconfig dpu-operator-config -o yaml | sed -n '/status:/,$p'
kubectl get deploy,pods -n dpf-operator-system
kubectl get pods -n opi-nvidia-dpf-adapter-system
```

| Check | Want |
|---|---|
| `VendorOperatorSupported` | True |
| `VendorOperatorReady` | True / Ready |
| `VendorDPUReady` | True / Ready **and** live DPF `DPU` phase=`Ready` (not Deleting / Unknown) |
| OPI `Ready` | May stay **False** / `FinalizerAdded` on host-only GOAL-01 (daemon-owned; not a Vendor fail) |
| DPF sibling Deployments | Available (`provisioning` + `dpuservice`) |
| VSP | Running / Ready (`1/1`, container=`vsp`) |
| `kamaji-etcd-defrag-job` | Ignore ContainerCreating (kamaji disabled) |
| DPU CR phase | May show `Deleting` briefly after SLR; re-check — not a VendorDPUReady fail if condition is True |

---

## Out of scope for GOAL-01

- Kubernetes on the DPU ARM  
- `DataProcessingUnit` / `ServiceFunctionChain` traffic validation beyond VSP Ready  
- Faking `VendorDPUReady` without completing NVCONFIG/reset  

---

## Results log

### Meta

- Date / time:
- Hub user / `REGISTRY`:
- `IMG`:
- `KUBECONFIG_HOST`:
- Go version used for T2 / T3:

### Baseline (P0–P4)

```text
# P0: hostname, lspci -nn | grep 15b3, kubectl get nodes
# P1: helm version, go version, kubectl version --client, mst status
# P2: lsmod | grep mlx5; mst start; ls /dev/mst; ofed_info/doca-info if any
# P3: kubectl get crd applications… certificates…; pods -n argocd; pods -n cert-manager; helm list -A
# P4: ns / helm / dpu leftovers
```

### T2

```text
# paste: go/buildah/podman versions
# paste: commands run
# paste: kubectl get deploy,pods -n openshift-dpu-operator
# paste: errors
```

### T3

```text
# paste: test -f sdk_helm_client.go result
# paste: IMG=
# paste: kubectl get deploy,pods -n opi-nvidia-dpf-adapter-system
```

### T4

```text
# paste: dpuoperatorconfig yaml (status.conditions)
# paste: deploy/pods in dpf-operator-system
# paste: relevant adapter logs
```

### T5

```text
# T5.4: mlxfwreset -d /dev/mst/mt41686_pciconf0 -y -l 4 --sync 0 r
# (first attempt without --sync 0 → fsm sync timed out)

# T5.5 (2026-11-06) conditions:
# Ready=False FinalizerAdded (expected host-only)
# VendorOperatorSupported=True Supported
# VendorOperatorReady=True Ready
# VendorDPUReady=True Ready ("NVIDIA DPU objects are not in Rebooting")

# dpf-operator-system Deployments: controller 1/1, provisioning 2/2, dpuservice 1/1
# pods: bfb-registry, dh2-dms, managers Running; kamaji-etcd-defrag-job ContainerCreating (ignore)
# opi-nvidia-dpf-adapter-system: 2x controller-manager Running, nvidia-vsp 1/1 Running
# node dh2 Ready after SLR
```

### Verdict

- [x] PASS — all T5.5 gates  
- [ ] FAIL — describe  

```text
GOAL-01 PASS on dh2: dpf-operator v26.4.0 installed via OPI LCM/adapter Helm path;
VendorOperatorSupported + VendorOperatorReady + VendorDPUReady True; hardware VSP Ready.
OPI Ready remains False (daemon-owned). Kamaji defrag Job ignored (kamaji disabled).
```

---

## Appendix A — Cleanup history (already completed on dh2)

Kept for reference only. Do not re-run unless the lab is dirty again.

Order that worked:
1. Delete `opi-nvidia-dpf-adapter-system`, `opi-dpu-tenant`
2. `helm uninstall` all releases in `dpf-operator-system` (dpf-operator, argo-cd, kamaji, maintenance-operator, node-feature-discovery)
3. Unstick namespace delete (Applications finalizers, CRD terminating, ns finalize)
4. Reinstall Argo into **`argocd`** (not `dpf-operator-system`); use Application/CRD finalizer cleanup + `buildah`/`helm --take-ownership` as needed
5. Keep `cert-manager` and `kube-system`

NVIDIA CRDs may still exist cluster-wide (Helm keep policy). Leave them unless a later install fails.
