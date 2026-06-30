//------------------------------------------------------------------------------
// tb_glitch_filter.sv
//
// Testbench for glitch_filter — 3-stage up-down pattern detector.
//
// CRITICAL: All test sequences must be sent with continuous din_valid
// (no gaps). A gap (din_valid=0) creates a 0-valued sample that can
// appear as a false glitch (e.g. sequence 2000→3000→0 looks UP-then-DOWN).
//
// Each test sequence uses flush_seq() to pipeline-flush with valid
// zeros, then a continuous send_seq() for the N-sample glass window.
//
// Tests:
//   1. Pass-through: monotonic ramp, no glitch → event_count = 0
//   2. UP-then-DOWN glitch → event_count = 1
//   3. DOWN-then-UP glitch → event_count = 2
//   4. Sub-threshold: opposite sign but both jumps < threshold → no increment
//   5. Monotonic edge: same sign, large jumps → no increment
//   6. Bypass mode: glitch passes through, event_count stable
//   7. Resume active: event_count increments again
//   8. Multiple glitch accumulation
//   9. max_delta tracks largest jump
//
// Architecture reference: Architecture.md §3, §3a
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_glitch_filter;

    import dbg_pkg::*;

    // =========================================================================
    // Clock
    // =========================================================================
    reg clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg        rst_n = 0;
    reg [15:0] din = 16'd0;
    reg        din_valid = 1'b0;
    wire [15:0] dout;
    wire        dout_valid;
    reg [15:0] threshold = 16'd500;
    reg        bypass = 1'b0;
    dbg_info_t dbg_info;
    wire [15:0] dbg_max_delta;

    glitch_filter u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .din           (din),
        .din_valid     (din_valid),
        .dout          (dout),
        .dout_valid    (dout_valid),
        .threshold     (threshold),
        .bypass        (bypass),
        .dbg_info      (dbg_info),
        .dbg_max_delta (dbg_max_delta)
    );

    // =========================================================================
    // Test infrastructure
    // =========================================================================
    int pass_count = 0;
    int fail_count = 0;
    int test_id    = 0;

    task automatic check(string name, bit condition);
        test_id++;
        if (condition) begin
            $display("  %0d. PASS: %s", test_id, name);
            pass_count++;
        end else begin
            $display("  %0d. FAIL: %s", test_id, name);
            fail_count++;
        end
    endtask

    // ------------------------------------------------------------------------
    // Send N samples continuously (din_valid stays high throughout)
    // After last sample, one more clock with din=0, din_valid=0
    // ------------------------------------------------------------------------
    task send_seq(input int n, input [15:0] vals []);
        for (int i = 0; i < n; i++) begin
            @(posedge clk);
            din       <= vals[i];
            din_valid <= 1'b1;
        end
        // One extra cycle to deassert (data may go to 0)
        @(posedge clk);
        din_valid <= 1'b0;
        din       <= 16'd0;
    endtask

    // ------------------------------------------------------------------------
    // Flush pipeline: send 5 zeros with valid=1 to flush old data out,
    // then deassert
    // ------------------------------------------------------------------------
    task flush_pipeline();
        repeat (5) begin
            @(posedge clk);
            din       <= 16'd0;
            din_valid <= 1'b1;
        end
        @(posedge clk);
        din_valid <= 1'b0;
        din       <= 16'd0;
        // Wait for flush to drain
        repeat (8) @(posedge clk);
    endtask

    // =========================================================================
    // Main test
    // =========================================================================
    initial begin
        $display("");
        $display("========================================================================");
        $display("  tb_glitch_filter — Phase 2 Glitch Filter Testbench");
        $display("========================================================================");
        $display("");

        // -------------------------------------------------------------------
        // Reset
        // -------------------------------------------------------------------
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        flush_pipeline();

        // -------------------------------------------------------------------
        // Test 1: Pass-through — monotonic ramp, no glitch
        // -------------------------------------------------------------------
        $display("--- Test 1: Pass-through (no glitch) ---");

        // Monotonic ramp: 1000→2000→3000→4000→5000 (jumps +1000, same sign)
        send_seq(5, '{16'd1000, 16'd2000, 16'd3000, 16'd4000, 16'd5000});
        repeat (8) @(posedge clk);

        check("no glitch: event_count = 0", dbg_info.event_count == 16'd0);

        flush_pipeline();

        $display("");

        // -------------------------------------------------------------------
        // Test 2: UP-then-DOWN glitch
        // -------------------------------------------------------------------
        $display("--- Test 2: UP-then-DOWN glitch ---");

        // Glass: 1000→3000→1000 (d1=+2000 pos, d2=-2000 neg)
        send_seq(3, '{16'd1000, 16'd3000, 16'd1000});
        repeat (8) @(posedge clk);

        check("UP-DOWN: event_count = 1", dbg_info.event_count == 16'd1);

        flush_pipeline();

        $display("");

        // -------------------------------------------------------------------
        // Test 3: DOWN-then-UP glitch
        // -------------------------------------------------------------------
        $display("--- Test 3: DOWN-then-UP glitch ---");

        // Glass: 3000→1000→3000 (d1=-2000 neg, d2=+2000 pos)
        send_seq(3, '{16'd3000, 16'd1000, 16'd3000});
        repeat (8) @(posedge clk);

        check("DOWN-UP: event_count = 2", dbg_info.event_count == 16'd2);

        flush_pipeline();

        $display("");

        // -------------------------------------------------------------------
        // Test 4: Sub-threshold (both jumps < threshold)
        // -------------------------------------------------------------------
        $display("--- Test 4: Sub-threshold (no false positive) ---");

        // Glass: 1000→1300→1000 (jumps = ±300, < 500 threshold)
        send_seq(3, '{16'd1000, 16'd1300, 16'd1000});
        repeat (8) @(posedge clk);

        check("sub-threshold: event_count still 2",
               dbg_info.event_count == 16'd2);

        flush_pipeline();

        $display("");

        // -------------------------------------------------------------------
        // Test 5: Monotonic edge (same sign, large jump)
        // -------------------------------------------------------------------
        $display("--- Test 5: Monotonic edge (no false positive) ---");

        // 1000→5000→9000 (both +4000, same sign)
        send_seq(3, '{16'd1000, 16'd5000, 16'd9000});
        repeat (8) @(posedge clk);

        check("monotonic: event_count still 2",
               dbg_info.event_count == 16'd2);

        flush_pipeline();

        $display("");

        // -------------------------------------------------------------------
        // Test 6: Bypass mode
        // -------------------------------------------------------------------
        $display("--- Test 6: Bypass mode ---");

        bypass = 1'b1;
        repeat (5) @(posedge clk);

        check("bypass: state = 0 (BYPASS)",
               dbg_info.state == 4'd0);

        send_seq(3, '{16'd5000, 16'd1000, 16'd5000});
        repeat (8) @(posedge clk);

        check("bypass: event_count still 2",
               dbg_info.event_count == 16'd2);

        bypass = 1'b0;
        repeat (5) @(posedge clk);
        flush_pipeline();

        $display("");

        // -------------------------------------------------------------------
        // Test 7: Resume active filtering
        // -------------------------------------------------------------------
        $display("--- Test 7: Resume active filtering ---");

        check("active: state = 1 (ACTIVE)",
               dbg_info.state == 4'd1);

        send_seq(3, '{16'd5000, 16'd1000, 16'd5000});
        repeat (8) @(posedge clk);

        check("resume: event_count = 3",
               dbg_info.event_count == 16'd3);

        flush_pipeline();

        $display("");

        // -------------------------------------------------------------------
        // Test 8: Multiple glitch accumulation
        // -------------------------------------------------------------------
        $display("--- Test 8: Multiple glitch accumulation ---");

        for (int i = 0; i < 3; i++) begin
            send_seq(3, '{16'd9000, 16'd1000, 16'd9000});
            repeat (8) @(posedge clk);
        end

        check("accumulate: event_count = 6",
               dbg_info.event_count == 16'd6);

        flush_pipeline();

        $display("");

        // -------------------------------------------------------------------
        // Test 9: max_delta tracks largest jump
        // -------------------------------------------------------------------
        $display("--- Test 9: max_delta tracking ---");

        check("max_delta >= 8000",
               dbg_max_delta >= 16'd8000);

        $display("");

        // -------------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------------
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_glitch_filter FAILED ***");
            $fatal(1, "FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("  ** tb_glitch_filter PASSED **");
        end

        $finish;
    end

endmodule : tb_glitch_filter
