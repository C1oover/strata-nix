{
  description = "NixOS package and module for the Strata local LLM inference engine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    strata = {
      url = "github:Niko1221/Strata/main";
      flake = false;
    };
    llama-cpp = {
      # Must match third_party/ggml/VERSION.txt in inputs.strata
      url = "github:ggml-org/llama.cpp/3cf03257f219afbe7334045ff7c6a06ac68c627d";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, strata, llama-cpp } @ inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          cudaSupport = true;
        };
      };
    in
    {
      packages.${system} = rec {
        strata = pkgs.callPackage ./package.nix {
          strataSrc = inputs.strata;
          llamaSrc = inputs.llama-cpp;
        };
        default = strata;
      };

      overlays.default = final: prev: {
        strata = self.packages.${system}.strata;
      };

      nixosModules.strata = import ./module.nix { inherit self; };
      nixosModules.default = self.nixosModules.strata;
    };
}
