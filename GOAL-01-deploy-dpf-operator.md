# GOAL-01 — Deploy `dpf-operator` through OPI

**Lab host:** `dh2`  
**Where you are (2026-11-06):** Helm install OK (`VendorOperatorSupported=True`, `dpf-operator-controller-manager` Running). **Next: T5** — make `VendorOperatorReady` + `VendorDPUReady` True and clear VSP CrashLoop.

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
| OPI `DpuOperatorConfig` conditions | `VendorOperatorSupported=True`, `VendorOperatorReady=True`, `VendorDPUReady=True` |
| Adapter pods | managers Running; `nvidia-vsp` Ready (no CrashLoop) |

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
kubectl -n openshift-dpu-operator get certificate,issuer,secret webhook-server-cert
kubectl -n openshift-dpu-operator get deploy dpu-operator-controller-manager
```

**Expect**

- Namespace `openshift-dpu-operator` exists  
- CRDs `dpuoperatorconfigs`, `dataprocessingunits`, `servicefunctionchains` exist (DPU CRDs may briefly show Terminating from undeploy; they should settle)  
- Deployment **Available**; current manager pod **Running / Ready**  
- Certificate Ready; Secret `webhook-server-cert` present  

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
kubectl logs -n dpf-operator-system deploy/dpf-operator-controller-manager --tail=80
kubectl rollout status -n dpf-operator-system \
  deploy/dpf-provisioning-controller-manager \
  deploy/dpuservice-controller-manager --timeout=300s
kubectl get deploy,pods -n dpf-operator-system
```

### T5.2 — Redeploy adapter with Argo fallback fix (`:goal01-fix3`)

Code now treats `argocd/argo-cd-argocd-server` as a valid Argo prerequisite
([`pkg/lifecycle/status.go`](../opi-nvidia-dpf-adapter/pkg/lifecycle/status.go)).

```bash
cd ~/opi-nvidia-dpf-adapter
grep -n 'argo-cd-argocd-server' pkg/lifecycle/status.go
# Must list argocd fallbacks. If missing: sync tree from workstation.

export IMG=docker.io/sknrao/opi-nvidia-dpf-adapter:goal01-fix3
make docker-build docker-push IMG=$IMG
make deploy IMG=$IMG
# Re-apply helm-cache volume + helm-installer RBAC if make deploy resets them
# (emptyDir helm-cache is in config/manager/manager.yaml; helm_installer_* in config/rbac).

kubectl -n opi-nvidia-dpf-adapter-system rollout status \
  deploy/opi-nvidia-dpf-adapter-controller-manager
```

Nudge LCM and check conditions:

```bash
kubectl annotate dpuoperatorconfig dpu-operator-config \
  lifecycle.opi.nvidia.com/reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite
sleep 15
kubectl get dpuoperatorconfig dpu-operator-config -o yaml | sed -n '/status:/,$p'
```

**Want:** `VendorOperatorReady` → `True` / `Ready` (after T5.1 + T5.2).

### T5.3 — Fix VSP CrashLoop (hardware overlay)

Default VSP is kind/mock. Lab BlueField needs the hardware overlay.

```bash
# 1) Which container fails (before overlay)
kubectl -n opi-nvidia-dpf-adapter-system get pods -l app.kubernetes.io/component=vsp -o wide
kubectl -n opi-nvidia-dpf-adapter-system logs -l app.kubernetes.io/component=vsp -c vsp --tail=80 || true
kubectl -n opi-nvidia-dpf-adapter-system logs -l app.kubernetes.io/component=vsp -c opi-daemon --tail=80 || true

# 2) Node label required by overlay nodeSelector
kubectl label node dh2 hardware.opiproject.org/profile=nvidia-bluefield --overwrite

# 3) Apply hardware VSP (overlay pins goal01-fix3 — keep in sync with T5.2 IMG)
cd ~/opi-nvidia-dpf-adapter
# Confirm pin:
grep -A2 'newName:' config/overlays/hardware-vsp/kustomization.yaml
kustomize build config/overlays/hardware-vsp | kubectl apply -f -
# Or: kubectl apply -k config/overlays/hardware-vsp

kubectl -n opi-nvidia-dpf-adapter-system rollout status ds/opi-nvidia-dpf-adapter-nvidia-vsp --timeout=180s
kubectl -n opi-nvidia-dpf-adapter-system get pods -l app.kubernetes.io/component=vsp -o wide
```

**Expect:** VSP pod Ready (hardware overlay drops opi-daemon sidecar; single `vsp` container).  
**Stop if:** CrashLoop continues — paste `kubectl describe` + logs; check `lspci -nn | grep 15b3` and `/sys` mounts.

### T5.4 — Host reset for `VendorDPUReady` (NVCONFIG / SystemLevelReset)

Adapter **will not** reboot the host. DPU `dpf-operator-system/dh2-bluefield-2`
reports pending NVCONFIG and `SystemLevelReset`.

```bash
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 -o yaml | tee /tmp/dpu-before-reset.yaml
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 \
  -o jsonpath='{.status.phase}{" method="}{.status.agentStatus.rebootMethod}{" rebootPhase="}{.status.rebootStatus.phase}{"\n"}'
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 \
  -o jsonpath='{.metadata.annotations.provisioning\.dpu\.nvidia\.com/host-power-cycle-required}{"\n"}'
```

Then on **dh2** (maintenance window):

1. Ensure DPF host-agent / provisioning has applied or queued NVCONFIG (see DPU status `lastObservedPendingNvconfig`).
2. Perform the reset DPF requests for method **`SystemLevelReset`** (typically host reboot, or the NVIDIA-documented `mlxfwreset` / firmware reset for this mode — follow the method named on the DPU object, not a guess).
3. After the node rejoins the cluster:

```bash
kubectl get nodes
kubectl -n dpf-operator-system get dpu dh2-bluefield-2 -o wide
# Wait until phase Ready / rebootStatus Succeeded (not Rebooting)

kubectl annotate dpuoperatorconfig dpu-operator-config \
  lifecycle.opi.nvidia.com/reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite
kubectl get dpuoperatorconfig dpu-operator-config -o yaml | sed -n '/status:/,$p'
```

**Want:** `VendorDPUReady=True` / `Ready`.

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
| `VendorDPUReady` | True / Ready |
| DPF sibling Deployments | Available |
| VSP | Running / Ready |

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

### T5

```text
# paste: DPFOperatorConfig apply + sibling rollout
# paste: IMG=goal01-fix3 deploy
# paste: VSP pods after hardware overlay
# paste: DPU status before/after host reset
# paste: final conditions + get pods
```

### Verdict

- [ ] PASS — all T5.5 gates  
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
