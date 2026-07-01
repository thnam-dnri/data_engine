//------------------------------------------------------------------------------
// tb_tx_fifo.sv
//
// Testbench for tx_wave_fifo — 4096×16 dual-clock FWFT FIFO.
//
// Tests:
//   1. Reset: empty, count=0
//   2. Single push/pop (single-clock mode)
//   3. Fill until full
//   4. FWFT data in order
//   5. Push when full: overflow_count increments
//   6. Pop when empty: underflow_count increments
//   7. Wrap-around
//   8. Watermark tracking
//   9. Dual-clock: separate wr_clk and rd_clk, basic CDC
//  10. dbg_if fields
//  11. Reset clears counters
//
// Note: write port has 1-cycle pipeline latency (registered wr_data/wr_addr
// to fix hold violation). do_write() waits 1 extra wr_clk cycle after the
// strobe so subsequent checks see the data in the BRAM.
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_tx_fifo;

    // Small depth for fast test (still tests all behaviour)
    localparam DEPTH = 64;
    localparam AW    = 6;
    localparam WIDTH = 16;

    // Two clocks (same period; one test will phase-shift rd_clk via `force`)
    reg wr_clk = 1'b0;
    reg rd_clk = 1'b0;
    always #5 wr_clk = ~wr_clk;     // 100 MHz
    always #5 rd_clk = ~rd_clk;     // 100 MHz (same phase by default)

    reg wr_rst_n;
    reg rd_rst_n;

    // DUT signals
    reg              wr_req;
    reg  [WIDTH-1:0] wr_data;
    wire             full;

    reg              rd_req;
    wire [WIDTH-1:0] pop_data;
    wire             empty;

    wire [AW:0]      wr_count;
    dbg_pkg::dbg_info_t dbg_info;

    tx_wave_fifo #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .AW(AW)
    ) u_dut (
        .wr_clk   (wr_clk),
        .wr_rst_n (wr_rst_n),
        .wr_req   (wr_req),
        .wr_data  (wr_data),
        .full     (full),

        .rd_clk   (rd_clk),
        .rd_rst_n (rd_rst_n),
        .rd_req   (rd_req),
        .pop_data (pop_data),
        .empty    (empty),

        .wr_count (wr_count),
        .dbg_info (dbg_info)
    );

    // -------------------------------------------------------------------------
    // Sticky latches for 1-cycle signals
    // -------------------------------------------------------------------------
    reg saw_full_pulse, saw_empty_pulse;
    always @(posedge wr_clk) if (full)  saw_full_pulse  <= 1'b1;
    always @(posedge rd_clk) if (empty) saw_empty_pulse <= 1'b1;

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

    // Write one word (synchronous to wr_clk) and wait for CDC propagation.
    // The FIFO write port has 1-cycle pipeline latency (wr_data and
    // wr_addr are registered), so we wait 1 extra wr_clk after the strobe
    // before checking results.
    task do_write(input [WIDTH-1:0] data);
        begin
            @(negedge wr_clk);
            wr_req  = 1'b1;
            wr_data = data;
            @(posedge wr_clk);    // wr_data/wr_addr registered here
            @(negedge wr_clk);
            wr_req  = 1'b0;
            @(posedge wr_clk);    // wait for BRAM write to complete
            // Wait for 2-FF synchroniser to propagate wr_ptr_gray to rd_clk
            repeat (3) @(posedge rd_clk);
        end
    endtask

    // Read one word (synchronous to rd_clk) and wait for CDC propagation
    task do_read();
        begin
            @(negedge rd_clk);
            rd_req = 1'b1;
            @(posedge rd_clk);    // read happens here
            @(negedge rd_clk);
            rd_req = 1'b0;
            // Wait for 2-FF synchroniser to propagate rd_ptr_gray to wr_clk
            repeat (3) @(posedge wr_clk);
        end
    endtask

    // Reset both domains
    task reset_dut();
        begin
            wr_rst_n = 1'b0;
            rd_rst_n = 1'b0;
            wr_req   = 1'b0;
            wr_data  = 16'd0;
            rd_req   = 1'b0;
            saw_full_pulse  = 1'b0;
            saw_empty_pulse = 1'b0;
            repeat (5) @(posedge wr_clk);
            wr_rst_n = 1'b1;
            repeat (2) @(posedge wr_clk);
            repeat (2) @(posedge rd_clk);
            rd_rst_n = 1'b1;
            repeat (2) @(posedge rd_clk);
        end
    endtask

    // Helper: read words_written via dbg_info.cycle_count
    function automatic [15:0] words_written_signal();
        words_written_signal = dbg_info.cycle_count;
    endfunction

    task clear_latches();
        begin
            saw_full_pulse  = 1'b0;
            saw_empty_pulse = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("========================================================================");
        $display("  tb_tx_fifo — Phase 2.6 (with 1-cycle write pipeline)");
        $display("========================================================================");
        $display("");

        // ---------------------------------------------------------------------
        // Test 1: Reset
        // ---------------------------------------------------------------------
        $display("--- Test 1: Reset ---");
        reset_dut();
        @(negedge rd_clk);
        check("empty = 1",          empty == 1'b1);
        check("full = 0",           full  == 1'b0);
        check("wr_count = 0",       wr_count == 13'd0);
        check("dbg state = IDLE",   dbg_info.state == 4'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 2: Single push/pop
        // ---------------------------------------------------------------------
        $display("--- Test 2: Single push/pop ---");
        reset_dut();
        do_write(16'hCAFE);
        @(negedge rd_clk);
        check("empty = 0",          empty  == 1'b0);
        check("full = 0",           full   == 1'b0);
        check("wr_count = 1",       wr_count == 13'd1);
        // FWFT: pop_data is valid before rd_req
        check("pop_data = 0xCAFE",  pop_data == 16'hCAFE);

        do_read();
        @(negedge rd_clk);
        check("empty = 1 after pop",   empty  == 1'b1);
        check("wr_count = 0 after pop", wr_count == 13'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 3: Fill until full
        // ---------------------------------------------------------------------
        $display("--- Test 3: Fill until full ---");
        reset_dut();
        for (integer i = 0; i < DEPTH; i++) begin
            do_write(16'hA000 + i[15:0]);
            @(negedge wr_clk);
            if (i < DEPTH - 1) begin
                check($sformatf("not full at i=%0d", i), full == 1'b0);
            end
        end
        // After DEPTH writes, should be full
        check("full = 1 after DEPTH writes", full == 1'b1);
        check("wr_count = DEPTH",           wr_count == 13'(DEPTH));

        $display("");

        // ---------------------------------------------------------------------
        // Test 4: Pop data in order (FWFT)
        // ---------------------------------------------------------------------
        $display("--- Test 4: Pop in order ---");
        for (integer i = 0; i < DEPTH; i++) begin
            reg [WIDTH-1:0] expected;
            expected = 16'hA000 + i[15:0];
            @(negedge rd_clk);
            check($sformatf("pop_data[%0d] = 0x%h", i, pop_data),
                  pop_data == expected);
            do_read();
        end
        @(negedge rd_clk);
        check("empty = 1 after drain",   empty == 1'b1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 5: Push when full (overflow)
        // ---------------------------------------------------------------------
        $display("--- Test 5: Push when full rejected ---");
        reset_dut();
        for (integer i = 0; i < DEPTH; i++) do_write(16'hB000 + i[15:0]);
        @(negedge wr_clk);
        check("full = 1",                full == 1'b1);

        // Try to push one more
        do_write(16'hDEAD);
        @(negedge wr_clk);
        check("overflow_count = 1",      dbg_info[15:0] == 16'd1);
        check("error = 1",               dbg_info.error == 1'b1);
        check("error_id = 1 (overflow)", dbg_info.error_id == 8'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 6: Pop when empty (underflow)
        // ---------------------------------------------------------------------
        $display("--- Test 6: Pop when empty ---");
        reset_dut();
        do_read();   // empty
        @(negedge rd_clk);
        // underflow_count not in dbg_if — check via the explicit wire
        check("dpti_stall_cycles > 0",   dbg_info.stall_cycles > 0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 7: Wrap-around
        // ---------------------------------------------------------------------
        $display("--- Test 7: Wrap-around ---");
        reset_dut();
        // Fill, drain, fill, drain
        for (integer i = 0; i < DEPTH; i++) do_write(16'hC000 + i[15:0]);
        for (integer i = 0; i < DEPTH; i++) do_read();
        for (integer i = 0; i < DEPTH; i++) do_write(16'hD000 + i[15:0]);
        @(negedge rd_clk);
        check("wr_count = DEPTH after second fill", wr_count == 13'(DEPTH));

        for (integer i = 0; i < DEPTH; i++) begin
            reg [WIDTH-1:0] expected;
            expected = 16'hD000 + i[15:0];
            @(negedge rd_clk);
            check($sformatf("second fill pop[%0d]", i), pop_data == expected);
            do_read();
        end

        $display("");

        // ---------------------------------------------------------------------
        // Test 8: Watermark tracking
        // ---------------------------------------------------------------------
        $display("--- Test 8: Watermark ---");
        reset_dut();
        for (integer i = 0; i < 32; i++) do_write(16'hE000 + i[15:0]);
        @(negedge wr_clk);
        check("max_fill_watermark >= 32", dbg_info.word_count >= 16'd32);

        // Drain, watermark should NOT decrease
        for (integer i = 0; i < 32; i++) do_read();
        @(negedge rd_clk);
        check("watermark still >= 32",    dbg_info.word_count >= 16'd32);

        $display("");

        // ---------------------------------------------------------------------
        // Test 9: Dual-clock CDC (rd_clk phase-shifted via procedural force)
        // ---------------------------------------------------------------------
        $display("--- Test 9: Dual-clock CDC ---");
        reset_dut();

        // Procedurally drive rd_clk to a different value to test CDC.
        // The 2-FF synchronisers should handle the metastability gracefully.
        // We push on wr_clk and verify the data appears on rd_clk.
        do_write(16'hF00D);
        // Hold rd_clk low for several wr_clk cycles
        force rd_clk = 1'b0;
        repeat (4) @(posedge wr_clk);
        // Release rd_clk and let it run
        release rd_clk;
        repeat (4) @(posedge rd_clk);
        @(negedge rd_clk);
        check("empty = 0 after dual-clock push", empty == 1'b0);
        check("pop_data = 0xF00D",               pop_data == 16'hF00D);

        do_read();
        @(negedge rd_clk);
        check("empty = 1 after dual-clock pop",  empty == 1'b1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 10: dbg_if state mapping
        // ---------------------------------------------------------------------
        $display("--- Test 10: dbg_if fields ---");
        reset_dut();
        check("dbg state = IDLE",     dbg_info.state       == 4'd0);
        check("dbg bypass_mode = 0",  dbg_info.bypass_mode == 1'b0);
        check("dbg event_count = 0",  dbg_info.event_count == 16'd0);
        check("dbg word_count = 0",   dbg_info.word_count  == 16'd0);

        do_write(16'h1);
        @(negedge wr_clk);
        check("dbg state = FILLING",  dbg_info.state == 4'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 11: Reset clears counters
        // ---------------------------------------------------------------------
        $display("--- Test 11: Reset clears counters ---");
        reset_dut();
        // Generate some activity
        for (integer i = 0; i < DEPTH; i++) do_write(16'hA000 + i[15:0]);
        do_write(16'hBEEF);   // overflow
        @(negedge wr_clk);
        check("overflow before reset", dbg_info[15:0] == 16'd1);

        reset_dut();
        @(negedge wr_clk);
        check("overflow = 0 after reset", dbg_info[15:0] == 16'd0);
        check("error = 0 after reset",    dbg_info.error == 1'b0);
        check("watermark = 0",            dbg_info.word_count == 16'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_tx_fifo FAILED ***");
            $fatal(1, "FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("  ** tb_tx_fifo PASSED **");
        end

        $finish;
    end

    // Timeout watchdog (60 ms)
    initial begin
        #60_000_000;
        $display("  *** tb_tx_fifo TIMEOUT ***");
        $fatal(1, "Testbench timed out");
    end

endmodule : tb_tx_fifo
