//------------------------------------------------------------------------------
// adc_interface.sv
//
// ADC Interface — IDDR deinterleaver for AD9648 interleaved CMOS mode.
//
// The AD9648 presents both channels on a single 14-bit data bus in CMOS mode:
//   Channel A is sampled on the RISING edge of DCO
//   Channel B is sampled on the FALLING edge of DCO
//
// This module instantiates 14 IDDR primitives (SAME_EDGE_PIPELINED mode) to
// capture both edges, plus a BUFG for DCO clock distribution.
//
// Debug interface (dbg_if):
//   state:    0=IDLE, 1=DCO_LOCKED, 2=DEINTERLEAVE_ACTIVE, 3=DCO_LOST
//   error:    sticky, set on DCO loss (write 1 to clear via COMMON_1)
//   error_id: 1=DCO_lost
//   event_count: samples deinterleaved (increments each valid dco cycle)
//   word_count:  16-bit packed channel-pair words produced
//
// Ports conform to Architecture.md §1 and sig_recorder reference.
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

import dbg_pkg::*;

module adc_interface (
    // --- Clock & Reset ---
    input  wire       adc_dco,         // AD9648 data clock output (LVCMOS18)
    input  wire       sys_clk,         // system clock (100 MHz) for DCO watchdog
    input  wire       sys_rst_n,       // system reset (async, active-low)
    output wire       dco_clk_out,     // BUFG'd DCO clock for downstream CDC

    // --- ADC Data Bus ---
    input  wire [13:0] adc_data,       // interleaved 14-bit CMOS bus

    // --- Deinterleaved Outputs (adc_dco domain) ---
    output logic [15:0] ch_a_data,     // Channel A sample (rising edge)
    output logic [15:0] ch_b_data,     // Channel B sample (falling edge)
    output logic        data_valid,    // strobe: ch_a/ch_b valid this cycle

    // --- Channel Select ---
    input  wire        channel_sel,    // 0=chA, 1=chB (for single-channel output)

    // --- Debug Interface ---
    output dbg_pkg::dbg_info_t dbg_info  // 128-bit packed debug data
);

    // =========================================================================
    // DCO clock buffer
    // =========================================================================
    wire dco_clk;
    BUFG u_dco_bufg (.I(adc_dco), .O(dco_clk));
    assign dco_clk_out = dco_clk;

    // =========================================================================
    // DCO lock detection (cross-domain: dco_clk + sys_clk)
    // =========================================================================
    // Why crossing domains? A stopped clock cannot be detected within its own
    // domain, so we use sys_clk as a watchdog reference.
    //
    // ─ On dco_clk: free-running toggle flips every cycle
    // ─ On sys_clk: 2-stage sync the toggle; if it stops changing for
    //   DCO_LOCK_TIMEOUT sys_clk cycles, DCO is declared lost.
    //
    // The locked signal is then CDC'd back to dco_clk (1-bit, CDC-safe).
    // =========================================================================
    localparam DCO_LOCK_TIMEOUT = 16'd100;  // ~1 us @ 100 MHz

    // --- dco_clk domain: free-running toggle ---
    reg dco_toggle;
    always @(posedge dco_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) dco_toggle <= 1'b0;
        else            dco_toggle <= ~dco_toggle;
    end

    // --- sys_clk domain: 2-stage sync + watchdog ---
    reg dco_toggle_s1, dco_toggle_s2, dco_toggle_s3;
    reg [15:0] dco_watchdog;
    reg        dco_locked_sys;    // sys_clk domain
    reg        dco_lost_sys;      // sys_clk domain

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dco_toggle_s1 <= 1'b0;
            dco_toggle_s2 <= 1'b0;
            dco_toggle_s3 <= 1'b0;
            dco_watchdog  <= 16'd0;
            dco_locked_sys <= 1'b0;
            dco_lost_sys   <= 1'b0;
        end else begin
            dco_toggle_s1 <= dco_toggle;
            dco_toggle_s2 <= dco_toggle_s1;
            dco_toggle_s3 <= dco_toggle_s2;

            if (dco_toggle_s2 != dco_toggle_s3) begin
                // Toggle changed — DCO is active. Reset watchdog.
                dco_watchdog  <= 16'd0;
                dco_locked_sys <= 1'b1;
                dco_lost_sys   <= 1'b0;
            end else if (dco_watchdog < DCO_LOCK_TIMEOUT) begin
                dco_watchdog <= dco_watchdog + 1'b1;
            end else begin
                // Watchdog expired — DCO has stopped
                dco_locked_sys <= 1'b0;
                if (dco_locked_sys) begin
                    // Was locked, now lost
                    dco_lost_sys <= 1'b1;
                end
            end
        end
    end

    // CDC back to dco_clk domain (1-bit, 2-stage sync)
    reg dco_locked_s1, dco_locked_s2;
    always @(posedge dco_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dco_locked_s1 <= 1'b0;
            dco_locked_s2 <= 1'b0;
        end else begin
            dco_locked_s1 <= dco_locked_sys;
            dco_locked_s2 <= dco_locked_s1;
        end
    end
    wire dco_locked = dco_locked_s2;

    // =========================================================================
    // IDDR instantiations (14 bits × SAME_EDGE_PIPELINED)
    // =========================================================================
    wire [13:0] ch_a_iddr, ch_b_iddr;

    genvar gi;
    generate
        for (gi = 0; gi < 14; gi = gi + 1) begin : iddr_gen
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("ASYNC")
            ) iddr_inst (
                .Q1 (ch_a_iddr[gi]),   // rising edge → Channel A
                .Q2 (ch_b_iddr[gi]),   // falling edge → Channel B
                .C  (dco_clk),
                .CE (1'b1),            // always enabled; DCO lock only affects debug
                .D  (adc_data[gi]),
                .R  (1'b0),
                .S  (1'b0)
            );
        end
    endgenerate

    // =========================================================================
    // Output register: zero-extend 14-bit ADC to 16-bit
    // =========================================================================
    always @(posedge dco_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ch_a_data  <= 16'd0;
            ch_b_data  <= 16'd0;
            data_valid <= 1'b0;
        end else begin
            ch_a_data  <= {2'b00, ch_a_iddr};  // zero-extend to 16-bit
            ch_b_data  <= {2'b00, ch_b_iddr};
            data_valid <= dco_locked;
        end
    end

    // =========================================================================
    // Single-channel output mux (for Phase 1 streaming)
    // =========================================================================
    wire [15:0] sample_out = channel_sel ? ch_b_data : ch_a_data;
    wire        sample_valid = data_valid;

    // =========================================================================
    // Debug interface (dbg_if)
    // =========================================================================
    logic [3:0]  dbg_state;
    logic [15:0] dbg_cycle_count;
    logic [7:0]  dbg_stall_cycles;
    logic        dbg_error;
    logic [7:0]  dbg_error_id;
    logic        dbg_bypass_mode;
    logic [15:0] dbg_event_count;
    logic [15:0] dbg_word_count;

    // State encoding
    localparam ST_IDLE              = 4'd0;
    localparam ST_DCO_LOCKED        = 4'd1;
    localparam ST_DEINTERLEAVE_ACT  = 4'd2;
    localparam ST_DCO_LOST          = 4'd3;

    // --- CDC dco_lost_sys → dco_clk domain ---
    reg dco_lost_s1, dco_lost_s2;
    always @(posedge dco_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dco_lost_s1 <= 1'b0;
            dco_lost_s2 <= 1'b0;
        end else begin
            dco_lost_s1 <= dco_lost_sys;
            dco_lost_s2 <= dco_lost_s1;
        end
    end
    wire dco_lost = dco_lost_s2;

    // State machine (dco_clk domain)
    always @(posedge dco_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dbg_state       <= ST_IDLE;
            dbg_cycle_count <= 16'd0;
            dbg_stall_cycles <= 8'd0;
            dbg_error       <= 1'b0;
            dbg_error_id    <= 8'd0;
            dbg_bypass_mode <= 1'b0;
            dbg_event_count <= 16'd0;
            dbg_word_count  <= 16'd0;
        end else begin
            // Cycle counter (free-running)
            dbg_cycle_count <= dbg_cycle_count + 1'b1;

            // State decode
            case (dbg_state)
                ST_IDLE: begin
                    if (dco_locked && !dco_lost)
                        dbg_state <= ST_DCO_LOCKED;
                end

                ST_DCO_LOCKED: begin
                    if (dco_lost) begin
                        dbg_state <= ST_DCO_LOST;
                    end else begin
                        dbg_state <= ST_DEINTERLEAVE_ACT;
                    end
                end

                ST_DEINTERLEAVE_ACT: begin
                    if (dco_lost) begin
                        dbg_state <= ST_DCO_LOST;
                    end
                end

                ST_DCO_LOST: begin
                    if (dco_locked) begin
                        dbg_state <= ST_DCO_LOCKED;
                    end
                end
            endcase

            // Error: sticky on DCO loss
            if (dco_lost) begin
                dbg_error    <= 1'b1;
                dbg_error_id <= 8'd1;  // DCO_lost
            end

            // Event counter: count valid samples
            if (data_valid) begin
                dbg_event_count <= dbg_event_count + 1'b1;
                dbg_word_count  <= dbg_word_count + 1'b1;
            end
        end
    end

    // drive dbg_info output (positional concatenation for iverilog compat)
    assign dbg_info = {
        dbg_state,           // [127:124]  4 bits
        dbg_cycle_count,     // [123:108] 16 bits
        dbg_stall_cycles,    // [107:100]  8 bits
        4'd0,                // [99:96]    4 bits reserved_0
        dbg_error,           // [95]       1 bit
        dbg_error_id,        // [94:87]    8 bits
        1'b0,                // [86]       1 bit bypass_mode
        22'd0,               // [85:64]   22 bits reserved_1
        dbg_event_count,     // [63:48]   16 bits
        16'd0,               // [47:32]   16 bits reserved_2
        dbg_word_count,      // [31:16]   16 bits
        16'd0                // [15:0]    16 bits reserved_3
    };

endmodule : adc_interface
