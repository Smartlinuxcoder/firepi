{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = [
    pkgs.yosys
    pkgs.nextpnr
    pkgs.icestorm
    pkgs.gnumake
    pkgs.pkg-config
    pkgs.mpremote
  ];

  shellHook = ''
    echo "arsonism"
  '';
}
