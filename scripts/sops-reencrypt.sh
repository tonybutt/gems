#!/usr/bin/env bash
# Re-encrypt all SOPS-encrypted files with current keys from .sops.yaml

set -euo pipefail

usage() {
  echo "Usage: sops-reencrypt [OPTIONS] [DIRECTORY]"
  echo ""
  echo "Re-encrypt all SOPS-encrypted files with current keys from .sops.yaml"
  echo ""
  echo "Options:"
  echo "  -h, --help     Show this help message"
  echo "  -n, --dry-run  Show files that would be re-encrypted without making changes"
  echo ""
  echo "Arguments:"
  echo "  DIRECTORY      Directory to search (default: git root or current directory)"
}

DRY_RUN=false
REPO_ROOT=""

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
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      REPO_ROOT="$1"
      shift
      ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

echo "Searching for SOPS-encrypted files in: $REPO_ROOT"

# Find all candidate files, excluding .git directory
mapfile -t encrypted_files < <(
  find "$REPO_ROOT" \
    -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.env" -o -name "*.json" -o -name "*.dockerconfigjson" \) \
    ! -path "*/.git/*" \
    -exec grep -l "^sops:" {} \; 2>/dev/null
)

if [ ${#encrypted_files[@]} -eq 0 ]; then
  echo "No SOPS-encrypted files found."
  exit 0
fi

echo "Found ${#encrypted_files[@]} encrypted file(s)"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "Dry run - files that would be re-encrypted:"
  for file in "${encrypted_files[@]}"; do
    echo "  $file"
  done
  exit 0
fi

# Determine input type based on file extension
get_input_type() {
  local file="$1"
  case "$file" in
    *.dockerconfigjson) echo "json" ;;
    *.env)              echo "dotenv" ;;
    *)                  echo "" ;;
  esac
}

failed=0
for file in "${encrypted_files[@]}"; do
  echo "Re-encrypting: $file"
  input_type=$(get_input_type "$file")
  if [ -n "$input_type" ]; then
    sops_args=(updatekeys --yes --input-type "$input_type" "$file")
  else
    sops_args=(updatekeys --yes "$file")
  fi
  if sops "${sops_args[@]}"; then
    echo "  Success"
  else
    echo "  Failed"
    failed=$((failed + 1))
  fi
done

echo ""
if [ $failed -eq 0 ]; then
  echo "All files re-encrypted successfully."
else
  echo "$failed file(s) failed to re-encrypt."
  exit 1
fi
