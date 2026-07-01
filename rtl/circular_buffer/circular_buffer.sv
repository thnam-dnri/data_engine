//------------------------------------------------------------------------------
// circular_buffer.sv
//
// Dual-Port BRAM Rolling History Buffer (data_engine port).
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Ported from sig_recorder `circular_buffer.v`, SystemVerilog-ified, and wrapped
// with the standard `dbg_info_t` debug interface per Architecture.md §4 + §12.1.
//
// Issue 001 invariant: Port A (write) advances UNCONDITIONALLY on `wr_en`.
// DPTI/USB backpressure must NEVER reach the ADC. Any "freeze wr_ptr during
// readout" path is a regression to reject.
//
// Port A: continuous write, `wr_ptr` advances UNCONDITIONALLY on `wr_en`.
// Port B: registered memory read by address (1-cycle latency). Driven by the
//         burst waveform reader (`waveform_reader.v`).
//
// `wr_ptr` is exposed for trigger snapshots — `trigger.v` latches it as
// `trigger_ptr` on each trigger fire and pushes a descriptor.
//
// Debug interface (Architecture.md §4):
//   - live wr_ptr              — current write pointer
//   - live burst_rd_ptr        — most-recent read address (driven by reader)
//   - wrap_around_count        — number of wr_ptr wraps since reset
//   - max_fill_watermark        — peak (wr_ptr - burst_rd_ptr) seen during bursts
//   - collision flag            — sticky: wr_ptr caught burst_rd_ptr during burst
//
// Parameters:
//   DEPTH = 8192  (was 2048 in legacy; +2 BRAMs of 120 — trivial)
//   WIDTH = 16    (was 14; 16 lets TX byte-streamer split {hi,lo} cleanly)
//   AW    = 13    ($clog2(8192))
//------------------------------------------------------------------------------

`default_nettype none

module circular_buffer #(
    parameter DEPTH = 8192,
    parameter WIDTH = 16,
    parameter AW    = 13
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---- Port A: continuous write (rolling history) ----
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire [AW-1:0]    wr_ptr,

    // ---- Port B: registered memory read by burst waveform reader ----
    input  wire             rd_en,         // reader is active
    input  wire [AW-1:0]    rd_addr,
    output reg  [WIDTH-1:0] rd_data,

    // ---- Debug interface (Architecture.md §4, §12.1) ----
    output dbg_pkg::dbg_info_t dbg_info
);

    import dbg_pkg::*;

    // -------------------------------------------------------------------------
    // BRAM: DEPTH × WIDTH — simple dual-port Block RAM.
    // Vivado infers Block RAM from the separated write/read processes below.
    // Write address must not be in a reset-aware process for BRAM inference.
    // -------------------------------------------------------------------------
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // -------------------------------------------------------------------------
    // wr_ptr advance (separate from memory write for BRAM inference).
    // UNCONDITIONAL advance on wr_en (Issue 001 §0.4 invariant):
    //   - Port A never stalls, freezes, or backpressures.
    //   - The only failure mode for an undrained system is event loss via
    //     lost_event_counter downstream — never history buffer corruption.
    // -------------------------------------------------------------------------
    reg [AW-1:0] wr_ptr_r;
    assign wr_ptr = wr_ptr_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_r <= {AW{1'b0}};
        end else if (wr_en) begin
            wr_ptr_r <= wr_ptr_r + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Port A write (clock-only, no reset — BRAM-friendly pattern).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_ptr_r] <= wr_data;
        end
    end

    // -------------------------------------------------------------------------
    // Port B read (registered, 1-cycle latency).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

    // -------------------------------------------------------------------------
    // Debug counters: wrap_around, max_fill_watermark, collision
    // -------------------------------------------------------------------------
    logic [15:0] wrap_count;
    logic [15:0] max_fill;
    logic        collision;

    // Latched rd_addr for fill-level computation (combinational from rd_addr
    // is fine; 1-cycle delay matches the BRAM read latency).
    reg [AW-1:0] rd_addr_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_r <= {AW{1'b0}};
        end else if (rd_en) begin
            rd_addr_r <= rd_addr;
        end
    end

    // Fill = wr_ptr - rd_addr_r (modulo DEPTH). Since DEPTH is a power of 2,
    // natural AW-bit subtraction gives the mod-2^AW result. fill==0 means
    // the writer is at the reader's current position.
    wire [AW-1:0] fill_now = wr_ptr_r - rd_addr_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wrap_count <= 16'd0;
            max_fill   <= 16'd0;
            collision  <= 1'b0;
        end else begin
            // Wrap detection: wr_ptr wrapped from DEPTH-1 to 0
            if (wr_en && wr_ptr_r == {AW{1'b1}}) begin
                wrap_count <= wrap_count + 1'b1;
            end

            // Max-fill watermark (only update when a burst is active)
            if (rd_en && fill_now > max_fill[AW-1:0]) begin
                max_fill <= {9'd0, fill_now};
            end

            // Collision: writer caught the reader during a burst
            // (wr_ptr passed rd_addr_r while reader is active)
            if (rd_en && wr_en && fill_now == {AW{1'b0}}) begin
                collision <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // dbg_info output (positional concatenation for iverilog compat).
    // Layout (Architecture.md §4):
    //   [127:124] state         — 0=IDLE, 1=BURST_ACTIVE
    //   [123:108] wrap_count    — wraps since reset
    //   [107:100] max_fill      — peak fill during burst (low 8 bits)
    //   [99:96]   reserved
    //   [95]      error         — sticky collision flag
    //   [94:87]   error_id      — 1=collision
    //   [86]      bypass_mode   — 0 (no bypass on memory)
    //   [85:64]   reserved
    //   [63:48]   event_count   — wrap_count (overload: useful counter)
    //   [47:32]   reserved
    //   [31:16]   word_count    — max_fill watermark
    //   [15:0]    reserved
    // -------------------------------------------------------------------------
    assign dbg_info = {
        rd_en ? 4'd1 : 4'd0,             // [127:124] state
        wrap_count,                      // [123:108] wrap_count
        max_fill[7:0],                   // [107:100] max_fill (low 8)
        4'd0,                            // [99:96]   reserved
        collision,                       // [95]      error
        (collision ? 8'd1 : 8'd0),       // [94:87]   error_id
        1'b0,                            // [86]      bypass_mode
        22'd0,                           // [85:64]   reserved
        wrap_count,                      // [63:48]   event_count
        16'd0,                           // [47:32]   reserved
        max_fill,                        // [31:16]   word_count
        16'd0                            // [15:0]    reserved
    };

endmodule : circular_buffer

`default_nettype wire
