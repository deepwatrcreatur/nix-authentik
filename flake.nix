{
  description = "NixOS module for running Authentik natively with nixpkgs packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs supportedSystems;
    in
    {
      nixosModules = {
        default = import ./modules/authentik.nix;
        authentik = import ./modules/authentik.nix;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.authentik;
          authentik = pkgs.authentik;
          authentik-proxy = pkgs.authentik.proxy;
        }
      );

      overlays.default = final: prev: {
        authentik = self.packages.${prev.system}.authentik;
        authentik-proxy = self.packages.${prev.system}.authentik-proxy;
      };

      nixosConfigurations.authentik-example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.authentik
          {
            networking.hostName = "authentik-example";
            system.stateVersion = "25.11";

            fileSystems."/" = {
              device = "none";
              fsType = "tmpfs";
            };

            boot.loader.grub.devices = [ "nodev" ];

            services.authentik = {
              enable = true;
              secretKeyFile = builtins.toFile "authentik-secret-key" "example-secret-key-change-me\n";
              bootstrapPasswordFile = builtins.toFile "authentik-bootstrap-password" "change-me\n";
              domain = "auth.example.test";
            };
          }
        ];
      };
    };
}
