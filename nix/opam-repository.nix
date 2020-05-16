{ pkgs ? import <nixpkgs> {} }:
let
  upstream = builtins.fetchGit {
    url = "https://github.com/ocaml/opam-repository";
    rev = "513d3767ad627b97c4b58c6669fb5bc55238371e";
  };
  dune-universe = builtins.fetchGit {
    url = "https://github.com/dune-universe/opam-overlays";
    rev = "05ec075202d3fead23859d191dff094e3b4ae81d";
  };
in
  pkgs.symlinkJoin {
    name = "combined-opam-repository";
    paths = [ upstream dune-universe ];
  }
