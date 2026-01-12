#!/usr/bin/env bash
# Generate Talos configurations from Nix definitions
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TALOS_DIR="$REPO_ROOT/talos"
NODES_DIR="$TALOS_DIR/nodes"
PATCHES_DIR="$TALOS_DIR/patches"
GEN_DIR="$TALOS_DIR/gen"

usage() {
  echo "Usage: talos-gen <command>"
  echo ""
  echo "Commands:"
  echo "  secrets     Generate new cluster secrets (creates talos/secrets.yaml)"
  echo "  configs     Generate per-node configs (talos/gen/<node>.yaml)"
  echo ""
  echo "Examples:"
  echo "  talos-gen secrets    # Create new encrypted secrets file"
  echo "  talos-gen configs    # Generate node configs to talos/gen/"
}

# Generate new secrets
generate_secrets() {
  echo "Generating new cluster secrets..."

  SECRETS_FILE="$TALOS_DIR/secrets.yaml"

  if [ -f "$SECRETS_FILE" ]; then
    echo "Warning: $SECRETS_FILE already exists."
    read -p "Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 1
    fi
  fi

  # Generate secrets
  talosctl gen secrets -o "$SECRETS_FILE"

  # Encrypt with SOPS
  echo "Encrypting secrets with SOPS..."
  sops -e -i "$SECRETS_FILE"

  echo "Secrets generated and encrypted at $SECRETS_FILE"
}

# Generate full configs
generate_configs() {
  echo "Generating Talos configs..."

  SECRETS_FILE="$TALOS_DIR/secrets.yaml"

  if [ ! -f "$SECRETS_FILE" ]; then
    echo "Error: $SECRETS_FILE not found. Run 'talos-gen secrets' first."
    return 1
  fi

  # Decrypt secrets temporarily
  echo "Decrypting secrets..."
  sops -d -i "$SECRETS_FILE"

  mkdir -p "$GEN_DIR"

  # Generate per-node configs with all patches baked in
  for node in "${NODES[@]}"; do
    IFS=':' read -r name _ip type <<< "$node"

    echo "Generating config for $name ($type)..."
    talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
      --with-secrets "$SECRETS_FILE" \
      --config-patch "@$PATCHES_DIR/base.yaml" \
      --config-patch "@$NODES_DIR/$name.yaml" \
      --output-types "$type" \
      -o "$GEN_DIR/$name.yaml" \
      --force
  done

  # Generate talosconfig
  echo "Generating talosconfig..."
  talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
    --with-secrets "$SECRETS_FILE" \
    --output-types talosconfig \
    -o "$GEN_DIR/talosconfig" \
    --force

  # Re-encrypt secrets
  echo "Re-encrypting secrets..."
  sops -e -i "$SECRETS_FILE"

  echo ""
  echo "Configs generated:"
  for node in "${NODES[@]}"; do
    IFS=':' read -r name _ip _type <<< "$node"
    echo "  $GEN_DIR/$name.yaml"
  done
  echo "  $GEN_DIR/talosconfig"
}

# Main
if [ $# -eq 0 ]; then
  usage
  exit 1
fi

COMMAND="$1"

case "$COMMAND" in
  secrets)
    generate_secrets
    ;;
  configs)
    generate_configs
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $COMMAND"
    usage
    exit 1
    ;;
esac
