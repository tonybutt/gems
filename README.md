## Dependencies
- Nix
This project leverages a flake for dependencies and common commands.
### Generate Talos Cluster configs
```sh
talhelper genconfig
```
### Bootstrap CNI
```sh
helm template \
    cilium \
    cilium/cilium \
    --version 1.16.3 \
    --values clusters/gems/platform/cilium/helm-values.yaml \
    | kubectl apply -f -
```

### Bootstrap Flux
```sh
export GITHUB_TOKEN=<token>
flux bootstrap github \
  --token-auth \
  --owner=tonybutt \
  --repository=gems \
  --branch=main \
  --path=clusters/gems \
  --personal
```

```sh
rage-keygen -o $HOME/.config/sops/age/keys.txt
```

```sh
cat $HOME/.config/sops/age/keys.txt | kubectl create secret generic sops-age \
--namespace=flux-system \
--from-file=age.agekey=/dev/stdin
```

### Bootstrap Cloudflared
```sh
cloudflared tunnel login
cloudflared tunnel create test-tunnel
cloudflared tunnel route dns test-tunnel test.abutt.dev
```