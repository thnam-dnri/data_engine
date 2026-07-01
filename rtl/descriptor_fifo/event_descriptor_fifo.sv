//------------------------------------------------------------------------------
// event_descriptor_fifo.sv
//
// Descriptor FIFO — trigger truth source for event-mode acquisition.
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Ported from sig_recorder `event_descriptor_fifo.v` to SystemVerilog,
// widened 106 → 160 bits to match data_engine `descriptor_t` layout
// (Architecture.md §8), and wrapped with the standard `dbg_info_t`
// debug interface per §12.1.
//
// Issue 001 §0.5: every trigger pushes a descriptor here. There is no
// `trig_pending` bit — the descriptor FIFO is the SOLE source of truth
// for the waveform reader. Rejected pushes (when full) are silently
// dropped and counted via `lost_event_counter` (sticky in dbg_info).
//
// 64-deep, First-Word-Fall-Through (FWFT), single-clock @ sys_clk (100 MHz).
//
// Descriptor packing (160 bits, matches pipeline_pkg::descriptor_t):
//   [159:112] timestamp          (48-bit, sample counter at trigger point)
//   [111:96]  amplitude          (16-bit, peak sample value)
//   [95:80]   energy             (16-bit, integrated area under pulse)
//   [79:78]   trigger_type       (2-bit, which trigger mode fired)
//   [77:65]   waveform_offset    (13-bit, buffer addr of pretrigger start)
//   [64:54]   waveform_length    (11-bit, samples to read, up to 2048)
//   [53]      channel_id         (1-bit, which ADC channel triggered)
//   [52:37]   board_id           (16-bit, unique board identifier)
//   [36:5]    firmware_version   (32-bit, bitfile version)
//   [4:0]     diag_snapshot      (5-bit, coprocessed status at trigger time)
//
// BRAM: 64 × 160 = 10240 bits ≈ 1 BRAM (~10 kb out of 4860 kb budget).
//------------------------------------------------------------------------------

`default_nettype none

module event_descriptor_fifo #(
    parameter DEPTH = 64,
    parameter DW    = 160
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- Push side (driven by trigger logic) ----
    input  wire                     push_req,
    input  wire [DW-1:0]            push_data,
    output wire                     full,

    // ---- Pop side (FWFT — driven by waveform_reader) ----
    input  wire                     pop_req,
    output wire [DW-1:0]            pop_data,
    output wire                     empty,

    // ---- Fill level + lost event indicator ----
    output wire [7:0]               count,         // number of descriptors in FIFO
    output reg                      lost_event_pulse, // 1-cycle when a push is rejected

    // ---- Debug interface (Architecture.md §8, §12.1) ----
    output dbg_pkg::dbg_info_t      dbg_info
);

    import dbg_pkg::*;

    // -------------------------------------------------------------------------
    // Wrap-aware pointers (1 extra bit to disambiguate full/empty on power-of-2
    // ring). DEPTH=64 → AW=$clog2(64)=6, pointers are 7 bits.
    // -------------------------------------------------------------------------
    localparam AW = 6;

    (* ram_style = "block" *)
    reg [DW-1:0] mem [0:DEPTH-1];

    reg [AW:0]   wr_ptr;
    reg [AW:0]   rd_ptr;

    wire push_actual = push_req && !full;
    wire pop_actual  = pop_req  && !empty;

    // -------------------------------------------------------------------------
    // Storage + pointers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {(AW+1){1'b0}};
            rd_ptr <= {(AW+1){1'b0}};
        end else begin
            if (push_actual) begin
                mem[wr_ptr[AW-1:0]] <= push_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (pop_actual) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // FWFT read: combinational output of mem at rd_ptr. The event FSM
    // (trigger + circular buffer) pushes the descriptor one cycle before
    // the waveform_reader pops it, so the mem location is always written
    // by the time the continuous assignment reads it.
    // -------------------------------------------------------------------------
    assign pop_data = mem[rd_ptr[AW-1:0]];

    // -------------------------------------------------------------------------
    // Flag logic (wrap-difference style)
    // -------------------------------------------------------------------------
    assign full  = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0])
                 && (wr_ptr[AW]    != rd_ptr[AW]);

    assign empty = (wr_ptr == rd_ptr);

    // Fill level: number of valid descriptors in the FIFO.
    // Uses the full AW+1-bit pointer difference (mod 2^(AW+1)) so the count
    // correctly tracks across wraps. Result range: 0..DEPTH (0..64 for DEPTH=64).
    assign count = wr_ptr - rd_ptr;

    // -------------------------------------------------------------------------
    // Lost event detection: push was requested but FIFO was full
    // -------------------------------------------------------------------------
    reg [15:0] lost_event_count;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lost_event_count <= 16'd0;
            lost_event_pulse <= 1'b0;
        end else begin
            lost_event_pulse <= 1'b0;
            if (push_req && full) begin
                lost_event_count <= lost_event_count + 1'b1;
                lost_event_pulse <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // dbg_info output (positional concatenation for iverilog compat).
    // Layout (Architecture.md §8 + dbg_pkg.sv §12.1):
    //   [127:124] state          — 0=IDLE (empty), 1=FILLING, 2=DRAINING, 3=FULL
    //   [123:108] cycle_count    — lost_event_count (overload: critical counter)
    //   [107:100] stall_cycles   — fill_level (low 8 bits, /64)
    //   [99:96]   reserved
    //   [95]      error          — sticky lost_event
    //   [94:87]   error_id       — 1=lost_event
    //   [86]      bypass_mode    — 0 (no bypass)
    //   [85:64]   reserved
    //   [63:48]   event_count    — lost_event_count
    //   [47:32]   reserved
    //   [31:16]   word_count     — fill_level
    //   [15:0]    reserved       — could hold depth watermark
    // -------------------------------------------------------------------------
    wire [1:0] fsm_state = empty ? 2'd0 :
                            full  ? 2'd3 :
                            (wr_ptr > rd_ptr) ? 2'd1 : 2'd2; // 1=filling, 2=draining

    assign dbg_info = {
        {2'd0, fsm_state},          // [127:124] FSM state
        lost_event_count,           // [123:108] lost_event_count (cycle_count slot)
        count,                      // [107:100] fill_level (stall_cycles slot)
        4'd0,                       // [99:96]   reserved
        (lost_event_count != 0),    // [95]      error (sticky lost)
        (lost_event_count != 0 ? 8'd1 : 8'd0),  // [94:87]   error_id
        1'b0,                       // [86]      bypass_mode
        22'd0,                      // [85:64]   reserved
        lost_event_count,           // [63:48]   event_count
        16'd0,                      // [47:32]   reserved
        {8'd0, count},              // [31:16]   word_count (fill level)
        16'd0                       // [15:0]    reserved
    };

endmodule : event_descriptor_fifo

`default_nettype wire
