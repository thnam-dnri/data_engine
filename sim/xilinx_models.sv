//------------------------------------------------------------------------------
// xilinx_models.sv
//
// Behavioral models of Xilinx primitives for iverilog simulation (non-synth).
// Used only when `ifndef SYNTHESIS.
//
// Implements:
//   - IDDR: Input Double Data Rate (SAME_EDGE_PIPELINED mode)
//   - BUFG: Global clock buffer (pass-through)
//   - OBUFDS: Differential output buffer (pass-through)
//   - LUT1: 1-input LUT (truth-table pass-through/inverter/etc.)
//
// These are NOT synthesizable — they provide enough accuracy for functional
// testbenches but do NOT model timing, skew, or Xilinx-specific behavior.
//------------------------------------------------------------------------------

// =========================================================================
// IDDR — Input Double Data Rate
// SAME_EDGE_PIPELINED mode: Q1 = rising edge, Q2 = falling edge
// =========================================================================
module IDDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE_PIPELINED",
    parameter INIT_Q1 = 1'b0,
    parameter INIT_Q2 = 1'b0,
    parameter SRTYPE = "ASYNC"
) (
    output reg Q1,
    output reg Q2,
    input  wire C,
    input  wire CE,
    input  wire D,
    input  wire R,
    input  wire S
);

    // Track previous clock value for edge detection
    reg c_prev;

    always @(posedge C or posedge R) begin
        if (R) begin
            Q1 <= INIT_Q1;
            Q2 <= INIT_Q2;
            c_prev <= 1'b0;
        end else if (CE) begin
            // Rising edge sample
            Q1 <= D;
            c_prev <= 1'b1;
        end
    end

    always @(negedge C or posedge R) begin
        if (R) begin
            Q2 <= INIT_Q2;
        end else if (CE) begin
            // Falling edge sample
            Q2 <= D;
        end
    end

endmodule : IDDR

// =========================================================================
// BUFG — Global clock buffer (pass-through for simulation)
// =========================================================================
module BUFG (
    input  wire I,
    output wire O
);
    assign O = I;
endmodule : BUFG

// =========================================================================
// OBUFDS — Differential output buffer (pass-through for simulation)
// =========================================================================
module OBUFDS #(
    parameter IOSTANDARD = "DEFAULT",
    parameter SLEW = "SLOW"
) (
    output wire O,
    output wire OB,
    input  wire I
);
    assign O  = I;
    assign OB = ~I;
endmodule : OBUFDS

// =========================================================================
// LUT1 — 1-input lookup table
// =========================================================================
module LUT1 #(
    parameter [1:0] INIT = 2'b10
) (
    output wire O,
    input  wire I0
);
    assign O = I0 ? INIT[1] : INIT[0];
endmodule : LUT1
