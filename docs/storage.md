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
- **Reclaim Policy**: `Delete` - PV storage is deleted when PVC is deleted
- **Provisioner**: `openebs.io/local`

### Host Path Location

Local volumes are stored at `/var/openebs/local` on each node. This path is bind-mounted into the kubelet container via Talos machine configuration.

### Talos Configuration Requirements

For OpenEBS LocalPV to work on Talos, the following machine config is required:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/openebs/local
        type: bind
        source: /var/openebs/local
        options:
          - rbind
          - rshared
          - rw
```

### Important Notes

1. **Upgrades**: When upgrading Talos, always use `talosctl upgrade --preserve` to avoid wiping the `/var/openebs/local` directory.

2. **Data Locality**: Pods using LocalPV storage are bound to the node where the PV was created. Use node affinity or topology constraints if needed.

3. **No Replication**: LocalPV provides single-node storage. For replicated storage, consider OpenEBS Mayastor or Jiva.

4. **Namespace Security**: The openebs namespace requires privileged pod security labels due to hostPath volume usage.

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
