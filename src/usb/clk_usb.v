// 6 MHz USB low-speed clock PLL
// Input: 25 MHz, Output: 6 MHz via CLKOS
//
// With FEEDBK_PATH="CLKOP":
//   f_CLKOP = f_CLKI * CLKFB_DIV / CLKI_DIV = 25 * 5 / 1 = 125 MHz
//   f_VCO   = f_CLKOP * CLKOP_DIV = 125 * 6 = 750 MHz
//   f_CLKOS = f_VCO / CLKOS_DIV = 750 / 125 = 6.0 MHz
//
// Parameters match Lattice SCUBA-generated PLL from ulx3s-misc

module clk_usb
(
    input  clk_in,   // 25 MHz
    output clk_usb,  // 6 MHz
    output locked
);

wire clkop_fb;  // 125 MHz feedback signal (internal only)

(* FREQUENCY_PIN_CLKI="25" *)
(* FREQUENCY_PIN_CLKOP="125" *)
(* FREQUENCY_PIN_CLKOS="6" *)
(* ICP_CURRENT="7" *) (* LPF_RESISTOR="16" *)
EHXPLLL #(
    .PLLRST_ENA("DISABLED"),
    .INTFB_WAKE("DISABLED"),
    .STDBY_ENABLE("DISABLED"),
    .DPHASE_SOURCE("DISABLED"),
    .OUTDIVIDER_MUXA("DIVA"),
    .OUTDIVIDER_MUXB("DIVB"),
    .OUTDIVIDER_MUXC("DIVC"),
    .OUTDIVIDER_MUXD("DIVD"),
    .CLKI_DIV(1),
    .CLKOP_ENABLE("ENABLED"),
    .CLKOP_DIV(6),
    .CLKOP_CPHASE(5),
    .CLKOP_FPHASE(0),
    .CLKOS_ENABLE("ENABLED"),
    .CLKOS_DIV(125),
    .CLKOS_CPHASE(124),
    .CLKOS_FPHASE(0),
    .CLKOS2_ENABLE("DISABLED"),
    .CLKOS3_ENABLE("DISABLED"),
    .FEEDBK_PATH("CLKOP"),
    .CLKFB_DIV(5)
) pll_usb_i (
    .RST(1'b0),
    .STDBY(1'b0),
    .CLKI(clk_in),
    .CLKOP(clkop_fb),
    .CLKOS(clk_usb),
    .CLKOS2(),
    .CLKOS3(),
    .CLKFB(clkop_fb),
    .CLKINTFB(),
    .PHASESEL0(1'b0),
    .PHASESEL1(1'b0),
    .PHASEDIR(1'b0),
    .PHASESTEP(1'b0),
    .PHASELOADREG(1'b0),
    .PLLWAKESYNC(1'b0),
    .ENCLKOP(1'b0),
    .ENCLKOS(1'b0),
    .LOCK(locked)
);

endmodule
