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
  echo "  configs     Generate full talosctl configs (controlplane.yaml, worker.yaml)"
  echo "  all         Run patches, then configs (requires existing secrets)"
  echo ""
  echo "Examples:"
  echo "  talos-gen patches    # Regenerate patches from nix/nodes.nix"
  echo "  talos-gen secrets    # Create new encrypted secrets file"
  echo "  talos-gen configs    # Generate configs using existing secrets"
}

# Generate node patches from Nix
generate_patches() {
  echo "Generating patches from Nix definitions..."

  mkdir -p "$NODES_DIR" "$PATCHES_DIR"

  # Generate base patches
  cat > "$PATCHES_DIR/base.yaml" << 'EOF'
machine:
  kubelet:
    image: ghcr.io/siderolabs/kubelet:v${KUBERNETES_VERSION}
  install:
    image: ghcr.io/siderolabs/installer:v${TALOS_VERSION}
    extraKernelArgs:
      - net.ifnames=0
    disk: ${INSTALL_DISK}
cluster:
  apiServer:
    image: registry.k8s.io/kube-apiserver:v${KUBERNETES_VERSION}
  controllerManager:
    image: registry.k8s.io/kube-controller-manager:v${KUBERNETES_VERSION}
  scheduler:
    image: registry.k8s.io/kube-scheduler:v${KUBERNETES_VERSION}
  network:
    cni:
      name: none
  proxy:
    disabled: true
  allowSchedulingOnControlPlanes: true
EOF

  # Substitute variables
  sed -i "s/\${KUBERNETES_VERSION}/$KUBERNETES_VERSION/g" "$PATCHES_DIR/base.yaml"
  sed -i "s/\${TALOS_VERSION}/$TALOS_VERSION/g" "$PATCHES_DIR/base.yaml"
  sed -i "s|\${INSTALL_DISK}|$INSTALL_DISK|g" "$PATCHES_DIR/base.yaml"

  echo "  Created $PATCHES_DIR/base.yaml"

  # Generate per-node patches
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

  # Build patch args for first control plane node
  FIRST_CP=""
  PATCH_ARGS=""
  for node in "${NODES[@]}"; do
    IFS=':' read -r name _ip type <<< "$node"
    if [ "$type" = "controlplane" ] && [ -z "$FIRST_CP" ]; then
      FIRST_CP="$name"
      PATCH_ARGS="@$NODES_DIR/$name.yaml,@$PATCHES_DIR/base.yaml"
      break
    fi
  done

  # Generate configs
  talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
    --with-secrets "$SECRETS_FILE" \
    --config-patch "$PATCH_ARGS" \
    -o "$TALOS_DIR" \
    --force

  # Re-encrypt secrets
  echo "Re-encrypting secrets..."
  sops -e -i "$SECRETS_FILE"

  echo "Configs generated:"
  echo "  $TALOS_DIR/controlplane.yaml"
  echo "  $TALOS_DIR/worker.yaml"
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
