// USB 1.1 PHY (top level)
// Converted from VHDL (usb_phy.vhd)
// Original Verilog by Rudolf Usselmann, VHDL by Martin Neumann
// RX PHY replacement by EMARD
//
// Copyright (C) 2000-2002 Rudolf Usselmann
// www.asics.ws / rudi@asics.ws
//
// This source file may be used and distributed without
// restriction provided that this copyright statement is not
// removed from the file and that any derivative work contains
// the original copyright notice and the associated disclaimer.

module usb_phy
#(
    parameter usb_rst_det = 1'b1
)
(
    input  wire       clk,           // 48 MHz (full speed) or 6 MHz (low speed)
    input  wire       rst,           // active low
    input  wire       phy_tx_mode,   // HIGH for differential IO mode
    output wire       usb_rst,
    // Transceiver Interface
    input  wire       rxd,
    input  wire       rxdp,
    input  wire       rxdn,
    output wire       txdp,
    output wire       txdn,
    output wire       txoe,
    // Clock recovery debug
    output wire       ce_o,
    // RX debug interface
    output wire       sync_err_o,
    output wire       bit_stuff_err_o,
    output wire       byte_err_o,
    // UTMI Interface
    input  wire       LineCtrl_i,
    input  wire [7:0] DataOut_i,
    input  wire       TxValid_i,
    output wire       TxReady_o,
    output wire [7:0] DataIn_o,
    output wire       RxValid_o,
    output wire       RxActive_o,
    output wire       RxError_o,
    output wire [1:0] LineState_o
);

    wire [1:0] LineState;
    wire       fs_ce;
    wire       txoe_out;
    wire       reset;

    assign LineState_o = LineState;
    assign txoe = txoe_out;

    // TX PHY
    usb_tx_phy i_tx_phy (
        .clk       (clk),
        .rst       (rst),
        .fs_ce     (fs_ce),
        .phy_mode  (phy_tx_mode),
        // Transceiver Interface
        .txdp      (txdp),
        .txdn      (txdn),
        .txoe      (txoe_out),
        // UTMI Interface
        .LineCtrl_i(LineCtrl_i),
        .DataOut_i (DataOut_i),
        .TxValid_i (TxValid_i),
        .TxReady_o (TxReady_o)
    );

    // RX PHY (EMARD version)
    assign reset = ~rst;
    usb_rx_phy E_rx_phy_emard (
        .clk               (clk),
        .reset             (reset),
        .clk_recovered_edge(fs_ce),
        // Transceiver Interface
        .usb_dif           (rxd),
        .usb_dp            (rxdp),
        .usb_dn            (rxdn),
        // UTMI Interface
        .data              (DataIn_o),
        .valid             (RxValid_o),
        .rx_active         (RxActive_o),
        .rx_en             (txoe_out),
        .linestate         (LineState)
    );

    assign RxError_o = 1'b0;
    assign ce_o = fs_ce;
    assign sync_err_o = 1'b0;
    assign bit_stuff_err_o = 1'b0;
    assign byte_err_o = 1'b0;

    // USB Reset detection (SE0 for at least 2.5us)
    generate
        if (usb_rst_det == 1'b1) begin : usb_rst_g
            reg [4:0] rst_cnt = 5'd0;
            reg       usb_rst_out = 1'b0;

            always @(posedge clk) begin
                if (rst == 1'b0)
                    rst_cnt <= 5'd0;
                else begin
                    if (LineState != 2'b00)
                        rst_cnt <= 5'd0;
                    else if (!usb_rst_out && fs_ce)
                        rst_cnt <= rst_cnt + 1;
                end
            end

            always @(posedge clk) begin
                if (rst_cnt == 5'b11111)
                    usb_rst_out <= 1'b1;
                else
                    usb_rst_out <= 1'b0;
            end

            assign usb_rst = usb_rst_out;
        end else begin : no_usb_rst
            assign usb_rst = 1'b0;
        end
    endgenerate

endmodule
