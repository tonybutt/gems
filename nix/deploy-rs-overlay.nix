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
