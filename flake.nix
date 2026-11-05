{
  description = "DesignCraft — page layout and publishing, a free alternative to InDesign, in pure Rust";

  inputs = {
    # DesignCraft needs edition 2024 and rustc ≥ 1.95, so the flake tracks unstable. Consumers on a
    # release channel can retarget it: `inputs.designcraft.inputs.nixpkgs.follows = "nixpkgs";`
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Optional build input of the repository: the fonts that the build embeds when `CRAFT_FONTS_DIR`
    # is set. Official releases always build with them; without them everything works but some
    # scripts have no glyphs. Pinned to the revision the release workflow uses — bump deliberately
    # (`nix flake update craft-fonts`).
    craft-fonts = {
      url = "github:storytold/craft-fonts/b076417b5880bd4154bd22f00695b1d28c6bea83";
      flake = false;
    };

    # Splits the dependency build from the app build, so a source change does not recompile the
    # whole dependency graph.
    crane = {
      url = "github:ipetkov/crane";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      craft-fonts,
      crane,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # The AppStream metadata carries a release date. The flake source's own commit date is
      # reproducible, unlike "now"; a tarball or dirty tree without one falls back to the epoch.
      buildDate =
        let
          d = self.lastModifiedDate or "";
        in
        if builtins.stringLength d >= 8 then
          "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}"
        else
          "1970-01-01";

      packageArgs = {
        inherit craft-fonts buildDate;
      };

      # Written by `.github/workflows/binary.yml`; absent until the first binary release.
      binaryInfo =
        if builtins.pathExists ./binary-url.json then
          builtins.fromJSON (builtins.readFile ./binary-url.json)
        else
          null;

      forAllSystems = f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }) system);
    in
    {
      packages = forAllSystems (
        pkgs: system:
        let
          source = pkgs.callPackage ./nix/package.nix (packageArgs // { craneLib = crane.mkLib pkgs; });
          binary = pkgs.callPackage ./nix/binary.nix {
            name = "designcraft";
            info = binaryInfo;
          };
          binaryAvailable = binaryInfo != null && binaryInfo.system == system;
        in
        {
          designcraft-source = source;
          designcraft = if binaryAvailable then binary else source;
          default = if binaryAvailable then binary else source;
        }
        // lib.optionalAttrs binaryAvailable {
          designcraft-binary = binary;
        }
      );

      # `nixpkgs.overlays = [ inputs.designcraft.overlays.default ]` → `pkgs.designcraft` everywhere.
      overlays.default = final: _prev: {
        designcraft = final.callPackage ./nix/package.nix (
          packageArgs // { craneLib = crane.mkLib final; }
        );
      };

      apps = forAllSystems (
        _: system: {
          default = {
            type = "app";
            program = lib.getExe self.packages.${system}.designcraft;
          };
        }
      );

      devShells = forAllSystems (
        pkgs: system:
        let
          designcraft = self.packages.${system}.designcraft-source;
        in
        {
          default = pkgs.mkShell (
            {
              # The package's own native inputs, so `cargo build` in the shell needs no extra setup.
              inputsFrom = [ designcraft ];
              packages = with pkgs; [
                cargo
                rustc
                clippy
                rustfmt
                rust-analyzer
              ];
              # `cargo run` dlopens the Vulkan loader, libwayland and libxkbcommon like the packaged binary.
              LD_LIBRARY_PATH = lib.makeLibraryPath designcraft.passthru.runtimeLibs;
              RUST_BACKTRACE = "1";
            }
            // lib.optionalAttrs (craft-fonts != null) {
              # Embedded fonts in `cargo run` too; build.rs reads this as CRAFT_FONTS_DIR.
              CRAFT_FONTS_DIR = toString craft-fonts;
            }
          );
        }
      );

      checks = forAllSystems (
        pkgs: system:
        let
          designcraft = self.packages.${system}.designcraft-source;
        in
        {
          designcraft = designcraft;

          # Both module entry points evaluate with `enable = true` (no full NixOS evaluation).
          modules = pkgs.callPackage ./nix/module-check.nix { inherit designcraft; };

          # `nix fmt` formats the flake; this keeps it formatted.
          formatting =
            pkgs.runCommand "designcraft-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; }
              ''
                nixfmt --check ${./flake.nix} ${./nix}
                touch $out
              '';
        }
      );

      formatter = forAllSystems (pkgs: _: pkgs.nixfmt);

      # Both modules take the package from this flake unless `programs.designcraft.package` is set,
      # so `nixosModules.default`/`homeManagerModules.default` work without the overlay.
      nixosModules.default =
        { pkgs, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          imports = [ (import ./nix/module.nix { kind = "nixos"; }) ];
          _module.args = {
            designcraftSourcePackage = self.packages.${system}.designcraft-source;
            designcraftBinaryPackage = self.packages.${system}.designcraft-binary or null;
          };
        };

      homeManagerModules.default =
        { pkgs, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          imports = [ (import ./nix/module.nix { kind = "home-manager"; }) ];
          _module.args = {
            designcraftSourcePackage = self.packages.${system}.designcraft-source;
            designcraftBinaryPackage = self.packages.${system}.designcraft-binary or null;
          };
        };
    };
}
