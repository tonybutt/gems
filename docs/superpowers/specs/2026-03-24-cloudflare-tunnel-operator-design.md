# Cloudflare Tunnel Operator Design

## Overview

A Kubernetes operator written in Rust that manages Cloudflare tunnels via a `CloudflareTunnel` CRD. One CR produces one tunnel, one `cloudflared` deployment, one Gateway, and the associated DNS records. Apps own their own HTTPRoutes.

## CRD: `CloudflareTunnel`

```yaml
apiVersion: tunnels.abutt.dev/v1alpha1
kind: CloudflareTunnel
metadata:
  name: gems
  namespace: cloudflared
spec:
  zone: abutt.dev
  image: cloudflare/cloudflared:2024.11.0 # optional, has default
  credentialsRef: # optional, falls back to controller default
    name: cloudflare-api-token
    namespace: cloudflare-operator
  gateway:
    gatewayClassName: cilium
    listeners:
      - hostname: blog.abutt.dev
      - hostname: auth.abutt.dev
      - hostname: "*.abutt.dev"
```

### Spec Fields

| Field                      | Required | Description                                                                      |
| -------------------------- | -------- | -------------------------------------------------------------------------------- |
| `zone`                     | yes      | Cloudflare zone name for DNS record management                                   |
| `image`                    | no       | cloudflared container image (default: latest stable)                             |
| `credentialsRef`           | no       | Secret reference for Cloudflare API token. Falls back to controller-wide default |
| `gateway.gatewayClassName` | yes      | GatewayClass to use (e.g., `cilium`)                                             |
| `gateway.listeners`        | yes      | List of hostnames the tunnel serves                                              |

### Status

```yaml
status:
  tunnelId: "abc-123-def"
  conditions:
    - type: Ready
      status: "True"
      reason: TunnelEstablished
      message: "Tunnel is active with 3 routes"
    - type: DNSReady
      status: "True"
      reason: RecordsCreated
      message: "3 DNS records created"
  routes:
    - hostname: blog.abutt.dev
      dnsRecord: "blog.abutt.dev -> abc-123-def.cfargotunnel.com"
      status: Active
    - hostname: "*.abutt.dev"
      dnsRecord: "*.abutt.dev -> abc-123-def.cfargotunnel.com"
      status: Active
```

## Architecture

### Reconcile Loop

The controller watches `CloudflareTunnel` CRs and reconciles these resources:

```
CloudflareTunnel CR
├── Secret (tunnel credentials JSON)
├── ConfigMap (cloudflared config)
├── Deployment (cloudflared pod)
└── Gateway (listeners per hostname)

+ Cloudflare API side effects:
├── Tunnel (created/deleted)
└── DNS CNAME records (per listener hostname)
```

**Reconcile steps:**

1. **Ensure tunnel exists** — check status for `tunnelId`. If missing, create via Cloudflare API, store credentials in a Secret, record ID in status.
2. **Sync DNS records** — for each listener hostname, ensure a CNAME to `<tunnel-id>.cfargotunnel.com` exists. Remove stale records for hostnames no longer in spec.
3. **Sync Gateway** — create/update Gateway with listeners matching spec. Gateway allows routes from all namespaces (`allowedRoutes: { namespaces: { from: All } }`).
4. **Sync ConfigMap** — single cloudflared ingress rule routing all traffic to the Gateway service.
5. **Sync Deployment** — `cloudflared` pod mounting the credential Secret and ConfigMap.
6. **Update status** — tunnel ID, conditions, per-route status.

### Cloudflared Configuration

The cloudflared config is intentionally simple. All routing is delegated to the Gateway API:

```yaml
tunnel: <tunnel-id>
ingress:
  - service: http://<tunnel-name>-gateway.<namespace>.svc.cluster.local:80
  - service: http_status:404
```

### Deletion

A finalizer on the CR ensures Cloudflare-side cleanup:

1. Delete DNS CNAME records via Cloudflare API
2. Delete the tunnel via Cloudflare API
3. Remove the finalizer (Kubernetes GCs owned child resources via ownerReferences)

### Error Handling

Standard requeue-with-backoff. If the Cloudflare API is unavailable, the reconciler requeues. Status conditions reflect what is healthy and what is not.

### Authentication

Two distinct types of secrets are involved:

- **API token** — used to call the Cloudflare API (create tunnels, manage DNS). Either a controller-wide default Secret (referenced via controller flags/env) or a per-CR override via `spec.credentialsRef`.
- **Tunnel credentials** — per-tunnel JSON blob returned by the Cloudflare API when creating a tunnel. Stored in a controller-owned Secret. Not user-managed.

## App Integration

Apps create their own HTTPRoutes referencing the controller-managed Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: blog
  namespace: blog
spec:
  parentRefs:
    - name: gems
      namespace: cloudflared
  hostnames:
    - blog.abutt.dev
  rules:
    - backendRefs:
        - name: blog
          port: 80
```

## Project Structure

Separate repository: `ghcr.io/tonybutt/cloudflare-tunnel-operator`

```
cloudflare-tunnel-operator/
├── flake.nix
├── flake.lock
├── rust-toolchain.toml         # Single source of truth for Rust version + components
├── Cargo.toml
├── Cargo.lock
├── nix/
│   ├── shell.nix               # Dev shell (toolchain from rust-toolchain.toml, kubectl, gh, git)
│   ├── package.nix             # buildRustPackage
│   ├── container.nix           # nix2container image
│   ├── treefmt.nix             # treefmt-nix config
│   └── git-hooks.nix           # cachix/git-hooks.nix, pkgs override, clippy enabled
├── src/
│   ├── main.rs                 # Entrypoint, controller setup
│   ├── crd.rs                  # CRD struct definitions (CustomResource derive)
│   ├── controller.rs           # Reconcile loop
│   ├── cloudflare/
│   │   ├── mod.rs
│   │   ├── client.rs           # Cloudflare API client (tunnels, DNS)
│   │   └── types.rs            # API request/response types
│   └── resources/
│       ├── mod.rs
│       ├── secret.rs           # Tunnel credential Secret builder
│       ├── configmap.rs        # cloudflared config builder
│       ├── deployment.rs       # cloudflared Deployment builder
│       └── gateway.rs          # Gateway resource builder
├── docs/
│   ├── getting-started.md      # Quick start guide
│   ├── configuration.md        # Full CRD reference, examples
│   ├── architecture.md         # How the operator works internally
│   └── troubleshooting.md      # Common issues, debugging
├── deploy/
│   ├── crd.yaml                # Generated CRD manifest
│   └── kustomization.yaml      # Controller deployment + RBAC
└── Dockerfile                  # Fallback (primary build via nix)
```

## Nix Flake

### Inputs

- `nixpkgs`
- `oxalica/rust-overlay` — Rust toolchain from `rust-toolchain.toml`
- `nix-community/nix2container` — container image building
- `cachix/git-hooks.nix` — pre-commit hooks with `pkgs` override, clippy enabled
- `numtide/treefmt-nix` — code formatting

### Dev Shell

Rust toolchain derived from `rust-toolchain.toml`. Additional tools: `kubectl`, `gh`, `git`. Pre-commit hooks via git-hooks.nix with clippy.

### Build

`buildRustPackage` using the oxalica-provided toolchain.

### Container

`nix2container` — minimal image containing only the operator binary. Published to `ghcr.io/tonybutt/cloudflare-tunnel-operator`.

## Rust Dependencies

| Crate                            | Purpose                                |
| -------------------------------- | -------------------------------------- |
| `kube` (client, runtime, derive) | K8s client, Controller, CustomResource |
| `k8s-openapi`                    | Kubernetes API types                   |
| `schemars`                       | JSON Schema for CRD generation         |
| `serde` / `serde_json`           | Serialization                          |
| `tokio`                          | Async runtime                          |
| `reqwest`                        | HTTP client for Cloudflare API         |
| `thiserror`                      | Error types                            |
| `tracing` / `tracing-subscriber` | Structured logging                     |

## Documentation

### README

The README serves as the primary install guide and must cover:

- **Overview** — what the operator does, in one paragraph
- **Prerequisites** — Kubernetes cluster, Cloudflare account, API token with required permissions (Zone:DNS:Edit, Account:Cloudflare Tunnel:Edit)
- **Installation** — step-by-step:
  1. Apply the CRD
  2. Create the API token Secret
  3. Deploy the controller (with example manifests)
  4. Create a `CloudflareTunnel` CR (with a complete working example)
  5. Create an HTTPRoute in the app namespace (with example)
- **Configuration reference** — full spec field documentation with defaults
- **Status fields** — what each condition means
- **Uninstall** — clean removal steps (finalizers handle Cloudflare cleanup)

### Docs Site

A `docs/` directory in the repo root with markdown files, structured for potential static site hosting:

```
docs/
├── getting-started.md    # Quick start guide
├── configuration.md      # Full CRD reference, examples
├── architecture.md       # How the operator works internally
└── troubleshooting.md    # Common issues, debugging
```

These docs expand on the README with deeper explanations, multiple examples, and operational guidance.

## Deployment into gems Cluster

New entry in the gems repo: `apps/cloudflare-tunnel-operator/`

- Controller Deployment (GHCR image, single replica)
- ServiceAccount + ClusterRole + ClusterRoleBinding
- CRD manifest
- Default API token Secret (SOPS-encrypted)

Existing `apps/cloudflared/` and `apps/valentines-tunnel/` are replaced by `CloudflareTunnel` CRs.

## RBAC

The controller's ClusterRole needs:

- `tunnels.abutt.dev/cloudflaretunnels` — get, list, watch, update (status), patch
- `apps/deployments` — get, list, watch, create, update, delete
- `core/secrets` — get, list, watch, create, update, delete
- `core/configmaps` — get, list, watch, create, update, delete
- `gateway.networking.k8s.io/gateways` — get, list, watch, create, update, delete
- `coordination.k8s.io/leases` — get, list, watch, create, update (leader election)
- `core/events` — create, patch (event recording)
