# Talos cluster node definitions
{
  cluster = {
    name = "gems";
    endpoint = "192.168.86.250";
    talosVersion = "1.9.3";
    kubernetesVersion = "1.32.0";
  };

  nodes = [
    { name = "gem-master-0"; ip = "192.168.86.250"; type = "controlplane"; }
    { name = "gem-master-1"; ip = "192.168.86.21"; type = "controlplane"; }
    { name = "gem-master-2"; ip = "192.168.86.31"; type = "controlplane"; }
    { name = "gem-worker-0"; ip = "192.168.86.25"; type = "worker"; }
    { name = "gem-worker-1"; ip = "192.168.86.33"; type = "worker"; }
  ];
}
