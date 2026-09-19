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
  echo "  join-config <node>  Emit talos/ca.crt and secrets/<node>-bootstrap-kubeconfig.age"
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

    role_patches=()
    if [ "$type" = "controlplane" ]; then
      role_patches=(
        --config-patch "@$PATCHES_DIR/controlplane-delete-node.yaml"
        --config-patch "@$PATCHES_DIR/controlplane.yaml"
      )
    fi

    echo "Generating config for $name ($type)..."
    talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
      --with-secrets "$SECRETS_FILE" \
      --install-image "factory.talos.dev/metal-installer/$TALOS_SCHEMATIC:v$TALOS_VERSION" \
      --kubernetes-version "$KUBERNETES_VERSION" \
      --config-patch "@$PATCHES_DIR/base.yaml" \
      "${role_patches[@]}" \
      --config-patch "@$NODES_DIR/$name.yaml" \
      --output-types "$type" \
      -o "$GEN_DIR/$name.yaml" \
      --force
  done

  # Generate talosconfig
  echo "Generating talosconfig..."
  talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
    --with-secrets "$SECRETS_FILE" \
    --install-image "factory.talos.dev/metal-installer/$TALOS_SCHEMATIC:v$TALOS_VERSION" \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --output-types talosconfig \
    -o "$GEN_DIR/talosconfig" \
    --force

  # Add endpoints to talosconfig (control plane IPs)
  echo "Adding endpoints to talosconfig..."
  ENDPOINTS=()
  for node in "${NODES[@]}"; do
    IFS=':' read -r _name ip type <<< "$node"
    if [ "$type" = "controlplane" ]; then
      ENDPOINTS+=("$ip")
    fi
  done
  talosctl config endpoint --talosconfig "$GEN_DIR/talosconfig" "${ENDPOINTS[@]}"

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

generate_join_config() {
  local node="$1"
  local secrets_file="$TALOS_DIR/secrets.yaml"
  local recipients_file="$REPO_ROOT/secrets/secrets.nix"
  local out_file="$REPO_ROOT/secrets/${node}-bootstrap-kubeconfig.age"
  local ca_file="$TALOS_DIR/ca.crt"

  if [ ! -f "$secrets_file" ]; then
    echo "Error: $secrets_file not found. Run 'talos-gen secrets' first."
    return 1
  fi
  if [ ! -f "$recipients_file" ]; then
    echo "Error: $recipients_file not found."
    return 1
  fi

  local plain
  plain="$(mktemp)"
  trap 'rm -f "$plain"' RETURN
  sops -d "$secrets_file" > "$plain"

  local ca_b64 token
  ca_b64="$(yq '.certs.k8s.crt' "$plain")"
  token="$(yq '.secrets.bootstraptoken' "$plain")"

  echo "$ca_b64" | base64 -d > "$ca_file"
  openssl x509 -in "$ca_file" -noout -subject

  local -a age_args=()
  local recipient
  while IFS= read -r recipient; do
    age_args+=(-r "$recipient")
  done < <(nix eval --json -f "$recipients_file" "\"${node}-bootstrap-kubeconfig.age\".publicKeys" | jq -r '.[]')

  age "${age_args[@]}" -o "$out_file" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: $CLUSTER_NAME
    cluster:
      server: https://127.0.0.1:7445
      certificate-authority-data: $ca_b64
users:
  - name: tls-bootstrap-token-user
    user:
      token: $token
contexts:
  - name: tls-bootstrap-token-user@$CLUSTER_NAME
    context:
      cluster: $CLUSTER_NAME
      user: tls-bootstrap-token-user
current-context: tls-bootstrap-token-user@$CLUSTER_NAME
EOF

  echo "Wrote $ca_file and $out_file"
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
  join-config)
    if [ $# -lt 2 ]; then
      echo "Usage: talos-gen join-config <node>"
      exit 1
    fi
    generate_join_config "$2"
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
