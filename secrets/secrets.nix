let
  tiberius = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnQDGTR3J244BlVZ3u0I9l476XRxlv0DdmREzTku3Ib abutt@tiberius.com";
  lapnix = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPYkXD5kuITfXNUgU+yzirklzKXKRlT5ZKYwKo03lzzz abutt@tiberius.com";
  atlas = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII+cqj41D3k8Dk9Bz4l/06XVkkxMJIpg1orvuf56/Hme";
  gem-gpu-0 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvbzebaUTlqOi79EjAsPs98PYNvZmr3U+QDEXdXclf1 gem-gpu-0";
in
{
  "gem-gpu-0-bootstrap-kubeconfig.age".publicKeys = [
    tiberius
    lapnix
    atlas
    gem-gpu-0
  ];
}
