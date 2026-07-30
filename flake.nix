{
  description = "cloud microbenchmarks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [
              "terraform"
            ];
        };

        rAnalysisPackages = with pkgs.rPackages; [
          dplyr
          tidyr
          purrr
          Cairo
          ggplot2
          ggpubr
          ggpattern
          ggforce
          ggrepel
          directlabels
          lubridate
          slider
          stringr
          RColorBrewer
          shades
          duckdb
          readr
          DBI
          rmarkdown
          knitr
          jsonlite
          scales
        ] ++ [ pkgs.R ];

      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            opentofu
            awscli2
            stackit-cli
            google-cloud-sdk
            sockperf
            fio
            iperf3
          ];
        };

        devShells.analysis = pkgs.mkShell {
          packages = rAnalysisPackages;

          #LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

          shellHook = ''
            echo "Analysis dev environment loaded"
            echo "Includes R + analysis packages"
          '';
        };
      }
    );
}
