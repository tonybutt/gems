## Dependencies
- Nix
This project leverages a flake for dependencies and common commands.
### Bootstrap
```shell
  bootstrap-gems
```

### Applying Infrastructure Configurations
I keep the configuration for the cluster ephermal by leveraging talos's strategic merge patches.
*Base Patches* are applied to all nodes in the cluster.
*Node Specific Patches* are applied to a specific node in the cluster.
All patches for nodes are in the [infrastructure nodes](./infrastructure/nodes) directory.
```shell
  apply-<node name>
```
This command will apply the configuration for the specified node with the base patches and the node specific patches. This command is crafted declaratively from the flake configuration by configuring the nodes attribute set.

### Upgrading the Cluster
*Talos OS*
```shell
  upgrade-<node name> <talos version>
```
*Kubernetes*
```shell
  talosctl -n <controlplane node> upgrade-k8s --to <k8s version> --dry-run
```
When upgrading you have to update the machine configuration patches to the versions you are upgrading to.
```yaml
machine:
  install:
    image: ghcr.io/siderolabs/installer:v1.9.3
  kubelet:
    image: ghcr.io/siderolabs/kubelet:v1.32.0
cluster:
  apiServer:
    image: ghcr.io/siderolabs/kube-apiserver:v1.32.0
  controllerManager:
    image: ghcr.io/siderolabs/kube-controller-manager:v1.32.0
  scheduler:
    image: ghcr.io/siderolabs/kube-scheduler:v1.32.0
```
