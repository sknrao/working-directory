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

---

## How / why Kamaji `DPUCluster` works on dh5 (verified 2026-11-12)

Read this before Create. This is what failed before and what actually made
`dpu-cluster-1` **Ready**.

### Two control planes (do not conflate)

| Plane | Address | Role |
|---|---|---|
| **Host k3s** | `172.22.1.5:6443` on `br-dpu` | Management: Argo, cert-manager, OPI adapter, DPF managers, Kamaji |
| **DPU tenant (Kamaji)** | VIP `172.22.1.200` → Service NodePort `31628` | Control plane **for DPU nodes** only; DPU kubelets join *this* |

Keepalived on the host claims the VIP on `br-dpu` and fronts the Kamaji
TenantControlPlane Service. Health check is HTTPS to `VIP:NodePort` (on this
run: `https://172.22.1.200:31628`). When VIP is missing → `no route to host` →
`DPUCluster` `NotReady`.

### Lab IP map (source of truth)

From [opiproject/lab ips.md](https://github.com/opiproject/lab/blob/main/Documentation/ips.md):

| IP | Device | Use as keepalived VIP? |
|---|---|---|
| `172.22.1.5` | dh5 **host** | No — already the host |
| `172.22.3.5` | dh5 **BF-3** (`dh5bf3`) | No — DPU’s own OOB address |
| `172.22.1.100` | **tgen1** | No — allocated / replies to ping |
| `172.22.1.200` | *(unused in ips.md)* | **Yes** for this lab (ping failed before claim) |

Ranges: `.1.0/24` = hosts, `.3.0/24` = DPUs. VIP must be free on OOB L2
(`br-dpu` / `172.22.0.0/16` here), not the BF-3’s IP.

### What NVIDIA documents vs what k3s needs

[NVIDIA DPUCluster (Kamaji)](https://networking-docs.nvidia.com/dpf/26.4.1/dpucluster)
requires `spec.clusterEndpoint.keepalived` (`interface`, `vip`,
`virtualRouterID`, `nodeSelector`). Sample uses:

```yaml
nodeSelector:
  node-role.kubernetes.io/control-plane: ""
```

On **k3s**, the node label is `node-role.kubernetes.io/control-plane=true`.
Empty-string selector → DaemonSet **DESIRED 0** → no VIP → health check fails.
**Lab fix:** `control-plane: "true"` (see `config/samples/dpucluster-kamaji-lab.yaml`).

If the CR already has `true` but the DS still shows `control-plane=` (empty),
JSON-patch the DS (merge patch often no-ops on that map), then wait for
keepalived `1/1`.

### Failure modes we hit (do not repeat)

| Mistake | Symptom | Correct approach |
|---|---|---|
| Widen k3s `service-node-port-range` to include `6443` | kubectl `connection refused` after restart; YAML/`kube-apiserver-arg` collision with join-surface `anonymous-auth` | **Never.** Use keepalived VIP |
| Kamaji `DPUCluster` **without** keepalived | Service wants NodePort `6443` outside `30000-32767` | Always set `clusterEndpoint.keepalived` |
| VIP = `172.22.3.5` (BF-3) | Steals DPU OOB address | Unused host-subnet IP (e.g. `.1.200`) |
| VIP = `172.22.1.100` | In use (tgen1) | `ping -c1` before apply; prefer free IP not in ips.md |
| `nodeSelector: control-plane: ""` on k3s | keepalived DS DESIRED 0 | Use `"true"` |
| Guess DPU IP as `172.22.1.3` or assume static `172.22.3.5` after flash | SSH/ping miss | After reboot OOB is **DHCP**. Discover: `ip neigh show dev br-dpu` on host; on DPU `ip -4 -br addr` (`br-comm-ch`, this run: `172.22.222.5`) |
| Secret key `kubeconfig` / unescaped `.` | Empty decode; false “0 nodes” | Key is `admin.conf` → jsonpath `{.data.admin\.conf}` |
| Kamaji kubelet-config has k8s **1.35+** fields; BF kubelet **1.34.x** | `DPU Cluster Config` / `NodeNotFound`; kubelet crash: `KubeletCrashLoopBackOffMax` / `imagePullCredentialsVerificationPolicy` | See **Join stuck: kubelet config skew** below. **Not fixed in-repo** (Kamaji reconciles ConfigMap). Patch **on-node** `/var/lib/kubelet/config.yaml` |
| Argo `application.namespaces` = `[argocd dpf-operator-system]` (Helm list) | DPUServices `ApplicationsReady=Pending` (“not yet deployed”); App Sync/Health empty | Set `argocd,dpf-operator-system` (comma, no brackets); restart application-controller. Documented in M1 Argo prereq |
| Host missing Multus NAD CRD | OPI `DpuOperatorConfig` `Ready=False` / `NetworkFunctionNADError` | Install Multus (thick DS or CRD); not a Create fail |
| DPU `OVS_DOCA=no` + 0 hugepages; `ovs-vswitchd` EMER `conntrack_offload_config` | `OPERATIONAL=False`; NPD `OVSvSwitchNotRunning`; `sfc-controller` can’t open `br-sfc.mgmt` | **Prevent:** apply `dpuflavor-bf3-lab.yaml` + bf3 sample flavor annotation (also stamped by FieldMapping on new flavors). **Break-glass:** on DPU `doca-hugepages config --app ovs-doca --size 2048 --num 512 --force` + `OVS_DOCA=yes`; restart ovs; `rollout restart deploy/dpf-provisioning-controller-manager` |

### Verified Ready signals (this run)

```text
DPUCluster: READY=True PHASE=Ready
TenantControlPlane: Ready, endpoint 172.22.1.200:31628
keepalived pod: 1/1 Running
br-dpu: inet 172.22.1.200/32 scope global
ping 172.22.1.200: success from host
curl -sk https://172.22.1.5:31628/version: works (NodePort on host IP)
curl -sk https://172.22.1.200:31628/version: works once VIP is claimed
```

`Nodes Count` on `DPUCluster` = DPUs **assigned**, not Kamaji `kubectl get nodes`.
Empty `get nodes` with `nodesCount=1` still means join incomplete.

### After BFB reboot — access (expected every Create)

| Step | Detail |
|---|---|
| Static `172.22.3.5` | Often **gone** until lab DHCP/static is restored |
| Discover IP | Host: `ip -4 neigh show dev br-dpu`. DPU: `br-comm-ch` address (verified: `172.22.222.5`) |
| Console | `screen /dev/rshim0/console` (kill leftover `screen` if device busy). BMC `172.22.4.5` up |
| Password | Default `ubuntu`/`ubuntu` with **expire=True** — first login must change (≥12 chars). Console works; SSH needs the **current** OOB IP |
| Tenant kubeconfig | `secret/dpu-cluster-1-admin-kubeconfig` key **`admin.conf`** (escape the dot) |

### Join stuck: kubelet config skew (verified 2026-11-12)

**Symptom:** DPF conditions OS/FW/Reboot True; `DPUClusterReady=False` `NodeNotFound`; VIP reachable from DPU (`curl -sk https://172.22.1.200:31628` → `403`); kubelet `activating` / crash:

`FeatureGate KubeletCrashLoopBackOffMax not enabled` + `imagePullCredentialsVerificationPolicy must not be set…`

**Cause:** Kamaji TCP `v1.34.0` + BF kubelet `v1.34.8`, but Kamaji still uploads **1.35-default** fields into `kube-system/kubelet-config` and the node’s `/var/lib/kubelet/config.yaml`. Known Kamaji class of bug (clastix/kamaji#1062).

**Must you redo this every Create?** **Yes, until Kamaji is upgraded / configured to strip those fields for &lt;1.35.** There is **no** durable in-repo code fix yet — patching the tenant ConfigMap is reconciled back by Kamaji. The working fix is **on the DPU node**:

```bash
# SSH to current br-comm-ch IP (not a guessed .3.5)
ssh ubuntu@<dpu-oob-ip>
sudo cp -a /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak
# Remove top-level crashLoopBackOff: block and imagePullCredentialsVerificationPolicy: line
sudo systemctl restart kubelet
# Want: active; journal shows "Watching apiserver"
```

Then: `KUBECONFIG=…admin.conf kubectl get nodes` → `dh5-bluefield-3 Ready`; DPF `phase=Ready`; OPI `DPFReady=True`.

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

1. **Milestone 1** healthy (`VendorOperator*` True; hardware VSP; `kamaji-cm` Running).
2. **Milestone 2** Observe concepts (VSP annotations, inventory correlation) — optional
   overlap on BF-3; Create sample can follow once `DPUCluster` is Ready.
3. **Kamaji** — already installed if `kamaji-system` pods are Ready (`make lab-kamaji`).
4. **`DPUCluster.spec.clusterEndpoint.keepalived`** filled (NVIDIA path). Do **not**
   widen k3s `service-node-port-range` to include `6443` — that previously took
   host kubectl down (duplicate `kube-apiserver-arg` + API port collision risk).
   Bare `type: kamaji` without keepalived falls back to NodePort `6443` and fails.
5. Host join-surface / Argo apps-in-any-namespace still useful for host tooling
   (`make lab-k3s-join-surface`); DPU join targets **Kamaji VIP**, not host k3s.
6. OOB / `br-dpu` as required for provisioning.

If this host still has a **static** `DPUCluster`, follow the cutover in
[M1](../opi-nvidia-dpf-adapter/docs/user-guide-milestone-01-dpf-bringup.md)
(static → Kamaji) **before** expecting Create against Kamaji.

---

## Procedure

### T0 — Keepalived VIP + Kamaji DPUCluster

```bash
# Do NOT touch NodePort range. Confirm hack absent:
sudo grep -n 'service-node-port-range' /etc/rancher/k3s/config.yaml || echo "ok: no 6443 NodePort hack"

# dh5 sample: keepalived br-dpu, vip=172.22.1.200, nodeSelector control-plane=true
# k3s uses =true; NVIDIA "" schedules 0 keepalived pods. If DS stuck at
# NODE SELECTOR ...control-plane=  (empty), JSON-patch DS + CR to "true".
ping -c1 -W1 172.22.1.200 || true

cd ~/opi-nvidia-dpf-adapter
# Sync latest sample (or set keepalived by hand if tree is stale):
grep -A6 'keepalived:' config/samples/dpucluster-kamaji-lab.yaml

kubectl -n dpf-operator-system get dpfoperatorconfig dpfoperatorconfig \
  -o jsonpath='kamaji.disable={.spec.kamajiClusterManager.disable} static.disable={.spec.staticClusterManager.disable}{"\n"}'
# want: kamaji.disable=false static.disable=true

kubectl apply -f config/samples/dpucluster-kamaji-lab.yaml
kubectl -n dpf-operator-system get dpucluster dpu-cluster-1 -o wide
kubectl -n dpf-operator-system get pods | grep -i keepalived || true
kubectl get tenantcontrolplane -A 2>/dev/null || true
# Want: DPUCluster Ready; VIP on br-dpu; TCP endpoint VIP:<NodePort>
# (this lab: 172.22.1.200:31628 — NodePort is allocated, not host :6443)
ip -4 addr show br-dpu | grep 172.22.1.200
ping -c2 172.22.1.200
kubectl get tenantcontrolplane -A
```

### T0 PASS gate (stop here until green)

| Check | Want |
|---|---|
| `dpucluster dpu-cluster-1` | `READY=True` `PHASE=Ready` |
| keepalived pod | `1/1 Running` |
| `br-dpu` | `inet 172.22.1.200/32` |
| `ping 172.22.1.200` | replies |
| TenantControlPlane | Ready; endpoint `172.22.1.200:<NodePort>` |

**Do not start T1 (OPI Create) until T0 PASS.**

### T1 — Apply BF-3 OPI sample

```bash
# Flavor first (immutable). Contains OVS_DOCA=yes + hugepages=3072.
kubectl apply -f config/samples/dpuflavor-bf3-lab.yaml
# OPI object points at dpf-lab-ovs-flavor via annotation.
kubectl apply -f config/samples/dataprocessingunit-bf3-lab.yaml
kubectl get dataprocessingunit dh5-bluefield-3
```

Also once per cluster (if not already done):

```bash
make lab-fix-argo-app-namespaces
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
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
| T0 Kamaji + DPUCluster | **PASS** 2026-11-12 | keepalived `true` selector; VIP `172.22.1.200` on `br-dpu`; TCP `172.22.1.200:31628`; HealthCheckPassed |
| T1 OPI apply | **PASS** 2026-11-12 | `dataprocessingunit-bf3-lab.yaml` |
| T2 DPF Ready | **PASS** 2026-11-12 | After on-node kubelet config strip (Kamaji 1.35-field skew); node Ready `v1.34.8` InternalIP `192.168.122.122` |
| T3 Correlation | **PASS** 2026-11-12 | label `translation.opi.nvidia.com/source-name=dh5-bluefield-3`; VSP serial/PCI/product |
| T4 OPI DPFReady | **PASS** 2026-11-12 | `DPFReady=True/AllChildrenReady`, `DPFHardwareCompatible=True` |
| OPERATIONAL / NAD | **PASS** 2026-11-12 | Host Multus CRD; Argo `application.namespaces` comma form; DPU hugepages + `OVS_DOCA=yes`; `OPERATIONAL=True` / `OperationalReady=AllReady` after provisioning-controller restart |

---

## Related

| Doc | Role |
|---|---|
| [GOAL-01-deploy-dpf-operator.md](GOAL-01-deploy-dpf-operator.md) | LCM / Helm bring-up |
| [GOAL-02-observe-dpu.md](GOAL-02-observe-dpu.md) | Observe before / alongside Create |
| [../opi-nvidia-dpf-adapter/docs/user-guide-milestone-03-create.md](../opi-nvidia-dpf-adapter/docs/user-guide-milestone-03-create.md) | Short Create user guide |
| [../opi-nvidia-dpf-adapter/docs/user-guide-milestone-01-dpf-bringup.md](../opi-nvidia-dpf-adapter/docs/user-guide-milestone-01-dpf-bringup.md) | Kamaji install + static→Kamaji cutover |
