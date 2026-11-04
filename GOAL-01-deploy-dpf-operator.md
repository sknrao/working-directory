# GOAL-01 — Deploy `dpf-operator` through OPI

**Lab host:** `dh2`  
**Where you are (2026-11-04):** T-clean done; cert-manager OK; Argo in `argocd` OK.  
**Next step:** **T2** — install OPI `dpu-operator`.  
**Do not skip tool setup.** Every command below is required unless marked optional.

---

## Goal

On the **host** Kubernetes cluster only:

1. Deploy OPI `dpu-operator` (CRDs + controller).
2. Deploy companion `opi-nvidia-dpf-adapter` (this repo’s clean tree).
3. Apply one `DpuOperatorConfig` so the adapter LCM **Helm-installs**
   NVIDIA `dpf-operator` **v26.4.0**.

**PASS:** `dpf-operator-system` exists, controller Deployment Ready, LCM
logs show install (not a pre-existing lab leftover).

**DPU-side Kubernetes is not required for GOAL-01.**

---

## Current lab baseline (already done on dh2)

Confirm before T2:

```bash
kubectl get crd applications.argoproj.io certificates.cert-manager.io
kubectl get ns | grep -E 'dpf-operator|opi-nvidia|opi-dpu-tenant' || echo "cleaned"
helm list -A
kubectl get pods -n argocd
kubectl get pods -n cert-manager
```

**Required baseline**

| Item | Want |
|---|---|
| `applications.argoproj.io` | exists |
| `certificates.cert-manager.io` | exists |
| namespaces `dpf-operator-system`, `opi-nvidia-dpf-adapter-system`, `opi-dpu-tenant` | absent |
| Helm `argo-cd` | in namespace `argocd` |
| Helm `cert-manager` | in namespace `cert-manager` |
| Argo / cert-manager pods | Running |

If baseline fails, stop and fix (see Appendix A — cleanup history). Do not start T2.

---

## Tools checklist (install on dh2 before T2)

Run on **dh2** (the machine that builds and talks to the cluster).

### 0) Verify each tool (do not assume)

```bash
uname -a
kubectl version --client
helm version
git --version
go version
buildah --version
podman --version
jq --version
task --version || true
```

| Tool | Required? | Notes |
|---|---|---|
| `kubectl` | **Yes** | Must reach the host k3s API |
| `helm` | **Yes** | Already used for Argo |
| `git` | **Yes** | Clone `dpu-operator` |
| `go` | **Yes** | Install **Go 1.26.10** once (covers OPI `dpu-operator` go 1.24.12 **and** adapter go 1.26.0 / toolchain 1.26.10) |
| `buildah` | **Yes** | OPI `dpu-operator` image build/push uses **buildah**, not `docker build` |
| `podman` | **Yes** | Used by build helpers / binfmt |
| `jq` | Recommended | Cleanup / debug |
| `task` | Recommended | Or use `go run ./tools/task/task.go …` from `dpu-operator` |
| `docker` **or** `podman` as `CONTAINER_TOOL` | **Yes for T3** | Adapter `make docker-build` defaults to `docker`; set `CONTAINER_TOOL=podman` if you have no Docker |

### 1) Install missing tools (Ubuntu/Debian-style examples)

Adjust for your distro if packages differ. Install **once** before T2; do not wait until a command fails.

```bash
# packages
sudo apt-get update
sudo apt-get install -y git jq buildah podman

# Go 1.26.10 (official tarball) — use this for BOTH T2 and T3
curl -fsSL https://go.dev/dl/go1.26.10.linux-amd64.tar.gz -o /tmp/go.tgz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf /tmp/go.tgz
export PATH=/usr/local/go/bin:$PATH
echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc
go version   # must print go1.26.10 (or matching 1.26.x you installed)

# task (optional but convenient)
go install github.com/go-task/task/v3/cmd/task@latest
export PATH="$(go env GOPATH)/bin:$PATH"
echo 'export PATH="$(go env GOPATH)/bin:$PATH"' >> ~/.bashrc
task --version
```

**Stop if:** `go version` fails or is older than 1.26.  
**Stop if:** `buildah --version` or `podman --version` fails.

### 2) Cluster access

```bash
# If you normally use root's k3s config:
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# or: export KUBECONFIG=$HOME/.kube/config

kubectl get nodes
kubectl get ns
```

**Expect:** at least one Ready node; `argocd` and `cert-manager` namespaces exist.

### 3) Container registry = Docker Hub

Upstream `task` pushes images as:

`$REGISTRY/dpu-operator:dev`, `$REGISTRY/dpu-daemon:dev`, …

So set:

```bash
export REGISTRY=docker.io/<YOUR_DOCKERHUB_USER>
# Example: export REGISTRY=docker.io/johndoe
```

**You must log in before push** (use a Docker Hub **access token**, not your account password if 2FA is on):

```bash
buildah login docker.io
# Username: <YOUR_DOCKERHUB_USER>
# Password: <Docker Hub access token>
```

(`docker login docker.io` is fine *extra*, but **buildah login** is what the push path needs.)

**Cluster pull:** make the Hub repos **public**, or configure imagePullSecrets on the cluster so k3s can pull private images. Public is simplest for GOAL-01.

**Verify login:**

```bash
buildah login --get-login docker.io
```

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

### T2.3 — Build and push images

`deploy-upstream-certmanager-1c` does **not** build images. You must build+push first.

```bash
cd ~/dpu-operator
export REGISTRY=docker.io/<YOUR_DOCKERHUB_USER>

task build-image-all
# OR without task binary:
# go run ./tools/task/task.go build-image-all
```

What this does: compiles binaries, `buildah` builds images, `buildah manifest push` to `docker://$REGISTRY/…:dev`.

**Expect:** exit 0. First run can take a long time.

**Stop if:** missing `buildah`/`podman`/Go — return to tools checklist.  
**Stop if:** push Unauthorized — `buildah login docker.io` again.  
**Stop if:** qemu/binfmt / sudo prompts — grant sudo; re-run.

### T2.4 — Deploy (single host cluster + cert-manager profile)

Correct profile for **one** host Kubernetes cluster (not dual host/DPU):

```bash
cd ~/dpu-operator
export REGISTRY=docker.io/<YOUR_DOCKERHUB_USER>
HOST_KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Pass KUBECONFIG_HOST on the CLI — required
task deploy-upstream-certmanager-1c KUBECONFIG_HOST="$HOST_KUBECONFIG"
# OR:
# go run ./tools/task/task.go deploy-upstream-certmanager-1c KUBECONFIG_HOST="$HOST_KUBECONFIG"
```

What this does:
- Rewrites image refs from `$REGISTRY`
- Applies manifests into namespace `openshift-dpu-operator`
- Waits for `dpu-operator-controller-manager` Available

**Do NOT** run `kubectl apply -f examples/config.yaml` yet.  
That creates `DpuOperatorConfig`; we do that in **T4** with NVIDIA annotations.

### T2.5 — Verify T2

```bash
kubectl get ns openshift-dpu-operator
kubectl get crd dpuoperatorconfigs.config.openshift.io
kubectl get crd dataprocessingunits.config.openshift.io
kubectl get crd servicefunctionchains.config.openshift.io
kubectl get deploy,pods -n openshift-dpu-operator -o wide
kubectl describe deploy -n openshift-dpu-operator dpu-operator-controller-manager | tail -40
```

**Expect**

- Namespace `openshift-dpu-operator` exists  
- Three CRDs exist  
- Deployment Available; pod(s) Running  

**Common failures**

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` | Hub private / wrong `REGISTRY` / nodes can’t pull | Public repo or pull secret; check image name on Hub |
| `Unauthorized` on push | Not logged in to Hub | `buildah login docker.io` |
| Looks for `/root/kubeconfig.ocpcluster` | Task var not overridden | Re-run with `KUBECONFIG_HOST="$HOST_KUBECONFIG"` on the **task CLI** (export alone is ignored) |
| Push to `hostname:5000` | `REGISTRY` unset | `export REGISTRY=docker.io/<user>` before `build-image-all` |
| `task: command not found` | PATH | Install task or use `go run ./tools/task/task.go …` |

**Paste Results / T2, then continue.**

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
kubectl logs -n opi-nvidia-dpf-adapter-system \
  deploy/opi-nvidia-dpf-adapter-controller-manager -c manager --tail=80
```

**Expect:** pods Running; logs show Lifecycle Manager; no CrashLoop.  
**Also required later:** this pod must reach `https://helm.ngc.nvidia.com`.

**Stop if:** ImagePullBackOff / CrashLoop / missing `sdk_helm_client.go` in the image source.

---

## T4 — Apply enablement CR (triggers DPF install)

Use the same contract as `opi-nvidia-dpf-adapter/config/samples/dpuoperatorconfig-nvidia.yaml`  
(annotations + `spec.vendor` when the CRD accepts it):

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
  vendor: nvidia
EOF
```

If apply rejects `spec.vendor` (older CRD without that field), re-apply **without** the `vendor:` line; keep the annotations.

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
| Adapter logs | `installed` (fresh) |
| Conditions | `VendorOperatorSupported` not `Blocked` |

**If `Blocked`:** Argo/cert-manager CRDs missing — return to baseline.  
**If Helm/NGC errors:** egress from adapter pod to NGC.  
**If apply rejected:** paste full kubectl error into Results.

---

## Out of scope for GOAL-01

- Kubernetes on the DPU ARM  
- `DataProcessingUnit` / `ServiceFunctionChain`  
- Traffic validation  

---

## Results log

### Meta

- Date / time:
- Hub user / `REGISTRY`:
- `IMG`:
- `KUBECONFIG_HOST`:
- Go version used for T2 / T3:

### Baseline

```text
# paste: kubectl get crd applications… certificates…
# paste: helm list -A
# paste: kubectl get pods -n argocd ; kubectl get pods -n cert-manager
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

### Verdict

- [ ] PASS  
- [ ] FAIL — describe  

```text

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
