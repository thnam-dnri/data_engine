//------------------------------------------------------------------------------
// cdc_fifo.sv
//
// Clock Domain Crossing FIFO — adc_dco → sys_clk
//
// Wraps xpm_fifo_async (Xilinx Parameterized Macro) for the ADC data crossing.
// Packs both channels into a single 32-bit word per DCO cycle:
//   din[31:16] = ch_b_data[15:0]
//   din[15:0]  = ch_a_data[15:0]
//
// The XPM handles Gray-code pointers and CDC internally. No hand-written
// pointer logic needed. Depth = 64 entries is sufficient for phase drift
// between adc_dco (~105 MHz) and sys_clk (100 MHz).
//
// For iverilog simulation, a behavioral FIFO model (non-synthesizable) is
// used when SYNTHESIS is not defined. Uses pointer-based full/empty detection.
//
// Debug interface (dbg_info):
//   state:        0=IDLE, 1=STREAMING
//   error:        sticky overflow/underflow
//   error_id:     1=overflow, 2=underflow
//   event_count:  words read from FIFO
//   Block-specific: fill_level[5:0], watermark[5:0]
//
// Architecture reference: Architecture.md §2
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

import dbg_pkg::*;

module cdc_fifo (
    // --- Write Domain (adc_dco) ---
    input  wire       wr_clk,         // adc_dco (~105 MHz)
    input  wire       wr_rst_n,       // write-side reset (async, active-low)
    input  wire       wr_en,          // write enable
    input  wire [31:0] din,           // {ch_b[15:0], ch_a[15:0]}
    output wire        full,          // FIFO full (backpressure to upstream)

    // --- Read Domain (sys_clk, 100 MHz) ---
    input  wire       rd_clk,         // sys_clk (100 MHz)
    input  wire       rd_rst_n,       // read-side reset
    input  wire       rd_en,          // read enable (FWFT: asserted when space)
    output wire [31:0] dout,          // {ch_b[15:0], ch_a[15:0]}
    output wire        empty,         // FIFO empty

    // --- Debug Interface ---
    output dbg_info_t  dbg_info       // 128-bit packed debug data
);

    // =========================================================================
    // xpm_fifo_async instantiation (synthesis) / behavioral model (sim)
    // =========================================================================

`ifndef SYNTHESIS
    // -----------------------------------------------------------------------
    // Behavioral FIFO model for iverilog simulation
    // Depth = 64, FWFT read mode, 32-bit data width
    // Uses pointer-based full/empty detection (simplified for sim)
    // -----------------------------------------------------------------------
    localparam DEPTH = 64;
    localparam AW    = 6;  // log2(DEPTH)

    reg [31:0] mem [0:DEPTH-1];
    reg [AW:0]  wr_ptr = 0;   // MSB wrap bit for full/empty detection
    reg [AW:0]  rd_ptr = 0;

    // Pointer-based full/empty detection
    // full  when wr_ptr[AW] != rd_ptr[AW] and lower bits are equal
    // empty when wr_ptr == rd_ptr
    wire [AW-1:0] rd_ptr_w = rd_ptr[AW-1:0];
    wire [AW-1:0] wr_ptr_w = wr_ptr[AW-1:0];
    assign full  = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr_w == rd_ptr_w);
    assign empty = (wr_ptr == rd_ptr);

    // FWFT output register
    reg [31:0] dout_fwft;
    assign dout = dout_fwft;

    // Write pointer (wr_clk domain)
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr <= 0;
        end else if (wr_en && !full) begin
            mem[wr_ptr_w] <= din;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // Read pointer + FWFT (rd_clk domain)
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr    <= 0;
            dout_fwft <= 32'd0;
        end else if (rd_en && !empty) begin
            dout_fwft <= mem[rd_ptr_w];
            rd_ptr    <= rd_ptr + 1'b1;
        end
    end

    // Debug: approximate fill level from pointer diff
    wire [AW:0] fill_diff = wr_ptr - rd_ptr;

`else
    // -----------------------------------------------------------------------
    // Xilinx xpm_fifo_async (synthesis)
    // -----------------------------------------------------------------------
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE   ("distributed"),
        .FIFO_READ_LATENCY  (0),
        .FIFO_WRITE_DEPTH   (64),
        .READ_DATA_WIDTH    (32),
        .WRITE_DATA_WIDTH   (32),
        .READ_MODE          ("fwft"),
        .CDC_SYNC_STAGES    (4)
    ) u_fifo (
        .sleep          (1'b0),
        .rst            (~wr_rst_n),
        .wr_clk         (wr_clk),
        .wr_en          (wr_en),
        .din            (din),
        .full           (full),
        .wr_ack         (),
        .overflow       (),
        .wr_rst_busy    (),
        .rd_clk         (rd_clk),
        .rd_en          (rd_en),
        .dout           (dout),
        .empty          (empty),
        .underflow      (),
        .rd_rst_busy    ()
    );

    wire [AW:0] fill_diff = 0;
`endif

    // =========================================================================
    // Debug interface (sys_clk domain)
    // =========================================================================
    logic [3:0]  dbg_fill_level;
    logic        dbg_overflow, dbg_underflow;
    logic [3:0]  dbg_watermark;
    logic [15:0] dbg_word_count_rd;

    // Overflow/underflow detection
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            dbg_fill_level    <= 4'd0;
            dbg_overflow      <= 1'b0;
            dbg_underflow     <= 1'b0;
            dbg_watermark     <= 4'd0;
            dbg_word_count_rd <= 16'd0;
        end else begin
            // Track fill level
            dbg_fill_level <= fill_diff[3:0];

            // Watermark
            if (fill_diff[3:0] > dbg_watermark)
                dbg_watermark <= fill_diff[3:0];

            // Overflow (sticky)
            if (full && wr_en)
                dbg_overflow <= 1'b1;

            // Underflow (sticky)
            if (empty && rd_en)
                dbg_underflow <= 1'b1;

            // Word count
            if (rd_en && !empty)
                dbg_word_count_rd <= dbg_word_count_rd + 1'b1;
        end
    end

    // Drive dbg_info output (positional concatenation)
    assign dbg_info = {
        (full ? 4'd1 : 4'd0),            // [127:124]  4 bits state
        16'd0,                            // [123:108] 16 bits cycle_count
        8'd0,                             // [107:100]  8 bits stall_cycles
        4'd0,                             // [99:96]    4 bits reserved_0
        (dbg_overflow | dbg_underflow),   // [95]       1 bit error
        (dbg_overflow ? 8'd1 : (dbg_underflow ? 8'd2 : 8'd0)), // [94:87] error_id
        1'b0,                             // [86]       1 bit bypass_mode
        22'd0,                            // [85:64]   22 bits reserved_1
        dbg_word_count_rd,                // [63:48]   16 bits event_count
        16'd0,                            // [47:32]   16 bits reserved_2
        dbg_word_count_rd,                // [31:16]   16 bits word_count
        16'd0                             // [15:0]    16 bits reserved_3
    };

endmodule : cdc_fifo
