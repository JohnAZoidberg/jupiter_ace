// USB HID keyboard report to ps2_key[10:0] converter
// Converts 8-byte HID keyboard reports into ps2_key events
// compatible with keyboard_for_ace.v
//
// ps2_key[10]  = new key event (active for 1 clock)
// ps2_key[9]   = released flag (1=released, 0=pressed)
// ps2_key[8]   = extended flag (for E0-prefixed PS/2 scancodes)
// ps2_key[7:0] = PS/2 scancode
//
// HID report format (8 bytes):
//   byte 0: modifier bit flags (LCtrl,LShift,LAlt,LGUI,RCtrl,RShift,RAlt,RGUI)
//   byte 1: reserved (always 0)
//   bytes 2-7: up to 6 simultaneous keycodes (0 = no key)

module usbhid_to_ps2 (
    input  wire        clk,
    input  wire [63:0] hid_report,
    input  wire        hid_valid,
    output reg  [10:0] ps2_key
);

    // HID-to-PS/2 lookup table: 256 entries x 9 bits {extended, scancode}
    reg [8:0] hid_to_ps2_rom [0:255];
    initial $readmemh("hid_to_ps2.mem", hid_to_ps2_rom);

    // Current and previous HID reports
    reg [63:0] report_cur;
    reg [63:0] report_prev;

    // State machine
    localparam S_IDLE          = 3'd0;
    localparam S_CHECK_MODS    = 3'd1;
    localparam S_CHECK_RELEASED = 3'd2;
    localparam S_CHECK_PRESSED = 3'd3;
    localparam S_EMIT          = 3'd4;
    localparam S_EMIT_HOLD     = 3'd5;  // hold event for CDC

    reg [2:0] state = S_IDLE;
    reg [2:0] return_state;    // state to return to after emit
    reg [3:0] scan_idx;        // index for scanning modifiers (0-7) or keys (0-5)
    reg       emit_release;    // 1 = releasing, 0 = pressing
    reg [7:0] emit_hid_code;   // HID code to emit
    reg [2:0] hold_cnt;        // hold counter for CDC pulse stretching

    // Wires for current report fields
    wire [7:0] cur_mods  = report_cur[7:0];
    wire [7:0] prev_mods = report_prev[7:0];

    // Extract key from report by index (bytes 2-7)
    function [7:0] get_key;
        input [63:0] report;
        input [2:0]  idx;
        begin
            case (idx)
                3'd0: get_key = report[23:16];
                3'd1: get_key = report[31:24];
                3'd2: get_key = report[39:32];
                3'd3: get_key = report[47:40];
                3'd4: get_key = report[55:48];
                3'd5: get_key = report[63:56];
                default: get_key = 8'h00;
            endcase
        end
    endfunction

    // Check if a keycode exists in a report's key slots (bytes 2-7)
    function key_in_report;
        input [63:0] report;
        input [7:0]  keycode;
        begin
            key_in_report = (keycode != 8'h00) && (
                report[23:16] == keycode ||
                report[31:24] == keycode ||
                report[39:32] == keycode ||
                report[47:40] == keycode ||
                report[55:48] == keycode ||
                report[63:56] == keycode
            );
        end
    endfunction

    // Lookup result
    wire [8:0] ps2_lookup = hid_to_ps2_rom[emit_hid_code];

    always @(posedge clk) begin
        ps2_key[10] <= 1'b0;  // default: no event

        case (state)
            S_IDLE: begin
                if (hid_valid) begin
                    report_cur <= hid_report;
                    state <= S_CHECK_MODS;
                    scan_idx <= 4'd0;
                end
            end

            S_CHECK_MODS: begin
                if (scan_idx < 4'd8) begin
                    // Check each modifier bit
                    if (cur_mods[scan_idx[2:0]] != prev_mods[scan_idx[2:0]]) begin
                        // Modifier changed - emit event
                        // HID modifier usage codes: 0xE0 + bit position
                        emit_hid_code <= 8'hE0 + {5'd0, scan_idx[2:0]};
                        emit_release <= prev_mods[scan_idx[2:0]]; // was pressed, now released
                        return_state <= S_CHECK_MODS;
                        state <= S_EMIT;
                    end else begin
                        scan_idx <= scan_idx + 1;
                    end
                end else begin
                    // Done with modifiers, check released keys
                    scan_idx <= 4'd0;
                    state <= S_CHECK_RELEASED;
                end
            end

            S_CHECK_RELEASED: begin
                if (scan_idx < 4'd6) begin
                    // Check old keys not in new report
                    if (get_key(report_prev, scan_idx[2:0]) != 8'h00 &&
                        !key_in_report(report_cur, get_key(report_prev, scan_idx[2:0]))) begin
                        emit_hid_code <= get_key(report_prev, scan_idx[2:0]);
                        emit_release <= 1'b1;
                        return_state <= S_CHECK_RELEASED;
                        state <= S_EMIT;
                    end else begin
                        scan_idx <= scan_idx + 1;
                    end
                end else begin
                    // Done with releases, check pressed keys
                    scan_idx <= 4'd0;
                    state <= S_CHECK_PRESSED;
                end
            end

            S_CHECK_PRESSED: begin
                if (scan_idx < 4'd6) begin
                    // Check new keys not in old report
                    if (get_key(report_cur, scan_idx[2:0]) != 8'h00 &&
                        !key_in_report(report_prev, get_key(report_cur, scan_idx[2:0]))) begin
                        emit_hid_code <= get_key(report_cur, scan_idx[2:0]);
                        emit_release <= 1'b0;
                        return_state <= S_CHECK_PRESSED;
                        state <= S_EMIT;
                    end else begin
                        scan_idx <= scan_idx + 1;
                    end
                end else begin
                    // All done - save current as previous
                    report_prev <= report_cur;
                    state <= S_IDLE;
                end
            end

            S_EMIT: begin
                // Output the ps2_key event if lookup is valid
                if (ps2_lookup[7:0] != 8'h00) begin
                    ps2_key <= {1'b1, emit_release, ps2_lookup};
                    hold_cnt <= 3'd4;  // hold for 4 more clocks (total 5 @ 6MHz > 1 period @ 3.25MHz)
                    state <= S_EMIT_HOLD;
                end else begin
                    // No valid mapping, skip
                    scan_idx <= scan_idx + 1;
                    state <= return_state;
                end
            end

            S_EMIT_HOLD: begin
                // Keep ps2_key[10] high for CDC reliability
                if (hold_cnt != 3'd0) begin
                    hold_cnt <= hold_cnt - 1;
                end else begin
                    scan_idx <= scan_idx + 1;
                    state <= return_state;
                end
            end

            default:
                state <= S_IDLE;
        endcase
    end

endmodule
