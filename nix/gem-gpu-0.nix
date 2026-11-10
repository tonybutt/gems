{
  config,
  lib,
  pkgs,
  nodes,
  node,
  ...
}:
let
  inherit (lib)
    concatMapStringsSep
    filter
    toInt
    versions
    ;

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
}
