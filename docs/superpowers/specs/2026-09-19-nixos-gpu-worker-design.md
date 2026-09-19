# NixOS GPU Worker (gem-gpu-0) — Design

**Date:** 2026-09-19
**Hardware:** Razer Blade 17 (2022, RZ09-0423), Intel Alder Lake, NVIDIA RTX 3070 Ti (Ampere)
**Role:** Headless NixOS Kubernetes worker in the gems cluster, dedicated to GPU workloads.
**Supersedes:** `nix-config/docs/superpowers/specs/2026-04-28-razerblade-host-design.md`, which placed the host in nix-config and was never implemented. The host now lives in gems because every input to it (IP, Kubernetes version, control-plane endpoints, join credentials) already comes from this repo.

## Goal

1. Boot unattended after power loss with LUKS auto-unlocked by TPM2.
2. Register with the cluster as `gem-gpu-0`, tainted so only GPU work lands on it.
3. Expose the RTX 3070 Ti to pods through CDI.
4. Be provisioned with nixos-anywhere from a custom installer ISO and deployed with deploy-rs, both from the gems devshell.
5. Be defined in `nix/nodes.nix` like every other node, so the existing scripts know about it.

## Non-Goals

- No desktop, no home-manager, no Wi-Fi, no sleep.
- No cluster-side manifests. The NVIDIA device plugin and its taint toleration are a separate Flux change in `infrastructure/` after the node is Ready.
- No second GPU node abstraction. The host is one flat file; if a second machine appears, the shared parts get extracted then.

## Prerequisite ordering

nixpkgs ships Kubernetes 1.37 and the cluster runs 1.35.3. A kubelet may not be newer than its apiserver, so this host cannot join until the cluster is on 1.37. The host config asserts this at eval time and will refuse to build before it. Order of work:

1. Talos 1.12.6 → 1.13.10 → 1.14.1 (branch `chore/upgrade-talos-1.14`, already prepared).
2. `upgrade-k8s 1.37.x` and bump `versions.kubernetes` in nodes.nix.
3. This design.

## Inputs required from Anthony at implementation time

- A DHCP reservation for the Blade's wired MAC, and the resulting IP for its nodes.nix entry.
- A LUKS passphrase, supplied to nixos-anywhere as a key file at install time. It becomes the fallback slot after TPM enrollment.

## Layout

```
flake.nix                      inputs + wiring only
nix/nodes.nix                  gem-gpu-0 entry; every node gains os = "talos" | "nixos"
nix/gem-gpu-0.nix              the whole host (one flat module)
nix/installer-iso.nix          installer image
nix/deploy-rs-overlay.nix      deploy-rs binary from nixpkgs, lib from the flake
nix/shell.nix                  apply-gem-gpu-0 → deploy; Talos scripts filter os = "talos"
nix/packages.nix               talos-gen gets INSTALLER/CONTRACT vars and the NixOS node filtered out
scripts/talos-gen.sh           new subcommand: join-config <node>
secrets/secrets.nix            agenix recipient map
secrets/gem-gpu-0-bootstrap-kubeconfig.age
talos/ca.crt                   cluster CA, plaintext, committed (public key material)
docs/gpu-worker.md             install and join runbook
```

### Flake inputs

Three new inputs, each doing one thing nixpkgs does not: `disko`, `agenix`, `deploy-rs`. All `follows` nixpkgs where they take one; agenix's `darwin` and `home-manager` inputs are set to follow nothing so they drop out of the lock. nixos-hardware is not added: it exports no Alder Lake or Ampere module attribute, and the four settings those directories would have applied (Intel microcode, fstrim, open kernel modules, the nvidia video driver) are one line each in the host. New devshell packages: `nixos-anywhere` and `deploy-rs` from nixpkgs, `agenix` from the agenix input.

### flake.nix additions

- `nixosConfigurations.gem-gpu-0` = `nixpkgs.lib.nixosSystem` with `specialArgs = { nodes; node; }` (the whole nodes.nix attrset and this node's entry) and modules: `disko.nixosModules.disko`, `agenix.nixosModules.default`, `./nix/gem-gpu-0.nix`.
- `nixosConfigurations.installer` from `./nix/installer-iso.nix`; `packages.x86_64-linux.installer-iso` = its `system.build.isoImage`.
- `deploy.nodes.gem-gpu-0`: hostname = node IP, `sshUser = "anthony"`, `user = "root"`, `profiles.system.path = deploy-rs.lib.activate.nixos` on the configuration, magic rollback and auto-rollback left at their defaults (on).
- `checks.x86_64-linux` gains `gem-gpu-0 = nixosConfigurations.gem-gpu-0.config.system.build.toplevel` and the deploy-rs `deployChecks`.

flake.nix stays a table of contents: one `nixosSystem` call, one deploy node, one ISO output, one check entry. All configuration lives in the `nix/` files.

## nodes.nix

```nix
{
  name = "gem-gpu-0";
  ip = "<reserved IP>";
  type = "worker";
  os = "nixos";
}
```

Existing nodes get `os = "talos"`. `talos-gen configs`, the `apply-<talos node>` and `upgrade-<talos node>` generators, and the talosconfig endpoint list all filter on `os == "talos"`. `apply-gem-gpu-0` is generated for `os == "nixos"` and runs `deploy .#gem-gpu-0`. There is no `upgrade-gem-gpu-0`; a NixOS upgrade is a flake update plus apply.

## Host: nix/gem-gpu-0.nix

One module, sections in this order. It takes `nodes` and `node` from specialArgs and derives hostname, node IP, control-plane endpoints, and the Kubernetes version from them. No values are duplicated from nodes.nix.

### Hardware and boot

- `nixpkgs.hostPlatform = "x86_64-linux"`, `hardware.enableRedistributableFirmware = true`, `hardware.cpu.intel.updateMicrocode = true`, `services.fstrim.enable = true`.
- Initrd modules written by hand, no generated hardware-configuration: `nvme`, `xhci_pci`, `thunderbolt`, `usb_storage`, `sd_mod`, `rtsx_pci_sdmmc`; `kernelModules = [ "kvm-intel" ]`.
- systemd-boot, `boot.initrd.systemd.enable = true`, LUKS device `crypted` at `/dev/disk/by-partlabel/disk-main-luks` with `crypttabExtraOpts = [ "tpm2-device=auto" ]`.
- Disko: `/dev/nvme0n1`, GPT, 1G ESP (vfat, `/boot`, `umask=0077`), remainder LUKS (`allowDiscards`, `passwordFile = "/tmp/secret.key"`) containing ext4 at `/` with `noatime`. No swap.
- Sysctls Talos sets that Cilium and the kubelet expect: `net.ipv4.ip_forward = 1`, `net.ipv6.conf.all.forwarding = 1`, `fs.inotify.max_user_instances = 8192`, `fs.inotify.max_user_watches = 1048576`.

### Power

- `services.logind.settings.Login`: `HandleLidSwitch`, `HandleLidSwitchDocked`, `HandleLidSwitchExternalPower` = `ignore`; `HandlePowerKey` = `poweroff`.
- `systemd.sleep.settings.Sleep`: suspend, hibernate, hybrid-sleep, suspend-then-hibernate all `no`.

### Networking

- `networking.hostName = node.name`, `useNetworkd = true`, `useDHCP = true`, `wireless.enable = false`, `networkmanager.enable = false`, `firewall.enable = false`.
- `systemd.network.wait-online.anyInterface = true`.

### NVIDIA

- `services.xserver.videoDrivers = [ "nvidia" ]` (this is how the driver loads; no display server is enabled).
- `hardware.graphics.enable = true`.
- `hardware.nvidia`: `package = config.boot.kernelPackages.nvidiaPackages.production`; `open = true` (Ampere supports the open kernel modules); `nvidiaPersistenced = true`; `powerManagement.enable = false`; `powerManagement.finegrained = false`; no `prime`.
- `hardware.nvidia-container-toolkit.enable = true`. This generates the CDI spec under `/var/run/cdi`. The module wires CDI into podman and docker only, so containerd gets `enable_cdi` and `cdi_spec_dirs` set explicitly below.
- `nixpkgs.config.allowUnfreePredicate` allows by name: `nvidia-x11`, `nvidia-settings`, `nvidia-persistenced`. Nothing else unfree.

### Container runtime

- `virtualisation.containerd.enable = true`.
- `settings.plugins."io.containerd.grpc.v1.cri"`: `containerd.runtimes.runc.options.SystemdCgroup = true`; `cni.bin_dir = "/opt/cni/bin"`; `cni.conf_dir = "/etc/cni/net.d"`; `enable_cdi = true`; `cdi_spec_dirs = [ "/etc/cdi" "/var/run/cdi" ]`. Cilium's install container populates both CNI directories.
- `systemd.tmpfiles.rules` create `/opt/cni/bin`, `/etc/cni/net.d`, `/var/lib/kubelet` (0700), `/var/openebs/local`.

### API server proxy (KubePrism stand-in)

`services.haproxy` with a TCP frontend on `127.0.0.1:7445` and a backend of every control-plane node from nodes.nix on port 6443, `check inter 2s`. The kubelet and the Cilium agent both use it, so `infrastructure/controllers/cilium/helm-values.yaml` is untouched. The apiserver certificate already lists `127.0.0.1`.

### Kubelet

A plain `systemd.services.kubelet`, not `services.kubernetes`. Reason: that module has no bootstrap-kubeconfig path, writes a static-certificate kubeconfig into the store, and its `roles` switch drags in flannel and its own PKI.

- Unit: `after` and `requires` `containerd.service` and `haproxy.service`; `wantedBy multi-user.target`; `Restart = always`; `path` includes `util-linux`, `iproute2`, `ethtool`, `kubernetes`.
- ExecStart: `kubelet --config=<KubeletConfiguration> --kubeconfig=/var/lib/kubelet/kubeconfig --bootstrap-kubeconfig=<agenix path> --cert-dir=/var/lib/kubelet/pki --node-ip=<node.ip>`.
- KubeletConfiguration (`kubelet.config.k8s.io/v1beta1`) rendered from Nix with `pkgs.formats.yaml`:
  - `cgroupDriver: systemd`, `containerRuntimeEndpoint: unix:///run/containerd/containerd.sock`
  - `clusterDNS: [10.96.0.10]`, `clusterDomain: cluster.local`
  - `authentication`: anonymous off, webhook on, `x509.clientCAFile` = the committed `talos/ca.crt`; `authorization.mode: Webhook`
  - `rotateCertificates: true`, `serverTLSBootstrap: false` (the cluster has no serving-cert approver, matching the Talos kubelets)
  - `seccompDefault: true`, `failSwapOn: true`
  - `registerWithTaints: [{ key: nvidia.com/gpu, value: present, effect: NoSchedule }]`
- Eval-time assertion: with `k = lib.versions.minor pkgs.kubernetes.version` and `c = lib.versions.minor nodes.versions.kubernetes`, require `k <= c && k >= c - 3`, message naming `upgrade-k8s` and nodes.nix as the fix.

### SSH, users, sudo, nix

- `users.users.anthony`: normal user, `wheel`, authorized keys = the two `no-touch-required sk-ssh-ed25519` YubiKey keys from nix-config's SSH module.
- `services.openssh`: enabled, ed25519 host key only, `PasswordAuthentication`, `KbdInteractiveAuthentication` off, `PermitRootLogin no`, `AuthenticationMethods publickey`.
- `security.sudo.wheelNeedsPassword = false`. The user has no password (`users.mutableUsers = false`, key-only SSH), and both deploy-rs activation and the one-time TPM enrollment need root. Scoping sudo to the deploy-rs binaries would leave the enrollment step with no way to run.
- `nix.settings`: `experimental-features = [ nix-command flakes ]`, `trusted-users = [ anthony ]` (deploy-rs pushes the closure as that user), `auto-optimise-store`; `nix.gc.automatic = true`, weekly, `--delete-older-than 14d`.
- `system.stateVersion = "26.11"`, the release of the pinned nixpkgs.

### Secrets

- `age.secrets.bootstrap-kubeconfig.file = ../secrets/gem-gpu-0-bootstrap-kubeconfig.age`, owner root, mode 0400. Identity is the host's `/etc/ssh/ssh_host_ed25519_key` (agenix default).
- age cannot use FIDO `sk-ssh-ed25519` keys as recipients, so the YubiKeys are for SSH login only. Recipients in `secrets/secrets.nix` are the three operator machine keys already trusted in `.sops.yaml` (`tiberius`, `lapnix`, `atlas`) plus the `gem-gpu-0` host key.
- The host key is generated on the workstation before install into a gitignored `tmp/` tree and shipped in with `nixos-anywhere --extra-files`, so the first boot already decrypts.

## talos-gen join-config

New subcommand `talos-gen join-config <node>`:

1. Decrypts `talos/secrets.yaml` exactly as `configs` does.
2. Writes `talos/ca.crt` from `cluster.ca.crt` (plaintext, committed, not secret).
3. Builds a kubeconfig with `server: https://127.0.0.1:7445`, the CA embedded, and a `tls-bootstrap-token-user` whose token is `cluster.token`. This is the same bootstrap token the Talos kubelets used, and the cluster already carries the `system-bootstrap-node-bootstrapper` and `approve-node-client-csr` bindings, so the CSR is auto-approved.
4. Encrypts it with `age`, recipients read from `secrets/secrets.nix` via `nix eval`, to `secrets/<node>-bootstrap-kubeconfig.age`.
5. Re-encrypts `talos/secrets.yaml`.

## Installer ISO: nix/installer-iso.nix

`installation-cd-minimal` plus: `services.openssh.enable = true`, root authorized keys = the two YubiKey keys, flakes enabled, `nixpkgs.hostPlatform`. Nothing else. `nix build .#installer-iso` produces it. nixos-anywhere does the actual install from the workstation.

## Runbook: docs/gpu-worker.md

1. Confirm the cluster is on Kubernetes 1.37 and nodes.nix matches.
2. Add the DHCP reservation; put the IP in nodes.nix.
3. `ssh-keygen -t ed25519 -N "" -f ./tmp/etc/ssh/ssh_host_ed25519_key`; add the public key to `secrets/secrets.nix` as `gem-gpu-0`.
4. `talos-gen join-config gem-gpu-0`; commit `talos/ca.crt` and the `.age` file.
5. `nix build .#installer-iso`, write to USB, boot the Blade, note its IP.
6. `nixos-anywhere --flake .#gem-gpu-0 --disk-encryption-keys /tmp/secret.key ./luks.key --extra-files ./tmp root@<iso-ip>`.
7. After reboot (enter the passphrase once): `sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p2`. Reboot to confirm unattended unlock.
8. `kubectl get nodes`: `gem-gpu-0` Ready with the `nvidia.com/gpu=present:NoSchedule` taint. Cilium's DaemonSet lands on its own.
9. Follow-up PR: NVIDIA device plugin in `infrastructure/`, `deviceListStrategy: cdi-cri`, tolerating the taint.
10. Day two: `apply-gem-gpu-0`.

## Testing

- `nix flake check` builds the host toplevel, the installer ISO derivation, and the deploy-rs checks. The Kubernetes skew assertion is exercised by this.
- `talosctl validate` still passes for the regenerated Talos configs after the `os` filter lands.
- Live verification is the runbook: node Ready, taint present, `kubectl describe node` shows `nvidia.com/gpu` capacity once the device plugin is deployed.

## Rules touched

- Nix standard updated 2026-09-19: headless hosts deploy with deploy-rs. This host follows the new rule.
- Secrets use agenix per the Nix standard, alongside the existing SOPS usage for Talos and Flux material. The CA is committed in plaintext because it is public key material, not a secret.
