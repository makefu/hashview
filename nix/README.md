# Hashview Nix packaging

A Nix flake that packages [Hashview](../README.md) (web server + cracking agent)
and a `services.hashview` NixOS module.

## Flake outputs

| Output | What |
| --- | --- |
| `packages.<system>.hashview-web` | Web server |
| `packages.<system>.hashview-agent` | Cracking agent |
| `nixosModules.default` (alias `hashview`) | The `services.hashview` module |
| `nixosConfigurations.minimal` | Smallest runnable system (a bootable VM) |
| `checks.<system>.{unit,integration,e2e}` | Test tiers (see [Tests](#tests)) |
| `devShells.<system>.default` | Test Python env + hashcat |

The app is not relocatable and targets an older stack; the flake applies its
build-time source patches in `overlay.nix` (kept out of the source tree). See the
packaging commit message for the rationale.

## Quick start

Try it without touching an existing host — build and run the minimal VM:

```sh
nix run .#nixosConfigurations.minimal.config.system.build.vm
# open http://localhost:5000  (port 5000 is forwarded from the guest)
```

First page walks you through creating the admin account, then log in with the
email/password you set.

## Using the module

Add the flake as an input and import the module. The minimal configuration is a
single line — it provisions a local MariaDB reached over the unix socket with
passwordless socket auth, plus a local web server and agent:

```nix
{
  imports = [ hashview.nixosModules.default ];
  services.hashview.enable = true;
}
```

`nix/minimal.nix` is exactly this plus a CPU OpenCL backend so cracking works on
a box without a GPU (see [NVIDIA GPU](#nvidia-gpu)).

### Key options

| Option | Default | Notes |
| --- | --- | --- |
| `services.hashview.web.host` / `.port` | `127.0.0.1` / `5000` | Listener (behind nginx by default) |
| `services.hashview.web.package` | `pkgs.hashview-web` | Overridable |
| `services.hashview.web.secretKeyFile` | generated once | Flask `SECRET_KEY` |
| `services.hashview.web.settings` | `{}` | Extra `config.conf` sections (e.g. SMTP), deep-merged |
| `services.hashview.agent.package` | `pkgs.hashview-agent` | Overridable |
| `services.hashview.agent.server` / `.port` / `.useSsl` | web host/port / `false` | Where the agent connects |
| `services.hashview.hashcat.package` | `pkgs.hashcat` | `HC_BIN_PATH` the agent runs |
| `services.hashview.database.createLocally` | `true` | Provision local MariaDB |
| `services.hashview.database.passwordFile` | `null` | DB password from a file; `null` = socket auth |
| `services.hashview.database.connectionString` | `null` | Full SQLAlchemy URI; overrides everything |

Point at an external database instead of the local one:

```nix
services.hashview.database = {
  createLocally = false;
  # either host/user + passwordFile ...
  host = "db.internal";
  passwordFile = "/run/secrets/hashview-db";
  # ... or a full DSN (wins over all other database options)
  # connectionString = "mysql+mysqlconnector://user:pass@db.internal/hashview";
};
```

## TLS termination with nginx

The web server binds `127.0.0.1:5000` and is not exposed directly. Enable the
built-in nginx reverse proxy to terminate TLS in front of it:

```nix
{
  services.hashview = {
    enable = true;
    web.nginx = {
      enable = true;
      hostName = "hashview.example.com";
      enableACME = true;   # Let's Encrypt cert
      forceSSL = true;     # redirect http -> https
    };
  };

  # Required for ACME (port 80 must be reachable and DNS must resolve to this host)
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com";
  };
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

Notes:

- A local agent still talks to the web server over plain HTTP on the internal
  `127.0.0.1:5000` — it does not go through nginx.
- A **remote** agent should reach the server through nginx over TLS:

  ```nix
  services.hashview = {
    web.enable = false;                 # this box only runs the agent
    agent = {
      enable = true;
      server = "hashview.example.com";
      port = 443;
      useSsl = true;                    # the agent verifies loosely (verify=False upstream)
    };
  };
  ```

- To bring your own certificate instead of ACME, drop `enableACME` and set the
  cert on the vhost directly, e.g. via
  `services.nginx.virtualHosts."hashview.example.com".sslCertificate*` or add
  extra `web.settings` / plain `services.nginx` config alongside.

## NVIDIA GPU

The minimal config ships `pocl` (a CPU OpenCL runtime) so hashcat can crack
without a GPU. On a box with a physical NVIDIA card, use the driver's CUDA/OpenCL
runtime instead — do **not** import `minimal.nix` (it pins `OCL_ICD_VENDORS` to
pocl and would hide the NVIDIA ICD):

```nix
{ config, ... }:
{
  imports = [ hashview.nixosModules.default ];
  services.hashview.enable = true;

  # NVIDIA proprietary driver + OpenCL/CUDA userspace runtime.
  hardware.graphics.enable = true;                     # NixOS >= 24.11 (was hardware.opengl.enable)
  services.xserver.videoDrivers = [ "nvidia" ];        # loads the kernel module, no X needed
  hardware.nvidia.package =
    config.boot.kernelPackages.nvidiaPackages.stable;
  # hardware.nvidia.open = true;                       # only on GPUs the open module supports
}
```

With no `OCL_ICD_VENDORS` override, hashcat's OpenCL loader finds the NVIDIA ICD
under `/run/opengl-driver/etc/OpenCL/vendors`, and its CUDA backend picks up
`libcuda` from `/run/opengl-driver/lib`. Verify with:

```sh
sudo -u hashview OCL_ICD_VENDORS= hashcat -I     # should list the NVIDIA device
```

### Caveats

- **Driver/kernel match, then reboot.** The kernel module and the userspace
  driver must be the same version; installing the driver requires a reboot
  before hashcat sees the device.
- **Device access.** The agent runs as the unprivileged `hashview` user. It needs
  read/write on `/dev/nvidia*` (0666 by default, so it usually just works). If
  you add systemd device hardening (`PrivateDevices`, `DeviceAllow`, …) to
  `systemd.services.hashview-agent`, allow the NVIDIA nodes or the GPU disappears.
- **Don't leave pocl in the mix unintentionally.** If both pocl and the NVIDIA
  ICD are visible, hashcat enumerates the CPU device too and may split work onto
  it. Keep `OCL_ICD_VENDORS` unset (system default) for GPU-only, or point it at
  the NVIDIA vendors dir explicitly. If you started from `minimal.nix`, override
  with `systemd.services.hashview-agent.environment.OCL_ICD_VENDORS = lib.mkForce "/run/opengl-driver/etc/OpenCL/vendors";`.
- **The crack command is fixed upstream.** The server builds the hashcat command
  line (`-O -w 3`, no `--hwmon-temp-abort` tuning). On a hot/throttling card
  hashcat may self-abort at its temperature limit; that is server-side behaviour,
  not something the module exposes.
- **Headless is fine.** No display/X session is required; `hardware.graphics` +
  the `nvidia` driver are enough for compute.

## Tests

```sh
nix flake check                          # runs all three tiers
nix build .#checks.x86_64-linux.unit         # in-sandbox security tests
nix build .#checks.x86_64-linux.integration  # Playwright suite vs a live server
nix build .#checks.x86_64-linux.e2e -L       # boots the minimal config, cracks MD5("root")
```

The e2e test installs the exact minimal configuration and drives it over HTTP
with `curl` until the seeded hash is recovered — proof the packaged app, the
module wiring, and the agent/hashcat path all work.
