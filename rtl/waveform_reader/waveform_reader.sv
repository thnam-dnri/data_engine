//------------------------------------------------------------------------------
// waveform_reader.sv
//
// Burst BRAM Reader driven by Descriptor FIFO.
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Ported from sig_recorder `waveform_reader.v` to SystemVerilog, widened to
// 160-bit descriptor (matches data_engine descriptor_t), and wrapped with
// the standard `dbg_info_t` debug interface per Architecture.md §4 + §12.1.
//
// Role:
//   Pops a descriptor from event_descriptor_fifo, drives the circular_buffer
//   Port B at `rd_addr`, and streams `waveform_length` consecutive samples
//   into the TX waveform FIFO as `sample_valid`/`sample_data[15:0]`.
//
// Hard rule (Issue 001 §0.4 invariant): TX FIFO backpressure may stall THIS
// reader, but NEVER the circular buffer write side. tx_full simply pauses
// the reader until it drops; Port A keeps writing.
//
// Timing (FPGA BRAM with registered address input):
//   cbuf_rd_addr is a combinatorial output from internal rd_addr.
//   At posedge N: rd_addr changes, cbuf_rd_addr follows combinatorially.
//   At posedge N+1: BRAM registered address captures the value via wire.
//   At posedge N+2: BRAM Port B output (cbuf_rd_data) is valid.
//
//   FSM: S_BURST_SET → S_BURST_WAIT → S_BURST_EMIT
//   Each sample takes 2 cycles (SET → WAIT → EMIT → SET → ...).
//   1800 samples = 3600 cycles = 36 µs @ 100 MHz. Well within 78 µs wrap margin
//   (per Architecture.md §4: 2-level buffering allows 2 back-to-back events).
//
// Descriptor fields consumed (descriptor_t, 160 bits, Architecture.md §8):
//   [159:112] timestamp         (48-bit)
//   [111:96]  amplitude         (16-bit)
//   [95:80]   energy            (16-bit)
//   [79:78]   trigger_type      (2-bit)
//   [77:65]   waveform_offset   (13-bit, BRAM address of pretrigger start)
//   [64:54]   waveform_length   (11-bit, samples to read, up to 2048)
//   [53]      channel_id        (1-bit)
//   [52:37]   board_id          (16-bit)
//   [36:5]    firmware_version  (32-bit)
//   [4:0]     diag_snapshot     (5-bit)
//------------------------------------------------------------------------------

`default_nettype none

module waveform_reader #(
    parameter DW = 160   // descriptor width (must match descriptor_t)
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---- Descriptor pop side (FWFT FIFO) ----
    input  wire             desc_empty,
    input  wire [DW-1:0]    desc_data,
    output reg              desc_pop_req,

    // ---- Circular buffer Port B (registered read) ----
    // cbuf_rd_addr is COMBINATORIAL from internal rd_addr (not registered),
    // so the BRAM input is stable for a full clock cycle before the data
    // is captured by the BRAM's internal address register.
    output wire [12:0]      cbuf_rd_addr,
    input  wire [15:0]      cbuf_rd_data,

    // ---- Sample stream into TX FIFO ----
    output reg              sample_valid,
    output reg  [15:0]      sample_data,
    input  wire             tx_full,

    // ---- Burst metadata (for top_pipeline packet builder) ----
    // 1-cycle pulse when a new event starts. burst_descriptor is latched
    // and held valid for the entire burst (1800 samples + 2 cycles).
    output reg              burst_start,
    output reg  [DW-1:0]    burst_descriptor,
    output reg  [10:0]      burst_remaining,  // live count: samples left to emit

    // ---- Status ----
    output reg              busy,

    // ---- Debug interface (Architecture.md §4, §12.1) ----
    output dbg_pkg::dbg_info_t dbg_info
);

    import dbg_pkg::*;

    // -------------------------------------------------------------------------
    // Descriptor field extraction (matches pipeline_pkg::descriptor_t)
    // -------------------------------------------------------------------------
    wire [47:0] d_timestamp       = desc_data[159:112];
    wire [15:0] d_amplitude       = desc_data[111:96];
    wire [15:0] d_energy          = desc_data[95:80];
    wire [1:0]  d_trigger_type    = desc_data[79:78];
    wire [12:0] d_waveform_offset = desc_data[77:65];
    wire [10:0] d_waveform_length = desc_data[64:54];
    wire        d_channel_id      = desc_data[53];
    wire [15:0] d_board_id        = desc_data[52:37];
    wire [31:0] d_firmware_ver    = desc_data[36:5];
    wire [4:0]  d_diag_snapshot   = desc_data[4:0];

    // -------------------------------------------------------------------------
    // cbuf_rd_addr is COMBINATORIAL from the internal rd_addr register.
    //
    // This ensures the BRAM address wire is stable one full clock cycle
    // before the BRAM's internal address register captures it — matching
    // the actual FPGA hardware timing (the registered BRAM address input
    // captures at posedge from a combinatorial source, not from another
    // register whose output changes with clock-to-Q delay).
    // -------------------------------------------------------------------------
    reg  [12:0]  rd_addr;
    assign cbuf_rd_addr = rd_addr;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [2:0] S_IDLE       = 3'd0,
                     S_BURST_SET  = 3'd1,
                     S_BURST_WAIT = 3'd2,
                     S_BURST_EMIT = 3'd3,
                     S_DONE       = 3'd4;

    reg [2:0]  state;
    reg [10:0] remaining;          // samples remaining to emit (was 12-bit, now 11-bit)
    reg [DW-1:0] latched_descriptor;

    // -------------------------------------------------------------------------
    // Debug counters
    // -------------------------------------------------------------------------
    reg [15:0] events_read;
    reg [15:0] wrap_handled_count;
    reg [15:0] tx_stall_cycles;
    reg [15:0] events_total_words;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            desc_pop_req     <= 1'b0;
            sample_valid     <= 1'b0;
            sample_data      <= 16'd0;
            burst_start      <= 1'b0;
            burst_descriptor <= {DW{1'b0}};
            burst_remaining  <= 11'd0;
            busy             <= 1'b0;
            rd_addr          <= 13'd0;
            remaining        <= 11'd0;
            latched_descriptor <= {DW{1'b0}};
            events_read      <= 16'd0;
            wrap_handled_count <= 16'd0;
            tx_stall_cycles  <= 16'd0;
            events_total_words <= 16'd0;
        end else begin
            // Defaults: de-assert pulse signals
            desc_pop_req <= 1'b0;
            sample_valid <= 1'b0;
            burst_start  <= 1'b0;

            case (state)
                //-------------------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (!desc_empty) begin
                        // Read descriptor fields (FWFT — data valid now).
                        latched_descriptor <= desc_data;

                        // Pop the descriptor (1-cycle pulse).
                        desc_pop_req <= 1'b1;

                        // Initialize burst pointer/counter.
                        // rd_addr is COMBINATORIALLY reflected on cbuf_rd_addr.
                        rd_addr   <= d_waveform_offset;
                        remaining <= d_waveform_length;

                        // Emit 1-cycle burst_start with latched descriptor.
                        burst_start      <= 1'b1;
                        burst_descriptor <= desc_data;
                        burst_remaining  <= d_waveform_length;

                        busy  <= 1'b1;
                        state <= S_BURST_SET;

                        events_read <= events_read + 1'b1;
                    end
                end

                //-------------------------------------------------------------
                // S_BURST_SET: rd_addr is already valid on cbuf_rd_addr
                // (combinatorial). The BRAM's address register captures at
                // the same posedge. Go to wait state.
                //-------------------------------------------------------------
                S_BURST_SET: begin
                    state <= S_BURST_WAIT;
                end

                //-------------------------------------------------------------
                // S_BURST_WAIT: BRAM Port B is reading. One more cycle for
                // the registered output. Go to emit.
                //-------------------------------------------------------------
                S_BURST_WAIT: begin
                    state <= S_BURST_EMIT;
                end

                //-------------------------------------------------------------
                // BRAM Port B output is valid this cycle.
                // Push into TX FIFO if not full; otherwise hold here.
                //-------------------------------------------------------------
                S_BURST_EMIT: begin
                    if (!tx_full) begin
                        sample_valid <= 1'b1;
                        sample_data  <= cbuf_rd_data;
                        burst_remaining <= remaining - 1'b1;
                        events_total_words <= events_total_words + 1'b1;

                        if (remaining == 11'd1) begin
                            state <= S_DONE;
                        end else begin
                            // Detect wrap: rd_addr about to wrap around 8192
                            if (rd_addr == 13'd8191) begin
                                wrap_handled_count <= wrap_handled_count + 1'b1;
                            end
                            remaining <= remaining - 1'b1;
                            rd_addr   <= rd_addr + 1'b1; // cbuf_rd_addr follows combinatorially
                            state     <= S_BURST_SET;
                        end
                    end else begin
                        // TX FIFO backpressure: hold here, count stall cycle
                        tx_stall_cycles <= tx_stall_cycles + 1'b1;
                    end
                end

                //-------------------------------------------------------------
                S_DONE: begin
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // dbg_info output (positional concatenation for iverilog compat).
    // Layout (Architecture.md §4 + dbg_pkg.sv §12.1):
    //   [127:124] state           — 0=IDLE, 1=BURST_SET, 2=BURST_WAIT, 3=BURST_EMIT, 4=DONE
    //   [123:108] cycle_count     — wrap_handled_count
    //   [107:100] stall_cycles    — tx_stall_cycles (low 8 bits, rate proxy)
    //   [99:96]   reserved
    //   [95]      error
    //   [94:87]   error_id
    //   [86]      bypass_mode     — 0
    //   [85:64]   reserved
    //   [63:48]   event_count     — events_read
    //   [47:32]   reserved
    //   [31:16]   word_count      — events_total_words
    //   [15:0]    reserved
    // -------------------------------------------------------------------------
    assign dbg_info = {
        state,                         // [127:124] FSM state
        wrap_handled_count,            // [123:108] wrap count
        tx_stall_cycles[7:0],          // [107:100] stall cycles (low 8)
        4'd0,                          // [99:96]   reserved
        1'b0,                          // [95]      error
        8'd0,                          // [94:87]   error_id
        1'b0,                          // [86]      bypass_mode
        22'd0,                         // [85:64]   reserved
        events_read,                   // [63:48]   event_count
        16'd0,                         // [47:32]   reserved
        events_total_words,            // [31:16]   word_count
        16'd0                          // [15:0]    reserved
    };

endmodule : waveform_reader

`default_nettype wire
