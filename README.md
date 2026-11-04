# Working directory (temporary)

Scratch space for OPI ↔ NVIDIA DPF bring-up.  
**Delete this folder when the project is done.**

| File | Purpose |
|---|---|
| [GOAL-01-deploy-dpf-operator.md](GOAL-01-deploy-dpf-operator.md) | First goal: install `dpf-operator` via OPI + adapter — **full commands** for T0–T4 (host K8s, cert-manager, Argo, `dpu-operator` task deploy, adapter, enablement CR) |

How we use it:

1. Agent writes / updates the goal `.md` (concrete steps + expectations).
2. You run the steps **in order**, stop at the first failed gate, and paste outputs into that file’s **Results** section (or paste the same into chat).
3. We iterate from those results.
