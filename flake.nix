{
  description = "Jupiter Ace FPGA recreation for ULX3S (ECP5)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          idcode = "0x21111043"; # ECP5 12F
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "jupiter-ace";
            version = "unstable";
            src = ./.;

            nativeBuildInputs = with pkgs; [
              yosys
              nextpnr
              trellis
            ];

            buildPhase = ''
              cd ulx3s
              mkdir -p bin

              # Synthesize
              yosys -p "synth_ecp5 -json bin/toplevel.json" \
                ../src/top/jupiter_ace_ulx3s.v \
                ../src/sys/clk_25_system.v ../src/sys/ps2.v ../src/sys/dvi.v \
                ../src/fpga_ace.v ../src/jace_logic.v ../src/memory.v ../src/keyboard_for_ace.v \
                ../src/cpu/tv80n.v ../src/cpu/tv80_core.v ../src/cpu/tv80_alu.v \
                ../src/cpu/tv80_reg.v ../src/cpu/tv80_mcode.v \
                ../src/usb/clk_usb.v \
                ../src/usb/usbh_host_hid.v ../src/usb/usbh_sie.v \
                ../src/usb/usbh_crc5.v ../src/usb/usbh_crc16.v \
                ../src/usb/usb_phy.v ../src/usb/usb_rx_phy.v ../src/usb/usb_tx_phy.v \
                ../src/usb/usbhid_to_ps2.v

              # Place & route
              nextpnr-ecp5 \
                --25k \
                --package CABGA381 \
                --freq 25 \
                --json bin/toplevel.json \
                --textcfg bin/toplevel.config \
                --lpf ulx3s_ace.lpf

              # Pack bitstream
              ecppack --idcode ${idcode} bin/toplevel.config bin/toplevel.bit
            '';

            installPhase = ''
              mkdir -p $out
              cp bin/toplevel.bit $out/jupiter_ace.bit
            '';
          };
        });

      apps = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          flash = pkgs.writeShellScript "jupiter-ace-flash" ''
            ${pkgs.fujprog}/bin/fujprog ${self.packages.${system}.default}/jupiter_ace.bit
          '';
        in
        {
          default = {
            type = "app";
            program = "${flash}";
          };
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              yosys
              nextpnr
              trellis
              fujprog
              gnumake
            ];

            shellHook = ''
              echo "Jupiter Ace dev environment ready"
              echo "  Build:  nix build"
              echo "  Flash:  nix run"
            '';
          };
        });
    };
}
