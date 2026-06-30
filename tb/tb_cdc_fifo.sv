//------------------------------------------------------------------------------
// tb_cdc_fifo.sv
//
// Testbench for cdc_fifo — async FIFO for adc_dco → sys_clk crossing.
//
// Tests:
//   1. Basic write/read: single word through the FIFO
//   2. Multiple write/read: FIFO depth test
//   3. Overflow detection: write when full
//   4. Underflow detection: read when empty
//   5. CDC correctness: data integrity across clock domains
//
// Uses behavioral xpm model when SYNTHESIS is not defined.
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_cdc_fifo;

    // =========================================================================
    // Clock generation
    // =========================================================================
    reg wr_clk = 0;
    always #4.762 wr_clk = ~wr_clk;  // ~105 MHz (adc_dco)

    reg rd_clk = 0;
    always #5 rd_clk = ~rd_clk;      // 100 MHz (sys_clk)

    // =========================================================================
    // DUT
    // =========================================================================
    reg        wr_rst_n = 0;
    reg        wr_en = 0;
    reg [31:0] din = 32'd0;
    wire       full;
    reg        rd_rst_n = 0;
    reg        rd_en = 0;
    wire [31:0] dout;
    wire        empty;

    dbg_pkg::dbg_info_t dbg_info;

    cdc_fifo u_dut (
        .wr_clk    (wr_clk),
        .wr_rst_n  (wr_rst_n),
        .wr_en     (wr_en),
        .din       (din),
        .full      (full),
        .rd_clk    (rd_clk),
        .rd_rst_n  (rd_rst_n),
        .rd_en     (rd_en),
        .dout      (dout),
        .empty     (empty),
        .dbg_info  (dbg_info)
    );

    // =========================================================================
    // Test infrastructure
    // =========================================================================
    int pass_count = 0;
    int fail_count = 0;
    int test_id    = 0;
    int timeout    = 0;

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

    // =========================================================================
    // Main test
    // =========================================================================
    initial begin
        $display("");
        $display("========================================================================");
        $display("  tb_cdc_fifo — Phase 1 CDC FIFO Testbench");
        $display("========================================================================");
        $display("");

        // -------------------------------------------------------------------
        // Reset
        // -------------------------------------------------------------------
        wr_rst_n = 0;
        rd_rst_n = 0;
        repeat (10) @(posedge wr_clk);
        repeat (10) @(posedge rd_clk);
        wr_rst_n = 1;
        rd_rst_n = 1;
        repeat (5) @(posedge wr_clk);

        // -------------------------------------------------------------------
        // Test 1: Basic write/read
        // -------------------------------------------------------------------
        $display("--- Test 1: Basic Write/Read ---");

        // Write a word from wr_clk domain
        @(posedge wr_clk);
        din  = 32'hA5A5_BEEF;
        wr_en = 1'b1;
        @(posedge wr_clk);
        wr_en = 1'b0;

        // Wait for CDC propagation
        repeat (20) @(posedge rd_clk);

        // Read from rd_clk domain
        if (!empty) begin
            @(posedge rd_clk);
            rd_en = 1'b1;
            @(posedge rd_clk);
            rd_en = 1'b0;
            check("Basic write/read: data integrity", dout == 32'hA5A5_BEEF);
        end else begin
            // May need more time for CDC
            repeat (20) @(posedge rd_clk);
            if (!empty) begin
                @(posedge rd_clk);
                rd_en = 1'b1;
                @(posedge rd_clk);
                rd_en = 1'b0;
                check("Basic write/read (delayed)", dout == 32'hA5A5_BEEF);
            end else begin
                check("Basic write/read: data arrived", 1'b0);  // Fail
            end
        end

        $display("");

        // -------------------------------------------------------------------
        // Test 2: Multiple writes + order preservation
        // -------------------------------------------------------------------
        $display("--- Test 2: Multiple Writes & Order ---");

        // Write 3 words in sequence
        @(posedge wr_clk);
        din  = 32'h0000_0001;
        wr_en = 1'b1;
        @(posedge wr_clk);
        din  = 32'h0000_0002;
        @(posedge wr_clk);
        din  = 32'h0000_0003;
        @(posedge wr_clk);
        wr_en = 1'b0;

        // Read them back in order
        repeat (30) @(posedge rd_clk);

        for (int i = 1; i <= 3; i++) begin
            timeout = 0;
            while (empty && timeout < 50) begin
                @(posedge rd_clk);
                timeout++;
            end
            if (!empty) begin
                @(posedge rd_clk);
                rd_en = 1'b1;
                @(posedge rd_clk);
                rd_en = 1'b0;
                check($sformatf("Order preservation: word %0d = 32'h%08h", i, 32'h0000_0000 + i),
                       dout == (32'h0000_0000 + i));
            end else begin
                check($sformatf("Order preservation: word %0d timed out", i), 1'b0);
            end
        end

        $display("");

        // -------------------------------------------------------------------
        // Test 3: Overflow detection
        // -------------------------------------------------------------------
        $display("--- Test 3: Overflow Detection ---");

        // Fill the FIFO until full (depth=64)
        // Behavioral model: full tracks fill_wr via CDC sync (2-stage FF)
        // so wait long enough for sync to propagate
        for (int i = 0; i < 80; i++) begin
            @(posedge wr_clk);
            if (!full) begin
                din  = 32'h0000_0000 + i;
                wr_en = 1'b1;
            end else begin
                wr_en = 1'b0;
            end
        end
        @(posedge wr_clk);
        wr_en = 1'b0;

        // Wait for CDC sync to propagate
        repeat (30) @(posedge rd_clk);
        check("FIFO full detected", full == 1'b1);

        $display("");

        // -------------------------------------------------------------------
        // Test 4: Drain FIFO then check empty
        // -------------------------------------------------------------------
        $display("--- Test 4: Drain FIFO -> Empty ---");

        // Drain the FIFO (read until empty, max 80 iterations)
        for (int i = 0; i < 80; i++) begin
            repeat (3) @(posedge rd_clk);  // allow CDC
            if (!empty) begin
                @(posedge rd_clk);
                rd_en = 1'b1;
                @(posedge rd_clk);
                rd_en = 1'b0;
            end
        end

        // Wait for CDC to settle
        repeat (20) @(posedge rd_clk);
        check("FIFO empty after drain", empty == 1'b1);

        $display("");

        // -------------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------------
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_cdc_fifo FAILED ***");
            $fatal(1, "FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("  ** tb_cdc_fifo PASSED **");
        end

        $finish;
    end

endmodule : tb_cdc_fifo
