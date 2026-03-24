# Cloudflare Tunnel Operator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Kubernetes operator in Rust that manages Cloudflare tunnels, DNS records, cloudflared deployments, and Gateways via a `CloudflareTunnel` CRD.

**Architecture:** A single-binary controller using `kube-rs` watches `CloudflareTunnel` CRs and reconciles child resources (Secret, ConfigMap, Deployment, Gateway) plus Cloudflare API side effects (tunnel creation, DNS CNAMEs). Apps own their own HTTPRoutes. Uses a finalizer for cleanup.

**Tech Stack:** Rust (kube-rs 3.1.0, k8s-openapi 0.27.1, reqwest, tokio, tracing), Nix (oxalica/rust-overlay, buildRustPackage, nix2container, treefmt-nix, cachix/git-hooks.nix), e2e tests with kind.

**Spec:** `docs/superpowers/specs/2026-03-24-cloudflare-tunnel-operator-design.md`

---

## File Structure

```
cloudflare-tunnel-operator/
├── flake.nix                       # Nix flake: inputs, outputs, devShell, packages, container
├── nix/
│   ├── shell.nix                   # Dev shell: rust toolchain, kubectl, gh, git, kind
│   ├── package.nix                 # buildRustPackage definition
│   ├── container.nix               # nix2container image
│   ├── treefmt.nix                 # treefmt-nix: rustfmt, nixfmt, prettier
│   └── git-hooks.nix               # cachix/git-hooks.nix: clippy, treefmt
├── rust-toolchain.toml             # Rust stable + clippy, rustfmt components
├── Cargo.toml                      # Workspace root with dependencies
├── src/
│   ├── main.rs                     # Entrypoint: parse args, build client, run controller
│   ├── crd.rs                      # CloudflareTunnel CRD types (CustomResource derive)
│   ├── controller.rs               # Reconcile loop, finalizer, error policy
│   ├── cloudflare/
│   │   ├── mod.rs                  # Re-exports
│   │   ├── client.rs               # CloudflareClient: tunnels, DNS, zones
│   │   └── types.rs                # API request/response types
│   └── resources/
│       ├── mod.rs                   # Re-exports
│       ├── secret.rs               # Tunnel credential Secret builder
│       ├── configmap.rs            # cloudflared ConfigMap builder
│       ├── deployment.rs           # cloudflared Deployment builder
│       └── gateway.rs              # Gateway resource builder (DynamicObject)
├── tests/
│   └── e2e/
│       ├── main.rs                 # e2e test harness: kind cluster setup/teardown
│       └── tunnel_lifecycle.rs     # Full CR create/update/delete tests
├── deploy/
│   ├── crd.yaml                    # Generated CRD manifest
│   ├── rbac.yaml                   # ServiceAccount, ClusterRole, ClusterRoleBinding
│   └── deployment.yaml             # Controller Deployment
├── docs/
│   ├── getting-started.md
│   ├── configuration.md
│   ├── architecture.md
│   └── troubleshooting.md
├── README.md
├── Dockerfile
└── .github/
    └── workflows/
        └── ci.yml                  # Build, test, push container
```

---

## Task 1: Repository Bootstrap

**Files:**

- Create: `README.md`
- Create: `rust-toolchain.toml`
- Create: `Cargo.toml`
- Create: `flake.nix`
- Create: `nix/shell.nix`
- Create: `nix/package.nix`
- Create: `nix/container.nix`
- Create: `nix/treefmt.nix`
- Create: `nix/git-hooks.nix`
- Create: `src/main.rs`
- Create: `.envrc`

- [ ] **Step 1: Create the GitHub repository**

```bash
gh repo create tonybutt/cloudflare-tunnel-operator --public --clone
cd cloudflare-tunnel-operator
```

- [ ] **Step 2: Create `rust-toolchain.toml`**

```toml
[toolchain]
channel = "stable"
components = ["clippy", "rustfmt"]
```

- [ ] **Step 3: Create `Cargo.toml`**

```toml
[package]
name = "cloudflare-tunnel-operator"
version = "0.1.0"
edition = "2024"

[dependencies]
kube = { version = "3.1", features = ["runtime", "client", "derive"] }
k8s-openapi = { version = "0.27", features = ["latest"] }
schemars = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
futures = "0.3"
reqwest = { version = "0.12", features = ["json"] }
thiserror = "2"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
base64 = "0.22"
rand = "0.9"
anyhow = "1"
chrono = { version = "0.4", features = ["serde"] }
async-trait = "0.1"

[dev-dependencies]
kube = { version = "3.1", features = ["runtime", "client", "derive"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread", "process"] }
async-trait = "0.1"
```

- [ ] **Step 4: Create `src/main.rs` with a minimal placeholder**

```rust
fn main() {
    println!("cloudflare-tunnel-operator");
}
```

- [ ] **Step 5: Create `flake.nix`**

```nix
{
  description = "Cloudflare Tunnel Operator for Kubernetes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      nix2container,
      treefmt-nix,
      git-hooks,
    }:
    let
      system = "x86_64-linux";
      overlays = [ rust-overlay.overlays.default ];
      pkgs = import nixpkgs { inherit system overlays; };

      rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

      package = import ./nix/package.nix { inherit pkgs rustToolchain; };
      container = import ./nix/container.nix {
        inherit pkgs package;
        nix2container = nix2container.packages.${system}.nix2container;
      };
      treefmt = import ./nix/treefmt.nix { inherit pkgs treefmt-nix; };
      pre-commit = import ./nix/git-hooks.nix {
        inherit system pkgs git-hooks treefmt rustToolchain;
      };
    in
    {
      formatter.${system} = treefmt.config.build.wrapper;

      packages.${system} = {
        default = package;
        container = container;
      };

      devShells.${system}.default = import ./nix/shell.nix {
        inherit pkgs rustToolchain;
        git-hooks = pre-commit;
      };

      checks.${system} = {
        formatting = treefmt.config.build.check self;
        pre-commit = pre-commit;
      };
    };
}
```

- [ ] **Step 6: Create `nix/shell.nix`**

```nix
{
  pkgs,
  rustToolchain,
  git-hooks,
}:

pkgs.mkShell {
  name = "cloudflare-tunnel-operator";

  packages = with pkgs; [
    rustToolchain
    kubectl
    gh
    git
    kind
  ];

  shellHook = ''
    ${git-hooks.shellHook}
  '';
}
```

- [ ] **Step 7: Create `nix/package.nix`**

```nix
{
  pkgs,
  rustToolchain,
}:

pkgs.rustPlatform.buildRustPackage {
  pname = "cloudflare-tunnel-operator";
  version = "0.1.0";
  src = ../.;
  cargoLock.lockFile = ../Cargo.lock;

  nativeBuildInputs = with pkgs; [
    rustToolchain
    pkg-config
  ];

  buildInputs = with pkgs; [
    openssl
  ];
}
```

- [ ] **Step 8: Create `nix/container.nix`**

```nix
{
  pkgs,
  package,
  nix2container,
}:

nix2container.buildImage {
  name = "ghcr.io/tonybutt/cloudflare-tunnel-operator";
  tag = "latest";

  config = {
    entrypoint = [ "${package}/bin/cloudflare-tunnel-operator" ];
  };

  layers = [
    (nix2container.buildLayer {
      deps = [ package ];
    })
  ];
}
```

- [ ] **Step 9: Create `nix/treefmt.nix`**

```nix
{ pkgs, treefmt-nix }:

treefmt-nix.lib.evalModule pkgs {
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    rustfmt.enable = true;
    prettier = {
      enable = true;
      includes = [
        "*.md"
        "*.json"
        "*.yaml"
        "*.yml"
      ];
    };
  };
}
```

- [ ] **Step 10: Create `nix/git-hooks.nix`**

```nix
{
  system,
  pkgs,
  git-hooks,
  treefmt,
  rustToolchain,
}:

git-hooks.lib.${system}.run {
  src = ../.;
  hooks = {
    treefmt = {
      enable = true;
      package = treefmt.config.build.wrapper;
      entry = "${treefmt.config.build.wrapper}/bin/treefmt --fail-on-change";
    };
    clippy = {
      enable = true;
      packageOverrides = {
        cargo = rustToolchain;
        clippy = rustToolchain;
      };
    };
    commitizen.enable = true;
  };
}
```

- [ ] **Step 11: Create `.envrc`**

```
use flake
```

- [ ] **Step 12: Verify build**

```bash
cargo build
nix build
nix flake check
```

Expected: all succeed.

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "feat: bootstrap project with nix flake and cargo skeleton"
```

---

## Task 2: CRD Types

**Files:**

- Create: `src/crd.rs`
- Modify: `src/main.rs`

- [ ] **Step 1: Create `src/crd.rs` with the CRD struct definitions**

```rust
use k8s_openapi::apimachinery::pkg::apis::meta::v1::Condition;
use kube::CustomResource;
use schemars::{JsonSchema, json_schema};
use serde::{Deserialize, Serialize};

#[derive(CustomResource, Serialize, Deserialize, Default, Debug, Clone, JsonSchema)]
#[kube(
    group = "tunnels.abutt.dev",
    version = "v1alpha1",
    kind = "CloudflareTunnel",
    plural = "cloudflaretunnels",
    namespaced,
    status = "CloudflareTunnelStatus",
    shortname = "cft",
    printcolumn(
        name = "Tunnel ID",
        type_ = "string",
        json_path = ".status.tunnelId"
    ),
    printcolumn(
        name = "Ready",
        type_ = "string",
        json_path = ".status.conditions[?(@.type=='Ready')].status"
    ),
)]
pub struct CloudflareTunnelSpec {
    /// Cloudflare zone name for DNS record management.
    pub zone: String,

    /// Gateway configuration.
    pub gateway: GatewaySpec,

    /// cloudflared container image override.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,

    /// Reference to a Secret containing a Cloudflare API token.
    /// Falls back to the controller-wide default if not set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credentials_ref: Option<SecretRef>,
}

#[derive(Serialize, Deserialize, Default, Debug, Clone, JsonSchema)]
pub struct GatewaySpec {
    /// GatewayClass to use (e.g., "cilium").
    pub gateway_class_name: String,

    /// Hostnames the tunnel serves. Each gets a DNS record and Gateway listener.
    pub listeners: Vec<Listener>,
}

#[derive(Serialize, Deserialize, Default, Debug, Clone, JsonSchema)]
pub struct Listener {
    /// Hostname for this listener (e.g., "blog.abutt.dev" or "*.abutt.dev").
    pub hostname: String,
}

#[derive(Serialize, Deserialize, Default, Debug, Clone, JsonSchema)]
pub struct SecretRef {
    /// Name of the Secret.
    pub name: String,

    /// Namespace of the Secret.
    pub namespace: String,
}

#[derive(Serialize, Deserialize, Default, Debug, Clone, JsonSchema)]
pub struct CloudflareTunnelStatus {
    /// The Cloudflare tunnel ID.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tunnel_id: Option<String>,

    /// Standard Kubernetes conditions.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[schemars(schema_with = "conditions")]
    pub conditions: Vec<Condition>,

    /// Per-route status.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub routes: Vec<RouteStatus>,
}

#[derive(Serialize, Deserialize, Default, Debug, Clone, JsonSchema)]
pub struct RouteStatus {
    pub hostname: String,
    pub dns_record: String,
    pub status: String,
}

fn conditions(_: &mut schemars::generate::SchemaGenerator) -> schemars::Schema {
    json_schema!({
        "type": "array",
        "x-kubernetes-list-type": "map",
        "x-kubernetes-list-map-keys": ["type"],
        "items": {
            "type": "object",
            "properties": {
                "lastTransitionTime": { "format": "date-time", "type": "string" },
                "message": { "type": "string" },
                "observedGeneration": { "type": "integer", "format": "int64", "default": 0 },
                "reason": { "type": "string" },
                "status": { "type": "string" },
                "type": { "type": "string" }
            },
            "required": ["lastTransitionTime", "message", "reason", "status", "type"],
        },
    })
}
```

- [ ] **Step 2: Update `src/main.rs` to reference the crd module and print the CRD YAML**

```rust
use kube::CustomResourceExt;

mod crd;

fn main() {
    // Print CRD YAML for generation
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s.as_str()) == Some("crd") {
        print!(
            "{}",
            serde_json::to_string_pretty(&crd::CloudflareTunnel::crd()).unwrap()
        );
        return;
    }

    println!("cloudflare-tunnel-operator");
}
```

- [ ] **Step 3: Verify it compiles**

```bash
cargo build
```

Expected: success.

- [ ] **Step 4: Generate and inspect the CRD**

```bash
cargo run -- crd | head -50
```

Expected: valid JSON CRD output with group `tunnels.abutt.dev`.

- [ ] **Step 5: Commit**

```bash
git add src/crd.rs src/main.rs
git commit -m "feat: define CloudflareTunnel CRD types"
```

---

## Task 3: Cloudflare API Client

**Files:**

- Create: `src/cloudflare/mod.rs`
- Create: `src/cloudflare/types.rs`
- Create: `src/cloudflare/client.rs`

- [ ] **Step 1: Create `src/cloudflare/types.rs` with API request/response types**

```rust
use serde::{Deserialize, Serialize};

/// Generic Cloudflare API response wrapper.
#[derive(Debug, Deserialize)]
pub struct CfResponse<T> {
    pub result: T,
    pub success: bool,
}

/// Generic Cloudflare API list response wrapper.
#[derive(Debug, Deserialize)]
pub struct CfListResponse<T> {
    pub result: Vec<T>,
    pub success: bool,
}

// --- Zones ---

#[derive(Debug, Deserialize)]
pub struct Zone {
    pub id: String,
    pub name: String,
    pub account: Account,
}

#[derive(Debug, Deserialize)]
pub struct Account {
    pub id: String,
}

// --- Tunnels ---

#[derive(Debug, Serialize)]
pub struct CreateTunnelRequest {
    pub name: String,
    pub tunnel_secret: String,
    pub config_src: String,
}

#[derive(Debug, Deserialize)]
pub struct Tunnel {
    pub id: String,
    pub name: String,
}

// --- DNS ---

#[derive(Debug, Serialize)]
pub struct CreateDnsRecordRequest {
    #[serde(rename = "type")]
    pub record_type: String,
    pub name: String,
    pub content: String,
    pub proxied: bool,
    pub comment: String,
    pub ttl: u32,
}

#[derive(Debug, Deserialize)]
pub struct DnsRecord {
    pub id: String,
    pub name: String,
    pub content: String,
    #[serde(rename = "type")]
    pub record_type: String,
}
```

- [ ] **Step 2: Create `src/cloudflare/client.rs` with the API client**

```rust
use crate::cloudflare::types::*;
use base64::Engine;
use rand::Rng;

const CF_API_BASE: &str = "https://api.cloudflare.com/client/v4";
const TUNNEL_COMMENT: &str = "Managed by cloudflare-tunnel-operator";

#[derive(Debug, thiserror::Error)]
pub enum CloudflareError {
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("API error: {0}")]
    Api(String),
}

#[derive(Clone)]
pub struct CloudflareClient {
    http: reqwest::Client,
    token: String,
}

impl CloudflareClient {
    pub fn new(token: String) -> Self {
        Self {
            http: reqwest::Client::new(),
            token,
        }
    }

    fn auth_header(&self) -> String {
        format!("Bearer {}", self.token)
    }

    // --- Zones ---

    pub async fn get_zone_id(&self, zone_name: &str) -> Result<(String, String), CloudflareError> {
        let resp: CfListResponse<Zone> = self
            .http
            .get(format!("{CF_API_BASE}/zones"))
            .header("Authorization", self.auth_header())
            .query(&[("name", zone_name)])
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;

        let zone = resp
            .result
            .into_iter()
            .next()
            .ok_or_else(|| CloudflareError::Api(format!("zone '{}' not found", zone_name)))?;

        Ok((zone.id, zone.account.id))
    }

    // --- Tunnels ---

    pub async fn create_tunnel(
        &self,
        account_id: &str,
        name: &str,
    ) -> Result<(Tunnel, String), CloudflareError> {
        let secret_bytes: [u8; 32] = rand::rng().random();
        let tunnel_secret = base64::engine::general_purpose::STANDARD.encode(secret_bytes);

        let resp: CfResponse<Tunnel> = self
            .http
            .post(format!("{CF_API_BASE}/accounts/{account_id}/cfd_tunnel"))
            .header("Authorization", self.auth_header())
            .json(&CreateTunnelRequest {
                name: name.to_string(),
                tunnel_secret: tunnel_secret.clone(),
                config_src: "local".to_string(),
            })
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;

        // Build the credentials JSON that cloudflared expects
        let creds = serde_json::json!({
            "AccountTag": account_id,
            "TunnelID": resp.result.id,
            "TunnelSecret": tunnel_secret,
        });

        Ok((resp.result, creds.to_string()))
    }

    pub async fn delete_tunnel(
        &self,
        account_id: &str,
        tunnel_id: &str,
    ) -> Result<(), CloudflareError> {
        // Clean up connections first
        self.http
            .delete(format!(
                "{CF_API_BASE}/accounts/{account_id}/cfd_tunnel/{tunnel_id}/connections"
            ))
            .header("Authorization", self.auth_header())
            .send()
            .await?
            .error_for_status()?;

        self.http
            .delete(format!(
                "{CF_API_BASE}/accounts/{account_id}/cfd_tunnel/{tunnel_id}"
            ))
            .header("Authorization", self.auth_header())
            .json(&serde_json::json!({}))
            .send()
            .await?
            .error_for_status()?;

        Ok(())
    }

    pub async fn get_tunnel(
        &self,
        account_id: &str,
        tunnel_id: &str,
    ) -> Result<Option<Tunnel>, CloudflareError> {
        let resp = self
            .http
            .get(format!(
                "{CF_API_BASE}/accounts/{account_id}/cfd_tunnel/{tunnel_id}"
            ))
            .header("Authorization", self.auth_header())
            .send()
            .await?;

        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }

        let body: CfResponse<Tunnel> = resp.error_for_status()?.json().await?;
        Ok(Some(body.result))
    }

    // --- DNS ---

    pub async fn ensure_dns_cname(
        &self,
        zone_id: &str,
        hostname: &str,
        tunnel_id: &str,
    ) -> Result<DnsRecord, CloudflareError> {
        let target = format!("{tunnel_id}.cfargotunnel.com");

        // Check if record already exists
        let existing: CfListResponse<DnsRecord> = self
            .http
            .get(format!("{CF_API_BASE}/zones/{zone_id}/dns_records"))
            .header("Authorization", self.auth_header())
            .query(&[("type", "CNAME"), ("name", hostname)])
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;

        if let Some(record) = existing.result.into_iter().next() {
            if record.content == target {
                return Ok(record);
            }
            // Delete stale record before creating new one
            self.delete_dns_record(zone_id, &record.id).await?;
        }

        let resp: CfResponse<DnsRecord> = self
            .http
            .post(format!("{CF_API_BASE}/zones/{zone_id}/dns_records"))
            .header("Authorization", self.auth_header())
            .json(&CreateDnsRecordRequest {
                record_type: "CNAME".to_string(),
                name: hostname.to_string(),
                content: target,
                proxied: true,
                comment: TUNNEL_COMMENT.to_string(),
                ttl: 1,
            })
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;

        Ok(resp.result)
    }

    pub async fn delete_dns_record(
        &self,
        zone_id: &str,
        record_id: &str,
    ) -> Result<(), CloudflareError> {
        self.http
            .delete(format!(
                "{CF_API_BASE}/zones/{zone_id}/dns_records/{record_id}"
            ))
            .header("Authorization", self.auth_header())
            .send()
            .await?
            .error_for_status()?;

        Ok(())
    }

    pub async fn list_dns_records_by_comment(
        &self,
        zone_id: &str,
    ) -> Result<Vec<DnsRecord>, CloudflareError> {
        let resp: CfListResponse<DnsRecord> = self
            .http
            .get(format!("{CF_API_BASE}/zones/{zone_id}/dns_records"))
            .header("Authorization", self.auth_header())
            .query(&[
                ("type", "CNAME"),
                ("comment.contains", TUNNEL_COMMENT),
            ])
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;

        Ok(resp.result)
    }
}
```

- [ ] **Step 3: Create `src/cloudflare/mod.rs`**

```rust
pub mod client;
pub mod types;
```

- [ ] **Step 4: Verify it compiles**

```bash
cargo build
```

Expected: success (add `mod cloudflare;` to `main.rs` first).

- [ ] **Step 5: Commit**

```bash
git add src/cloudflare/ src/main.rs
git commit -m "feat: add Cloudflare API client for tunnels and DNS"
```

---

## Task 4: Kubernetes Resource Builders

**Files:**

- Create: `src/resources/mod.rs`
- Create: `src/resources/secret.rs`
- Create: `src/resources/configmap.rs`
- Create: `src/resources/deployment.rs`
- Create: `src/resources/gateway.rs`

- [ ] **Step 1: Create `src/resources/secret.rs`**

Build a Secret containing the tunnel credentials JSON. Sets `ownerReferences` to the parent `CloudflareTunnel` CR.

```rust
use k8s_openapi::api::core::v1::Secret;
use k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta;
use k8s_openapi::ByteString;
use kube::Resource;
use std::collections::BTreeMap;

use crate::crd::CloudflareTunnel;

pub fn build(tunnel: &CloudflareTunnel, credentials_json: &str) -> Secret {
    let name = tunnel.metadata.name.as_deref().unwrap();
    let ns = tunnel.metadata.namespace.as_deref().unwrap();
    let oref = tunnel.controller_owner_ref(&()).unwrap();

    Secret {
        metadata: ObjectMeta {
            name: Some(format!("{name}-tunnel-credentials")),
            namespace: Some(ns.to_string()),
            owner_references: Some(vec![oref]),
            labels: Some(BTreeMap::from([(
                "app.kubernetes.io/managed-by".to_string(),
                "cloudflare-tunnel-operator".to_string(),
            )])),
            ..Default::default()
        },
        data: Some(BTreeMap::from([(
            "credentials.json".to_string(),
            ByteString(credentials_json.as_bytes().to_vec()),
        )])),
        ..Default::default()
    }
}
```

- [ ] **Step 2: Create `src/resources/configmap.rs`**

Build the cloudflared config ConfigMap with the simple ingress rule.

```rust
use k8s_openapi::api::core::v1::ConfigMap;
use k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta;
use kube::Resource;
use std::collections::BTreeMap;

use crate::crd::CloudflareTunnel;

pub fn build(tunnel: &CloudflareTunnel, tunnel_id: &str) -> ConfigMap {
    let name = tunnel.metadata.name.as_deref().unwrap();
    let ns = tunnel.metadata.namespace.as_deref().unwrap();
    let oref = tunnel.controller_owner_ref(&()).unwrap();

    let gateway_svc = format!("http://{name}-gateway.{ns}.svc.cluster.local:80");

    let config = format!(
        "tunnel: {tunnel_id}\n\
         credentials-file: /etc/cloudflared/credentials.json\n\
         ingress:\n\
         - service: {gateway_svc}\n\
         - service: http_status:404\n"
    );

    ConfigMap {
        metadata: ObjectMeta {
            name: Some(format!("{name}-config")),
            namespace: Some(ns.to_string()),
            owner_references: Some(vec![oref]),
            labels: Some(BTreeMap::from([(
                "app.kubernetes.io/managed-by".to_string(),
                "cloudflare-tunnel-operator".to_string(),
            )])),
            ..Default::default()
        },
        data: Some(BTreeMap::from([(
            "config.yaml".to_string(),
            config,
        )])),
        ..Default::default()
    }
}
```

- [ ] **Step 3: Create `src/resources/deployment.rs`**

Build the cloudflared Deployment.

```rust
use k8s_openapi::api::apps::v1::{Deployment, DeploymentSpec};
use k8s_openapi::api::core::v1::{
    Container, PodSpec, PodTemplateSpec, Volume, VolumeMount,
    SecretVolumeSource, ConfigMapVolumeSource,
};
use k8s_openapi::apimachinery::pkg::apis::meta::v1::{LabelSelector, ObjectMeta};
use kube::Resource;
use std::collections::BTreeMap;

use crate::crd::CloudflareTunnel;

const DEFAULT_IMAGE: &str = "cloudflare/cloudflared:2024.11.0";

pub fn build(tunnel: &CloudflareTunnel) -> Deployment {
    let name = tunnel.metadata.name.as_deref().unwrap();
    let ns = tunnel.metadata.namespace.as_deref().unwrap();
    let oref = tunnel.controller_owner_ref(&()).unwrap();

    let image = tunnel
        .spec
        .image
        .as_deref()
        .unwrap_or(DEFAULT_IMAGE)
        .to_string();

    let labels = BTreeMap::from([
        ("app.kubernetes.io/name".to_string(), "cloudflared".to_string()),
        ("app.kubernetes.io/instance".to_string(), name.to_string()),
        (
            "app.kubernetes.io/managed-by".to_string(),
            "cloudflare-tunnel-operator".to_string(),
        ),
    ]);

    Deployment {
        metadata: ObjectMeta {
            name: Some(format!("{name}-cloudflared")),
            namespace: Some(ns.to_string()),
            owner_references: Some(vec![oref]),
            labels: Some(labels.clone()),
            ..Default::default()
        },
        spec: Some(DeploymentSpec {
            replicas: Some(1),
            selector: LabelSelector {
                match_labels: Some(labels.clone()),
                ..Default::default()
            },
            template: PodTemplateSpec {
                metadata: Some(ObjectMeta {
                    labels: Some(labels),
                    ..Default::default()
                }),
                spec: Some(PodSpec {
                    containers: vec![Container {
                        name: "cloudflared".to_string(),
                        image: Some(image),
                        args: Some(vec![
                            "tunnel".to_string(),
                            "--config".to_string(),
                            "/etc/cloudflared/config.yaml".to_string(),
                            "run".to_string(),
                        ]),
                        volume_mounts: Some(vec![
                            VolumeMount {
                                name: "credentials".to_string(),
                                mount_path: "/etc/cloudflared/credentials.json".to_string(),
                                sub_path: Some("credentials.json".to_string()),
                                read_only: Some(true),
                                ..Default::default()
                            },
                            VolumeMount {
                                name: "config".to_string(),
                                mount_path: "/etc/cloudflared/config.yaml".to_string(),
                                sub_path: Some("config.yaml".to_string()),
                                read_only: Some(true),
                                ..Default::default()
                            },
                        ]),
                        ..Default::default()
                    }],
                    volumes: Some(vec![
                        Volume {
                            name: "credentials".to_string(),
                            secret: Some(SecretVolumeSource {
                                secret_name: Some(format!("{name}-tunnel-credentials")),
                                ..Default::default()
                            }),
                            ..Default::default()
                        },
                        Volume {
                            name: "config".to_string(),
                            config_map: Some(ConfigMapVolumeSource {
                                name: Some(format!("{name}-config")),
                                ..Default::default()
                            }),
                            ..Default::default()
                        },
                    ]),
                    ..Default::default()
                }),
            },
            ..Default::default()
        }),
        ..Default::default()
    }
}
```

- [ ] **Step 4: Create `src/resources/gateway.rs`**

Build a Gateway resource as a `DynamicObject` (Gateway API types aren't in k8s-openapi).

```rust
use kube::api::{ApiResource, DynamicObject, ObjectMeta};
use kube::Resource;
use std::collections::BTreeMap;

use crate::crd::CloudflareTunnel;

pub const GATEWAY_AR: ApiResource = ApiResource {
    group: std::borrow::Cow::Borrowed("gateway.networking.k8s.io"),
    version: std::borrow::Cow::Borrowed("v1"),
    api_version: std::borrow::Cow::Borrowed("gateway.networking.k8s.io/v1"),
    kind: std::borrow::Cow::Borrowed("Gateway"),
    plural: std::borrow::Cow::Borrowed("gateways"),
};

pub fn build(tunnel: &CloudflareTunnel) -> DynamicObject {
    let name = tunnel.metadata.name.as_deref().unwrap();
    let ns = tunnel.metadata.namespace.as_deref().unwrap();
    let oref = tunnel.controller_owner_ref(&()).unwrap();
    let spec = &tunnel.spec;

    let listeners: Vec<serde_json::Value> = spec
        .gateway
        .listeners
        .iter()
        .enumerate()
        .map(|(i, l)| {
            serde_json::json!({
                "name": format!("listener-{i}"),
                "hostname": l.hostname,
                "port": 80,
                "protocol": "HTTP",
                "allowedRoutes": {
                    "namespaces": {
                        "from": "All"
                    }
                }
            })
        })
        .collect();

    let data = serde_json::json!({
        "apiVersion": "gateway.networking.k8s.io/v1",
        "kind": "Gateway",
        "metadata": {
            "name": format!("{name}-gateway"),
            "namespace": ns,
            "ownerReferences": [oref],
            "labels": {
                "app.kubernetes.io/managed-by": "cloudflare-tunnel-operator"
            }
        },
        "spec": {
            "gatewayClassName": spec.gateway.gateway_class_name,
            "listeners": listeners
        }
    });

    serde_json::from_value(data).unwrap()
}
```

- [ ] **Step 5: Create `src/resources/mod.rs`**

```rust
pub mod configmap;
pub mod deployment;
pub mod gateway;
pub mod secret;
```

- [ ] **Step 6: Add `mod resources;` to `main.rs` and verify it compiles**

```bash
cargo build
```

Expected: success.

- [ ] **Step 7: Commit**

```bash
git add src/resources/ src/main.rs
git commit -m "feat: add Kubernetes resource builders for child resources"
```

---

## Task 5: Controller Reconcile Loop

**Files:**

- Create: `src/controller.rs`
- Modify: `src/main.rs`

- [ ] **Step 1: Create `src/controller.rs`**

The core reconcile loop: finalizer-wrapped, manages all child resources and Cloudflare API calls.

```rust
use crate::cloudflare::client::CloudflareClient;
use crate::crd::{CloudflareTunnel, CloudflareTunnelStatus, RouteStatus};
use crate::resources;
use k8s_openapi::api::apps::v1::Deployment;
use k8s_openapi::api::core::v1::{ConfigMap, Secret};
use k8s_openapi::apimachinery::pkg::apis::meta::v1::Condition;
use kube::api::{Api, DynamicObject, Patch, PatchParams};
use kube::runtime::controller::Action;
use kube::runtime::finalizer::{finalizer, Event};
use kube::{Client, Resource, ResourceExt};
use std::sync::Arc;
use tokio::time::Duration;

const FINALIZER: &str = "tunnels.abutt.dev/cleanup";
const MANAGER: &str = "cloudflare-tunnel-operator";
const REQUEUE_INTERVAL: Duration = Duration::from_secs(300);

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Kubernetes error: {0}")]
    Kube(#[source] kube::Error),
    #[error("Cloudflare error: {0}")]
    Cloudflare(#[from] crate::cloudflare::client::CloudflareError),
    #[error("Finalizer error: {0}")]
    Finalizer(#[source] Box<kube::runtime::finalizer::Error<Error>>),
    #[error("Missing field: {0}")]
    MissingField(&'static str),
}

pub struct Ctx {
    pub client: Client,
    pub cf_client: CloudflareClient,
}

pub async fn reconcile(obj: Arc<CloudflareTunnel>, ctx: Arc<Ctx>) -> Result<Action, Error> {
    let ns = obj
        .metadata
        .namespace
        .as_deref()
        .ok_or(Error::MissingField(".metadata.namespace"))?;
    let api: Api<CloudflareTunnel> = Api::namespaced(ctx.client.clone(), ns);

    finalizer(&api, FINALIZER, obj, |event| async {
        match event {
            Event::Apply(obj) => apply(obj, ctx.clone()).await,
            Event::Cleanup(obj) => cleanup(obj, ctx.clone()).await,
        }
    })
    .await
    .map_err(|e| Error::Finalizer(Box::new(e)))
}

async fn apply(obj: Arc<CloudflareTunnel>, ctx: Arc<Ctx>) -> Result<Action, Error> {
    let client = &ctx.client;
    let name = obj.name_any();
    let ns = obj.namespace().ok_or(Error::MissingField(".metadata.namespace"))?;
    let pp = PatchParams::apply(MANAGER);

    tracing::info!(name = %name, namespace = %ns, "reconciling");

    // 0. Resolve Cloudflare API client — per-CR override or controller default
    let cf: &dyn CloudflareApi = if let Some(ref creds_ref) = obj.spec.credentials_ref {
        let secret_api: Api<Secret> =
            Api::namespaced(client.clone(), &creds_ref.namespace);
        let secret = secret_api.get(&creds_ref.name).await.map_err(Error::Kube)?;
        let token = secret
            .data
            .as_ref()
            .and_then(|d| d.get("token"))
            .map(|b| String::from_utf8_lossy(&b.0).to_string())
            .ok_or(Error::MissingField("token in credentialsRef secret"))?;
        // Note: in practice, cache these per-CR clients to avoid recreating on each reconcile
        &CloudflareClient::new(token)
    } else {
        ctx.cf_client.as_ref()
    };

    // 1. Resolve zone
    let (zone_id, account_id) = cf.get_zone_id(&obj.spec.zone).await?;

    // 2. Ensure tunnel exists
    let (tunnel_id, credentials_json) = match &obj.status.as_ref().and_then(|s| s.tunnel_id.clone())
    {
        Some(id) => {
            // Verify tunnel still exists
            match cf.get_tunnel(&account_id, id).await? {
                Some(_) => {
                    // Read credentials from existing secret
                    let secret_api: Api<Secret> = Api::namespaced(client.clone(), &ns);
                    let secret_name = format!("{name}-tunnel-credentials");
                    let secret = secret_api.get(&secret_name).await.map_err(Error::Kube)?;
                    let creds = secret
                        .data
                        .as_ref()
                        .and_then(|d| d.get("credentials.json"))
                        .map(|b| String::from_utf8_lossy(&b.0).to_string())
                        .ok_or(Error::MissingField("credentials.json in secret"))?;
                    (id.clone(), creds)
                }
                None => {
                    // Tunnel was deleted externally, recreate
                    let (tunnel, creds) = cf.create_tunnel(&account_id, &name).await?;
                    (tunnel.id, creds)
                }
            }
        }
        None => {
            let (tunnel, creds) = cf.create_tunnel(&account_id, &name).await?;
            (tunnel.id, creds)
        }
    };

    // 3. Sync DNS records — ensure desired records exist, remove stale ones
    let desired_hostnames: std::collections::HashSet<&str> = obj
        .spec
        .gateway
        .listeners
        .iter()
        .map(|l| l.hostname.as_str())
        .collect();

    let mut route_statuses = Vec::new();
    for listener in &obj.spec.gateway.listeners {
        let record = cf
            .ensure_dns_cname(&zone_id, &listener.hostname, &tunnel_id)
            .await?;
        route_statuses.push(RouteStatus {
            hostname: listener.hostname.clone(),
            dns_record: format!("{} -> {}", listener.hostname, record.content),
            status: "Active".to_string(),
        });
    }

    // Remove DNS records for hostnames no longer in spec
    let target = format!("{tunnel_id}.cfargotunnel.com");
    let existing_records = cf.list_dns_records_by_comment(&zone_id).await?;
    for record in existing_records {
        if record.content == target && !desired_hostnames.contains(record.name.as_str()) {
            tracing::info!(hostname = %record.name, "removing stale DNS record");
            cf.delete_dns_record(&zone_id, &record.id).await?;
        }
    }

    // 4. Sync Secret
    let secret = resources::secret::build(&obj, &credentials_json);
    let secret_api: Api<Secret> = Api::namespaced(client.clone(), &ns);
    secret_api
        .patch(
            secret.metadata.name.as_deref().unwrap(),
            &pp,
            &Patch::Apply(&secret),
        )
        .await
        .map_err(Error::Kube)?;

    // 5. Sync ConfigMap
    let cm = resources::configmap::build(&obj, &tunnel_id);
    let cm_api: Api<ConfigMap> = Api::namespaced(client.clone(), &ns);
    cm_api
        .patch(cm.metadata.name.as_deref().unwrap(), &pp, &Patch::Apply(&cm))
        .await
        .map_err(Error::Kube)?;

    // 6. Sync Deployment
    let deploy = resources::deployment::build(&obj);
    let deploy_api: Api<Deployment> = Api::namespaced(client.clone(), &ns);
    deploy_api
        .patch(
            deploy.metadata.name.as_deref().unwrap(),
            &pp,
            &Patch::Apply(&deploy),
        )
        .await
        .map_err(Error::Kube)?;

    // 7. Sync Gateway
    let gw = resources::gateway::build(&obj);
    let gw_api: Api<DynamicObject> =
        Api::namespaced_with(client.clone(), &ns, &resources::gateway::GATEWAY_AR);
    gw_api
        .patch(
            gw.metadata.name.as_deref().unwrap(),
            &pp,
            &Patch::Apply(&gw),
        )
        .await
        .map_err(Error::Kube)?;

    // 8. Update status
    let now = chrono::Utc::now().to_rfc3339();
    let status = CloudflareTunnelStatus {
        tunnel_id: Some(tunnel_id),
        conditions: vec![Condition {
            type_: "Ready".to_string(),
            status: "True".to_string(),
            reason: "Reconciled".to_string(),
            message: format!(
                "Tunnel active with {} routes",
                obj.spec.gateway.listeners.len()
            ),
            last_transition_time: k8s_openapi::apimachinery::pkg::apis::meta::v1::Time(
                chrono::DateTime::parse_from_rfc3339(&now).unwrap().into(),
            ),
            observed_generation: obj.metadata.generation,
        }],
        routes: route_statuses,
    };

    let tunnel_api: Api<CloudflareTunnel> = Api::namespaced(client.clone(), &ns);
    tunnel_api
        .patch_status(
            &name,
            &pp,
            &Patch::Apply(serde_json::json!({
                "apiVersion": "tunnels.abutt.dev/v1alpha1",
                "kind": "CloudflareTunnel",
                "status": status,
            })),
        )
        .await
        .map_err(Error::Kube)?;

    tracing::info!(name = %name, "reconciled successfully");
    Ok(Action::requeue(REQUEUE_INTERVAL))
}

async fn cleanup(obj: Arc<CloudflareTunnel>, ctx: Arc<Ctx>) -> Result<Action, Error> {
    let cf = &ctx.cf_client;
    let name = obj.name_any();

    tracing::info!(name = %name, "cleaning up");

    if let Ok((zone_id, account_id)) = cf.get_zone_id(&obj.spec.zone).await {
        // Delete DNS records
        let records = cf.list_dns_records_by_comment(&zone_id).await?;
        if let Some(tunnel_id) = obj.status.as_ref().and_then(|s| s.tunnel_id.as_deref()) {
            let target = format!("{tunnel_id}.cfargotunnel.com");
            for record in records {
                if record.content == target {
                    cf.delete_dns_record(&zone_id, &record.id).await?;
                }
            }
            // Delete tunnel
            cf.delete_tunnel(&account_id, tunnel_id).await?;
        }
    }

    tracing::info!(name = %name, "cleanup complete");
    Ok(Action::await_change())
}

pub fn error_policy(_obj: Arc<CloudflareTunnel>, error: &Error, _ctx: Arc<Ctx>) -> Action {
    tracing::warn!(error = %error, "reconcile error, requeuing");
    Action::requeue(Duration::from_secs(15))
}
```

- [ ] **Step 2: Update `src/main.rs` to wire up the controller**

```rust
use kube::runtime::controller::Controller;
use kube::runtime::watcher;
use kube::{Api, Client};
use k8s_openapi::api::apps::v1::Deployment;
use k8s_openapi::api::core::v1::{ConfigMap, Secret};
use kube::api::DynamicObject;
use std::sync::Arc;
use futures::StreamExt;

mod cloudflare;
mod controller;
mod crd;
mod resources;

use crate::cloudflare::client::CloudflareClient;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // CRD generation mode
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s.as_str()) == Some("crd") {
        use kube::CustomResourceExt;
        print!(
            "{}",
            serde_json::to_string_pretty(&crd::CloudflareTunnel::crd())?
        );
        return Ok(());
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("cloudflare_tunnel_operator=info".parse()?),
        )
        .json()
        .init();

    tracing::info!("starting cloudflare-tunnel-operator");

    let client = Client::try_default().await?;

    let cf_token = std::env::var("CF_API_TOKEN")
        .expect("CF_API_TOKEN must be set");
    let cf_client = CloudflareClient::new(cf_token);

    let ctx = Arc::new(controller::Ctx {
        client: client.clone(),
        cf_client,
    });

    let tunnels = Api::<crd::CloudflareTunnel>::all(client.clone());
    let deployments = Api::<Deployment>::all(client.clone());
    let secrets = Api::<Secret>::all(client.clone());
    let configmaps = Api::<ConfigMap>::all(client.clone());
    let gateways = Api::<DynamicObject>::all_with(
        client.clone(),
        &resources::gateway::GATEWAY_AR,
    );

    Controller::new(tunnels, watcher::Config::default())
        .owns(deployments, watcher::Config::default())
        .owns(secrets, watcher::Config::default())
        .owns(configmaps, watcher::Config::default())
        .owns_with(
            gateways,
            resources::gateway::GATEWAY_AR.clone(),
            watcher::Config::default(),
        )
        .shutdown_on_signal()
        .run(
            controller::reconcile,
            controller::error_policy,
            ctx,
        )
        .for_each(|res| async move {
            match res {
                Ok(o) => tracing::info!("reconciled {:?}", o),
                Err(e) => tracing::warn!("reconcile failed: {}", e),
            }
        })
        .await;

    Ok(())
}
```

Note: add `anyhow = "1"` and `chrono = { version = "0.4", features = ["serde"] }` to `Cargo.toml` dependencies.

- [ ] **Step 3: Verify it compiles**

```bash
cargo build
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add src/controller.rs src/main.rs Cargo.toml
git commit -m "feat: implement reconcile loop with finalizer"
```

---

## Task 6: Deploy Manifests

**Files:**

- Create: `deploy/crd.yaml`
- Create: `deploy/rbac.yaml`
- Create: `deploy/deployment.yaml`

- [ ] **Step 1: Generate the CRD YAML**

```bash
cargo run -- crd > deploy/crd.yaml
```

- [ ] **Step 2: Create `deploy/rbac.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloudflare-tunnel-operator
  namespace: cloudflare-operator
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cloudflare-tunnel-operator
rules:
  # CRD
  - apiGroups: ["tunnels.abutt.dev"]
    resources: ["cloudflaretunnels"]
    verbs: ["get", "list", "watch", "patch"]
  - apiGroups: ["tunnels.abutt.dev"]
    resources: ["cloudflaretunnels/status"]
    verbs: ["get", "patch"]
  # Child resources
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Gateway API
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gateways"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Leader election
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update"]
  # Events
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cloudflare-tunnel-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cloudflare-tunnel-operator
subjects:
  - kind: ServiceAccount
    name: cloudflare-tunnel-operator
    namespace: cloudflare-operator
```

- [ ] **Step 3: Create `deploy/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflare-tunnel-operator
  namespace: cloudflare-operator
  labels:
    app.kubernetes.io/name: cloudflare-tunnel-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudflare-tunnel-operator
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cloudflare-tunnel-operator
    spec:
      serviceAccountName: cloudflare-tunnel-operator
      containers:
        - name: operator
          image: ghcr.io/tonybutt/cloudflare-tunnel-operator:latest
          env:
            - name: CF_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflare-api-token
                  key: token
            - name: RUST_LOG
              value: "cloudflare_tunnel_operator=info"
          resources:
            requests:
              memory: "32Mi"
              cpu: "10m"
            limits:
              memory: "128Mi"
```

- [ ] **Step 4: Commit**

```bash
git add deploy/
git commit -m "feat: add deploy manifests (CRD, RBAC, Deployment)"
```

---

## Task 7: E2E Tests with kind

**Files:**

- Create: `tests/e2e/main.rs`
- Create: `tests/e2e/tunnel_lifecycle.rs`
- Modify: `Cargo.toml` (add `[[test]]` section)
- Modify: `src/cloudflare/client.rs` (extract trait for mocking)

The e2e tests spin up a kind cluster, install the CRD, run the controller with a mock Cloudflare API, and verify the full lifecycle (create CR -> child resources appear -> delete CR -> cleanup).

- [ ] **Step 1: Extract a `CloudflareApi` trait from the client for testability**

In `src/cloudflare/client.rs`, add a trait that `CloudflareClient` implements. The e2e tests will use a mock implementation.

```rust
// Add to src/cloudflare/client.rs, above the impl block:

#[async_trait::async_trait]
pub trait CloudflareApi: Send + Sync {
    async fn get_zone_id(&self, zone_name: &str) -> Result<(String, String), CloudflareError>;
    async fn create_tunnel(
        &self,
        account_id: &str,
        name: &str,
    ) -> Result<(Tunnel, String), CloudflareError>;
    async fn delete_tunnel(
        &self,
        account_id: &str,
        tunnel_id: &str,
    ) -> Result<(), CloudflareError>;
    async fn get_tunnel(
        &self,
        account_id: &str,
        tunnel_id: &str,
    ) -> Result<Option<Tunnel>, CloudflareError>;
    async fn ensure_dns_cname(
        &self,
        zone_id: &str,
        hostname: &str,
        tunnel_id: &str,
    ) -> Result<DnsRecord, CloudflareError>;
    async fn delete_dns_record(
        &self,
        zone_id: &str,
        record_id: &str,
    ) -> Result<(), CloudflareError>;
    async fn list_dns_records_by_comment(
        &self,
        zone_id: &str,
    ) -> Result<Vec<DnsRecord>, CloudflareError>;
}
```

Add `async-trait = "0.1"` to `Cargo.toml`. Update `Ctx` to use `Box<dyn CloudflareApi>` instead of `CloudflareClient`. Update `controller.rs` references accordingly.

- [ ] **Step 2: Add test configuration to `Cargo.toml`**

```toml
[[test]]
name = "e2e"
path = "tests/e2e/main.rs"
```

- [ ] **Step 3: Create `tests/e2e/main.rs`**

```rust
use k8s_openapi::api::apps::v1::Deployment;
use k8s_openapi::api::core::v1::{ConfigMap, Secret};
use kube::api::{Api, DynamicObject, ObjectMeta, Patch, PatchParams, PostParams};
use kube::runtime::controller::Controller;
use kube::runtime::watcher;
use kube::{Client, CustomResourceExt, ResourceExt};
use std::sync::Arc;
use tokio::time::{sleep, Duration};
use futures::StreamExt;

use cloudflare_tunnel_operator::cloudflare::client::*;
use cloudflare_tunnel_operator::cloudflare::types::*;
use cloudflare_tunnel_operator::controller;
use cloudflare_tunnel_operator::crd::*;
use cloudflare_tunnel_operator::resources;

mod tunnel_lifecycle;

/// Mock Cloudflare API client for e2e tests.
struct MockCloudflareClient {
    tunnel_id: String,
}

impl MockCloudflareClient {
    fn new() -> Self {
        Self {
            tunnel_id: "test-tunnel-id-1234".to_string(),
        }
    }
}

#[async_trait::async_trait]
impl CloudflareApi for MockCloudflareClient {
    async fn get_zone_id(&self, _zone_name: &str) -> Result<(String, String), CloudflareError> {
        Ok(("test-zone-id".to_string(), "test-account-id".to_string()))
    }

    async fn create_tunnel(
        &self,
        _account_id: &str,
        _name: &str,
    ) -> Result<(Tunnel, String), CloudflareError> {
        let creds = serde_json::json!({
            "AccountTag": "test-account-id",
            "TunnelID": self.tunnel_id,
            "TunnelSecret": "dGVzdC1zZWNyZXQ=",
        });
        Ok((
            Tunnel {
                id: self.tunnel_id.clone(),
                name: _name.to_string(),
            },
            creds.to_string(),
        ))
    }

    async fn delete_tunnel(
        &self,
        _account_id: &str,
        _tunnel_id: &str,
    ) -> Result<(), CloudflareError> {
        Ok(())
    }

    async fn get_tunnel(
        &self,
        _account_id: &str,
        _tunnel_id: &str,
    ) -> Result<Option<Tunnel>, CloudflareError> {
        Ok(Some(Tunnel {
            id: self.tunnel_id.clone(),
            name: "test".to_string(),
        }))
    }

    async fn ensure_dns_cname(
        &self,
        _zone_id: &str,
        hostname: &str,
        tunnel_id: &str,
    ) -> Result<DnsRecord, CloudflareError> {
        Ok(DnsRecord {
            id: format!("record-{hostname}"),
            name: hostname.to_string(),
            content: format!("{tunnel_id}.cfargotunnel.com"),
            record_type: "CNAME".to_string(),
        })
    }

    async fn delete_dns_record(
        &self,
        _zone_id: &str,
        _record_id: &str,
    ) -> Result<(), CloudflareError> {
        Ok(())
    }

    async fn list_dns_records_by_comment(
        &self,
        _zone_id: &str,
    ) -> Result<Vec<DnsRecord>, CloudflareError> {
        Ok(vec![])
    }
}

/// Helper to create a kind cluster and return a client.
async fn setup_kind_cluster(name: &str) -> Client {
    let status = tokio::process::Command::new("kind")
        .args(["create", "cluster", "--name", name, "--wait", "60s"])
        .status()
        .await
        .expect("failed to run kind");
    assert!(status.success(), "kind cluster creation failed");

    // Install CRD
    let client = Client::try_default().await.unwrap();
    let crd = CloudflareTunnel::crd();
    let crd_api = Api::<k8s_openapi::apiextensions_apiserver::pkg::apis::apiextensions::v1::CustomResourceDefinition>::all(client.clone());
    crd_api
        .create(&PostParams::default(), &crd)
        .await
        .expect("failed to create CRD");

    // Wait for CRD to be established
    sleep(Duration::from_secs(2)).await;

    client
}

async fn teardown_kind_cluster(name: &str) {
    let _ = tokio::process::Command::new("kind")
        .args(["delete", "cluster", "--name", name])
        .status()
        .await;
}

/// Start the controller in the background with a mock CF client.
fn start_controller(client: Client) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let ctx = Arc::new(controller::Ctx {
            client: client.clone(),
            cf_client: Box::new(MockCloudflareClient::new()),
        });

        let tunnels = Api::<CloudflareTunnel>::all(client.clone());
        let deployments = Api::<Deployment>::all(client.clone());
        let secrets = Api::<Secret>::all(client.clone());
        let configmaps = Api::<ConfigMap>::all(client.clone());

        // Note: kind won't have Gateway API CRDs, so we skip owns() for gateways in tests
        Controller::new(tunnels, watcher::Config::default())
            .owns(deployments, watcher::Config::default())
            .owns(secrets, watcher::Config::default())
            .owns(configmaps, watcher::Config::default())
            .run(controller::reconcile, controller::error_policy, ctx)
            .for_each(|res| async move {
                match res {
                    Ok(_) => {}
                    Err(e) => eprintln!("reconcile error: {e}"),
                }
            })
            .await;
    })
}
```

- [ ] **Step 4: Create `tests/e2e/tunnel_lifecycle.rs`**

```rust
use super::*;

#[tokio::test]
async fn test_tunnel_create_produces_child_resources() {
    let cluster_name = "cft-e2e-create";
    let client = setup_kind_cluster(cluster_name).await;
    let controller_handle = start_controller(client.clone());

    // Create namespace
    let ns_api = Api::<k8s_openapi::api::core::v1::Namespace>::all(client.clone());
    ns_api
        .create(
            &PostParams::default(),
            &serde_json::from_value(serde_json::json!({
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": { "name": "test-tunnel" }
            }))
            .unwrap(),
        )
        .await
        .unwrap();

    // Create CloudflareTunnel CR
    let tunnel_api = Api::<CloudflareTunnel>::namespaced(client.clone(), "test-tunnel");
    let tunnel = CloudflareTunnel::new(
        "test",
        CloudflareTunnelSpec {
            zone: "example.com".to_string(),
            gateway: GatewaySpec {
                gateway_class_name: "test".to_string(),
                listeners: vec![Listener {
                    hostname: "app.example.com".to_string(),
                }],
            },
            image: None,
            credentials_ref: None,
        },
    );
    tunnel_api
        .create(&PostParams::default(), &tunnel)
        .await
        .unwrap();

    // Wait for reconciliation
    sleep(Duration::from_secs(10)).await;

    // Verify child resources were created
    let secret_api = Api::<Secret>::namespaced(client.clone(), "test-tunnel");
    let secret = secret_api.get("test-tunnel-credentials").await;
    assert!(secret.is_ok(), "tunnel credentials secret should exist");

    let cm_api = Api::<ConfigMap>::namespaced(client.clone(), "test-tunnel");
    let cm = cm_api.get("test-config").await;
    assert!(cm.is_ok(), "config map should exist");

    let deploy_api = Api::<Deployment>::namespaced(client.clone(), "test-tunnel");
    let deploy = deploy_api.get("test-cloudflared").await;
    assert!(deploy.is_ok(), "cloudflared deployment should exist");

    // Verify status was updated
    let updated = tunnel_api.get_status("test").await.unwrap();
    let status = updated.status.expect("status should be set");
    assert!(status.tunnel_id.is_some(), "tunnel_id should be set");
    assert!(!status.routes.is_empty(), "routes should be populated");

    // Cleanup
    controller_handle.abort();
    teardown_kind_cluster(cluster_name).await;
}

#[tokio::test]
async fn test_tunnel_delete_cleans_up() {
    let cluster_name = "cft-e2e-delete";
    let client = setup_kind_cluster(cluster_name).await;
    let controller_handle = start_controller(client.clone());

    // Create namespace
    let ns_api = Api::<k8s_openapi::api::core::v1::Namespace>::all(client.clone());
    ns_api
        .create(
            &PostParams::default(),
            &serde_json::from_value(serde_json::json!({
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": { "name": "test-delete" }
            }))
            .unwrap(),
        )
        .await
        .unwrap();

    // Create and then delete
    let tunnel_api = Api::<CloudflareTunnel>::namespaced(client.clone(), "test-delete");
    let tunnel = CloudflareTunnel::new(
        "test",
        CloudflareTunnelSpec {
            zone: "example.com".to_string(),
            gateway: GatewaySpec {
                gateway_class_name: "test".to_string(),
                listeners: vec![Listener {
                    hostname: "app.example.com".to_string(),
                }],
            },
            image: None,
            credentials_ref: None,
        },
    );
    tunnel_api
        .create(&PostParams::default(), &tunnel)
        .await
        .unwrap();

    sleep(Duration::from_secs(10)).await;

    // Delete the CR
    tunnel_api
        .delete("test", &Default::default())
        .await
        .unwrap();

    sleep(Duration::from_secs(10)).await;

    // Verify child resources were garbage collected
    let secret_api = Api::<Secret>::namespaced(client.clone(), "test-delete");
    let secret = secret_api.get("test-tunnel-credentials").await;
    assert!(secret.is_err(), "secret should be deleted");

    // Cleanup
    controller_handle.abort();
    teardown_kind_cluster(cluster_name).await;
}
```

- [ ] **Step 5: Make the library crate accessible from tests**

Convert `src/main.rs` into a binary that re-uses a library. Add to `Cargo.toml`:

```toml
[lib]
name = "cloudflare_tunnel_operator"
path = "src/lib.rs"

[[bin]]
name = "cloudflare-tunnel-operator"
path = "src/main.rs"
```

Create `src/lib.rs`:

```rust
pub mod cloudflare;
pub mod controller;
pub mod crd;
pub mod resources;
```

Remove `mod` declarations from `main.rs` and use `use cloudflare_tunnel_operator::*;` instead.

- [ ] **Step 6: Verify tests compile**

```bash
cargo test --no-run
```

Expected: compiles (won't run without kind available).

- [ ] **Step 7: Run e2e tests (requires kind + Docker)**

```bash
cargo test --test e2e -- --test-threads=1
```

Expected: both tests pass. Uses `--test-threads=1` to avoid kind cluster name collisions.

- [ ] **Step 8: Commit**

```bash
git add tests/ src/lib.rs src/main.rs src/cloudflare/client.rs Cargo.toml
git commit -m "feat: add e2e test suite with kind and mock Cloudflare API"
```

---

## Task 8: Documentation

**Files:**

- Create: `README.md`
- Create: `docs/getting-started.md`
- Create: `docs/configuration.md`
- Create: `docs/architecture.md`
- Create: `docs/troubleshooting.md`

- [ ] **Step 1: Write `README.md`**

Comprehensive install guide covering:

- Overview (what the operator does)
- Prerequisites (K8s cluster, Cloudflare account, API token permissions: Zone:DNS:Edit, Account:Cloudflare Tunnel:Edit, Zone:Zone:Read)
- Installation steps: apply CRD, create API token Secret, deploy controller, create a `CloudflareTunnel` CR, create HTTPRoutes in app namespaces
- Configuration reference (all spec fields with defaults)
- Status fields explanation
- Uninstall procedure
- Development (nix develop, cargo build, running tests)

- [ ] **Step 2: Write `docs/getting-started.md`**

Expanded quick start with a full walkthrough: creating the API token in Cloudflare dashboard, deploying the operator, creating a tunnel for `*.example.com`, and verifying with `kubectl get cft`.

- [ ] **Step 3: Write `docs/configuration.md`**

Full CRD reference with multiple examples: single domain, wildcard, multiple listeners, custom image, per-CR credentials override.

- [ ] **Step 4: Write `docs/architecture.md`**

How the operator works: reconcile loop, resource ownership, finalizer cleanup, Cloudflare API interactions, Gateway API integration.

- [ ] **Step 5: Write `docs/troubleshooting.md`**

Common issues: CRD not installed, API token permissions wrong, tunnel stuck in "inactive", DNS records not created, Gateway not routing.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/
git commit -m "docs: add README install guide and docs site"
```

---

## Task 9: CI Pipeline

**Files:**

- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: DeterminateSystems/magic-nix-cache-action@main
      - run: nix flake check

  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: DeterminateSystems/magic-nix-cache-action@main
      - run: nix build

  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: DeterminateSystems/magic-nix-cache-action@main
      - run: |
          nix develop -c bash -c "
            cargo test --test e2e -- --test-threads=1
          "

  push-container:
    if: github.ref == 'refs/heads/main'
    needs: [check, build, e2e]
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: DeterminateSystems/magic-nix-cache-action@main
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - run: |
          nix build .#container
          ./result | docker load
          docker push ghcr.io/tonybutt/cloudflare-tunnel-operator:latest
```

- [ ] **Step 2: Commit**

```bash
git add .github/
git commit -m "ci: add GitHub Actions for check, build, e2e, and container push"
```

---

## Task 10: Dockerfile Fallback

**Files:**

- Create: `Dockerfile`

- [ ] **Step 1: Create `Dockerfile`**

```dockerfile
FROM rust:1-bookworm AS builder
WORKDIR /app
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/cloudflare-tunnel-operator /usr/local/bin/
ENTRYPOINT ["cloudflare-tunnel-operator"]
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile
git commit -m "build: add Dockerfile as fallback build method"
```
