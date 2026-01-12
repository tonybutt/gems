#!/usr/bin/env bash
# Bootstrap a fresh Gems cluster
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

TALOS_DIR="talos"
GEN_DIR="$TALOS_DIR/gen"
CLUSTER_DIR="clusters/gems"
FIRST_MASTER_IP="192.168.86.250"

usage() {
  echo "Usage: bootstrap-gems [options]"
  echo ""
  echo "Bootstrap a fresh Gems cluster from scratch."
  echo ""
  echo "Options:"
  echo "  --skip-secrets    Skip secret generation (use existing)"
  echo "  --skip-configs    Skip config generation (use existing)"
  echo "  -h, --help        Show this help"
  echo ""
  echo "Prerequisites:"
  echo "  - Talos ISO flashed and machines booted"
  echo "  - First control plane reachable at $FIRST_MASTER_IP"
}

SKIP_SECRETS=false
SKIP_CONFIGS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-secrets)
      SKIP_SECRETS=true
      shift
      ;;
    --skip-configs)
      SKIP_CONFIGS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

echo "=== Gems Cluster Bootstrap ==="
echo ""

# Step 1: Generate secrets
if [ "$SKIP_SECRETS" = false ] && [ ! -f "$TALOS_DIR/secrets.yaml" ]; then
  echo "Step 1: Generating cluster secrets..."
  talos-gen secrets
else
  echo "Step 1: Skipping secret generation (exists or --skip-secrets)"
fi

# Step 2: Generate configs
if [ "$SKIP_CONFIGS" = false ]; then
  echo ""
  echo "Step 2: Generating node configs..."
  talos-gen configs
else
  echo ""
  echo "Step 2: Skipping config generation (--skip-configs)"
fi

# Step 3: Apply first control plane
echo ""
echo "Step 3: Applying config to first control plane ($FIRST_MASTER_IP)..."
talosctl apply-config \
  --talosconfig "$GEN_DIR/talosconfig" \
  -n "$FIRST_MASTER_IP" \
  --file "$GEN_DIR/gem-master-0.yaml" \
  --insecure

# Step 4: Bootstrap the cluster
echo ""
echo "Step 4: Bootstrapping cluster..."
echo "Waiting for API to be ready..."
sleep 10

talosctl bootstrap \
  --talosconfig "$GEN_DIR/talosconfig" \
  -n "$FIRST_MASTER_IP"

# Step 5: Wait for kubeconfig and install CNI
echo ""
echo "Step 5: Getting kubeconfig and installing CNI..."
echo "Waiting for Kubernetes API..."
sleep 30

talosctl kubeconfig \
  --talosconfig "$GEN_DIR/talosconfig" \
  -n "$FIRST_MASTER_IP" \
  --force

echo "Applying Cilium CNI..."
kubectl apply -f infrastructure/controllers/cilium/manifests/cilium.yaml

# Step 6: Wait for cluster health
echo ""
echo "Step 6: Waiting for cluster to become healthy..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s || true

# Step 7: Apply remaining control planes
echo ""
echo "Step 7: Applying remaining control plane nodes..."
for node in gem-master-1 gem-master-2; do
  if [ -f "$GEN_DIR/$node.yaml" ]; then
    echo "Applying config to $node..."
    # Extract IP from node name (requires nodes.nix format)
    talosctl apply-config \
      --talosconfig "$GEN_DIR/talosconfig" \
      --file "$GEN_DIR/$node.yaml" \
      -n "$FIRST_MASTER_IP"
  fi
done

# Step 8: Apply workers
echo ""
echo "Step 8: Applying worker nodes..."
for node in gem-worker-0 gem-worker-1; do
  if [ -f "$GEN_DIR/$node.yaml" ]; then
    echo "Applying config to $node..."
    talosctl apply-config \
      --talosconfig "$GEN_DIR/talosconfig" \
      --file "$GEN_DIR/$node.yaml" \
      -n "$FIRST_MASTER_IP"
  fi
done

# Step 9: Install Flux
echo ""
echo "Step 9: Installing Flux..."
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

# Create SOPS age secret for Flux
AGE_KEY_FILE="$CLUSTER_DIR/flux-system/age.agekey"
if [ -f "$AGE_KEY_FILE" ]; then
  echo "Creating SOPS age secret..."
  sops -d "$AGE_KEY_FILE" | kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo "Applying Flux components..."
kubectl apply -k "$CLUSTER_DIR/flux-system/"

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Next steps:"
echo "  1. Verify all nodes are ready: kubectl get nodes"
echo "  2. Check Flux status: flux get all"
echo "  3. Push changes to git for Flux to sync"
