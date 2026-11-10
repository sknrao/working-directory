# Working directory (temporary)

Scratch space for OPI ↔ NVIDIA DPF bring-up.  
**Delete this folder when the project is done.**

| File | Purpose |
|---|---|
| [GOAL-01-deploy-dpf-operator.md](GOAL-01-deploy-dpf-operator.md) | Goal 1: install `dpf-operator` via OPI + adapter. On a **new** host start at **P0–P4** (tools, Argo/cert-manager, drivers/MFT), then T2. dh2 = partial; dh5 BF-3 = full target. |
| [GOAL-02-observe-dpu.md](GOAL-02-observe-dpu.md) | Goal 2: Observe OPI `DataProcessingUnit` + VSP + status; **no Create**. Start at T1 or run [goal02-observe.sh](goal02-observe.sh). |

How we use it:

1. Open the goal `.md` and run **from the stated next step** (do not skip the tools checklist).
2. Stop at the first failed gate; paste outputs into that file’s **Results** section (or into chat).
3. We iterate from those results.
