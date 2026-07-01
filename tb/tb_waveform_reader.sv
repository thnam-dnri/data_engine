//------------------------------------------------------------------------------
// tb_waveform_reader.sv
//
// Testbench for waveform_reader — burst BRAM reader driven by descriptor FIFO.
//
// Tests:
//   1. Reset: idle, no output
//   2. Single burst: pop descriptor, read N samples, drain to TX FIFO
//   3. Burst metadata: burst_start pulses, burst_descriptor latched
//   4. burst_remaining decrements correctly
//   5. TX FIFO backpressure: tx_full stalls the reader
//   6. Multiple bursts in sequence
//   7. Wrap-around: rd_addr wraps from 8191 to 0
//   8. Empty descriptor FIFO: reader stays idle
//   9. dbg_if state mapping
//  10. Reset clears counters
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_waveform_reader;

    localparam DW = 160;
    localparam BRAM_DEPTH = 8192;
    localparam BRAM_AW = 13;

    // DUT clocks
    reg clk = 1'b0;
    always #5 clk = ~clk;       // 100 MHz

    reg rst_n;

    // ---- Descriptor FIFO side ----
    reg              desc_empty;
    reg  [DW-1:0]    desc_data;
    wire             desc_pop_req;

    // ---- Circular buffer side ----
    wire [BRAM_AW-1:0] cbuf_rd_addr;
    reg  [15:0]        cbuf_rd_data;     // Model: registered read from cbuf_rd_addr
    reg  [15:0]        cbuf_mem [0:BRAM_DEPTH-1];  // shadow BRAM

    // ---- TX FIFO side ----
    wire             sample_valid;
    wire [15:0]      sample_data;
    reg              tx_full;

    // ---- Burst metadata ----
    wire             burst_start;
    wire [DW-1:0]    burst_descriptor;
    wire [10:0]      burst_remaining;

    // ---- Status ----
    wire             busy;

    // ---- Debug ----
    dbg_pkg::dbg_info_t dbg_info;

    waveform_reader #(
        .DW(DW)
    ) u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .desc_empty      (desc_empty),
        .desc_data       (desc_data),
        .desc_pop_req    (desc_pop_req),
        .cbuf_rd_addr    (cbuf_rd_addr),
        .cbuf_rd_data    (cbuf_rd_data),
        .sample_valid    (sample_valid),
        .sample_data     (sample_data),
        .tx_full         (tx_full),
        .burst_start     (burst_start),
        .burst_descriptor(burst_descriptor),
        .burst_remaining (burst_remaining),
        .busy            (busy),
        .dbg_info        (dbg_info)
    );

    // -------------------------------------------------------------------------
    // BRAM model: 1-cycle registered read (matches real BRAM timing)
    //   Posedge N: address register captures cbuf_rd_addr
    //   Posedge N+1: data register captures mem[address]
    //   cbuf_rd_data is valid 1 cycle after the address change
    // -------------------------------------------------------------------------
    reg [BRAM_AW-1:0] captured_addr;
    reg [15:0]        bram_output;
    always @(posedge clk) begin
        captured_addr <= cbuf_rd_addr;
        bram_output   <= cbuf_mem[captured_addr];
    end
    always @* begin
        cbuf_rd_data = bram_output;
    end

    // -------------------------------------------------------------------------
    // Sticky latches for 1-cycle signals
    // -------------------------------------------------------------------------
    reg saw_burst_start;
    reg saw_desc_pop;
    always @(posedge clk) begin
        if (burst_start)  saw_burst_start <= 1'b1;
        if (desc_pop_req) saw_desc_pop     <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // Test infrastructure (plain 'task' — iverilog v12 quirk)
    // -------------------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;
    int test_id    = 0;

    task check(input string name, input bit condition);
        test_id++;
        if (condition) begin
            $display("  %0d. PASS: %s", test_id, name);
            pass_count++;
        end else begin
            $display("  %0d. FAIL: %s", test_id, name);
            fail_count++;
        end
    endtask

    task reset_dut();
        begin
            rst_n           = 1'b0;
            desc_empty      = 1'b1;
            desc_data       = 160'd0;
            tx_full         = 1'b0;
            saw_burst_start = 1'b0;
            saw_desc_pop    = 1'b0;
            for (integer i = 0; i < BRAM_DEPTH; i++) cbuf_mem[i] = 16'd0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task clear_latches();
        begin
            saw_burst_start = 1'b0;
            saw_desc_pop    = 1'b0;
        end
    endtask

    // Wait for the next desc_pop_req pulse, then deassert desc_empty
    task present_and_consume(input [DW-1:0] desc);
        begin
            @(negedge clk);
            desc_data  = desc;
            desc_empty = 1'b0;
            @(posedge clk);            // IDLE sees !desc_empty, pops descriptor
            // desc_pop_req is high for 1 cycle starting at this posedge
            @(posedge clk);            // one more cycle for the pop to register
            desc_empty = 1'b1;         // now empty
        end
    endtask

    // Build a descriptor with all fields
    function automatic [DW-1:0] make_desc(
        input [47:0] timestamp,
        input [12:0] offset,
        input [10:0] length
    );
        reg [DW-1:0] d;
        begin
            d = 160'd0;
            d[159:112] = timestamp;
            d[77:65]   = offset;
            d[64:54]   = length;
            make_desc  = d;
        end
    endfunction

    // Pre-fill the BRAM model
    task fill_bram(input [BRAM_AW-1:0] start, input int n, input [15:0] base);
        begin
            for (integer i = 0; i < n; i++) begin
                cbuf_mem[start + i[BRAM_AW-1:0]] = base + i[15:0];
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("========================================================================");
        $display("  tb_waveform_reader — Phase 2.5");
        $display("========================================================================");
        $display("");

        // ---------------------------------------------------------------------
        // Test 1: Reset state
        // ---------------------------------------------------------------------
        $display("--- Test 1: Reset ---");
        reset_dut();
        @(negedge clk);
        check("state = IDLE (0)",        dbg_info.state == 4'd0);
        check("busy = 0",                busy          == 1'b0);
        check("desc_pop_req = 0",        desc_pop_req  == 1'b0);
        check("sample_valid = 0",        sample_valid  == 1'b0);
        check("events_read = 0",         dbg_info.event_count == 16'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 2: Single burst
        // ---------------------------------------------------------------------
        $display("--- Test 2: Single burst ---");
        reset_dut();
        clear_latches();

        // Pre-fill BRAM with 8 known samples at offset 0
        fill_bram(13'd0, 8, 16'hA000);
        // Present a descriptor
        present_and_consume(make_desc(48'h0000_0000_1234, 13'd0, 11'd8));
        @(negedge clk);

        check("saw_burst_start",        saw_burst_start == 1'b1);
        check("saw_desc_pop",           saw_desc_pop    == 1'b1);
        check("busy = 1",               busy == 1'b1);
        check("events_read = 1",        dbg_info.event_count == 16'd1);
        check("burst_remaining = 8",    burst_remaining == 11'd8);

        // Wait for all 8 samples to come out (2 cycles per sample + init)
        // Total: 1 (IDLE→SET) + 2*8 (samples) + 1 (DONE) = 18 cycles
        repeat (30) @(posedge clk);
        @(negedge clk);
        check("busy = 0 after burst",   busy == 1'b0);
        check("state = IDLE after burst", dbg_info.state == 4'd0);
        check("events_total_words = 8", dbg_info.word_count == 16'd8);

        $display("");

        // ---------------------------------------------------------------------
        // Test 3: burst_remaining live count
        // ---------------------------------------------------------------------
        $display("--- Test 3: burst_remaining live count ---");
        reset_dut();
        fill_bram(13'd0, 10, 16'hB000);
        clear_latches();

        present_and_consume(make_desc(48'hCAFE, 13'd0, 11'd10));
        @(negedge clk);

        check("burst_remaining = 10 at start", burst_remaining == 11'd10);

        // Wait a few cycles, remaining should decrease
        repeat (4) @(posedge clk);
        @(negedge clk);
        check("burst_remaining < 10 after some cycles", burst_remaining < 11'd10);

        // Drain
        repeat (30) @(posedge clk);
        @(negedge clk);
        check("busy = 0 after drain",   busy == 1'b0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 4: TX FIFO backpressure stalls reader
        // ---------------------------------------------------------------------
        $display("--- Test 4: TX backpressure ---");
        reset_dut();
        fill_bram(13'd0, 20, 16'hC000);
        clear_latches();

        // Hold tx_full = 1 — reader should stall in BURST_EMIT
        @(negedge clk); tx_full = 1'b1;
        present_and_consume(make_desc(48'hBEEF, 13'd0, 11'd20));
        @(negedge clk);
        check("burst_start fired despite tx_full", saw_burst_start == 1'b1);

        // After some cycles, busy should still be 1 (stalled)
        repeat (10) @(posedge clk);
        @(negedge clk);
        check("busy = 1 (stalled)",      busy == 1'b1);
        check("tx_stall_cycles > 0",     dbg_info.stall_cycles > 0);

        // Release tx_full — reader should drain (20 samples * 2 cycles = 40 + 2 init = 42)
        @(negedge clk); tx_full = 1'b0;
        repeat (60) @(posedge clk);
        @(negedge clk);
        check("busy = 0 after release",  busy == 1'b0);
        check("events_total_words = 20", dbg_info.word_count == 16'd20);

        $display("");

        // ---------------------------------------------------------------------
        // Test 5: Multiple bursts in sequence
        // ---------------------------------------------------------------------
        $display("--- Test 5: Multiple bursts ---");
        reset_dut();
        fill_bram(13'd0, 30, 16'hD000);   // 30 samples
        clear_latches();

        // First burst: 10 samples
        present_and_consume(make_desc(48'h1, 13'd0, 11'd10));

        // Wait for it to complete
        repeat (30) @(posedge clk);
        @(negedge clk);
        check("events_read = 1 after first burst", dbg_info.event_count == 16'd1);
        check("busy = 0 after first burst",        busy == 1'b0);

        // Second burst: 15 samples starting at offset 10
        clear_latches();
        present_and_consume(make_desc(48'h2, 13'd10, 11'd15));
        @(negedge clk);
        check("burst_start for second",   saw_burst_start == 1'b1);

        // 15 samples * 2 cycles + 2 init/done = 32 cycles
        repeat (50) @(posedge clk);
        @(negedge clk);
        check("events_read = 2 after second burst", dbg_info.event_count == 16'd2);
        check("events_total_words = 25",  dbg_info.word_count  == 16'd25);

        $display("");

        // ---------------------------------------------------------------------
        // Test 6: Wrap-around
        // ---------------------------------------------------------------------
        $display("--- Test 6: Wrap-around ---");
        reset_dut();
        // Place samples at 8190, 8191, 0, 1, 2, 3 (4 wraps, 6 samples)
        cbuf_mem[8190] = 16'hF000;
        cbuf_mem[8191] = 16'hF001;
        cbuf_mem[0]    = 16'hF002;
        cbuf_mem[1]    = 16'hF003;
        cbuf_mem[2]    = 16'hF004;
        cbuf_mem[3]    = 16'hF005;
        clear_latches();

        present_and_consume(make_desc(48'h3, 13'd8190, 11'd6));

        repeat (30) @(posedge clk);
        @(negedge clk);
        check("wrap_handled = 1 (one wrap)", dbg_info.cycle_count == 16'd1);
        check("events_total_words = 6",      dbg_info.word_count  == 16'd6);

        $display("");

        // ---------------------------------------------------------------------
        // Test 7: Empty descriptor FIFO — reader stays idle
        // ---------------------------------------------------------------------
        $display("--- Test 7: Empty FIFO ---");
        reset_dut();
        clear_latches();

        desc_empty = 1'b1;
        desc_data  = 160'd0;
        repeat (10) @(posedge clk);
        @(negedge clk);
        check("state still IDLE",         dbg_info.state == 4'd0);
        check("busy = 0",                 busy          == 1'b0);
        check("no burst_start",           saw_burst_start == 1'b0);
        check("no desc_pop",              saw_desc_pop  == 1'b0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 8: dbg_if state mapping
        // ---------------------------------------------------------------------
        $display("--- Test 8: dbg_if state ---");
        reset_dut();
        check("dbg state = IDLE",         dbg_info.state       == 4'd0);
        check("dbg bypass_mode = 0",      dbg_info.bypass_mode == 1'b0);
        check("dbg event_count = 0",      dbg_info.event_count == 16'd0);
        check("dbg word_count = 0",       dbg_info.word_count  == 16'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 9: Reset clears counters
        // ---------------------------------------------------------------------
        $display("--- Test 9: Reset clears counters ---");
        // Trigger some events
        fill_bram(13'd0, 5, 16'hE000);
        present_and_consume(make_desc(48'h4, 13'd0, 11'd5));
        repeat (20) @(posedge clk);
        @(negedge clk);
        check("events_read = 1 before reset", dbg_info.event_count == 16'd1);
        check("word_count > 0",               dbg_info.word_count  != 16'd0);

        reset_dut();
        @(negedge clk);
        check("events_read = 0 after reset",  dbg_info.event_count == 16'd0);
        check("word_count = 0 after reset",   dbg_info.word_count  == 16'd0);
        check("state = IDLE",                 dbg_info.state       == 4'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_waveform_reader FAILED ***");
            $fatal(1, "FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("  ** tb_waveform_reader PASSED **");
        end

        $finish;
    end

    // Timeout watchdog (60 ms)
    initial begin
        #60_000_000;
        $display("  *** tb_waveform_reader TIMEOUT ***");
        $fatal(1, "Testbench timed out");
    end

endmodule : tb_waveform_reader
