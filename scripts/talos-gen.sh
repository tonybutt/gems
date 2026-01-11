#!/usr/bin/env bash
# Generate Talos configurations from Nix definitions
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TALOS_DIR="$REPO_ROOT/talos"
NODES_DIR="$TALOS_DIR/nodes"
PATCHES_DIR="$TALOS_DIR/patches"

usage() {
  echo "Usage: talos-gen <command>"
  echo ""
  echo "Commands:"
  echo "  patches     Generate node and base patches from Nix definitions"
  echo "  secrets     Generate new cluster secrets (creates talos/secrets.yaml)"
  echo "  configs     Generate per-node configs (talos/nodes/<node>.yaml)"
  echo "  all         Run patches, then configs (requires existing secrets)"
  echo ""
  echo "Examples:"
  echo "  talos-gen patches    # Regenerate patches from nix/nodes.nix"
  echo "  talos-gen secrets    # Create new encrypted secrets file"
  echo "  talos-gen configs    # Generate node configs using existing secrets"
}

# Generate patches from Nix
generate_patches() {
  echo "Generating patches from Nix definitions..."

  mkdir -p "$PATCHES_DIR" "$NODES_DIR"

  # Base patch - applies to all nodes
  cat > "$PATCHES_DIR/base.yaml" << EOF
machine:
  kubelet:
    image: ghcr.io/siderolabs/kubelet:v${KUBERNETES_VERSION}
  install:
    image: ghcr.io/siderolabs/installer:v${TALOS_VERSION}
    extraKernelArgs:
      - net.ifnames=0
    disk: ${INSTALL_DISK}
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
  allowSchedulingOnControlPlanes: true
EOF
  echo "  Created $PATCHES_DIR/base.yaml"

  # Per-node patches (hostname)
  for node in "${NODES[@]}"; do
    IFS=':' read -r name _ip _type <<< "$node"
    cat > "$NODES_DIR/$name.yaml" << EOF
machine:
  network:
    hostname: $name
EOF
    echo "  Created $NODES_DIR/$name.yaml"
  done

  echo "Patches generated successfully."
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

  mkdir -p "$NODES_DIR"

  # Generate per-node configs with all patches baked in
  for node in "${NODES[@]}"; do
    IFS=':' read -r name _ip type <<< "$node"

    echo "Generating config for $name ($type)..."
    talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
      --with-secrets "$SECRETS_FILE" \
      --config-patch "@$PATCHES_DIR/base.yaml" \
      --config-patch "@$NODES_DIR/$name.yaml" \
      --output-types "$type" \
      -o "$NODES_DIR/$name.yaml" \
      --force
  done

  # Generate talosconfig
  echo "Generating talosconfig..."
  talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
    --with-secrets "$SECRETS_FILE" \
    --output-types talosconfig \
    -o "$TALOS_DIR/talosconfig" \
    --force

  # Re-encrypt secrets
  echo "Re-encrypting secrets..."
  sops -e -i "$SECRETS_FILE"

  echo ""
  echo "Configs generated:"
  for node in "${NODES[@]}"; do
    IFS=':' read -r name _ip _type <<< "$node"
    echo "  $NODES_DIR/$name.yaml"
  done
  echo "  $TALOS_DIR/talosconfig"
}

# Main
if [ $# -eq 0 ]; then
  usage
  exit 1
fi

COMMAND="$1"

case "$COMMAND" in
  patches)
    generate_patches
    ;;
  secrets)
    generate_secrets
    ;;
  configs)
    generate_configs
    ;;
  all)
    generate_patches
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
