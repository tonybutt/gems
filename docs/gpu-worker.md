# GPU Worker: gem-gpu-0

Razer Blade 17 (2022, RZ09-0423) running NixOS as a Kubernetes worker
dedicated to GPU workloads. Defined in `nix/nodes.nix` with `os = "nixos"`
and built from `nix/gem-gpu-0.nix`.

## Prerequisites

- Cluster on the Kubernetes minor that nixpkgs ships. Check with
  `kubectl version` and `nix eval --raw .#nixosConfigurations.gem-gpu-0.config.systemd.services.kubelet.path`.
  The host refuses to build if the kubelet would be newer than the cluster.
- A DHCP reservation for the Blade's wired MAC matching its `ip` in `nix/nodes.nix`.
- `tmp/etc/ssh/ssh_host_ed25519_key` from the join-config step below. It is
  gitignored and is the host's only identity; back it up until the machine is installed.

## First install

1. Generate the host key and register it as an agenix recipient:

   ```bash
   mkdir -p tmp/etc/ssh
   ssh-keygen -t ed25519 -N "" -C gem-gpu-0 -f tmp/etc/ssh/ssh_host_ed25519_key
   ```

   Put the contents of `tmp/etc/ssh/ssh_host_ed25519_key.pub` in
   `secrets/secrets.nix` as `gem-gpu-0`.

2. Emit the join credential and the cluster CA, then commit both outputs:

   ```bash
   talos-gen join-config gem-gpu-0
   git add talos/ca.crt secrets/gem-gpu-0-bootstrap-kubeconfig.age
   ```

3. Build the installer and write it to a USB stick:

   ```bash
   nix build .#installer-iso
   sudo dd if=result/iso/nixos-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```

4. Boot the Blade from the stick (F12 at the Razer logo). Find its DHCP
   address on the router; call it `ISO_IP`.

5. Write the LUKS passphrase to a local file and install:

   ```bash
   printf '%s' 'the passphrase' > luks.key
   nixos-anywhere --flake .#gem-gpu-0 \
     --disk-encryption-keys /tmp/secret.key ./luks.key \
     --extra-files ./tmp \
     root@ISO_IP
   rm luks.key
   ```

   The machine reboots into NixOS and asks for the passphrase once on the console.

6. Enroll the TPM so later boots are unattended, then reboot to confirm:

   ```bash
   ssh anthony@<reserved IP>
   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p2
   sudo reboot
   ```

7. Confirm the node joined:

   ```bash
   kubectl get nodes gem-gpu-0 -o wide
   kubectl get node gem-gpu-0 -o jsonpath='{.spec.taints}'
   ```

   Expected: `Ready`, and the taint `nvidia.com/gpu=present:NoSchedule`.
   Cilium's DaemonSet schedules itself; nothing else does until it tolerates the taint.

8. Deploy the NVIDIA device plugin from `infrastructure/` with
   `deviceListStrategy: cdi-cri` and a toleration for the taint. That is a
   separate change; after it lands, `kubectl describe node gem-gpu-0` shows
   `nvidia.com/gpu: 1` under Capacity.

## Day two

```bash
apply-gem-gpu-0
```

deploy-rs pushes the closure over SSH as `anthony`, activates as root, and
rolls back if it cannot reconnect afterwards.

## Rotating the join credential

The bootstrap kubeconfig is only used until the kubelet has its own client
certificate. Re-run `talos-gen join-config gem-gpu-0` if the Talos secrets
bundle changes, then `apply-gem-gpu-0`.
