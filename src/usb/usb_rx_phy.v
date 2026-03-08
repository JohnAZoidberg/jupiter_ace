// USB RX PHY soft-core
// Converted from VHDL (usb_rx_phy.vhd) by EMARD
// License=GPL
//
// Differential data correctly recovered.
// Drop-in PHY replacement with more reliable data reception.

module usb_rx_phy
#(
    parameter C_clk_input_hz = 6000000,  // Hz input clock (6 or 48 MHz)
    parameter C_clk_bit_hz   = 1500000,  // Hz bit clock (1.5 Mbps or 12 Mbps)
    parameter C_PA_bits      = 8         // phase accumulator bits
)
(
    input  wire       clk,
    input  wire       reset,           // active high
    input  wire       usb_dif,         // differential D+/D- input
    input  wire       usb_dp,
    input  wire       usb_dn,
    output wire [1:0] linestate,
    output wire       clk_recovered,
    output wire       clk_recovered_edge,
    output wire       rawdata,
    input  wire       rx_en,
    output wire       rx_active,
    output wire       rx_error,
    output wire       valid,
    output wire [7:0] data
);

    // Phase accumulator increment: (2^(PA_bits-1)) * bit_rate / clk_rate
    // PA_inc=32 works for both 6MHz/1.5Mbps AND 48MHz/12Mbps (same ratio)
    localparam [C_PA_bits-1:0] C_PA_inc = ((1 << (C_PA_bits-1)) * C_clk_bit_hz) / C_clk_input_hz;
    // Phase accumulator compensation for edge re-sync
    localparam [C_PA_bits-2:0] C_PA_compensate = C_PA_inc[C_PA_bits-2:0] + C_PA_inc[C_PA_bits-2:0] + C_PA_inc[C_PA_bits-2:0];
    localparam [C_PA_bits-2:0] C_PA_init = C_PA_compensate;

    reg [C_PA_bits-1:0] R_PA;
    reg [1:0] R_dif_shift;
    reg [1:0] R_clk_recovered_shift;
    wire S_clk_recovered;
    wire S_linebit;
    reg  R_linebit_prev;
    wire S_bit;
    reg  R_frame;
    reg [7:0] R_data;
    reg [7:0] R_data_latch;
    reg [7:0] R_valid;
    reg [1:0] R_linestate;
    reg [1:0] R_linestate_prev;
    reg [1:0] R_linestate_sync;
    reg [6:0] R_idlecnt;
    reg R_preamble;
    reg R_rxactive;
    reg R_rx_en;
    reg R_valid_prev;

    // Synchronize inputs and track edges
    always @(posedge clk) begin
        if ((usb_dn || usb_dp) && rx_en)
            R_dif_shift <= {usb_dif, R_dif_shift[1]};
        R_clk_recovered_shift <= {S_clk_recovered, R_clk_recovered_shift[1]};
        R_linestate <= {usb_dn, usb_dp};
        R_linestate_prev <= R_linestate;
        R_rx_en <= rx_en;
    end

    // Phase accumulator for clock recovery
    always @(posedge clk) begin
        if (R_dif_shift[1] != R_dif_shift[0])
            R_PA[C_PA_bits-2:0] <= C_PA_init;
        else
            R_PA <= R_PA + C_PA_inc;
    end

    assign S_clk_recovered = R_PA[C_PA_bits-1];
    assign clk_recovered = S_clk_recovered;
    assign clk_recovered_edge = (R_clk_recovered_shift[1] != S_clk_recovered) ? 1'b1 : 1'b0;

    assign S_linebit = R_dif_shift[0];
    assign S_bit = ~(S_linebit ^ R_linebit_prev);  // NRZI decode

    // Data shift register, stuffed bit removal, byte latching
    always @(posedge clk) begin
        if (R_rx_en && !reset) begin
            if (R_clk_recovered_shift[1] != S_clk_recovered) begin
                // Synchronous with recovered clock
                // Idle counter for stuff bit detection
                if (R_linebit_prev == S_linebit)
                    R_idlecnt <= {R_idlecnt[0], R_idlecnt[6:1]};  // shift right
                else
                    R_idlecnt <= 7'b1000000;  // reset

                R_linebit_prev <= S_linebit;

                // Skip stuffed bit if in frame
                if ((!R_idlecnt[0] && R_frame) || !R_frame) begin
                    if (R_linestate_sync == 2'b00)
                        R_data <= 8'h00;  // SE0 resets data
                    else
                        R_data <= {S_bit, R_data[7:1]};  // shift in payload bit
                end

                // Latch byte
                if (R_frame && R_valid[1])
                    R_data_latch <= R_data;
            end
        end
    end

    // Frame detection, preamble detection, valid tracking
    always @(posedge clk) begin
        if (R_rx_en && !reset) begin
            if (R_clk_recovered_shift[1] != S_clk_recovered) begin
                // Synchronous with recovered clock
                if (R_linestate_sync == 2'b00) begin
                    // SE0 - end of frame
                    R_frame <= 1'b0;
                    R_valid <= 8'h00;
                    R_preamble <= 1'b0;
                    R_rxactive <= 1'b0;
                end else begin
                    if (R_frame) begin
                        if (R_preamble) begin
                            // Wait for end of preamble: "100000" pattern
                            if (R_data[6:1] == 6'b100000) begin
                                R_preamble <= 1'b0;
                                R_valid <= 8'h80;  // C_valid_init
                                R_rxactive <= 1'b1;
                            end
                        end else begin
                            // After preamble: circular-shift valid register
                            if (!R_idlecnt[0]) begin
                                // Not a stuffed bit
                                R_valid <= {R_valid[0], R_valid[7:1]};
                            end else begin
                                // Stuffed bit expected (S_bit should be 0)
                                if (S_bit) begin
                                    // Wrong stuff bit - drop frame
                                    R_valid <= 8'h00;
                                    R_frame <= 1'b0;
                                    R_rxactive <= 1'b0;
                                end
                            end
                        end
                    end else begin
                        // Not in frame - detect start: "000111" pattern
                        if (R_data[7:2] == 6'b000111) begin
                            R_frame <= 1'b1;
                            R_preamble <= 1'b1;
                            R_valid <= 8'h00;
                            R_rxactive <= 1'b0;
                        end
                    end
                end
                R_linestate_sync <= R_linestate;
            end
        end else begin
            // rx_en = 0 or reset
            R_valid <= 8'h00;
            R_frame <= 1'b0;
            R_rxactive <= 1'b0;
        end
    end

    assign data = R_data_latch;
    assign rawdata = R_linebit_prev;
    assign linestate = R_linestate;
    assign rx_active = R_frame;  // timing early
    assign rx_error = 1'b0;

    // Generate single-cycle valid pulse
    always @(posedge clk)
        R_valid_prev <= R_valid[0];

    assign valid = R_valid[0] & ~R_valid_prev;

endmodule
