{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      flateRelease = {
        x86_64-linux = {
          arch = "linux_amd64";
          hash = "sha256-BdPHlEdkfpUymqRccDXn66w6EglCly54gZ3q3Dvwr+s=";
        };
        aarch64-linux = {
          arch = "linux_arm64";
          hash = "sha256-NFuLZ53kOTQwAwl7eaq+x9BwwF5w7spcQTGTupeqNo8=";
        };
      };
    in
    {
      devShells = nixpkgs.lib.mapAttrs (
        system: release:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          flate = pkgs.stdenvNoCC.mkDerivation rec {
            pname = "flate";
            version = "0.7.3";
            src = pkgs.fetchurl {
              url = "https://github.com/home-operations/flate/releases/download/v${version}/flate_${version}_${release.arch}.tar.gz";
              inherit (release) hash;
            };
            sourceRoot = ".";
            installPhase = "install -Dm755 flate $out/bin/flate";
          };
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              flate
              pkgs.fluxcd
              # Match the Kanidm server version in apps/oliver/auth/kanidm.
              pkgs.kanidm_1_12
              pkgs.kubectl
              pkgs.opentofu
              pkgs.oxfmt
              pkgs.tofu-ls
              pkgs.yaml-language-server
            ];

            KANIDM_URL = "https://auth.neffi.fr/";
            shellHook = ''
              export KUBECONFIG="$HOME/.kube/config"
              export KUBE_CONFIG_PATH="$HOME/.kube/config"
            '';
          };
        }
      ) flateRelease;
    };
}
