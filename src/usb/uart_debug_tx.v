// UART TX for USB HID debugging - ASCII hex output
// Sends readable text over FTDI serial at 115200 baud
//
// Output format:
//   Heartbeat (~0.7s): "S:XX XXXX XXXX XX\r\n"  (LEDs, rx_done count, last rx_count, response PID)
//   HID report:        "R:XX XX XX XX XX XX XX XX\r\n"

module uart_debug_tx #(
    parameter CLKS_PER_BIT = 417  // 48 MHz / 115200 baud
)(
    input  wire        clk,
    input  wire [63:0] hid_report,
    input  wire        hid_valid,
    input  wire [7:0]  leds,
    input  wire [15:0] rx_done_cnt,
    input  wire [15:0] last_rx_count,
    input  wire [7:0]  last_response,
    output reg         tx = 1'b1
);

    // Nibble to lowercase hex ASCII
    function [7:0] hex;
        input [3:0] v;
        hex = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h57 + {4'd0, v});
    endfunction

    // ---- UART bit-level TX ----
    reg [7:0]  tx_shift = 8'd0;
    reg [3:0]  tx_bit = 4'd0;
    reg [8:0]  baud_cnt = 9'd0;
    reg        tx_load = 1'b0;
    reg [7:0]  tx_data = 8'd0;

    wire tx_idle = (tx_bit == 4'd0) && !tx_load;

    always @(posedge clk) begin
        if (tx_bit == 4'd0) begin
            if (tx_load) begin
                tx <= 1'b0;
                tx_shift <= tx_data;
                tx_bit <= 4'd1;
                baud_cnt <= 9'd0;
            end
        end else begin
            if (baud_cnt == CLKS_PER_BIT - 1) begin
                baud_cnt <= 9'd0;
                case (tx_bit)
                    4'd1:  begin tx <= tx_shift[0]; tx_bit <= 4'd2;  end
                    4'd2:  begin tx <= tx_shift[1]; tx_bit <= 4'd3;  end
                    4'd3:  begin tx <= tx_shift[2]; tx_bit <= 4'd4;  end
                    4'd4:  begin tx <= tx_shift[3]; tx_bit <= 4'd5;  end
                    4'd5:  begin tx <= tx_shift[4]; tx_bit <= 4'd6;  end
                    4'd6:  begin tx <= tx_shift[5]; tx_bit <= 4'd7;  end
                    4'd7:  begin tx <= tx_shift[6]; tx_bit <= 4'd8;  end
                    4'd8:  begin tx <= tx_shift[7]; tx_bit <= 4'd9;  end
                    4'd9:  begin tx <= 1'b1;        tx_bit <= 4'd10; end
                    4'd10: begin                    tx_bit <= 4'd0;  end
                    default: tx_bit <= 4'd0;
                endcase
            end else begin
                baud_cnt <= baud_cnt + 1;
            end
        end
    end

    // ---- Message sequencer ----
    localparam MS_IDLE   = 4'd0;
    localparam MS_PREFIX = 4'd1;
    localparam MS_COLON  = 4'd2;
    localparam MS_HI_NIB = 4'd3;
    localparam MS_LO_NIB = 4'd4;
    localparam MS_SEP    = 4'd5;
    localparam MS_CR     = 4'd6;
    localparam MS_LF     = 4'd7;
    localparam MS_DONE   = 4'd8;

    reg [3:0]  state = MS_IDLE;
    reg [63:0] report_reg = 64'd0;
    reg [7:0]  leds_reg = 8'd0;
    reg [15:0] cnt_reg = 16'd0;
    reg [15:0] rxc_reg = 16'd0;
    reg [7:0]  resp_reg = 8'd0;
    reg        is_report = 1'b0;
    reg [3:0]  byte_idx = 4'd0;
    reg [3:0]  bytes_remaining = 4'd0;
    reg [24:0] hb_cnt = 25'd0;

    // Current byte to encode as hex
    reg [7:0] cur_byte;
    always @(*) begin
        if (is_report) begin
            case (byte_idx)
                4'd0: cur_byte = report_reg[7:0];
                4'd1: cur_byte = report_reg[15:8];
                4'd2: cur_byte = report_reg[23:16];
                4'd3: cur_byte = report_reg[31:24];
                4'd4: cur_byte = report_reg[39:32];
                4'd5: cur_byte = report_reg[47:40];
                4'd6: cur_byte = report_reg[55:48];
                4'd7: cur_byte = report_reg[63:56];
                default: cur_byte = 8'd0;
            endcase
        end else begin
            case (byte_idx)
                4'd0: cur_byte = leds_reg;
                4'd1: cur_byte = cnt_reg[15:8];
                4'd2: cur_byte = cnt_reg[7:0];
                4'd3: cur_byte = rxc_reg[15:8];
                4'd4: cur_byte = rxc_reg[7:0];
                4'd5: cur_byte = resp_reg;
                default: cur_byte = 8'd0;
            endcase
        end
    end

    always @(posedge clk) begin
        hb_cnt <= hb_cnt + 1;
        tx_load <= 1'b0;

        case (state)
            MS_IDLE: begin
                if (hid_valid) begin
                    report_reg <= hid_report;
                    leds_reg <= leds;
                    is_report <= 1'b1;
                    byte_idx <= 4'd0;
                    bytes_remaining <= 4'd7;
                    state <= MS_PREFIX;
                end else if (hb_cnt == 25'd0) begin
                    leds_reg <= leds;
                    cnt_reg <= rx_done_cnt;
                    rxc_reg <= last_rx_count;
                    resp_reg <= last_response;
                    is_report <= 1'b0;
                    byte_idx <= 4'd0;
                    bytes_remaining <= 4'd5;  // leds + 2 cnt + 2 rxcount + response PID
                    state <= MS_PREFIX;
                end
            end

            MS_PREFIX: begin
                if (tx_idle) begin
                    tx_data <= is_report ? 8'h52 : 8'h53;  // 'R' or 'S'
                    tx_load <= 1'b1;
                    state <= MS_COLON;
                end
            end

            MS_COLON: begin
                if (tx_idle) begin
                    tx_data <= 8'h3A;  // ':'
                    tx_load <= 1'b1;
                    state <= MS_HI_NIB;
                end
            end

            MS_HI_NIB: begin
                if (tx_idle) begin
                    tx_data <= hex(cur_byte[7:4]);
                    tx_load <= 1'b1;
                    state <= MS_LO_NIB;
                end
            end

            MS_LO_NIB: begin
                if (tx_idle) begin
                    tx_data <= hex(cur_byte[3:0]);
                    tx_load <= 1'b1;
                    state <= MS_SEP;
                end
            end

            MS_SEP: begin
                if (tx_idle) begin
                    if (bytes_remaining > 4'd0) begin
                        tx_data <= 8'h20;  // space
                        tx_load <= 1'b1;
                        byte_idx <= byte_idx + 4'd1;
                        bytes_remaining <= bytes_remaining - 4'd1;
                        state <= MS_HI_NIB;
                    end else begin
                        state <= MS_CR;
                    end
                end
            end

            MS_CR: begin
                if (tx_idle) begin
                    tx_data <= 8'h0D;
                    tx_load <= 1'b1;
                    state <= MS_LF;
                end
            end

            MS_LF: begin
                if (tx_idle) begin
                    tx_data <= 8'h0A;
                    tx_load <= 1'b1;
                    state <= MS_DONE;
                end
            end

            MS_DONE: begin
                if (tx_idle)
                    state <= MS_IDLE;
            end

            default: state <= MS_IDLE;
        endcase
    end

endmodule
