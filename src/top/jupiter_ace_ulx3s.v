`timescale 1ns / 1ps
`default_nettype none
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date:    17:18:12 11/07/2015
// Design Name:
// Module Name:    jupiter_ace
// Project Name:
// Target Devices:
// Tool versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////
module jupiter_ace (
    input wire         clk25,
    input wire         usb_fpga_dp,      // USB D+ differential input
    inout wire         usb_fpga_bd_dp,   // USB D+ bidirectional
    inout wire         usb_fpga_bd_dn,   // USB D- bidirectional
    inout [11:11]      gp, gn,
    input [6:0]        btn,

    input wire         ear,
    output wire        audio_out_left,
    output wire        audio_out_right,

    input              wifi_txd,
    output             wifi_rxd,

    input              ftdi_txd,
    output             ftdi_rxd,

    output wire [3:0]  gpdi_dp, gpdi_dn,
    output             usb_fpga_pu_dp,
    output             usb_fpga_pu_dn,
    output wire [7:0]  led
  );

  assign wifi_rxd = ftdi_txd;
  // ftdi_rxd directly driven by debug UART below

  // USB host mode: pull-downs on D+ and D-
  assign usb_fpga_pu_dp = 0;
  assign usb_fpga_pu_dn = 0;

  wire kbd_reset;
  wire [7:0] kbd_rows;
  wire [4:0] kbd_columns;
  wire video; // 1-bit video signal (black/white)


  // Trivial conversion for audio
  wire mic,spk;
  assign audio_out_left  = spk;
  assign audio_out_right = mic;

  // Video timing
  wire vga_hsync, vga_vsync, vga_blank;

  // Power-on RESET (8 clocks)
  reg [7:0] poweron_reset = 8'h00;
  always @(posedge clkcpu) begin
    poweron_reset <= {poweron_reset[6:0],1'b1};
  end

  wire clkdvi;
  wire clkram;
  wire clkvga;
  wire clkcpu;

  clk_25_system
  clk_25_system_inst
  (
    .clk_in(clk25),
    .pll_125(clkdvi), // 125 Mhz, DDR bit rate
    .pll_75(clkram),  //  75 Mhz, treat bram as async
    .pll_25(clkvga),  //  25 Mhz, VGA pixel rate
    .pll_33(clkcpu)   //  3.25 Mhz, CPU clock
  );

  // =========================================================================
  // PS/2 keyboard (GPIO pins)
  // =========================================================================
  wire [10:0] hw_ps2_key;
  ps2 ps2_kbd (
     .clk(clkcpu),
     .ps2_clk(gp[11]),
     .ps2_data(gn[11]),
     .ps2_key(hw_ps2_key)
  );

  // =========================================================================
  // USB HID keyboard (US2 port)
  // =========================================================================

  // 6 MHz clock for USB low-speed
  wire clk_usb;
  wire usb_pll_locked;
  clk_usb clk_usb_inst (
    .clk_in(clk25),
    .clk_usb(clk_usb),
    .locked(usb_pll_locked)
  );

  // USB HID host controller
  wire [63:0] usb_hid_report;
  wire        usb_hid_valid;
  wire        usb_rx_done;
  wire [15:0] usb_rx_count;
  wire [7:0]  usb_response;
  usbh_host_hid #(
    .C_usb_speed(1),             // full-speed (48 MHz)
    .C_keepalive_phase_bits(15), // SOF interval for full-speed
    .C_keepalive_type(1'b0),     // SOF packets (required for full-speed devices)
    .C_report_length(8),         // 8-byte keyboard report
    .C_report_length_strict(0),  // accept any length > 0
    .C_setup_rom_file("usbh_setup_rom.mem"),
    .C_setup_rom_len(16)
  ) usb_hid_inst (
    .clk(clk_usb),
    .usb_dif(usb_fpga_dp),
    .usb_dp(usb_fpga_bd_dp),
    .usb_dn(usb_fpga_bd_dn),
    .bus_reset(~usb_pll_locked),
    .hid_report(usb_hid_report),
    .hid_valid(usb_hid_valid),
    .rx_done(usb_rx_done),
    .rx_count(usb_rx_count),
    .response(usb_response),
    .led(led)
  );

  // Count rx_done events and latch rx_count + response for debug
  reg [15:0] rx_done_count = 16'd0;
  reg [15:0] last_rx_count = 16'd0;
  reg [7:0]  last_response = 8'd0;
  always @(posedge clk_usb) begin
    if (usb_rx_done) begin
      rx_done_count <= rx_done_count + 16'd1;
      last_rx_count <= usb_rx_count;
      last_response <= usb_response;
    end
  end

  // UART debug output (sends HID reports + heartbeat over FTDI serial)
  uart_debug_tx uart_debug_inst (
    .clk(clk_usb),
    .hid_report(usb_hid_report),
    .hid_valid(usb_hid_valid),
    .leds(led),
    .rx_done_cnt(rx_done_count),
    .last_rx_count(last_rx_count),
    .last_response(last_response),
    .tx(ftdi_rxd)
  );

  // Convert HID reports to ps2_key events (48 MHz domain)
  wire [10:0] usb_ps2_key;
  usbhid_to_ps2 usbhid_to_ps2_inst (
    .clk(clk_usb),
    .hid_report(usb_hid_report),
    .hid_valid(usb_hid_valid),
    .ps2_key(usb_ps2_key)
  );

  // Clock domain crossing: 48 MHz -> 3.25 MHz
  // The USB ps2_key[10] is held high for ~5 clocks at 48 MHz (~104ns).
  // At 3.25 MHz (308ns period), the synchronizer catches it reliably.
  // Edge detection creates a single pulse in the CPU clock domain.
  reg [10:0] usb_ps2_key_sync1, usb_ps2_key_sync2;
  reg        usb_ps2_key_prev10;
  always @(posedge clkcpu) begin
    usb_ps2_key_sync1 <= usb_ps2_key;
    usb_ps2_key_sync2 <= usb_ps2_key_sync1;
    usb_ps2_key_prev10 <= usb_ps2_key_sync2[10];
  end
  // Rising edge of bit 10 = new event from USB keyboard
  wire usb_key_event = usb_ps2_key_sync2[10] & ~usb_ps2_key_prev10;
  wire [10:0] usb_ps2_key_out = {usb_key_event, usb_ps2_key_sync2[9:0]};

  // MUX: USB keyboard takes priority when it has an event
  wire [10:0] combined_ps2_key = usb_key_event ? usb_ps2_key_out : hw_ps2_key;

  // The Jupiter Ace core
  fpga_ace the_core (
    .clkram(clkram),
    .clk65(clkvga),
    .clkcpu(clkcpu),
    .reset(kbd_reset & poweron_reset[7] & btn[0]),
    .ear(ear),
    .kbd_reset(kbd_reset),
    .ps2_key(combined_ps2_key),
    .video(video),
    .hsync(vga_hsync),
    .vsync(vga_vsync),
    .blank(vga_blank),
    .mic(mic),
    .spk(spk)
  );

  // Convert VGA to DVI
  dvi vga2dvid (
    .pixclk(clkvga),
    .pixclk_x5(clkdvi),
    .red({8{video}}),
    .green({8{video}}),
    .blue({8{video}}),
    .vde(!vga_blank),
    .hSync(vga_hsync),
    .vSync(vga_vsync),
    .gpdi_dp(gpdi_dp),
    .gpdi_dn(gpdi_dn)
  );

endmodule
