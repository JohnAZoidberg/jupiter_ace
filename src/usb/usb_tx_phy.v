// USB 1.1 TX PHY
// Converted from VHDL (usb_tx_phy.vhd) by Martin Neumann / Rudolf Usselmann
// LineCtrl modifications by EMARD
//
// Copyright (C) 2000-2002 Rudolf Usselmann
// www.asics.ws / rudi@asics.ws
//
// This source file may be used and distributed without
// restriction provided that this copyright statement is not
// removed from the file and that any derivative work contains
// the original copyright notice and the associated disclaimer.

module usb_tx_phy (
    input  wire       clk,
    input  wire       rst,
    input  wire       fs_ce,
    input  wire       phy_mode,       // HIGH for differential IO mode
    // Transceiver Interface
    output reg        txdp,
    output reg        txdn,
    output reg        txoe,
    // UTMI Interface
    input  wire       LineCtrl_i,     // 0: Data TX, 1: LineCtrl
    input  wire [7:0] DataOut_i,      // TX byte or LineCtrl mode
    input  wire       TxValid_i,
    output reg        TxReady_o
);

    reg [7:0] hold_reg;
    reg       ld_data;
    wire      ld_data_d;
    wire      ld_sop_d;
    reg       R_LineCtrl_i;
    reg       R_long_i;
    reg       R_busreset_i;
    reg [15:0] bit_cnt;
    wire      sft_done_e;
    wire      any_eop_state;
    wire      append_eop;
    wire      se_state;
    reg       data_xmit;
    reg [7:0] hold_reg_d;
    reg [2:0] one_cnt;
    reg       sd_bs_o;
    reg       sd_nrzi_o;
    reg       sd_raw_o;
    reg       sft_done;
    reg       sft_done_r;
    reg [3:0] state;
    wire      stuff;
    reg       tx_ip;
    reg       tx_ip_sync;
    reg       txoe_r1, txoe_r2;
    wire      S_long;

    localparam IDLE_STATE = 4'b0000;
    localparam SOP_STATE  = 4'b0001;
    localparam DATA_STATE = 4'b0010;
    localparam WAIT_STATE = 4'b0011;
    localparam EOP0_STATE = 4'b1000;
    localparam EOP1_STATE = 4'b1001;
    localparam EOP2_STATE = 4'b1010;
    localparam EOP3_STATE = 4'b1011;
    localparam EOP4_STATE = 4'b1100;
    localparam EOP5_STATE = 4'b1101;

    // Misc Logic
    always @(posedge clk) begin
        if (rst == 1'b0)
            TxReady_o <= 1'b0;
        else
            TxReady_o <= (ld_data_d | (R_LineCtrl_i & any_eop_state)) & TxValid_i;
    end

    always @(posedge clk)
        ld_data <= ld_data_d;

    // Transmit in progress indicator
    always @(posedge clk) begin
        if (rst == 1'b0)
            tx_ip <= 1'b0;
        else begin
            if (ld_sop_d)
                tx_ip <= 1'b1;
            else if (append_eop)
                tx_ip <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst == 1'b0)
            tx_ip_sync <= 1'b0;
        else if (fs_ce)
            tx_ip_sync <= tx_ip;
    end

    always @(posedge clk) begin
        if (rst == 1'b0)
            data_xmit <= 1'b0;
        else begin
            if (TxValid_i && !tx_ip)
                data_xmit <= 1'b1;
            else if (!TxValid_i)
                data_xmit <= 1'b0;
        end
    end

    // Shift Register
    always @(posedge clk) begin
        if (rst == 1'b0)
            bit_cnt <= 16'd0;
        else begin
            if (!tx_ip_sync)
                bit_cnt <= 16'd0;
            else if (fs_ce && !stuff)
                bit_cnt <= bit_cnt + 1;
        end
    end

    always @(posedge clk) begin
        if (!tx_ip_sync)
            sd_raw_o <= 1'b0;
        else
            sd_raw_o <= hold_reg_d[bit_cnt[2:0]];
    end

    always @(posedge clk) begin
        if (rst == 1'b0) begin
            sft_done   <= 1'b0;
            sft_done_r <= 1'b0;
        end else begin
            if (bit_cnt[bit_cnt[15]] == (R_LineCtrl_i & R_long_i) && bit_cnt[2:0] == 3'b111)
                sft_done <= ~stuff;
            else
                sft_done <= 1'b0;
            sft_done_r <= sft_done;
        end
    end

    assign sft_done_e = sft_done & ~sft_done_r;

    // Out Data Hold Register
    always @(posedge clk) begin
        if (rst == 1'b0) begin
            hold_reg   <= 8'h00;
            hold_reg_d <= 8'h00;
        end else begin
            if (ld_sop_d)
                hold_reg <= 8'h80;
            else if (ld_data)
                hold_reg <= DataOut_i;
            hold_reg_d <= hold_reg;
        end
    end

    // Bit Stuffer
    always @(posedge clk) begin
        if (rst == 1'b0)
            one_cnt <= 3'b000;
        else begin
            if (!tx_ip_sync)
                one_cnt <= 3'b000;
            else if (fs_ce) begin
                if (!sd_raw_o || stuff)
                    one_cnt <= 3'b000;
                else
                    one_cnt <= one_cnt + 1;
            end
        end
    end

    assign stuff = (one_cnt == 3'b110) ? 1'b1 : 1'b0;

    always @(posedge clk) begin
        if (rst == 1'b0)
            sd_bs_o <= 1'b0;
        else if (fs_ce) begin
            if (!tx_ip_sync)
                sd_bs_o <= 1'b0;
            else begin
                if (stuff)
                    sd_bs_o <= 1'b0;
                else
                    sd_bs_o <= sd_raw_o;
            end
        end
    end

    // NRZI Encoder
    always @(posedge clk) begin
        if (rst == 1'b0)
            sd_nrzi_o <= 1'b1;
        else begin
            if (!tx_ip_sync || !txoe_r1 || R_LineCtrl_i) begin
                if (R_LineCtrl_i)
                    sd_nrzi_o <= S_long;
                else
                    sd_nrzi_o <= 1'b1;
            end
            else if (fs_ce) begin
                if (sd_bs_o)
                    sd_nrzi_o <= sd_nrzi_o;
                else
                    sd_nrzi_o <= ~sd_nrzi_o;
            end
        end
    end

    // Output Enable Logic
    always @(posedge clk) begin
        if (rst == 1'b0) begin
            txoe_r1 <= 1'b0;
            txoe_r2 <= 1'b0;
            txoe    <= 1'b1;
        end else if (fs_ce) begin
            txoe_r1 <= tx_ip_sync;
            txoe_r2 <= txoe_r1;
            txoe    <= ~(txoe_r1 | txoe_r2);
        end
    end

    // Output Registers
    always @(posedge clk) begin
        if (rst == 1'b0) begin
            txdp <= 1'b1;
            txdn <= 1'b0;
        end else if (fs_ce) begin
            if (phy_mode) begin
                txdp <= ~se_state &  sd_nrzi_o;
                txdn <= ~se_state & ~sd_nrzi_o;
            end else begin
                txdp <= sd_nrzi_o;
                txdn <= se_state;
            end
        end
    end

    // Tx State Machine
    assign any_eop_state = state[3];

    always @(posedge clk) begin
        if (rst == 1'b0)
            state <= IDLE_STATE;
        else begin
            if (!any_eop_state) begin
                case (state)
                    IDLE_STATE: begin
                        if (TxValid_i) begin
                            R_LineCtrl_i <= LineCtrl_i;
                            R_long_i     <= DataOut_i[0];
                            R_busreset_i <= DataOut_i[1];
                            state <= SOP_STATE;
                        end
                    end
                    SOP_STATE: begin
                        if (sft_done_e)
                            state <= DATA_STATE;
                    end
                    DATA_STATE: begin
                        if (!data_xmit && sft_done_e) begin
                            if (one_cnt == 3'b101 && hold_reg_d[7])
                                state <= EOP0_STATE;
                            else
                                state <= EOP1_STATE;
                        end
                    end
                    WAIT_STATE: begin
                        if (fs_ce)
                            state <= IDLE_STATE;
                    end
                    default: state <= IDLE_STATE;
                endcase
            end else begin
                if (fs_ce) begin
                    if (state == EOP5_STATE)
                        state <= WAIT_STATE;
                    else
                        state <= state + 1;
                end
            end
        end
    end

    assign append_eop = (state[3:2] == 2'b11) ? 1'b1 : 1'b0;
    assign se_state   = (append_eop || (state != WAIT_STATE && R_LineCtrl_i && R_long_i && R_busreset_i)) ? 1'b1 : 1'b0;
    assign ld_sop_d   = (state == IDLE_STATE) ? TxValid_i : 1'b0;
    assign ld_data_d  = (state == SOP_STATE || (state == DATA_STATE && data_xmit)) ? sft_done_e : 1'b0;
    assign S_long     = (state != WAIT_STATE && R_long_i) ? 1'b0 : 1'b1;

endmodule
