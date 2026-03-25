# Kanidm SSO Deployment Design

## Overview

Deploy kanidm as the central identity provider at `sso.abutt.dev`, replacing zitadel. OAuth2-proxy is reconfigured to use kanidm as its OIDC provider for protecting apps without native OIDC support. Apps with OIDC support (like gitea) will integrate with kanidm directly.

## Architecture

```
Internet → Cloudflare tunnel → Cilium Gateway
  ├─ HTTP listener (*.abutt.dev) → HTTPRoutes → apps, oauth2-proxy
  └─ TLS passthrough listener (sso.abutt.dev) → TLSRoute → kanidm:8443
```

**Auth flows:**

1. Apps without OIDC: `user → app → oauth2-proxy → kanidm → back to app`
2. Apps with OIDC: `user → app → kanidm → back to app`

## Components

### 1. cert-manager (new infrastructure controller)

- **Location:** `infrastructure/controllers/cert-manager/`
- **Pattern:** helm-rendered manifest (same as cilium, oauth2-proxy)
- **Chart:** `jetstack/cert-manager`
- **Namespace:** `cert-manager`
- **Purpose:** Issue TLS certificates via Let's Encrypt DNS-01 challenge through Cloudflare
- **Resources:**
  - `helm-values.yaml` — chart config with CRDs enabled
  - `manifests/cert-manager.yaml` — rendered manifest
  - `clusterissuer.yaml` — Let's Encrypt ClusterIssuer with Cloudflare DNS-01 solver
  - `kustomization.yaml`
  - `ns.yaml`

**Cloudflare API Token Setup:**

Create a token at https://dash.cloudflare.com/profile/api-tokens with:

- **Permissions:** Zone → DNS → Edit
- **Zone Resources:** Include → Specific Zone → `abutt.dev`
- **Name:** `cert-manager-dns01`

The token will be stored as a SOPS-encrypted secret in the cert-manager namespace, referenced by the ClusterIssuer.

### 2. kanidm (new app)

- **Location:** `apps/kanidm/`
- **Image:** `ghcr.io/kanidm/server:1.9.2`
- **Namespace:** `kanidm`
- **Resources:**
  - `ns.yaml` — namespace
  - `statefulset.yaml` — single-replica StatefulSet
  - `service.yaml` — ClusterIP on port 8443
  - `config.yaml` — kanidm server.toml configuration
  - `certificate.yaml` — cert-manager Certificate for `sso.abutt.dev`
  - `tlsroute.yaml` — TLSRoute for gateway passthrough
  - `kustomization.yaml`

**Storage:** 1Gi PVC using `openebs-hostpath` for `/data`

**TLS:** cert-manager issues a Let's Encrypt certificate for `sso.abutt.dev`. The certificate secret is mounted into the kanidm pod. kanidm serves TLS natively on port 8443.

**Server config (server.toml):**

```toml
bindaddress = "[::]:8443"
domain = "sso.abutt.dev"
origin = "https://sso.abutt.dev"
tls_chain = "/certs/tls.crt"
tls_key = "/certs/tls.key"
db_path = "/data/kanidm.db"
```

### 3. Cilium Gateway update

- **File:** `infrastructure/controllers/cilium/gateway.yaml`
- **Change:** Add a second listener for TLS passthrough

```yaml
listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.abutt.dev"
    allowedRoutes:
      namespaces:
        from: All
  - name: tls-passthrough
    protocol: TLS
    port: 443
    hostname: sso.abutt.dev
    tls:
      mode: Passthrough
    allowedRoutes:
      namespaces:
        from: All
```

**TLSRoute (v1alpha2):** Routes SNI `sso.abutt.dev` to kanidm service on port 8443.

**Cloudflare tunnel update:** The `abutt.dev` tunnel config needs an entry for `sso.abutt.dev` pointing to the gateway on port 443 (TLS, not HTTP).

### 4. oauth2-proxy reconfiguration

- **Location:** `infrastructure/controllers/oauth2-proxy/`
- **Changes:**
  - OIDC issuer URL: `https://auth.abutt.dev` → `https://sso.abutt.dev`
  - Re-render manifest from updated helm-values.yaml
  - Secrets will need updating with kanidm client ID/secret after kanidm is configured

### 5. Cleanup

- **Delete:** `apps/zitadel/` directory (manifests on main)
- **Remove:** zitadel reference from `apps/kustomization.yaml` (if present)
- **Delete remote branches:**
  - `origin/feat/zitadel-oauth2proxy`
  - `origin/feat/cloudflare-tunnel-gateway`

## Deployment Order

1. Deploy cert-manager + ClusterIssuer (with Cloudflare API token secret)
2. Deploy kanidm (cert-manager issues the TLS cert)
3. Update Cilium Gateway with TLS passthrough listener
4. Update cloudflare tunnel config for `sso.abutt.dev`
5. Verify kanidm is accessible at `https://sso.abutt.dev`
6. Configure kanidm: create admin account, OIDC client for oauth2-proxy
7. Update oauth2-proxy with kanidm OIDC credentials
8. Clean up zitadel and old branches

## Post-Deployment Configuration

After kanidm is running, manual steps needed:

1. Run `kanidm recover-account admin` to get initial admin password
2. Create OIDC client application in kanidm for oauth2-proxy
3. Create OIDC client applications for any apps with native OIDC (gitea, etc.)
4. Update oauth2-proxy secrets with the kanidm client ID and secret

## File Tree

```
infrastructure/controllers/
  cert-manager/
    helm-values.yaml
    manifests/cert-manager.yaml
    clusterissuer.yaml
    kustomization.yaml
    ns.yaml
    secrets/cloudflare-api-token.encrypted.yaml
apps/
  kanidm/
    ns.yaml
    statefulset.yaml
    service.yaml
    config.yaml
    certificate.yaml
    tlsroute.yaml
    kustomization.yaml
```
