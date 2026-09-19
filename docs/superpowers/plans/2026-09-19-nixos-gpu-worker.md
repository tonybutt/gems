# NixOS GPU Worker (gem-gpu-0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Razer Blade 17 as `gem-gpu-0`, a headless NixOS Kubernetes worker in the gems cluster, defined in nodes.nix, provisioned with nixos-anywhere from a custom ISO, deployed with deploy-rs, and tainted for GPU-only work.

**Architecture:** One flat NixOS module (`nix/gem-gpu-0.nix`) reads its identity from `nix/nodes.nix` through specialArgs. A plain systemd kubelet joins through a local haproxy that stands in for Talos KubePrism, using a bootstrap kubeconfig that `talos-gen join-config` derives from the existing Talos secrets bundle and encrypts with agenix. The Talos scripts learn to skip nodes whose `os` is not `talos`.

**Tech Stack:** NixOS 26.11 (nixos-unstable), disko, agenix, deploy-rs, nixos-anywhere, containerd 2.x with CDI, nvidia-container-toolkit, haproxy, Kubernetes 1.37 kubelet, Cilium (cluster side, unchanged).

**Spec:** `docs/superpowers/specs/2026-09-19-nixos-gpu-worker-design.md`

## Global Constraints

- Do not start until the cluster runs Kubernetes 1.37.x and `versions.kubernetes` in `nix/nodes.nix` says so. The host asserts kubelet minor ≤ cluster minor and ≥ cluster minor − 3, and nixpkgs ships kubelet 1.37.0.
- Talos 1.14.1 branch `chore/upgrade-talos-1.14` must be merged first; this plan builds on its nodes.nix shape (`installer.repository`, `versions.configContract`).
- Anthony supplies the DHCP-reserved IP for the Blade before Task 2. Every `<reserved IP>` below is that value.
- No comments in code (Anthony's core rule). Existing comment lines in files you edit stay; add none.
- Never `with lib;`, never `rec`. Use `inherit (lib) ...`.
- `nix flake update` and lockfile changes are their own commits.
- `git add` every new file before any `nix build`; untracked files are invisible to flakes.
- Commits are signed with Anthony's hardware key. Stage and write the message; if signing prompts for a touch you cannot provide, stop and hand the commit to Anthony. Never `--no-gpg-sign`, never `--no-verify`.
- Run `nix fmt` before every commit; the treefmt pre-commit hook fails on unformatted files.
- Known defect to fix before or alongside this plan: after the flake update, helm writes a warning to stderr and `scripts/render-helm.sh` merges stderr into the rendered manifest (`2>&1` on the `helm template` call), corrupting `infrastructure/controllers/cert-manager/manifests/cert-manager.yaml` and failing the `validate-kustomize` hook. It belongs to the Talos upgrade PR. Do not run `pre-commit run --all-files` expecting green until it is fixed; if the render-helm hook rewrites manifests during a commit, `git restore --staged --worktree infrastructure/` and report.
- Unfree packages only by name: `nvidia-x11`, `nvidia-settings`, `nvidia-persistenced`.
- The two YubiKey SSH keys, used verbatim wherever `YUBIKEYS` appears:

```
no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIO9ZH1VvOc2+1tAkzQzNwhyT+LT6wCBmt9gP2yeH8g+oAAAABHNzaDo= abutt@tiberius.com
no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIKoZU8AWvPjbgJfQXA3Kl6Ep9PzO6tGdN3GP4BRcTitOAAAABHNzaDo= anthony@abutt.io
```

- The three operator machine keys (agenix recipients, copied from `.sops.yaml`):

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnQDGTR3J244BlVZ3u0I9l476XRxlv0DdmREzTku3Ib abutt@tiberius.com
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPYkXD5kuITfXNUgU+yzirklzKXKRlT5ZKYwKo03lzzz abutt@tiberius.com
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII+cqj41D3k8Dk9Bz4l/06XVkkxMJIpg1orvuf56/Hme
```

---

## File Structure

| Path                                         | Action             | Responsibility                                                                             |
| -------------------------------------------- | ------------------ | ------------------------------------------------------------------------------------------ |
| `flake.nix`                                  | Modify             | Three new inputs; `nixosConfigurations`, `deploy`, `installer-iso` package, two new checks |
| `nix/nodes.nix`                              | Modify             | `os` on every node; the `gem-gpu-0` entry                                                  |
| `nix/packages.nix`                           | Modify             | talos-gen only sees Talos nodes; join-config runtime inputs                                |
| `nix/shell.nix`                              | Modify             | Talos scripts filter `os == "talos"`; `apply-gem-gpu-0`; new devshell tools; menu          |
| `scripts/talos-gen.sh`                       | Modify             | `join-config <node>` subcommand                                                            |
| `nix/gem-gpu-0.nix`                          | Create             | The whole host                                                                             |
| `nix/installer-iso.nix`                      | Create             | Installer image                                                                            |
| `nix/deploy-rs-overlay.nix`                  | Create             | deploy-rs binary from nixpkgs, lib from the flake                                          |
| `secrets/secrets.nix`                        | Create             | agenix recipient map                                                                       |
| `secrets/gem-gpu-0-bootstrap-kubeconfig.age` | Create (generated) | Encrypted bootstrap kubeconfig                                                             |
| `talos/ca.crt`                               | Create (generated) | Cluster CA, plaintext                                                                      |
| `.gitignore`                                 | Modify             | Ignore `tmp/` (pre-install host key)                                                       |
| `docs/gpu-worker.md`                         | Create             | Install and join runbook                                                                   |

---

### Task 1: Add disko, agenix, and deploy-rs inputs

**Files:**

- Modify: `flake.nix:4-24`

**Interfaces:**

- Produces: flake inputs `disko`, `agenix`, `deploy-rs` available in `outputs`.

- [ ] **Step 1: Add the inputs and output arguments**

Replace the `inputs` block and the `outputs` argument set in `flake.nix` with:

```nix
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.darwin.follows = "";
      inputs.home-manager.follows = "";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      git-hooks,
      disko,
      agenix,
      deploy-rs,
    }:
```

- [ ] **Step 2: Lock the new inputs**

Run: `nix flake lock`
Expected: output lists `Added input 'disko'`, `Added input 'agenix'`, `Added input 'deploy-rs'` and their transitive `flake-compat`/`utils` inputs. No nixpkgs change.

- [ ] **Step 3: Verify the devshell still evaluates**

Run: `nix develop --command true`
Expected: exit 0 (the menu prints, nothing else).

- [ ] **Step 4: Commit**

```bash
nix fmt
git add flake.nix flake.lock
git commit -m "build: Add disko, agenix, and deploy-rs inputs" -m "The GPU worker host needs disko for its disk layout, agenix for its join credential, and deploy-rs for deployment per the updated Nix standard for headless hosts. agenix's darwin and home-manager inputs follow nothing so they stay out of the lock."
```

---

### Task 2: Give every node an `os` and add gem-gpu-0

**Files:**

- Modify: `nix/nodes.nix`
- Modify: `nix/packages.nix:8`
- Modify: `nix/shell.nix:12-45`

**Interfaces:**

- Produces: each element of `nodes.nodes` has `os = "talos" | "nixos"`; `nodes.nodes` contains `{ name = "gem-gpu-0"; ip = "<reserved IP>"; type = "worker"; os = "nixos"; }`. Later tasks read `node.name`, `node.ip`, `nodes.cluster`, `nodes.versions.kubernetes`.

- [ ] **Step 1: Add `os` to the Talos nodes and append the new node**

In `nix/nodes.nix`, add `os = "talos";` after the `type` line of each existing node, then append the new entry before the closing `];`:

```nix
    {
      name = "gem-gpu-0";
      ip = "<reserved IP>";
      type = "worker";
      os = "nixos";
    }
```

- [ ] **Step 2: Filter talos-gen's node list**

In `nix/packages.nix`, replace the `nodesArray` definition:

```nix
  talosNodes = builtins.filter (n: n.os == "talos") nodes.nodes;

  nodesArray = builtins.concatStringsSep " " (map (n: ''"${n.name}:${n.ip}:${n.type}"'') talosNodes);
```

- [ ] **Step 3: Filter the Talos script generators in the devshell**

In `nix/shell.nix`, add after `nodeConfig = import ./nodes.nix;`:

```nix
  talosNodes = builtins.filter (n: n.os == "talos") nodeConfig.nodes;
```

Change `) nodeConfig.nodes;` at the end of `upgradeScripts` and `applyScripts` to `) talosNodes;` (two occurrences).

- [ ] **Step 4: Regenerate and validate the Talos configs**

Run:

```bash
nix develop --command talos-gen configs
git checkout talos/secrets.yaml
ls talos/gen/
for n in gem-master-0 gem-master-1 gem-master-2 gem-worker-0 gem-worker-1; do nix develop --command talosctl validate -c talos/gen/$n.yaml -m metal; done
```

Expected: `talos/gen/` holds five node configs and `talosconfig`, no `gem-gpu-0.yaml`; five lines ending `is valid for metal mode`.

- [ ] **Step 5: Confirm no Talos scripts exist for the NixOS node**

Run: `nix develop --command bash -c 'command -v apply-gem-gpu-0 upgrade-gem-gpu-0; command -v apply-gem-worker-1'`
Expected: first two names print nothing (exit 1), `apply-gem-worker-1` prints a store path.

- [ ] **Step 6: Commit**

```bash
nix fmt
git add nix/nodes.nix nix/packages.nix nix/shell.nix
git commit -m "feat(nodes): Add gem-gpu-0 and an os field per node" -m "The Razer Blade joins as a NixOS worker. Talos config generation and the per-node apply and upgrade scripts now render only for nodes whose os is talos."
```

---

### Task 3: agenix recipients, pre-install host key, and `talos-gen join-config`

**Files:**

- Create: `secrets/secrets.nix`
- Modify: `.gitignore`
- Modify: `scripts/talos-gen.sh`
- Modify: `nix/packages.nix:64-75`
- Create (generated): `secrets/gem-gpu-0-bootstrap-kubeconfig.age`, `talos/ca.crt`

**Interfaces:**

- Produces: `secrets/gem-gpu-0-bootstrap-kubeconfig.age` decryptable by `tmp/etc/ssh/ssh_host_ed25519_key`; `talos/ca.crt` PEM with subject `O=kubernetes`. Task 6 references both paths.

- [ ] **Step 1: Ignore the pre-install tree**

Append to `.gitignore`:

```
# Pre-install host key tree for nixos-anywhere --extra-files
tmp/
```

- [ ] **Step 2: Generate the host key**

Run:

```bash
mkdir -p tmp/etc/ssh
ssh-keygen -t ed25519 -N "" -C gem-gpu-0 -f tmp/etc/ssh/ssh_host_ed25519_key
cat tmp/etc/ssh/ssh_host_ed25519_key.pub
```

Expected: a line starting `ssh-ed25519 AAAA` ending `gem-gpu-0`. Copy it; it is `<gem-gpu-0 host pubkey>` below. Keep `tmp/` until the install in Task 9 is done; it is the only copy of the host's identity.

- [ ] **Step 3: Write the recipient map**

Create `secrets/secrets.nix`:

```nix
let
  tiberius = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnQDGTR3J244BlVZ3u0I9l476XRxlv0DdmREzTku3Ib abutt@tiberius.com";
  lapnix = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPYkXD5kuITfXNUgU+yzirklzKXKRlT5ZKYwKo03lzzz abutt@tiberius.com";
  atlas = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII+cqj41D3k8Dk9Bz4l/06XVkkxMJIpg1orvuf56/Hme";
  gem-gpu-0 = "<gem-gpu-0 host pubkey>";
in
{
  "gem-gpu-0-bootstrap-kubeconfig.age".publicKeys = [
    tiberius
    lapnix
    atlas
    gem-gpu-0
  ];
}
```

- [ ] **Step 4: Add the runtime inputs talos-gen needs for join-config**

In `nix/packages.nix`, replace the `talos-gen` runtimeInputs list:

```nix
    runtimeInputs = with pkgs; [
      talosctl
      sops
      gnused
      coreutils
      git
      yq-go
      jq
      age
      nix
      openssl
    ];
```

- [ ] **Step 5: Add the subcommand to the script**

In `scripts/talos-gen.sh`, add to `usage()` after the `configs` line:

```bash
  echo "  join-config <node>  Emit talos/ca.crt and secrets/<node>-bootstrap-kubeconfig.age"
```

Add this function after `generate_configs()`:

```bash
generate_join_config() {
  local node="$1"
  local secrets_file="$TALOS_DIR/secrets.yaml"
  local recipients_file="$REPO_ROOT/secrets/secrets.nix"
  local out_file="$REPO_ROOT/secrets/${node}-bootstrap-kubeconfig.age"
  local ca_file="$TALOS_DIR/ca.crt"

  if [ ! -f "$secrets_file" ]; then
    echo "Error: $secrets_file not found. Run 'talos-gen secrets' first."
    return 1
  fi
  if [ ! -f "$recipients_file" ]; then
    echo "Error: $recipients_file not found."
    return 1
  fi

  local plain
  plain="$(mktemp)"
  trap 'rm -f "$plain"' RETURN
  sops -d "$secrets_file" > "$plain"

  local ca_b64 token
  ca_b64="$(yq '.certs.k8s.crt' "$plain")"
  token="$(yq '.secrets.bootstraptoken' "$plain")"

  echo "$ca_b64" | base64 -d > "$ca_file"
  openssl x509 -in "$ca_file" -noout -subject

  local -a age_args=()
  local recipient
  while IFS= read -r recipient; do
    age_args+=(-r "$recipient")
  done < <(nix eval --json -f "$recipients_file" "\"${node}-bootstrap-kubeconfig.age\".publicKeys" | jq -r '.[]')

  age "${age_args[@]}" -o "$out_file" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: $CLUSTER_NAME
    cluster:
      server: https://127.0.0.1:7445
      certificate-authority-data: $ca_b64
users:
  - name: tls-bootstrap-token-user
    user:
      token: $token
contexts:
  - name: tls-bootstrap-token-user@$CLUSTER_NAME
    context:
      cluster: $CLUSTER_NAME
      user: tls-bootstrap-token-user
current-context: tls-bootstrap-token-user@$CLUSTER_NAME
EOF

  echo "Wrote $ca_file and $out_file"
}
```

Add a case to the `case "$COMMAND" in` block before `-h|--help)`:

```bash
  join-config)
    if [ $# -lt 2 ]; then
      echo "Usage: talos-gen join-config <node>"
      exit 1
    fi
    generate_join_config "$2"
    ;;
```

- [ ] **Step 6: Run it**

Run:

```bash
git add .gitignore secrets/secrets.nix scripts/talos-gen.sh nix/packages.nix
nix develop --command talos-gen join-config gem-gpu-0
git status --short talos/secrets.yaml
```

Expected: `subject=O=kubernetes`, then `Wrote .../talos/ca.crt and .../secrets/gem-gpu-0-bootstrap-kubeconfig.age`. `talos/secrets.yaml` shows no modification (the script decrypts to a temp file, unlike `configs`).

- [ ] **Step 7: Verify the secret decrypts with the host key and carries the live token**

Run:

```bash
age -d -i tmp/etc/ssh/ssh_host_ed25519_key secrets/gem-gpu-0-bootstrap-kubeconfig.age | nix shell nixpkgs#yq-go -c yq '.clusters[0].cluster.server, .users[0].user.token' | cut -c1-24
kubectl -n kube-system get secret bootstrap-token-2wffic -o jsonpath='{.data.token-id}' | base64 -d; echo
```

Expected: first command prints `https://127.0.0.1:7445` and a token beginning `2wffic.`; second prints `2wffic`. The bundle token and the live bootstrap token match.

- [ ] **Step 8: Commit**

```bash
nix fmt
git add secrets/secrets.nix secrets/gem-gpu-0-bootstrap-kubeconfig.age talos/ca.crt .gitignore scripts/talos-gen.sh nix/packages.nix
git commit -m "feat(talos-gen): Add join-config for NixOS workers" -m "Derives a kubelet bootstrap kubeconfig from the Talos secrets bundle and encrypts it with agenix for the node's host key plus the operator machines. The cluster CA is committed in plaintext; it is public key material and the kubelet needs it as a file."
```

---

### Task 4: Host module, part 1: boot, disk, network, power, users, nix

**Files:**

- Create: `nix/gem-gpu-0.nix`
- Modify: `flake.nix` (outputs `let` and attrset)

**Interfaces:**

- Consumes: `nodes` (the whole `nix/nodes.nix` attrset) and `node` (the gem-gpu-0 entry) as specialArgs.
- Produces: `nixosConfigurations.gem-gpu-0` and `checks.x86_64-linux.gem-gpu-0`. Tasks 5 and 6 add sections to the same module file.

- [ ] **Step 1: Create the module**

Create `nix/gem-gpu-0.nix`. The argument set is deliberately narrow; Tasks 5 and 6 widen it as they start using `config`, `lib`, `pkgs`, and `nodes` (deadnix in the hooks rejects unused arguments).

```nix
{ node, ... }:
let
  yubikeys = [
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIO9ZH1VvOc2+1tAkzQzNwhyT+LT6wCBmt9gP2yeH8g+oAAAABHNzaDo= abutt@tiberius.com"
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIKoZU8AWvPjbgJfQXA3Kl6Ep9PzO6tGdN3GP4BRcTitOAAAABHNzaDo= anthony@abutt.io"
  ];
in
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.11";

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;
  services.fstrim.enable = true;

  boot = {
    loader.systemd-boot.enable = true;
    loader.systemd-boot.configurationLimit = 5;
    loader.efi.canTouchEfiVariables = true;
    initrd.systemd.enable = true;
    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "thunderbolt"
      "usb_storage"
      "sd_mod"
      "rtsx_pci_sdmmc"
    ];
    kernelModules = [ "kvm-intel" ];
    initrd.luks.devices.crypted = {
      device = "/dev/disk/by-partlabel/disk-main-luks";
      crypttabExtraOpts = [ "tpm2-device=auto" ];
    };
    kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "fs.inotify.max_user_instances" = 8192;
      "fs.inotify.max_user_watches" = 1048576;
    };
  };

  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "crypted";
            settings.allowDiscards = true;
            passwordFile = "/tmp/secret.key";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [ "noatime" ];
            };
          };
        };
      };
    };
  };

  networking = {
    hostName = node.name;
    useNetworkd = true;
    useDHCP = true;
    wireless.enable = false;
    networkmanager.enable = false;
    firewall.enable = false;
  };
  systemd.network.wait-online.anyInterface = true;

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandlePowerKey = "poweroff";
  };
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };

  users.mutableUsers = false;
  users.users.anthony = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = yubikeys;
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AuthenticationMethods = "publickey";
    };
  };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "anthony" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
}
```

- [ ] **Step 2: Wire the configuration and check into the flake**

In `flake.nix`, add to the outputs `let` block after `nodes = import ./nix/nodes.nix;`:

```nix
      gpuNode = nixpkgs.lib.findFirst (n: n.name == "gem-gpu-0") (throw "gem-gpu-0 missing from nix/nodes.nix") nodes.nodes;
```

Add to the outputs attrset after `devShells`:

```nix
      nixosConfigurations.gem-gpu-0 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit nodes;
          node = gpuNode;
        };
        modules = [
          disko.nixosModules.disko
          agenix.nixosModules.default
          ./nix/gem-gpu-0.nix
        ];
      };
```

Add to `checks.${system}`:

```nix
        gem-gpu-0 = self.nixosConfigurations.gem-gpu-0.config.system.build.toplevel;
```

- [ ] **Step 3: Build the toplevel**

Run:

```bash
git add nix/gem-gpu-0.nix flake.nix
nix build .#nixosConfigurations.gem-gpu-0.config.system.build.toplevel --no-link --print-out-paths
```

Expected: one `/nix/store/...-nixos-system-gem-gpu-0-26.11...` path. If the build fails on an unknown option name, the error names it; do not add options not in this plan.

- [ ] **Step 4: Verify the values that come from nodes.nix**

Run:

```bash
nix eval --raw .#nixosConfigurations.gem-gpu-0.config.networking.hostName; echo
nix eval --json .#nixosConfigurations.gem-gpu-0.config.boot.initrd.luks.devices.crypted.crypttabExtraOpts
```

Expected: `gem-gpu-0` and `["tpm2-device=auto"]`.

- [ ] **Step 5: Commit**

```bash
nix fmt
git add nix/gem-gpu-0.nix flake.nix
git commit -m "feat(gem-gpu-0): Add host base with LUKS, networkd, and SSH" -m "Headless NixOS worker on the Razer Blade 17. Disk layout is disko with TPM2-unlocked LUKS, networking is wired DHCP with no host firewall to match the Talos nodes, and login is key-only with the YubiKeys."
```

---

### Task 5: Host module, part 2: NVIDIA and containerd

**Files:**

- Modify: `nix/gem-gpu-0.nix`

**Interfaces:**

- Produces: `virtualisation.containerd` with CDI and systemd cgroups; CDI spec generation; directories `/opt/cni/bin`, `/etc/cni/net.d`, `/var/lib/kubelet`, `/var/openebs/local`.

- [ ] **Step 1: Widen the module arguments**

Change the first line of `nix/gem-gpu-0.nix` to:

```nix
{
  config,
  lib,
  node,
  ...
}:
```

- [ ] **Step 2: Add the NVIDIA section**

Insert before the `networking = {` line:

```nix
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "nvidia-x11"
      "nvidia-settings"
      "nvidia-persistenced"
    ];

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.production;
    open = true;
    nvidiaPersistenced = true;
    powerManagement.enable = false;
    powerManagement.finegrained = false;
  };
  hardware.nvidia-container-toolkit.enable = true;
```

- [ ] **Step 3: Add containerd and the directories**

Insert directly after the NVIDIA section:

```nix
  virtualisation.containerd = {
    enable = true;
    settings.plugins."io.containerd.grpc.v1.cri" = {
      enable_cdi = true;
      cdi_spec_dirs = [
        "/etc/cdi"
        "/var/run/cdi"
      ];
      cni = {
        bin_dir = "/opt/cni/bin";
        conf_dir = "/etc/cni/net.d";
      };
      containerd.runtimes.runc.options.SystemdCgroup = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /opt/cni/bin 0755 root root -"
    "d /etc/cni/net.d 0755 root root -"
    "d /var/lib/kubelet 0700 root root -"
    "d /var/openebs/local 0755 root root -"
  ];
```

- [ ] **Step 4: Build and inspect the containerd config**

Run:

```bash
nix build .#nixosConfigurations.gem-gpu-0.config.system.build.toplevel --no-link
nix eval --raw .#nixosConfigurations.gem-gpu-0.config.virtualisation.containerd.args.config | xargs cat | grep -E 'enable_cdi|bin_dir|SystemdCgroup|cdi_spec_dirs'
nix eval --raw .#nixosConfigurations.gem-gpu-0.config.hardware.nvidia.package.version; echo
```

Expected: build succeeds (this downloads the nvidia driver, a few hundred MB); grep shows `enable_cdi = true`, `bin_dir = "/opt/cni/bin"`, `SystemdCgroup = true`, and the two spec dirs; version prints `595.` something.

- [ ] **Step 5: Commit**

```bash
nix fmt
git add nix/gem-gpu-0.nix
git commit -m "feat(gem-gpu-0): Add NVIDIA driver and containerd with CDI" -m "Production driver with open kernel modules and persistenced, no power management so the GPU stays up under pods. containerd uses systemd cgroups, CDI from the toolkit-generated spec, and the CNI directories Cilium populates."
```

---

### Task 6: Host module, part 3: haproxy, kubelet, agenix secret, version assertion

**Files:**

- Modify: `nix/gem-gpu-0.nix`

**Interfaces:**

- Consumes: `secrets/gem-gpu-0-bootstrap-kubeconfig.age` and `talos/ca.crt` from Task 3; `nodes.cluster`, `nodes.nodes`, `nodes.versions.kubernetes` from Task 2.
- Produces: `systemd.services.kubelet`, `services.haproxy` on `127.0.0.1:7445`.

- [ ] **Step 1: Widen the module arguments and add the let bindings**

Change the module header to:

```nix
{
  config,
  lib,
  pkgs,
  nodes,
  node,
  ...
}:
let
  inherit (lib) concatMapStringsSep filter toInt versions;

  yubikeys = [
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIO9ZH1VvOc2+1tAkzQzNwhyT+LT6wCBmt9gP2yeH8g+oAAAABHNzaDo= abutt@tiberius.com"
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIKoZU8AWvPjbgJfQXA3Kl6Ep9PzO6tGdN3GP4BRcTitOAAAABHNzaDo= anthony@abutt.io"
  ];

  controlPlanes = filter (n: n.type == "controlplane") nodes.nodes;

  kubeletMinor = toInt (versions.minor pkgs.kubernetes.version);
  clusterMinor = toInt (versions.minor nodes.versions.kubernetes);

  kubeletConfig = (pkgs.formats.yaml { }).generate "kubelet.yaml" {
    apiVersion = "kubelet.config.k8s.io/v1beta1";
    kind = "KubeletConfiguration";
    cgroupDriver = "systemd";
    containerRuntimeEndpoint = "unix:///run/containerd/containerd.sock";
    clusterDNS = [ "10.96.0.10" ];
    clusterDomain = "cluster.local";
    authentication = {
      anonymous.enabled = false;
      webhook.enabled = true;
      x509.clientCAFile = "${../talos/ca.crt}";
    };
    authorization.mode = "Webhook";
    rotateCertificates = true;
    serverTLSBootstrap = false;
    seccompDefault = true;
    failSwapOn = true;
    registerWithTaints = [
      {
        key = "nvidia.com/gpu";
        value = "present";
        effect = "NoSchedule";
      }
    ];
  };
in
```

- [ ] **Step 2: Add the assertion, haproxy, the secret, and the kubelet unit**

Insert before the final `}` of the module:

```nix
  assertions = [
    {
      assertion = kubeletMinor <= clusterMinor && kubeletMinor >= clusterMinor - 3;
      message = "kubelet ${pkgs.kubernetes.version} cannot join a ${nodes.versions.kubernetes} cluster: run upgrade-k8s and bump versions.kubernetes in nix/nodes.nix";
    }
  ];

  services.haproxy = {
    enable = true;
    config = ''
      global
        log stdout format raw local0

      defaults
        mode tcp
        log global
        timeout connect 5s
        timeout client 1h
        timeout server 1h

      frontend kube-apiserver
        bind 127.0.0.1:7445
        default_backend control-planes

      backend control-planes
        option tcp-check
      ${concatMapStringsSep "\n" (n: "  server ${n.name} ${n.ip}:6443 check inter 2s") controlPlanes}
    '';
  };

  age.secrets.bootstrap-kubeconfig = {
    file = ../secrets/gem-gpu-0-bootstrap-kubeconfig.age;
    mode = "0400";
  };

  systemd.services.kubelet = {
    description = "Kubernetes kubelet";
    wantedBy = [ "multi-user.target" ];
    after = [
      "containerd.service"
      "haproxy.service"
      "network-online.target"
    ];
    requires = [
      "containerd.service"
      "haproxy.service"
    ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      util-linux
      iproute2
      ethtool
      kubernetes
    ];
    serviceConfig = {
      ExecStart = ''
        ${pkgs.kubernetes}/bin/kubelet \
          --config=${kubeletConfig} \
          --kubeconfig=/var/lib/kubelet/kubeconfig \
          --bootstrap-kubeconfig=${config.age.secrets.bootstrap-kubeconfig.path} \
          --cert-dir=/var/lib/kubelet/pki \
          --node-ip=${node.ip}
      '';
      Restart = "always";
      RestartSec = "5s";
      WorkingDirectory = "/var/lib/kubelet";
    };
  };
```

- [ ] **Step 3: Build**

Run: `nix build .#nixosConfigurations.gem-gpu-0.config.system.build.toplevel --no-link`
Expected: success. If it fails with the assertion message, `nix/nodes.nix` still says 1.35.x; stop and confirm the Global Constraints prerequisite with Anthony.

- [ ] **Step 4: Inspect the rendered haproxy config and kubelet config**

Run:

```bash
nix eval --raw .#nixosConfigurations.gem-gpu-0.config.services.haproxy.config | grep server
nix eval --raw .#nixosConfigurations.gem-gpu-0.config.systemd.services.kubelet.serviceConfig.ExecStart | grep -oE -- '--config=/nix/store/[^ ]+' | cut -d= -f2 | xargs cat | grep -E 'registerWithTaints|nvidia.com/gpu|clientCAFile|cgroupDriver'
```

Expected: three `server gem-master-N 192.168.86.X:6443 check inter 2s` lines with the IPs from nodes.nix; the kubelet YAML shows `cgroupDriver: systemd`, a `clientCAFile: /nix/store/...-ca.crt`, and the `nvidia.com/gpu` taint.

- [ ] **Step 5: Prove the version assertion fires**

Run:

```bash
nix eval --impure --raw --expr '
  let
    flake = builtins.getFlake (toString ./.);
    nodes = import ./nix/nodes.nix;
    old = nodes // { versions = nodes.versions // { kubernetes = "1.30.0"; }; };
    sys = flake.inputs.nixpkgs.lib.nixosSystem {
      specialArgs = { nodes = old; node = builtins.head (builtins.filter (n: n.name == "gem-gpu-0") nodes.nodes); };
      modules = [ flake.inputs.disko.nixosModules.disko flake.inputs.agenix.nixosModules.default ./nix/gem-gpu-0.nix ];
    };
  in sys.config.system.build.toplevel.drvPath
' 2>&1 | grep -o "kubelet .* cannot join a 1.30.0 cluster.*nodes.nix"
```

Expected: the assertion message prints, naming `upgrade-k8s` and `nix/nodes.nix`.

- [ ] **Step 6: Commit**

```bash
nix fmt
git add nix/gem-gpu-0.nix
git commit -m "feat(gem-gpu-0): Add kubelet, API proxy, and join secret" -m "A plain systemd kubelet bootstraps through haproxy on 127.0.0.1:7445, which balances the control planes from nodes.nix the way KubePrism does on Talos, so the Cilium values stay unchanged. The node registers tainted for GPU work only. An eval-time assertion refuses a kubelet newer than the cluster."
```

---

### Task 7: Installer ISO

**Files:**

- Create: `nix/installer-iso.nix`
- Modify: `flake.nix`

**Interfaces:**

- Produces: `nixosConfigurations.installer`, `packages.x86_64-linux.installer-iso`.

- [ ] **Step 1: Create the ISO module**

Create `nix/installer-iso.nix`:

```nix
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  nixpkgs.hostPlatform = "x86_64-linux";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIO9ZH1VvOc2+1tAkzQzNwhyT+LT6wCBmt9gP2yeH8g+oAAAABHNzaDo= abutt@tiberius.com"
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIKoZU8AWvPjbgJfQXA3Kl6Ep9PzO6tGdN3GP4BRcTitOAAAABHNzaDo= anthony@abutt.io"
  ];
}
```

- [ ] **Step 2: Wire it into the flake**

In `flake.nix`, extend `nixosConfigurations` (it becomes an attrset with two entries):

```nix
      nixosConfigurations = {
        gem-gpu-0 = nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit nodes;
            node = gpuNode;
          };
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./nix/gem-gpu-0.nix
          ];
        };
        installer = nixpkgs.lib.nixosSystem { modules = [ ./nix/installer-iso.nix ]; };
      };
```

Add to `packages.${system}`:

```nix
        installer-iso = self.nixosConfigurations.installer.config.system.build.isoImage;
```

- [ ] **Step 3: Build the ISO**

Run:

```bash
git add nix/installer-iso.nix flake.nix
nix build .#installer-iso --print-out-paths
ls -lh result/iso/
```

Expected: a `nixos-*-x86_64-linux.iso` around 1 GB.

- [ ] **Step 4: Confirm the keys are in the image's root account**

Run: `nix eval --json .#nixosConfigurations.installer.config.users.users.root.openssh.authorizedKeys.keys | grep -o sk-ssh-ed25519 | wc -l`
Expected: `2`.

- [ ] **Step 5: Commit**

```bash
nix fmt
git add nix/installer-iso.nix flake.nix
git commit -m "feat: Add installer ISO for nixos-anywhere targets" -m "Minimal NixOS installer with sshd and the YubiKey public keys on root, so nixos-anywhere can install gem-gpu-0 from the workstation."
```

---

### Task 8: deploy-rs node, checks, devshell tools, apply script

**Files:**

- Create: `nix/deploy-rs-overlay.nix`
- Modify: `flake.nix`
- Modify: `nix/shell.nix`

**Interfaces:**

- Consumes: `nixosConfigurations.gem-gpu-0`, `gpuNode`.
- Produces: `deploy.nodes.gem-gpu-0`, `checks.x86_64-linux.deploy-*`, devshell command `apply-gem-gpu-0`.

- [ ] **Step 1: Create the overlay**

Create `nix/deploy-rs-overlay.nix`:

```nix
{ deploy-rs }:
final: prev:
let
  upstream = deploy-rs.overlays.default final prev;
in
{
  deploy-rs = {
    inherit (prev) deploy-rs;
    inherit (upstream.deploy-rs) lib;
  };
}
```

This follows the deploy-rs README section "Overall usage": the `deploy` binary and the activation helper come from nixpkgs's cached build, the `lib` from the flake input.

- [ ] **Step 2: Wire deploy into the flake**

In `flake.nix`, add to the outputs `let` block:

```nix
      deployPkgs = import nixpkgs {
        inherit system;
        overlays = [ (import ./nix/deploy-rs-overlay.nix { inherit deploy-rs; }) ];
      };
```

Add to the outputs attrset:

```nix
      deploy.nodes.gem-gpu-0 = {
        hostname = gpuNode.ip;
        sshUser = "anthony";
        profiles.system = {
          user = "root";
          path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.gem-gpu-0;
        };
      };
```

Change `checks.${system} = { ... };` to merge the deploy checks:

```nix
      checks.${system} = {
        formatting = treefmt.config.build.check self;
        pre-commit = pre-commit;
        gem-gpu-0 = self.nixosConfigurations.gem-gpu-0.config.system.build.toplevel;
      }
      // deployPkgs.deploy-rs.lib.deployChecks self.deploy;
```

Pass the deploy binary and the other new tools to the devshell by changing the `devShells` call:

```nix
      devShells.${system}.default = import ./nix/shell.nix {
        inherit pkgs packages nodes;
        git-hooks = pre-commit;
        deploy-rs = deployPkgs.deploy-rs;
        agenix = agenix.packages.${system}.default;
      };
```

- [ ] **Step 3: Add the tools and the apply script to the devshell**

In `nix/shell.nix`, change the argument set to:

```nix
{
  pkgs,
  packages,
  nodes,
  git-hooks,
  deploy-rs,
  agenix,
}:
```

Add after `talosNodes = ...;`:

```nix
  nixosNodes = builtins.filter (n: n.os == "nixos") nodeConfig.nodes;

  deployScripts = map (
    node:
    pkgs.writeShellScriptBin "apply-${node.name}" ''
      set -euo pipefail
      echo "Deploying ${node.name} (${node.ip}) with deploy-rs..."
      ${deploy-rs}/bin/deploy ".#${node.name}" "$@"
    ''
  ) nixosNodes;
```

In the menu script, change the `apply-<node>` line and add a line after it:

```nix
    echo "    apply-<node> [--insecure] Apply config to Talos node (-i for first apply)"
    echo "    apply-<nixos node>        Deploy NixOS node with deploy-rs"
```

Add to the `packages` list under the `# Kubernetes/Talos tools` group:

```nix
      nixos-anywhere
      deploy-rs
      agenix
```

Because `deploy-rs` and `agenix` are function arguments, not `pkgs` attributes, the `with pkgs;` list will still resolve them as the arguments (bindings shadow the `with`); leave them in the list as written.

Change `++ applyScripts;` to `++ applyScripts ++ deployScripts;`.

- [ ] **Step 4: Run the full check and inspect the script**

Run:

```bash
git add nix/deploy-rs-overlay.nix flake.nix nix/shell.nix
nix flake check
nix develop --command bash -c 'cat "$(command -v apply-gem-gpu-0)"; command -v deploy nixos-anywhere agenix'
```

Expected: `nix flake check` passes, including `deploy-schema`, `deploy-activate`, `gem-gpu-0`, `formatting`, `pre-commit`. The script body contains `deploy ".#gem-gpu-0"`, and three store paths print. If only `pre-commit` fails and the log names `render-helm` or `validate-kustomize`, that is the pre-existing hook defect listed in Global Constraints, not this task; stop and report it rather than editing manifests.

- [ ] **Step 5: Commit**

```bash
nix fmt
git add nix/deploy-rs-overlay.nix flake.nix nix/shell.nix
git commit -m "feat: Deploy gem-gpu-0 with deploy-rs from the devshell" -m "Adds the deploy node, its flake checks, and an apply-gem-gpu-0 script alongside the Talos apply scripts. The deploy binary comes from nixpkgs so nothing builds from source; only the activation lib comes from the deploy-rs input."
```

---

### Task 9: Runbook

**Files:**

- Create: `docs/gpu-worker.md`
- Modify: `README.md` (Available Commands table)

- [ ] **Step 1: Write the runbook**

Create `docs/gpu-worker.md`:

````markdown
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
````

- [ ] **Step 2: Add the commands to the README table**

In `README.md`, add two rows to the "Available Commands" table after the `upgrade-<node>` row:

```markdown
| `apply-gem-gpu-0` | Deploy the NixOS GPU worker with deploy-rs |
| `talos-gen join-config` | Emit the NixOS worker's join credential and CA |
```

- [ ] **Step 3: Check formatting**

Run: `nix fmt && git diff --stat`
Expected: only `docs/gpu-worker.md` and `README.md` changed; prettier accepted them.

- [ ] **Step 4: Commit**

```bash
git add docs/gpu-worker.md README.md
git commit -m "docs: Add gem-gpu-0 install and join runbook"
```

---

### Task 10: Install on hardware and verify (manual, Anthony)

**Files:** none

- [ ] **Step 1: Follow `docs/gpu-worker.md` steps 3 through 7**

- [ ] **Step 2: Confirm unattended unlock**

Power-cycle the Blade with no keyboard input. Expected: `ssh anthony@<reserved IP>` succeeds within two minutes.

- [ ] **Step 3: Confirm the kubelet bootstrapped**

Run on the node: `sudo ls /var/lib/kubelet/pki/ && systemctl is-active kubelet haproxy containerd`
Expected: `kubelet-client-current.pem` present; three lines reading `active`.

- [ ] **Step 4: Confirm the CDI spec exists**

Run on the node: `ls /var/run/cdi/ && nvidia-smi -L`
Expected: `nvidia-container-toolkit.json`; one line naming `NVIDIA GeForce RTX 3070 Ti Laptop GPU`.

- [ ] **Step 5: Confirm the taint keeps general work off**

Run: `kubectl get pods -A -o wide --field-selector spec.nodeName=gem-gpu-0`
Expected: only `cilium-*` pods.

- [ ] **Step 6: Log the session**

Use the `session-log` skill to record the outcome in the project vault.
