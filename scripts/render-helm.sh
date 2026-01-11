#!/usr/bin/env bash
# Render helm charts from helm-values.yaml files
#
# Each helm-values.yaml should have a header comment with chart metadata:
# # chart: cilium/cilium
# # version: 1.16.3
# # repo: https://helm.cilium.io/
# # namespace: kube-system
# # release-name: cilium
#
# The rendered output goes to manifests/ directory next to the values file.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

usage() {
  echo "Usage: render-helm [OPTIONS] [FILES...]"
  echo ""
  echo "Render helm charts from helm-values.yaml files"
  echo ""
  echo "Options:"
  echo "  -h, --help     Show this help message"
  echo "  -a, --all      Render all helm-values.yaml files in the repo"
  echo "  -n, --dry-run  Show what would be rendered without making changes"
  echo ""
  echo "Arguments:"
  echo "  FILES          Specific helm-values.yaml files to render"
}

DRY_RUN=false
RENDER_ALL=false
FILES=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -a|--all)
      RENDER_ALL=true
      shift
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

# Extract metadata from helm-values.yaml header comments
extract_metadata() {
  local file="$1"
  local key="$2"
  grep "^# ${key}:" "$file" 2>/dev/null | sed "s/^# ${key}: *//" | head -1
}

# Add helm repo if needed
ensure_repo() {
  local repo_name="$1"
  local repo_url="$2"

  if [ -z "$repo_url" ]; then
    return 0
  fi

  # Check if repo exists
  if ! helm repo list 2>/dev/null | grep -q "^${repo_name}"; then
    echo "  Adding helm repo: $repo_name -> $repo_url"
    helm repo add "$repo_name" "$repo_url" > /dev/null 2>&1 || true
  fi
}

# Render a single helm chart
render_chart() {
  local values_file="$1"
  local dir
  dir="$(dirname "$values_file")"

  # Extract metadata
  local chart
  chart=$(extract_metadata "$values_file" "chart")
  local version
  version=$(extract_metadata "$values_file" "version")
  local repo_url
  repo_url=$(extract_metadata "$values_file" "repo")
  local namespace
  namespace=$(extract_metadata "$values_file" "namespace")
  local release_name
  release_name=$(extract_metadata "$values_file" "release-name")

  # Validate required fields
  if [ -z "$chart" ]; then
    echo "  ERROR: Missing 'chart' in $values_file header"
    return 1
  fi

  # Set defaults
  namespace="${namespace:-default}"
  release_name="${release_name:-$(basename "$chart")}"

  # Extract repo name from chart (e.g., "cilium/cilium" -> "cilium")
  local repo_name
  repo_name=$(echo "$chart" | cut -d'/' -f1)

  # Ensure repo is added
  if [ -n "$repo_url" ]; then
    ensure_repo "$repo_name" "$repo_url"
    helm repo update "$repo_name" > /dev/null 2>&1 || true
  fi

  # Prepare output
  local output_dir="${dir}/manifests"
  local output_file="${output_dir}/${release_name}.yaml"

  echo "Rendering: $values_file"
  echo "  Chart: $chart (version: ${version:-latest})"
  echo "  Namespace: $namespace"
  echo "  Output: $output_file"

  if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] Would render to $output_file"
    return 0
  fi

  # Create output directory
  mkdir -p "$output_dir"

  # Build helm template command
  local helm_args=("template" "$release_name" "$chart" "--namespace" "$namespace" "-f" "$values_file")

  if [ -n "$version" ]; then
    helm_args+=("--version" "$version")
  fi

  # Render to temp file first
  local temp_file
  temp_file=$(mktemp)
  trap 'rm -f "$temp_file"' RETURN

  if ! helm "${helm_args[@]}" > "$temp_file" 2>&1; then
    echo "  ERROR: helm template failed"
    cat "$temp_file"
    return 1
  fi

  # Check if output changed
  if [ -f "$output_file" ] && cmp -s "$temp_file" "$output_file"; then
    echo "  No changes"
  else
    mv "$temp_file" "$output_file"
    echo "  Updated"

    # Stage the file if in git repo
    if git rev-parse --git-dir > /dev/null 2>&1; then
      git add "$output_file" 2>/dev/null || true
    fi
  fi
}

# Find all helm-values.yaml files
find_values_files() {
  find "$REPO_ROOT" -name "helm-values.yaml" -type f ! -path "*/.git/*"
}

# Main
main() {
  local exit_code=0

  if [ "$RENDER_ALL" = true ]; then
    echo "Searching for helm-values.yaml files in: $REPO_ROOT"
    mapfile -t FILES < <(find_values_files)

    if [ ${#FILES[@]} -eq 0 ]; then
      echo "No helm-values.yaml files found."
      exit 0
    fi

    echo "Found ${#FILES[@]} file(s)"
    echo ""
  fi

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "No files specified. Use --all to render all, or provide file paths."
    exit 1
  fi

  for file in "${FILES[@]}"; do
    # Resolve relative paths
    if [[ ! "$file" = /* ]]; then
      file="$REPO_ROOT/$file"
    fi

    if [ ! -f "$file" ]; then
      echo "File not found: $file"
      exit_code=1
      continue
    fi

    if ! render_chart "$file"; then
      exit_code=1
    fi
    echo ""
  done

  exit $exit_code
}

main
