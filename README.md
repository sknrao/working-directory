# Working directory (temporary)

Scratch space for OPI ↔ NVIDIA DPF bring-up.  
**Delete this folder when the project is done.**

| File | Purpose |
|---|---|
| [GOAL-01-deploy-dpf-operator.md](GOAL-01-deploy-dpf-operator.md) | First goal: install `dpf-operator` via OPI + adapter. **Start at Tools checklist → T2** (cleanup/Argo already done on dh2). No assumed tools: Go 1.26.10, buildah/podman, Docker Hub login, Task `KUBECONFIG_HOST=` CLI override. |

How we use it:

1. Open the goal `.md` and run **from the stated next step** (do not skip the tools checklist).
2. Stop at the first failed gate; paste outputs into that file’s **Results** section (or into chat).
3. We iterate from those results.
