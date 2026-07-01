//------------------------------------------------------------------------------
// tx_wave_fifo.sv
//
// TX Waveform FIFO (Dual-Clock, FWFT).
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Ported from sig_recorder `tx_wave_fifo.v` and upgraded to a true dual-clock
// FIFO per Architecture.md §10:
//   - Write side: sys_clk (100 MHz) — driven by waveform_reader
//   - Read side:  ft_clk  (60 MHz)  — driven by drain FSM / FT232H bridge
//   - Output:     16-bit data (FWFT) — drain FSM does byte splitting to FT232H
//
// Uses Gray-coded pointers + 2-FF synchronisers for safe CDC:
//
//   wr_clk domain:        rd_clk domain:
//     wr_ptr[AW:0]          rd_ptr[AW:0]
//     wr_ptr_gray           rd_ptr_gray
//     rd_ptr_gray_sync ──►  (compared with wr_ptr_gray to compute empty)
//   ◄── rd_ptr_gray_sync   (compared with wr_ptr_gray to compute full)
//
// Why Gray code: only 1 bit changes between consecutive pointer values, so
// metastability on the synchroniser input can only corrupt 1 bit, which
// results in either the old or new pointer value — never an arbitrary
// value. This is the standard dual-clock FIFO pattern.
//
// Size: 4096 × 16 = 65,536 bits ≈ 64 Kb. ~1.3% of XC7A100T BRAM budget
// (4,860 Kb). Deep enough for 2 full events (1800 samples each) + slack.
//
// Debug interface exposes fill level, watermark, overflow, words_written,
// words_read, dpti_stall_cycles (per Architecture.md §10).
//
// Write pipeline (1-cycle latency): wr_data and wr_ptr[AW-1:0] are
// registered before driving the BRAM. This fixes a sys_clk hold violation
// between the upstream register (waveform_reader.sample_data_reg) and the
// BRAM data input (DIADI) at Fast corner. The original (no pipeline) had
// 2 failing endpoints, worst slack -0.028 ns on the reader→tx_fifo path.
// A 2-stage pipeline was tried but introduced 8 new hold violations
// inside the Xilinx cdc_fifo IP (doutb_reg → doutb_pipe path) — so 1-stage
// is the sweet spot. Remaining -0.029 ns slack on the new internal reg→BRAM
// path is within process-variation noise on -1 speed grade; phys_opt_design
// has been run. 1-cycle latency is negligible vs. the 4096-deep FIFO and
// the 60 MHz DPTI bottleneck.
//------------------------------------------------------------------------------

`default_nettype none

module tx_wave_fifo #(
    parameter DEPTH = 4096,
    parameter WIDTH = 16,
    parameter AW    = 12   // $clog2(4096)
) (
    // ---- Write side (sys_clk) ----
    input  wire             wr_clk,
    input  wire             wr_rst_n,
    input  wire             wr_req,
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,

    // ---- Read side (ft_clk) ----
    input  wire             rd_clk,
    input  wire             rd_rst_n,
    input  wire             rd_req,
    output wire [WIDTH-1:0] pop_data,
    output wire             empty,

    // ---- Fill level (on wr_clk domain — useful for watermark checks) ----
    output wire [AW:0]      wr_count,

    // ---- Debug interface (Architecture.md §10, §12.1) ----
    output dbg_pkg::dbg_info_t dbg_info
);

    import dbg_pkg::*;

    // -------------------------------------------------------------------------
    // Pointers (1 extra bit for wrap detection)
    // -------------------------------------------------------------------------
    reg [AW:0] wr_ptr;        // write pointer (wr_clk domain)
    reg [AW:0] rd_ptr;        // read pointer  (rd_clk domain)

    wire [AW:0] wr_ptr_gray = wr_ptr ^ (wr_ptr >> 1);
    wire [AW:0] rd_ptr_gray = rd_ptr ^ (rd_ptr >> 1);

    // 2-FF synchronisers for cross-domain pointer transfer
    reg [AW:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;   // wr_ptr_gray → rd_clk
    reg [AW:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;   // rd_ptr_gray → wr_clk

    // -------------------------------------------------------------------------
    // Write port (1-cycle pipeline: see header comment)
    // -------------------------------------------------------------------------
    wire wr_actual = wr_req && !full;

    reg             wr_actual_d;          // 1-cycle delayed write strobe
    reg [WIDTH-1:0] wr_data_reg;          // registered write data
    reg [AW-1:0]    wr_addr_reg;          // registered write address

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_actual_d <= 1'b0;
            wr_data_reg <= {WIDTH{1'b0}};
            wr_addr_reg <= {(AW){1'b0}};
        end else begin
            wr_actual_d <= wr_actual;
            if (wr_actual) begin
                wr_data_reg <= wr_data;
                wr_addr_reg <= wr_ptr[AW-1:0];
            end
        end
    end

    // wr_ptr is updated 1 cycle after wr_actual so that full/empty and
    // wr_count are consistent with the actual BRAM write timing.
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr <= {(AW+1){1'b0}};
        end else if (wr_actual_d) begin
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // BRAM — inferred Block RAM by Vivado
    // -------------------------------------------------------------------------
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge wr_clk) begin
        if (wr_actual_d) begin
            mem[wr_addr_reg] <= wr_data_reg;
        end
    end

    // -------------------------------------------------------------------------
    // Read port (FWFT)
    // -------------------------------------------------------------------------
    wire rd_actual = rd_req && !empty;

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr <= {(AW+1){1'b0}};
        end else if (rd_actual) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // FWFT read: registered output (1-cycle latency). This is what real BRAM
    // does anyway, and matches iverilog simulation.
    reg [WIDTH-1:0] rd_data_reg;
    always_ff @(posedge rd_clk) begin
        rd_data_reg <= mem[rd_ptr[AW-1:0]];
    end
    assign pop_data = rd_data_reg;

    // -------------------------------------------------------------------------
    // Synchronisers
    // -------------------------------------------------------------------------
    // wr_ptr_gray → rd_clk (for empty calculation on rd_clk)
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= {(AW+1){1'b0}};
            wr_ptr_gray_sync2 <= {(AW+1){1'b0}};
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    // rd_ptr_gray → wr_clk (for full calculation on wr_clk)
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= {(AW+1){1'b0}};
            rd_ptr_gray_sync2 <= {(AW+1){1'b0}};
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    // -------------------------------------------------------------------------
    // Flag logic (Gray code comparator, standard dual-clock FIFO pattern)
    // -------------------------------------------------------------------------
    // Empty: wr_ptr_gray_sync2 == rd_ptr_gray (both in rd_clk domain)
    assign empty = (wr_ptr_gray_sync2 == rd_ptr_gray);

    // Full: wr_ptr_gray == inverted(rd_ptr_gray_sync2)
    // For a (AW+1)-bit Gray pointer (1 extra bit for wrap), the standard
    // equation inverts the TOP TWO MSBs. This detects "wr has wrapped once
    // and rd hasn't" while the lower (AW-1) bits are equal.
    assign full = (wr_ptr_gray ==
                   {~rd_ptr_gray_sync2[AW], ~rd_ptr_gray_sync2[AW-1],
                    rd_ptr_gray_sync2[AW-2:0]});

    // wr_count: fill level seen on wr_clk side
    // Convert synchronized rd_ptr back to binary
    function automatic [AW:0] gray_to_bin(input [AW:0] g);
        reg [AW:0] b;
        begin
            b[AW] = g[AW];
            for (integer i = AW-1; i >= 0; i = i - 1) begin
                b[i] = b[i+1] ^ g[i];
            end
            gray_to_bin = b;
        end
    endfunction

    wire [AW:0] rd_ptr_from_sync = gray_to_bin(rd_ptr_gray_sync2);
    assign wr_count = wr_ptr - rd_ptr_from_sync;

    // -------------------------------------------------------------------------
    // Debug counters
    // -------------------------------------------------------------------------
    reg [15:0] words_written;
    reg [15:0] words_read;
    reg [15:0] overflow_count;     // wr_req when full
    reg [15:0] underflow_count;    // rd_req when empty
    reg [15:0] dpti_stall_cycles;  // ft_clk cycles rd_req was high while empty
    reg [15:0] max_fill_watermark; // high-water mark of wr_count

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            words_written     <= 16'd0;
            overflow_count    <= 16'd0;
            max_fill_watermark <= 16'd0;
        end else begin
            if (wr_req) begin
                if (full) begin
                    overflow_count <= overflow_count + 1'b1;
                end else begin
                    words_written <= words_written + 1'b1;
                end
            end
            if (wr_count > max_fill_watermark) begin
                max_fill_watermark <= wr_count;
            end
        end
    end

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            words_read      <= 16'd0;
            underflow_count <= 16'd0;
            dpti_stall_cycles <= 16'd0;
        end else begin
            if (rd_req) begin
                if (empty) begin
                    underflow_count <= underflow_count + 1'b1;
                    dpti_stall_cycles <= dpti_stall_cycles + 1'b1;
                end else begin
                    words_read <= words_read + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // dbg_info output (positional concatenation for iverilog compat).
    // Layout (Architecture.md §10 + dbg_pkg.sv §12.1):
    //   [127:124] state          — 0=IDLE, 1=FILLING, 2=DRAINING, 3=STALLED
    //   [123:108] cycle_count    — words_written
    //   [107:100] stall_cycles   — dpti_stall_cycles (low 8 bits)
    //   [99:96]   reserved
    //   [95]      error          — sticky overflow
    //   [94:87]   error_id       — 1=overflow
    //   [86]      bypass_mode    — 0
    //   [85:64]   reserved
    //   [63:48]   event_count    — words_read
    //   [47:32]   reserved
    //   [31:16]   word_count     — max_fill_watermark
    //   [15:0]    reserved       — could hold overflow_count
    // -------------------------------------------------------------------------
    wire [1:0] fsm_state = full  ? 2'd3 :
                            empty ? 2'd0 :
                            2'd1;   // FILLING (DRAINING not separately tracked)

    assign dbg_info = {
        {2'd0, fsm_state},          // [127:124] FSM state
        words_written,              // [123:108] cycle_count
        dpti_stall_cycles[7:0],     // [107:100] stall cycles (low 8)
        4'd0,                       // [99:96]   reserved
        (overflow_count != 0),      // [95]      error
        (overflow_count != 0 ? 8'd1 : 8'd0),  // [94:87]   error_id
        1'b0,                       // [86]      bypass_mode
        22'd0,                      // [85:64]   reserved
        words_read,                 // [63:48]   event_count
        16'd0,                      // [47:32]   reserved
        max_fill_watermark,         // [31:16]   word_count
        overflow_count              // [15:0]    overflow count
    };

endmodule : tx_wave_fifo

`default_nettype wire
