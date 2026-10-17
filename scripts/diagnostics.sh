#!/usr/bin/env bash
# Dump everything useful for debugging a failed pipeline run into a directory.
# Usage: scripts/diagnostics.sh <output-dir>
set -uo pipefail

out="${1:?usage: diagnostics.sh <output-dir>}"
mkdir -p "$out"

kubectl version -o yaml >"$out/version.yaml" 2>&1
kubectl get nodes -o wide >"$out/nodes.txt" 2>&1
kubectl get all,pdb,events -A -o wide >"$out/all.txt" 2>&1
kubectl get events -A --sort-by=.lastTimestamp >"$out/events.txt" 2>&1
kubectl describe pods -A >"$out/describe-pods.txt" 2>&1
kubectl describe deployments -A >"$out/describe-deployments.txt" 2>&1

# Logs of every container in every pod, including the previous instance of a crashed one.
mkdir -p "$out/logs"
kubectl get pods -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' |
  while read -r ns name; do
    kubectl logs -n "$ns" "$name" --all-containers --tail=500 >"$out/logs/$ns.$name.log" 2>&1
    kubectl logs -n "$ns" "$name" --all-containers --previous --tail=500 >"$out/logs/$ns.$name.previous.log" 2>&1 || rm -f "$out/logs/$ns.$name.previous.log"
  done

echo "diagnostics written to $out"
