# Kanidm SSO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy kanidm as the central IDP at `sso.abutt.dev` with cert-manager for TLS, reconfigure oauth2-proxy, and clean up zitadel.

**Architecture:** cert-manager issues Let's Encrypt certs via Cloudflare DNS-01. Kanidm serves TLS natively on port 8443. Cilium Gateway uses TLS passthrough via TLSRoute to route `sso.abutt.dev` traffic directly to kanidm. OAuth2-proxy uses kanidm as its OIDC provider.

**Tech Stack:** kanidm 1.9.2, cert-manager 1.20.0, Cilium Gateway API TLSRoute, Flux CD, SOPS/age

**Spec:** `docs/superpowers/specs/2026-03-25-kanidm-sso-design.md`

---

### Task 1: Deploy cert-manager

**Files:**

- Create: `infrastructure/controllers/cert-manager/ns.yaml`
- Create: `infrastructure/controllers/cert-manager/helm-values.yaml`
- Create: `infrastructure/controllers/cert-manager/manifests/cert-manager.yaml` (rendered by helm)
- Create: `infrastructure/controllers/cert-manager/kustomization.yaml`
- Modify: `infrastructure/controllers/kustomization.yaml` (add cert-manager resource)

- [ ] **Step 1: Create namespace**

```yaml
# infrastructure/controllers/cert-manager/ns.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
```

- [ ] **Step 2: Create helm values**

```yaml
# infrastructure/controllers/cert-manager/helm-values.yaml
# chart: jetstack/cert-manager
# version: 1.20.0
# repo: https://charts.jetstack.io
# namespace: cert-manager
# release-name: cert-manager
crds:
  enabled: true
```

- [ ] **Step 3: Render helm chart**

Run: `render-helm infrastructure/controllers/cert-manager/helm-values.yaml`
Expected: `infrastructure/controllers/cert-manager/manifests/cert-manager.yaml` created

- [ ] **Step 4: Create kustomization**

```yaml
# infrastructure/controllers/cert-manager/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cert-manager
resources:
  - ns.yaml
  - manifests/cert-manager.yaml
```

- [ ] **Step 5: Add cert-manager to infrastructure controllers**

Modify `infrastructure/controllers/kustomization.yaml` — add `- cert-manager` to resources list.

- [ ] **Step 6: Verify kustomize build**

Run: `kustomize build infrastructure/controllers/cert-manager`
Expected: Valid YAML output with cert-manager resources in cert-manager namespace

- [ ] **Step 7: Commit**

```bash
git add infrastructure/controllers/cert-manager/ infrastructure/controllers/kustomization.yaml
git commit -m "feat: add cert-manager infrastructure controller"
```

---

### Task 2: Add ClusterIssuer with Cloudflare DNS-01

**Files:**

- Create: `infrastructure/controllers/cert-manager/secrets/cloudflare-api-token.encrypted.env`
- Create: `infrastructure/controllers/cert-manager/clusterissuer.yaml`
- Modify: `infrastructure/controllers/cert-manager/kustomization.yaml` (add clusterissuer + secret)

**Prerequisite:** User provides SOPS-encrypted Cloudflare API token.

- [ ] **Step 1: Create Cloudflare API token secret**

User creates:

```bash
echo "api-token=<CLOUDFLARE_TOKEN>" > infrastructure/controllers/cert-manager/secrets/cloudflare-api-token.env
sops -e infrastructure/controllers/cert-manager/secrets/cloudflare-api-token.env > infrastructure/controllers/cert-manager/secrets/cloudflare-api-token.encrypted.env
rm infrastructure/controllers/cert-manager/secrets/cloudflare-api-token.env
```

- [ ] **Step 2: Create ClusterIssuer**

```yaml
# infrastructure/controllers/cert-manager/clusterissuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: abutt@tiberius.com
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
        selector:
          dnsZones:
            - abutt.dev
```

- [ ] **Step 3: Update kustomization to include clusterissuer and secret**

```yaml
# infrastructure/controllers/cert-manager/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cert-manager
resources:
  - ns.yaml
  - manifests/cert-manager.yaml
  - clusterissuer.yaml
generatorOptions:
  disableNameSuffixHash: true
secretGenerator:
  - name: cloudflare-api-token
    envs:
      - secrets/cloudflare-api-token.encrypted.env
```

Note: The ClusterIssuer is cluster-scoped but references the secret in cert-manager namespace. The secretGenerator creates it in cert-manager namespace via the kustomization namespace setting.

- [ ] **Step 4: Commit**

```bash
git add infrastructure/controllers/cert-manager/
git commit -m "feat: add letsencrypt clusterissuer with cloudflare dns-01"
```

---

### Task 3: Deploy kanidm

**Files:**

- Create: `apps/kanidm/ns.yaml`
- Create: `apps/kanidm/config.toml`
- Create: `apps/kanidm/certificate.yaml`
- Create: `apps/kanidm/statefulset.yaml`
- Create: `apps/kanidm/service.yaml`
- Create: `apps/kanidm/kustomization.yaml`
- Modify: `apps/kustomization.yaml` (add kanidm)

- [ ] **Step 1: Create namespace**

```yaml
# apps/kanidm/ns.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kanidm
```

- [ ] **Step 2: Create kanidm server config**

```toml
# apps/kanidm/config.toml
bindaddress = "[::]:8443"
domain = "sso.abutt.dev"
origin = "https://sso.abutt.dev"
tls_chain = "/certs/tls.crt"
tls_key = "/certs/tls.key"
db_path = "/data/kanidm.db"
trust_x_forward_for = true
```

- [ ] **Step 3: Create certificate**

```yaml
# apps/kanidm/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kanidm-tls
spec:
  secretName: kanidm-tls
  issuerRef:
    name: letsencrypt
    kind: ClusterIssuer
  dnsNames:
    - sso.abutt.dev
```

- [ ] **Step 4: Create service**

```yaml
# apps/kanidm/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: kanidm
spec:
  selector:
    app: kanidm
  ports:
    - name: https
      port: 8443
      targetPort: 8443
      protocol: TCP
```

- [ ] **Step 5: Create statefulset**

```yaml
# apps/kanidm/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kanidm
  annotations:
    reloader.stakater.com/auto: "true"
spec:
  serviceName: kanidm
  replicas: 1
  selector:
    matchLabels:
      app: kanidm
  template:
    metadata:
      labels:
        app: kanidm
    spec:
      containers:
        - name: kanidm
          image: ghcr.io/kanidm/server:1.9.2
          ports:
            - containerPort: 8443
          volumeMounts:
            - name: config
              mountPath: /data/server.toml
              subPath: config.toml
              readOnly: true
            - name: certs
              mountPath: /certs
              readOnly: true
            - name: data
              mountPath: /data
          readinessProbe:
            httpGet:
              path: /status
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /status
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 10
            periodSeconds: 30
      volumes:
        - name: config
          configMap:
            name: kanidm-config
        - name: certs
          secret:
            secretName: kanidm-tls
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: openebs-hostpath
        resources:
          requests:
            storage: 1Gi
```

- [ ] **Step 6: Create kustomization**

```yaml
# apps/kanidm/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kanidm
resources:
  - ns.yaml
  - certificate.yaml
  - statefulset.yaml
  - service.yaml
generatorOptions:
  disableNameSuffixHash: true
configMapGenerator:
  - name: kanidm-config
    files:
      - config.toml
```

- [ ] **Step 7: Add kanidm to apps kustomization**

Modify `apps/kustomization.yaml` — add `- kanidm` to resources list.

- [ ] **Step 8: Verify kustomize build**

Run: `kustomize build apps/kanidm`
Expected: Valid YAML output with all kanidm resources in kanidm namespace

- [ ] **Step 9: Commit**

```bash
git add apps/kanidm/ apps/kustomization.yaml
git commit -m "feat: deploy kanidm identity provider"
```

---

### Task 4: Add TLS passthrough route for kanidm

**Files:**

- Modify: `infrastructure/controllers/cilium/gateway.yaml` (add TLS listener)
- Create: `apps/kanidm/tlsroute.yaml`
- Modify: `apps/kanidm/kustomization.yaml` (add tlsroute)
- Modify: `apps/cloudflared/abutt.dev/config.yaml` (add sso.abutt.dev route)

- [ ] **Step 1: Add TLS passthrough listener to gateway**

Modify `infrastructure/controllers/cilium/gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cloudflare-tunnel
  namespace: default
spec:
  gatewayClassName: cilium
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

- [ ] **Step 2: Create TLSRoute**

```yaml
# apps/kanidm/tlsroute.yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: kanidm
spec:
  parentRefs:
    - name: cloudflare-tunnel
      namespace: default
      sectionName: tls-passthrough
  hostnames:
    - sso.abutt.dev
  rules:
    - backendRefs:
        - name: kanidm
          port: 8443
```

- [ ] **Step 3: Add tlsroute to kanidm kustomization**

Add `- tlsroute.yaml` to the resources list in `apps/kanidm/kustomization.yaml`.

- [ ] **Step 4: Add sso.abutt.dev to cloudflare tunnel config**

Modify `apps/cloudflared/abutt.dev/config.yaml` — add `sso.abutt.dev` route before the wildcard, pointing to the gateway on port 443 with `originRequest.noTLSVerify: true` since the gateway terminates nothing:

```yaml
metrics: 0.0.0.0:2000
no-autoupdate: true
ingress:
  - hostname: "sso.abutt.dev"
    service: https://cilium-gateway-cloudflare-tunnel.default.svc.cluster.local:443
    originRequest:
      noTLSVerify: true
  - hostname: "valentines.abutt.dev"
    service: http://valentines.valentines.svc.cluster.local:80
  - hostname: "blog.abutt.dev"
    service: http://blog.blog.svc.cluster.local:80
  - hostname: "*.abutt.dev"
    service: http://cilium-gateway-cloudflare-tunnel.default.svc.cluster.local:80
  - service: http_status:503
```

- [ ] **Step 5: Commit**

```bash
git add infrastructure/controllers/cilium/gateway.yaml apps/kanidm/ apps/cloudflared/abutt.dev/config.yaml
git commit -m "feat: add TLS passthrough route for kanidm"
```

---

### Task 5: Reconfigure oauth2-proxy

**Files:**

- Modify: `infrastructure/controllers/oauth2-proxy/manifests/oauth2-proxy.yaml` (update OIDC issuer URL)

- [ ] **Step 1: Update OIDC issuer URL in oauth2-proxy manifest**

In `infrastructure/controllers/oauth2-proxy/manifests/oauth2-proxy.yaml`, find the ConfigMap with `oauth2_proxy.cfg` and change:

- `oidc_issuer_url = "https://auth.abutt.dev"` → `oidc_issuer_url = "https://sso.abutt.dev"`
- Comment should change from `# Zitadel OIDC provider` → `# Kanidm OIDC provider`

Note: oauth2-proxy secrets (client-id, client-secret, cookie-secret) will need updating after kanidm is configured and an OIDC client is created. This is a post-deployment manual step.

- [ ] **Step 2: Commit**

```bash
git add infrastructure/controllers/oauth2-proxy/
git commit -m "feat: point oauth2-proxy at kanidm OIDC"
```

---

### Task 6: Clean up zitadel and old branches

**Files:**

- Delete: `apps/zitadel/` directory
- Delete remote branches: `origin/feat/zitadel-oauth2proxy`, `origin/feat/cloudflare-tunnel-gateway`

- [ ] **Step 1: Remove zitadel app directory**

Run: `rm -rf apps/zitadel`

- [ ] **Step 2: Remove zitadel from apps kustomization if referenced**

Check `apps/kustomization.yaml` for any zitadel reference and remove it.

- [ ] **Step 3: Delete remote branches**

```bash
git push origin --delete feat/zitadel-oauth2proxy
git push origin --delete feat/cloudflare-tunnel-gateway
```

- [ ] **Step 4: Commit**

```bash
git add apps/zitadel apps/kustomization.yaml
git commit -m "chore: remove zitadel and clean up old branches"
```

---

### Task 7: Push and verify

- [ ] **Step 1: Push all changes**

Run: `git push`

- [ ] **Step 2: Wait for Flux reconciliation**

Run: `kubectl get kustomization -n flux-system -w`
Expected: All kustomizations show `True` / `Applied revision`

- [ ] **Step 3: Verify cert-manager is running**

Run: `kubectl get pods -n cert-manager`
Expected: cert-manager, cert-manager-cainjector, cert-manager-webhook pods Running

- [ ] **Step 4: Verify ClusterIssuer is ready**

Run: `kubectl get clusterissuer letsencrypt`
Expected: `READY: True`

- [ ] **Step 5: Verify kanidm certificate is issued**

Run: `kubectl get certificate kanidm-tls -n kanidm`
Expected: `READY: True`

- [ ] **Step 6: Verify kanidm is running**

Run: `kubectl get pods -n kanidm`
Expected: kanidm-0 Running 1/1

- [ ] **Step 7: Verify kanidm is accessible**

Run: `curl -k https://sso.abutt.dev/status`
Expected: 200 response

- [ ] **Step 8: Initialize kanidm admin**

Run: `kubectl exec -n kanidm kanidm-0 -- kanidmd recover-account admin`
Note: Save the generated password securely.
