# Minimal running Hashview configuration.
#
# Brings up the web server + a local agent + a local MariaDB reached over the
# unix socket with passwordless socket auth (no passwordFile needed). Import
# this alongside the hashview NixOS module into a system, e.g.:
#
#   imports = [ hashview.nixosModules.default ./minimal.nix ];
#
{ pkgs, ... }:
{
  services.hashview.enable = true;

  # The agent shells out to hashcat, which needs an OpenCL backend to run; pocl
  # provides a CPU device so cracking works on a box without a GPU.
  systemd.services.hashview-agent.environment.OCL_ICD_VENDORS =
    "${pkgs.pocl}/etc/OpenCL/vendors";
}
