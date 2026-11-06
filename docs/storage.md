# Cluster Storage Documentation

## Node Drive Inventory

All nodes in the Gems cluster are Intel NUCs with NVMe storage. Talos is installed on the primary NVMe drive on each node.

### Control Plane Nodes

| Node         | IP             | Drive        | Model                    | Size   | Serial             | WWID                                                                                               |
| ------------ | -------------- | ------------ | ------------------------ | ------ | ------------------ | -------------------------------------------------------------------------------------------------- |
| gem-master-0 | 192.168.86.250 | /dev/nvme0n1 | Lexar SSD NM6A1 256GB    | 256 GB | MJF971R001481P1100 | nvme.1e4b-4d4a46393731523030313438315031313030-4c6578617220535344204e4d364131203235364742-00000001 |
| gem-master-1 | 192.168.86.21  | /dev/nvme0n1 | KINGSTON OM8PDP3512B-A01 | 512 GB | 50026B76849EAB75   | eui.0026b76849eab755                                                                               |
| gem-master-2 | 192.168.86.31  | /dev/nvme0n1 | KINGSTON OM8PDP3512B-A01 | 512 GB | 50026B76849EABCC   | eui.0026b76849eabcc5                                                                               |

### Worker Nodes

| Node         | IP            | Drive        | Model                    | Size   | Serial           | WWID                 |
| ------------ | ------------- | ------------ | ------------------------ | ------ | ---------------- | -------------------- |
| gem-worker-0 | 192.168.86.25 | /dev/nvme0n1 | KINGSTON OM8PDP3256B-A01 | 256 GB | 50026B7684A9326B | eui.0026b7684a9326b5 |
| gem-worker-1 | 192.168.86.37 | /dev/nvme0n1 | KINGSTON OM8PDP3256B-A01 | 256 GB | 50026B7684A6F4EC | eui.0026b7684a6f4ec5 |

### Storage Summary

- **Total Cluster Storage**: 1.75 TB (1792 GB)
- **Control Plane Storage**: 1.25 TB (256 GB + 512 GB + 512 GB)
- **Worker Storage**: 512 GB (256 GB + 256 GB)

All drives are NVMe SSDs connected via PCIe. The drives use GPT partitioning with:

- Partition 1: EFI System Partition (~2.2 GB)
- Partition 2-6: Talos system partitions (BIOS, BOOT, META, STATE, EPHEMERAL)

## OpenEBS LocalPV Configuration

The cluster uses OpenEBS LocalPV Hostpath for persistent storage. This provides non-replicated local storage suitable for workloads that manage their own replication or don't require HA storage.

### Storage Class

The `openebs-hostpath` StorageClass is configured with:

- **Volume Binding Mode**: `WaitForFirstConsumer` - volumes are provisioned only when a pod using the PVC is scheduled
- **Reclaim Policy**: `Retain` - PV storage is kept when the PVC is deleted
- **Provisioner**: `openebs.io/local`

### Host Path Location

Local volumes are stored at `/var/mnt/openebs-local` on each node. That path is a
Talos `UserVolumeConfig` directory volume (`talos/patches/base.yaml`). Talos
mounts every user volume under `/var/mnt/<name>` and exposes `/var/mnt` to the
kubelet, so no kubelet `extraMounts` are needed. Talos 1.14's `KubeletConfig`
document cannot express extra mounts anyway.

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: openebs-local
volumeType: directory
```

Before Talos 1.14 the path was `/var/openebs/local`, bind-mounted into the
kubelet with `machine.kubelet.extraMounts`. See "Migrating from
/var/openebs/local" below.

### Important Notes

1. **Upgrades**: When upgrading Talos, always use `talosctl upgrade --preserve` to avoid wiping the EPHEMERAL partition that holds `/var/mnt/openebs-local`.

2. **Data Locality**: Pods using LocalPV storage are bound to the node where the PV was created. Use node affinity or topology constraints if needed.

3. **No Replication**: LocalPV provides single-node storage. For replicated storage, consider OpenEBS Mayastor or Jiva.

4. **Namespace Security**: The openebs namespace requires privileged pod security labels due to hostPath volume usage.

## Migrating from /var/openebs/local

A PV's `spec.local.path` is immutable, so each existing volume is copied on its
node and its PV is recreated with the new path. The StorageClass reclaim policy
is `Retain`, so deleting a PVC or PV never deletes data.

Volumes at the time of the move:

| PV                                       | Claim                | Node         |
| ---------------------------------------- | -------------------- | ------------ |
| pvc-c47f2904-0245-48e3-b09b-fe7b3c9015e6 | blog/blog-data       | gem-worker-0 |
| pvc-88880768-cad1-4400-b596-16d3a104871e | kanidm/data-kanidm-0 | gem-worker-1 |
| pvc-da8b0614-5392-4b64-a09a-ebfbc26666ef | jcu-site/jcu-data    | gem-worker-1 |
| pvc-b6571b5d-1f4e-40dd-9d06-7bd09ae79272 | opengym/opengym-data | gem-master-2 |

1. Canary: `talos-gen configs`, then `apply-gem-master-1` (no local volumes).
   Check `talosctl -n <ip> get volumestatus u-openebs-local` reports `ready`.
2. For each node that holds volumes, one node at a time:
   1. Back up each volume off the node.
   2. `flux suspend kustomization` for the owning app, then scale it to 0.
   3. `apply-<node>`; the dry-run reports no reboot.
   4. Copy the data with a privileged pod pinned to the node that mounts host
      `/var`: `cp -a /var/openebs/local/<pv>/. /var/mnt/openebs-local/<pv>/`.
   5. Save the PV (`kubectl get pv <pv> -o yaml`), delete the PVC and the PV,
      and create the PV again with `spec.local.path` set to
      `/var/mnt/openebs-local/<pv>`. Keep its name, annotations and node
      affinity; drop `uid`, `resourceVersion`, `status` and `claimRef.uid` so
      the recreated PVC binds to it.
   6. `flux resume kustomization`, scale the app back up, and check its data.
3. Apply the remaining nodes, then merge so Flux recreates the
   `openebs-hostpath` StorageClass (forced; its parameters are immutable) and
   the provisioner with the new base path.
4. Once every app is verified, remove `/var/openebs/local` from each node.

## Querying Disk Information

To refresh disk information from the cluster:

```bash
# List disks on all nodes
for node in 192.168.86.250 192.168.86.21 192.168.86.31 192.168.86.25 192.168.86.37; do
  echo "=== Node: $node ==="
  talosctl -n $node get disks
done

# Get detailed disk info in YAML format
talosctl -n <node-ip> get disks -o yaml

# View discovered volumes (partitions)
talosctl -n <node-ip> get discoveredvolumes
```
