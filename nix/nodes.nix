# Talos cluster node definitions
{
  cluster = {
    name = "gems";
    endpoint = "https://192.168.86.250:6443";
    controlPlaneEndpoint = "192.168.86.250";
  };

  versions = {
    talos = "1.12.1";
    kubernetes = "1.32.0";
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
      ip = "192.168.86.250";
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
      ip = "192.168.86.37";
      type = "worker";
    }
  ];
}
