//------------------------------------------------------------------------------
// tb_descriptor_fifo.sv
//
// Testbench for event_descriptor_fifo — 64×160 FWFT FIFO.
//
// Tests:
//   1. Reset: empty, count=0, full=0
//   2. Single push/pop: data preserved
//   3. Multiple push: count increments, full eventually asserted
//   4. FWFT: pop_data is valid before pop_req when not empty
//   5. Pop drains the FIFO, count decrements
//   6. Push when full: rejected, lost_event_count increments
//   7. Pop when empty: no effect
//   8. Wrap-around: fill → drain → fill cycle preserves all data
//   9. Simultaneous push+pop
//  10. dbg_if fields map correctly
//  11. Reset clears lost_event_count
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_descriptor_fifo;

    localparam DEPTH = 64;
    localparam DW    = 160;

    // DUT clocks
    reg clk = 1'b0;
    always #5 clk = ~clk;       // 100 MHz

    reg rst_n;

    // DUT signals
    reg              push_req;
    reg  [DW-1:0]    push_data;
    wire             full;

    reg              pop_req;
    wire [DW-1:0]    pop_data;
    wire             empty;

    wire [7:0]       count;
    wire             lost_event_pulse;

    dbg_pkg::dbg_info_t dbg_info;

    event_descriptor_fifo #(
        .DEPTH(DEPTH),
        .DW(DW)
    ) u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .push_req        (push_req),
        .push_data       (push_data),
        .full            (full),
        .pop_req         (pop_req),
        .pop_data        (pop_data),
        .empty           (empty),
        .count           (count),
        .lost_event_pulse(lost_event_pulse),
        .dbg_info        (dbg_info)
    );

    // -------------------------------------------------------------------------
    // Sticky latches for 1-cycle signals
    // -------------------------------------------------------------------------
    reg saw_lost_event;
    always @(posedge clk) begin
        if (lost_event_pulse) saw_lost_event <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // Test infrastructure (plain 'task' — iverilog v12 has bugs with
    // 'task automatic' + packed array input)
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

    // Push one descriptor
    task do_push(input [DW-1:0] data);
        begin
            @(negedge clk);
            push_req  = 1'b1;
            push_data = data;
            @(posedge clk);
            @(negedge clk);
            push_req  = 1'b0;
        end
    endtask

    // Pop one descriptor
    task do_pop();
        begin
            @(negedge clk);
            pop_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pop_req = 1'b0;
        end
    endtask

    // Reset DUT
    task reset_dut();
        begin
            rst_n         = 1'b0;
            push_req      = 1'b0;
            pop_req       = 1'b0;
            push_data     = 160'd0;
            saw_lost_event = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task clear_latches();
        begin
            saw_lost_event = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Build a 160-bit descriptor value from 32-bit fields
    // -------------------------------------------------------------------------
    function automatic [DW-1:0] make_desc(
        input [31:0] ts_lo,     // timestamp low (we use this as a unique id)
        input [7:0]  marker
    );
        reg [DW-1:0] d;
        begin
            d = 160'd0;
            d[31:0]   = ts_lo;
            d[63:56]  = marker;
            make_desc = d;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("========================================================================");
        $display("  tb_descriptor_fifo — Phase 2.4");
        $display("========================================================================");
        $display("");

        // ---------------------------------------------------------------------
        // Test 1: Reset state
        // ---------------------------------------------------------------------
        $display("--- Test 1: Reset ---");
        reset_dut();
        @(negedge clk);
        check("empty = 1",          empty   == 1'b1);
        check("full = 0",           full    == 1'b0);
        check("count = 0",          count   == 8'd0);
        check("dbg state = IDLE",   dbg_info.state == 4'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 2: Single push/pop
        // ---------------------------------------------------------------------
        $display("--- Test 2: Single push/pop ---");
        reset_dut();
        do_push(160'h0000_0001_DEAD_BEEF_CAFE_BABE_1234_5678);
        @(negedge clk);
        check("empty = 0 after push",    empty  == 1'b0);
        check("count = 1",               count  == 8'd1);

        // FWFT: pop_data should already be valid before pop_req
        check("FWFT: pop_data valid",    pop_data == 160'h0000_0001_DEAD_BEEF_CAFE_BABE_1234_5678);

        do_pop();
        @(negedge clk);
        check("empty = 1 after pop",     empty  == 1'b1);
        check("count = 0",               count  == 8'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 3: Fill until full
        // ---------------------------------------------------------------------
        $display("--- Test 3: Fill until full ---");
        reset_dut();

        for (integer i = 0; i < DEPTH; i++) begin
            do_push(make_desc(32'(i), 8'(i)));
            @(negedge clk);
            if (i < DEPTH - 1) begin
                check($sformatf("not full at i=%0d", i), full == 1'b0);
            end
        end
        // After DEPTH pushes, FIFO should be full
        check("full = 1 after DEPTH pushes", full == 1'b1);
        check("count = DEPTH",              count == 8'(DEPTH));

        $display("");

        // ---------------------------------------------------------------------
        // Test 4: Pop data in order (FWFT)
        // ---------------------------------------------------------------------
        $display("--- Test 4: Pop in order ---");
        // Don't reset — continue from full state
        for (integer i = 0; i < DEPTH; i++) begin
            reg [DW-1:0] expected;
            expected = make_desc(32'(i), 8'(i));
            @(negedge clk);
            check($sformatf("FWFT pop_data[%0d]", i), pop_data == expected);
            do_pop();
        end
        @(negedge clk);
        check("empty = 1 after draining",  empty == 1'b1);
        check("full = 0 after draining",   full  == 1'b0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 5: Push when full is rejected
        // ---------------------------------------------------------------------
        $display("--- Test 5: Push when full rejected ---");
        reset_dut();
        clear_latches();

        // Fill to capacity
        for (integer i = 0; i < DEPTH; i++) begin
            do_push(make_desc(32'(i), 8'(i)));
        end
        @(negedge clk);
        check("full = 1",  full == 1'b1);

        // Try to push one more — should be rejected
        do_push(160'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF);
        @(negedge clk);
        check("lost_event_pulse fired",   saw_lost_event == 1'b1);
        check("lost_event_count = 1",     dbg_info.event_count == 16'd1);
        check("error flag set",           dbg_info.error == 1'b1);
        check("error_id = 1 (lost)",      dbg_info.error_id == 8'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 6: Pop when empty has no effect
        // ---------------------------------------------------------------------
        $display("--- Test 6: Pop when empty ---");
        reset_dut();
        do_pop();   // empty
        @(negedge clk);
        check("count still 0",        count == 8'd0);
        check("empty still 1",        empty == 1'b1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 7: Wrap-around (fill → drain → fill)
        // ---------------------------------------------------------------------
        $display("--- Test 7: Wrap-around ---");
        reset_dut();

        // First cycle: push 16, pop all
        for (integer i = 0; i < 16; i++) do_push(make_desc(32'(i), 8'(1)));
        for (integer i = 0; i < 16; i++) do_pop();
        @(negedge clk);
        check("empty after first cycle",   empty == 1'b1);

        // Second cycle: push 32 (different data)
        for (integer i = 0; i < 32; i++) do_push(make_desc(32'(i + 100), 8'(2)));
        @(negedge clk);
        check("count = 32 after second push", count == 8'd32);

        // Pop and verify data is from second cycle
        for (integer i = 0; i < 32; i++) begin
            reg [DW-1:0] expected;
            expected = make_desc(32'(i + 100), 8'(2));
            @(negedge clk);
            check($sformatf("second-cycle pop[%0d]", i), pop_data == expected);
            do_pop();
        end
        @(negedge clk);
        check("empty after second cycle",   empty == 1'b1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 8: Simultaneous push+pop
        // ---------------------------------------------------------------------
        $display("--- Test 8: Simultaneous push+pop ---");
        reset_dut();

        // Pre-fill 12 with marker 3
        for (integer i = 0; i < 12; i++) do_push(make_desc(32'(i), 8'(3)));
        @(negedge clk);
        check("count = 12 before sim",    count == 8'd12);

        // Pop 1 + push 1 simultaneously 9 times. After each iteration,
        // pop_data should be the next pre-fill item (i+1 with marker 3).
        // We do 9 iterations, so we consume 9 of the 12 pre-fill items,
        // staying within the pre-fill regime.
        for (integer i = 0; i < 9; i++) begin
            @(negedge clk);
            pop_req   = 1'b1;
            push_req  = 1'b1;
            push_data = make_desc(32'(i + 100), 8'(4));
            @(posedge clk);
            @(negedge clk);
            pop_req  = 1'b0;
            push_req = 1'b0;
            check($sformatf("sim pop_data correct at i=%0d", i),
                  pop_data == make_desc(32'(i+1), 8'(3)));
        end
        @(negedge clk);
        check("count back to 12 after sim ops", count == 8'd12);

        $display("");

        // ---------------------------------------------------------------------
        // Test 9: dbg_if state mapping
        // ---------------------------------------------------------------------
        $display("--- Test 9: dbg_if state ---");
        reset_dut();
        check("dbg state = 0 (empty)",   dbg_info.state == 4'd0);
        check("dbg bypass_mode = 0",     dbg_info.bypass_mode == 1'b0);

        do_push(make_desc(32'd1, 8'd1));
        @(negedge clk);
        check("dbg state = 1 (filling)", dbg_info.state == 4'd1);
        check("dbg word_count = 1",      dbg_info.word_count[7:0] == 8'd1);

        // Fill to full
        for (integer i = 0; i < DEPTH - 1; i++) do_push(make_desc(32'(i+10), 8'(i)));
        @(negedge clk);
        check("dbg state = 3 (full)",    dbg_info.state == 4'd3);

        $display("");

        // ---------------------------------------------------------------------
        // Test 10: Reset clears lost_event_count
        // ---------------------------------------------------------------------
        $display("--- Test 10: Reset clears lost events ---");
        // From Test 9, lost_event_count should be 0 (no lost events yet)
        check("no lost events yet",     dbg_info.event_count == 16'd0);

        // Force a lost event by pushing to full
        do_push(160'hDEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF);
        @(negedge clk);
        check("lost_event_count = 1",   dbg_info.event_count == 16'd1);

        reset_dut();
        @(negedge clk);
        check("lost_event_count = 0 after reset", dbg_info.event_count == 16'd0);
        check("error = 0 after reset",           dbg_info.error == 1'b0);

        $display("");

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_descriptor_fifo FAILED ***");
            $fatal(1, "FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("  ** tb_descriptor_fifo PASSED **");
        end

        $finish;
    end

    // Timeout watchdog (60 ms)
    initial begin
        #60_000_000;
        $display("  *** tb_descriptor_fifo TIMEOUT ***");
        $fatal(1, "Testbench timed out");
    end

endmodule : tb_descriptor_fifo
