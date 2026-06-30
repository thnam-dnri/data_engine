//------------------------------------------------------------------------------
// glitch_filter.sv
//
// 3-stage up-down pattern detector for AD9648 0x0C98 artifact removal.
//
// The AD9648 emits a deterministic single-sample glitch (0x0C98) every 256
// DCO cycles. This module detects UP-then-DOWN (or DOWN-then-UP) jumps
// exceeding a configurable threshold and replaces the glitch sample with
// the linear interpolation of its neighbours.
//
// Principle:
//   With three consecutive samples s1 (oldest), s2, s3 (newest):
//     d1 = s2 - s1,   d2 = s3 - s2
//   Glitch at s2 if:
//     - d1 and d2 have opposite signs, AND
//     - |d1| > threshold, |d2| > threshold
//   Replacement: s2 <= (s1 + s3) / 2
//
// Three separate always @(posedge clk) blocks for the delay line prevent
// Vivado from inferring SRL32 shift-register optimisation, which would
// collapse the pipeline stages and break the temporal separation.
//
// Pipeline latency: 2 sys_clk cycles (1 for delay line, 1 for output reg).
// In bypass mode, latency drops to 1 cycle (single output register).
//
// Configuration (from register map):
//   threshold[15:0] — minimum jump magnitude to trigger detection (default 500)
//   bypass          — 1 = pass-through (no filtering, 1-cycle latency)
//
// Debug interface (dbg_info):
//   state:       0=BYPASS, 1=ACTIVE
//   event_count: glitches removed (saturating)
//   word_count:  samples processed
//   error:       filter_saturation (max delta > 3× threshold)
//   bypass_mode: bypass input
//
// Block-specific debug outputs:
//   max_delta[15:0] — largest |sample-to-sample jump| observed (sticky)
//
// Architecture reference: Architecture.md §3, §3a
// Debug register map: docs/debug_register_map.md §Glitch Filter
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

import dbg_pkg::*;

module glitch_filter (
    // --- Clock & Reset ---
    input  wire        clk,             // sys_clk (100 MHz)
    input  wire        rst_n,           // async active-low reset

    // --- Data Input ---
    input  wire [15:0] din,             // raw sample (from CDC FIFO or upstream)
    input  wire        din_valid,       // strobe

    // --- Data Output ---
    output reg  [15:0] dout,            // filtered sample
    output reg         dout_valid,      // strobe

    // --- Configuration (from register map) ---
    input  wire [15:0] threshold,       // detection threshold (default 500)
    input  wire        bypass,          // 1 = pass-through

    // --- Debug Interface ---
    output dbg_info_t  dbg_info,        // 128-bit packed struct (4 × 32-bit regs)
    output logic [15:0] dbg_max_delta   // sticky max jump observed
);

    // =========================================================================
    // Delay line — 3 separate always blocks prevent SRL32 inference
    // =========================================================================
    reg [15:0] s1, s2, s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s1 <= 16'd0;
        else        s1 <= din;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s2 <= 16'd0;
        else        s2 <= s1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s3 <= 16'd0;
        else        s3 <= s2;
    end

    // Window-valid counter: after 3 consecutive valid samples, the
    // delay-line window [s3, s2, s1] contains real data. Stays valid
    // while din_valid is high; clears on gap.
    reg [1:0] valid_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_cnt <= 2'd0;
        else if (din_valid && valid_cnt < 2'd3)
            valid_cnt <= valid_cnt + 1'b1;
        else if (!din_valid)
            valid_cnt <= 2'd0;
    end
    wire window_valid = (valid_cnt == 2'd3);

    // =========================================================================
    // Glitch detection
    // =========================================================================
    wire signed [16:0] d1 = $signed({1'b0, s2}) - $signed({1'b0, s1});
    wire signed [16:0] d2 = $signed({1'b0, s3}) - $signed({1'b0, s2});
    wire        d1_pos = d1[16] == 1'b0;
    wire        d1_neg = d1[16] == 1'b1;
    wire        d2_pos = d2[16] == 1'b0;
    wire        d2_neg = d2[16] == 1'b1;
    wire [15:0] d1_abs = d1_pos ? d1[15:0] : (~d1[15:0] + 1'b1);
    wire [15:0] d2_abs = d2_pos ? d2[15:0] : (~d2[15:0] + 1'b1);

    // Glitch = opposite signs AND both jumps exceed threshold
    // window_valid ensures all 3 window samples [s3,s2,s1] are real data
    // !bypass prevents detection/counting during bypass mode
    wire glitch_detected = !bypass && window_valid
        && ((d1_pos && d2_neg) || (d1_neg && d2_pos))
        && (d1_abs > threshold)
        && (d2_abs > threshold);

    // Register glitch_detected so the debug counter captures the correct
    // value (glitch_detected is combinatorial from pre-update register
    // values; the counter block sees post-update values).
    reg glitch_detected_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) glitch_detected_r <= 1'b0;
        else        glitch_detected_r <= glitch_detected;
    end

    // =========================================================================
    // Glitch replacement + output
    // =========================================================================
    // Replace s2 (middle of the 3-sample window) with linear interpolation
    wire [15:0] s2_interp = (s1 + s3) >> 1;
    // Pipeline glitch_detected matches the 1-cycle register delay for
    // sampling the window; the output uses the same delayed detection.
    reg        glitch_out_r;
    reg [15:0] s2_fixed_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_fixed_r  <= 16'd0;
            glitch_out_r <= 1'b0;
        end else if (window_valid) begin
            s2_fixed_r  <= glitch_detected ? s2_interp : s2;
            glitch_out_r <= 1'b1;
        end else begin
            glitch_out_r <= 1'b0;
        end
    end

    // Output register (bypass or filtered)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout       <= 16'd0;
            dout_valid <= 1'b0;
        end else if (bypass) begin
            dout       <= din;
            dout_valid <= din_valid;
        end else begin
            dout       <= s2_fixed_r;
            dout_valid <= glitch_out_r;
        end
    end

    // =========================================================================
    // Debug interface
    // =========================================================================
    logic [15:0] glitch_count;
    logic [15:0] sample_count;
    logic        saturation;
    logic [15:0] max_delta_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            glitch_count  <= 16'd0;
            sample_count  <= 16'd0;
            saturation    <= 1'b0;
            max_delta_reg <= 16'd0;
        end else begin
            // Sample counter
            if (din_valid) begin
                sample_count <= sample_count + 1'b1;
            end

            // Glitch counter (saturating) — uses registered detection
            if (glitch_detected_r && glitch_count < 16'hFFFF) begin
                glitch_count <= glitch_count + 1'b1;
            end

            // Sticky max delta (track the largest |d1| or |d2| ever seen)
            // Use pre-update values via registered version
            if (glitch_detected_r) begin
                if (d1_abs > max_delta_reg) max_delta_reg <= d1_abs;
                if (d2_abs > max_delta_reg) max_delta_reg <= d2_abs;
            end

            // Saturation: max delta > 3× threshold
            if (max_delta_reg > (threshold * 3)) begin
                saturation <= 1'b1;
            end
        end
    end

    assign dbg_max_delta = max_delta_reg;

    // dbg_info output (positional concatenation for iverilog compat)
    assign dbg_info = {
        (bypass ? 4'd0 : 4'd1),          // [127:124]  state (0=BYPASS, 1=ACTIVE)
        16'd0,                            // [123:108]  cycle_count
        8'd0,                            // [107:100]  stall_cycles
        4'd0,                            // [99:96]    reserved_0
        saturation,                      // [95]       error (filter_saturation)
        (saturation ? 8'd1 : 8'd0),      // [94:87]    error_id (1=filter_saturation)
        bypass,                          // [86]       bypass_mode
        22'd0,                           // [85:64]    reserved_1
        glitch_count,                    // [63:48]    event_count (glitches removed)
        16'd0,                           // [47:32]    reserved_2
        sample_count,                    // [31:16]    word_count (samples processed)
        16'd0                            // [15:0]     reserved_3
    };

endmodule : glitch_filter
