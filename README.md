# k8s-kind-e2e-matrix

![ci](https://github.com/Sup3rMar10/k8s-kind-e2e-matrix/actions/workflows/ci.yml/badge.svg)

A pull-request pipeline that builds an image, creates a throwaway [kind](https://kind.sigs.k8s.io/) cluster **per Kubernetes version**, deploys the manifests, runs end-to-end tests including a bad release and a rollback, and uploads diagnostics when anything fails.

> **What is verified.** On 2026-10-17 this pipeline ran green on GitHub Actions: `lint`, then `e2e` on Kubernetes **v1.32.2, v1.33.1 and v1.34.0**, each passing **11 of 11 checks**. A second run, started with the `break` input on purpose, failed on all three versions and **each uploaded a diagnostics artifact** (about 33 KB), which is what that path is for. It was never run against a real (non-kind) cluster.

## What the pipeline does

1. **lint:** `kubectl kustomize`, then [kubeconform](https://github.com/yannh/kubeconform) in strict mode against the Kubernetes 1.33 schemas, then `shellcheck`.
2. **e2e (matrix, one job per Kubernetes version):** build the image, `kind create cluster` with that node image, `kind load docker-image` (no registry involved), run `tests/e2e.sh`.
3. **On failure:** `scripts/diagnostics.sh` dumps nodes, events, `describe` output and every container's logs (including the previous instance of a crashed one), and the job uploads them as an artifact.

## What `tests/e2e.sh` checks

| Stage | Checks |
|---|---|
| Healthy deploy | `/healthz` and `/version` answer; the version equals the commit SHA that was built; 2 ready replicas; zero container restarts; the PodDisruptionBudget allows 1 disruption |
| Bad release (an image tag that cannot be pulled) | the rollout does **not** complete; capacity is kept (still 2 ready replicas, `maxUnavailable: 0`); the old build still answers |
| Rollback | `kubectl rollout undo`; 2 ready replicas and exactly 2 pods again; the original build answers again |

`BREAK=true` points the first deploy at a missing image, so the very first rollout fails. That is how the diagnostics path was exercised.

## Why a version matrix

A manifest that works on one Kubernetes minor version can break on the next (removed APIs, changed defaults). Three jobs in parallel cost the same wall-clock time as one and catch that before the cluster upgrade does. `fail-fast: false` lets all three finish so one failure does not hide another.

## Honest limits

- **kind is not production.** Single node, no cloud load balancer, no real CNI/CSI behaviour, no node pressure. Passing here means the manifests are coherent, not that they survive a real cluster.
- **The image is loaded into the nodes**, not pulled from a registry, so image pull secrets, registry rate limits and pull latency are not tested. (The "cannot be pulled" case is simulated with a tag that does not exist.)
- **No ingress, no TLS, no autoscaler, no real traffic.** Requests go through `kubectl port-forward` to the Service.
- The three node image tags are pinned by tag, not by digest.
- The 11 checks are about deployment mechanics; the app is a static nginx page with no business logic.
- Two earlier things I got wrong and fixed while building it: scripts lost their executable bit when committed from Windows (fixed with `git update-index --chmod=+x`), and a `poll` helper evaluated its command once instead of repeatedly.

## Run it locally

Needs Docker, [kind](https://kind.sigs.k8s.io/) and kubectl:

```
docker build --build-arg APP_VERSION=local -t webapp:ci app
kind create cluster --name e2e
kind load docker-image webapp:ci --name e2e
tests/e2e.sh local
```

I did **not** run it locally (Docker was not running on my machine); the CI runs above are the evidence.
