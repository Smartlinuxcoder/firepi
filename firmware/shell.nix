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
    echo "iCE40 toolchain ready:"
    echo " - yosys"
    echo " - nextpnr-ice40"
    echo " - icepack / icetime / iceprog"
  '';
}
