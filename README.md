## Dependencies
- Nix
This project leverages a flake for dependencies and common commands.
### Generate Talos Cluster configs
```sh
talhelper genconfig
```
### Bootstrap CNI
```sh
helm install \
    cilium \
    cilium/cilium \
    --version 1.16.3 \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445
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