#!/usr/bin/env bash
# End-to-end test of the deploy/base manifests against whatever cluster kubectl points at.
# Usage: tests/e2e.sh <expected-version>     (BREAK=true makes the first deploy fail on purpose)
set -euo pipefail

expected="${1:?usage: e2e.sh <expected-version>}"
here="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0

step() { echo; echo "== $*"; }

check() { # check <description> <command...>: passes when the command exits 0
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS  $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL  $desc"
    fail=$((fail + 1))
  fi
}

# GET a path from the service through a short-lived port-forward (the forward targets a ready pod
# at that moment, so a new one is opened per call instead of kept across rollouts).
get() {
  kubectl port-forward svc/webapp 18080:80 >/dev/null 2>&1 &
  local pf=$! out=""
  for _ in $(seq 1 30); do
    if out="$(curl -fsS --max-time 2 "http://127.0.0.1:18080$1" 2>/dev/null)"; then
      break
    fi
    out=""
    sleep 0.5
  done
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  printf '%s' "$out"
}

ready_replicas() { kubectl get deployment webapp -o jsonpath='{.status.readyReplicas}'; }
restarts() { kubectl get pods -l app=webapp -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s+=$1} END {print s+0}'; }
poll() { # poll <seconds> <command...>
  local n="$1"
  shift
  for _ in $(seq 1 "$n"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}
is_two_ready() { [ "$(ready_replicas)" = "2" ]; }
pdb_allows_one() { [ "$(kubectl get pdb webapp -o jsonpath='{.status.disruptionsAllowed}')" = "1" ]; }
only_two_pods() { [ "$(kubectl get pods -l app=webapp --no-headers | wc -l)" = "2" ]; }

step "deploy"
kubectl apply -k "$here/../deploy/base"
if [ "${BREAK:-false}" = "true" ]; then
  echo "BREAK=true: pointing the deployment at an image that does not exist"
  kubectl set image deployment/webapp webapp=webapp:missing
fi
kubectl rollout status deployment/webapp --timeout=120s

step "serves the expected build"
check "GET /healthz returns ok" test "$(get /healthz)" = "ok"
check "GET /version returns $expected" test "$(get /version)" = "$expected"

step "healthy deployment"
check "2 replicas ready" is_two_ready
check "no container restarts" test "$(restarts)" = "0"
check "PodDisruptionBudget allows 1 disruption" poll 20 pdb_allows_one

step "bad release: image that cannot be pulled"
kubectl set image deployment/webapp webapp=webapp:missing
if kubectl rollout status deployment/webapp --timeout=40s; then
  echo "  FAIL  bad rollout unexpectedly succeeded"
  fail=$((fail + 1))
else
  echo "  PASS  rollout does not complete"
  pass=$((pass + 1))
fi
check "capacity kept: still 2 ready replicas" is_two_ready
check "old build still answers: $expected" test "$(get /version)" = "$expected"

step "rollback"
kubectl rollout undo deployment/webapp
kubectl rollout status deployment/webapp --timeout=120s
check "back to 2 ready replicas and exactly 2 pods" poll 30 only_two_pods
check "2 replicas ready" is_two_ready
check "serves $expected again" test "$(get /version)" = "$expected"

echo
echo "checks passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
