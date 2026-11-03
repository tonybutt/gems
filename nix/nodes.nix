# Talos cluster node definitions
{
  cluster = {
    name = "gems";
    endpoint = "https://192.168.86.69:6443";
    controlPlaneEndpoint = "192.168.86.250";
  };

  # Image Factory schematic for the installer image. ghcr.io/siderolabs/installer
  # is no longer published as of Talos 1.14. Vanilla schematic (no extensions).
  schematic = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba";

  versions = {
    talos = "1.14.5";
    kubernetes = "1.37.2";
  };

  # Shared machine config applied to all nodes
  machineConfig = {
    install = {
      disk = "/dev/nvme0n1";
      extraKernelArgs = [ "net.ifnames=0" ];
    };
  };

  # Cluster-wide settings
  clusterConfig = {
    network = {
      cni = "none"; # Using Cilium
      podSubnets = [ "10.244.0.0/16" ];
      serviceSubnets = [ "10.96.0.0/12" ];
    };
    proxy = {
      disabled = true; # Using Cilium kube-proxy replacement
    };
    allowSchedulingOnControlPlanes = true;
  };

  # Node definitions
  nodes = [
    {
      name = "gem-master-0";
      ip = "192.168.86.35";
      type = "controlplane";
    }
    {
      name = "gem-master-1";
      ip = "192.168.86.21";
      type = "controlplane";
    }
    {
      name = "gem-master-2";
      ip = "192.168.86.31";
      type = "controlplane";
    }
    {
      name = "gem-worker-0";
      ip = "192.168.86.25";
      type = "worker";
    }
    {
      name = "gem-worker-1";
      ip = "192.168.86.33";
      type = "worker";
    }
  ];
}
