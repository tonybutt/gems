# Gems Homelab Cluster

Talos Kubernetes cluster managed with Nix and Flux.

## Prerequisites

- Nix with flakes enabled
- direnv (optional, for automatic shell)

## Quick Start

```bash
# Enter dev shell
nix develop

# Or with direnv
direnv allow
```

## Directory Structure

```
gems/
├── apps/                    # Application workloads
├── infrastructure/          # Infrastructure components
│   └── controllers/
│       └── cilium/          # CNI (rendered from helm)
├── clusters/gems/           # Flux configuration
│   └── flux-system/
├── talos/                   # Talos OS configuration
│   ├── patches/             # Shared patches (base.yaml)
│   ├── nodes/               # Per-node patches (hostname)
│   ├── gen/                 # Generated configs (gitignored)
│   └── secrets.yaml         # SOPS encrypted secrets
└── scripts/                 # Shell scripts
```

## Bootstrap (Fresh Cluster)

### 1. Prepare Talos ISO

```bash
# Download ISO with iSCSI extensions for OpenEBS
talos-iso --latest
# Flash to USB and boot target machines
```

### 2. Generate Secrets and Configs

```bash
# Generate and encrypt cluster secrets (first time only)
talos-gen secrets

# Generate node configs
talos-gen configs
```

### 3. Apply First Control Plane

```bash
# Apply config to first control plane (insecure - no certs yet)
apply-gem-master-0 --insecure

# Bootstrap the cluster
talosctl bootstrap --talosconfig talos/gen/talosconfig -n 192.168.86.250
```

### 4. Install CNI

```bash
# Get kubeconfig
kubeconfig

# Apply Cilium CNI (cluster will become healthy)
kubectl apply -f infrastructure/controllers/cilium/manifests/cilium.yaml
```

### 5. Apply Remaining Nodes

```bash
# Apply other control planes
apply-gem-master-1
apply-gem-master-2

# Apply workers
apply-gem-worker-0
apply-gem-worker-1
```

### 6. Install Flux

```bash
# Apply Flux to take over GitOps management
kubectl apply -k clusters/gems/flux-system/
```

## Day-2 Operations

### Applying Configuration Changes

Edit patches in `talos/patches/` or `talos/nodes/`, then:

```bash
talos-gen configs
apply-<node-name>
```

### Upgrading Talos

```bash
upgrade-<node-name> <version>
# Example: upgrade-gem-master-0 1.12.1
```

### Upgrading Kubernetes

```bash
talosctl -n 192.168.86.250 upgrade-k8s --to <version>
```

### Rendering Helm Charts

```bash
# Render specific chart
render-helm infrastructure/controllers/cilium/helm-values.yaml

# Render all charts
render-helm --all
```

### Re-encrypting SOPS Secrets

```bash
sops-reencrypt
```

## Available Commands

Run `menu` in the dev shell to see all commands:

- `apply-<node>` - Apply config to node (use `--insecure` for first apply)
- `upgrade-<node> <version>` - Upgrade Talos on node
- `talos-gen secrets` - Generate new cluster secrets
- `talos-gen configs` - Generate node configs
- `talos-iso` - Download Talos ISO with extensions
- `render-helm` - Render helm charts
- `kubeconfig` - Get kubeconfig from cluster
- `nix fmt` - Format all files

## Nodes

| Name         | IP             | Type         |
| ------------ | -------------- | ------------ |
| gem-master-0 | 192.168.86.250 | controlplane |
| gem-master-1 | 192.168.86.21  | controlplane |
| gem-master-2 | 192.168.86.31  | controlplane |
| gem-worker-0 | 192.168.86.25  | worker       |
| gem-worker-1 | 192.168.86.33  | worker       |
