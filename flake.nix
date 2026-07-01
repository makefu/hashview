{
  description = "Hashview - password cracking manager (web server + agent)";

  inputs.nixpkgs.url = "flake:nixpkgs";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      }));
    in
    {
      overlays.default = import ./nix/overlay.nix;

      packages = forAllSystems (pkgs: {
        inherit (pkgs) hashview-web hashview-agent;
        default = pkgs.hashview-web;
      });

      nixosModules.default = import ./nix/module.nix;
      nixosModules.hashview = import ./nix/module.nix;

      # Minimal runnable system:
      #   nix run .#nixosConfigurations.minimal.config.system.build.vm
      # then browse http://localhost:5000 (login admin@example.com after setup).
      nixosConfigurations.minimal = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          ./nix/minimal.nix
          ({ modulesPath, ... }: {
            imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];
            nixpkgs.overlays = [ self.overlays.default ];
            virtualisation.forwardPorts = [{ from = "host"; host.port = 5000; guest.port = 5000; }];
            virtualisation.memorySize = 4096;
            services.getty.autologinUser = "root";
            system.stateVersion = "25.05";
          })
        ];
      };

      checks = forAllSystems (pkgs: {
        unit = pkgs.callPackage ./nix/test-unit.nix { };
        integration = import ./nix/test-integration.nix { inherit pkgs self; };
        e2e = import ./nix/test-e2e.nix { inherit pkgs self; };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.hashviewTestPython pkgs.hashcat ];
        };
      });
    };
}
