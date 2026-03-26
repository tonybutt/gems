#!/usr/bin/env bash
# Validate all kustomization.yaml files build successfully.
# Runs kustomize build on each directory containing a kustomization.yaml,
# skipping flux-system (contains gotk-components which aren't plain kustomize).

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
failed=0
checked=0

while IFS= read -r kfile; do
  dir="$(dirname "$kfile")"
  rel="$(realpath --relative-to="$root" "$dir")"

  # Skip flux-system dir — gotk-components aren't plain kustomize
  if [[ "$rel" == *"flux-system"* ]]; then
    continue
  fi

  checked=$((checked + 1))
  if ! kustomize build "$dir" > /dev/null 2>&1; then
    echo "FAIL: $rel"
    # Show the actual error
    kustomize build "$dir" 2>&1 | tail -5 || true
    failed=$((failed + 1))
  fi
done < <(find "$root" -name "kustomization.yaml" -not -path "*/gotk-components*" | sort)

if [ "$failed" -gt 0 ]; then
  echo ""
  echo "$failed/$checked kustomizations failed to build"
  exit 1
else
  echo "$checked kustomizations validated successfully"
fi
