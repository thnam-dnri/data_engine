//------------------------------------------------------------------------------
// tb_circular_buffer.sv
//
// Testbench for circular_buffer — dual-port BRAM rolling history buffer.
//
// Tests:
//   1. Basic write/read: write N samples, read them back, verify match
//   2. Wrap-around: write >DEPTH samples, verify wrap_count increments
//   3. wr_ptr exposed: verify wr_ptr matches expected position
//   4. Read-during-write: simultaneous write + read at different addresses,
//      verify no corruption
//   5. max_fill watermark: track peak fill level during a burst
//   6. Collision detection: writer catches the reader, verify sticky flag
//   7. Reset: verify wr_ptr, wrap_count, max_fill, collision all clear
//   8. dbg_if fields: verify state, event_count, word_count map correctly
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_circular_buffer;

    // Small depth for fast test (still tests all behaviour)
    localparam DEPTH = 64;
    localparam AW    = 6;       // $clog2(64)
    localparam WIDTH = 16;

    // DUT clocks
    reg clk = 1'b0;
    always #5 clk = ~clk;       // 100 MHz

    reg rst_n;

    // DUT signals
    reg              wr_en;
    reg  [WIDTH-1:0] wr_data;
    wire [AW-1:0]    wr_ptr;

    reg              rd_en;
    reg  [AW-1:0]    rd_addr;
    wire [WIDTH-1:0] rd_data;

    dbg_pkg::dbg_info_t dbg_info;

    circular_buffer #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .AW(AW)
    ) u_dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_ptr   (wr_ptr),
        .rd_en    (rd_en),
        .rd_addr  (rd_addr),
        .rd_data  (rd_data),
        .dbg_info (dbg_info)
    );

    // -------------------------------------------------------------------------
    // Test infrastructure
    // -------------------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;
    int test_id    = 0;

    task automatic check(input string name, input bit condition);
        test_id++;
        if (condition) begin
            $display("  %0d. PASS: %s", test_id, name);
            pass_count++;
        end else begin
            $display("  %0d. FAIL: %s", test_id, name);
            fail_count++;
        end
    endtask

    task automatic write_sample(input [WIDTH-1:0] data);
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_data = data;
            @(posedge clk);
            @(negedge clk);  // wait for NBA to settle so caller can read wr_ptr
            wr_en   = 1'b0;
        end
    endtask

    task automatic write_idle();
        begin
            @(negedge clk);
            wr_en   = 1'b0;
        end
    endtask

    task automatic reset_dut();
        begin
            rst_n = 1'b0;
            wr_en = 1'b0;
            rd_en = 1'b0;
            // Reset shadow too
            for (integer i = 0; i < DEPTH; i++) shadow[i] = 16'h0000;
            shadow_wr_ptr = 0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Reference model: a software shadow of the BRAM for verification
    // -------------------------------------------------------------------------
    reg [WIDTH-1:0] shadow [0:DEPTH-1];
    integer         shadow_wr_ptr;

    task automatic shadow_write(input [WIDTH-1:0] data);
        begin
            shadow[shadow_wr_ptr] = data;
            shadow_wr_ptr = (shadow_wr_ptr + 1) % DEPTH;
        end
    endtask

    function automatic [WIDTH-1:0] shadow_read(input [AW-1:0] addr);
        return shadow[addr];
    endfunction

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("========================================================================");
        $display("  tb_circular_buffer — Phase 2.2");
        $display("========================================================================");
        $display("");

        // Initialise shadow
        for (integer i = 0; i < DEPTH; i++) shadow[i] = 16'h0000;
        shadow_wr_ptr = 0;

        // ---------------------------------------------------------------------
        // Test 1: Basic write/read
        // ---------------------------------------------------------------------
        $display("--- Test 1: Basic write/read ---");
        reset_dut();

        for (integer i = 0; i < 8; i++) begin
            write_sample(16'hA000 + i[15:0]);
            shadow_write(16'hA000 + i[15:0]);
        end
        write_idle();
        @(posedge clk);

        check("wr_ptr == 8", wr_ptr == 6'd8);

        for (integer i = 0; i < 8; i++) begin
            @(negedge clk);
            rd_en   = 1'b1;
            rd_addr = i[AW-1:0];
            @(posedge clk);     // BRAM samples rd_addr
            @(negedge clk);     // wait for NBA: rd_data <= mem[rd_addr]
            check($sformatf("read[%0d] = 0x%h (shadow 0x%h)", i, rd_data, shadow_read(i[AW-1:0])),
                  rd_data == shadow_read(i[AW-1:0]));
        end
        @(negedge clk);
        rd_en = 1'b0;

        $display("");

        // ---------------------------------------------------------------------
        // Test 2: Wrap-around
        // ---------------------------------------------------------------------
        $display("--- Test 2: Wrap-around ---");
        reset_dut();

        // Write DEPTH + 8 samples → should wrap exactly once
        for (integer i = 0; i < DEPTH + 8; i++) begin
            write_sample(16'hB000 + i[15:0]);
            shadow_write(16'hB000 + i[15:0]);
        end
        write_idle();
        @(negedge clk);

        check("wr_ptr wrapped to 8",  wr_ptr     == 6'd8);
        check("wrap_count = 1",       dbg_info.event_count == 16'd1);
        check("wrap_count (cycle_count field) = 1", dbg_info.cycle_count == 16'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 3: wr_ptr exposed correctly during continuous write
        // ---------------------------------------------------------------------
        $display("--- Test 3: wr_ptr tracking ---");
        reset_dut();

        for (integer i = 0; i < 20; i++) begin
            reg [AW-1:0] expected_ptr;
            expected_ptr = (i + 1);
            write_sample(16'hC000 + i[15:0]);
            check($sformatf("wr_ptr == %0d after write %0d", i+1, i),
                  wr_ptr == expected_ptr);
        end
        write_idle();

        $display("");

        // ---------------------------------------------------------------------
        // Test 4: Simultaneous read-during-write at different addresses
        // ---------------------------------------------------------------------
        $display("--- Test 4: Read-during-write ---");
        reset_dut();

        // Pre-fill the buffer
        for (integer i = 0; i < 16; i++) begin
            write_sample(16'hD000 + i[15:0]);
            shadow_write(16'hD000 + i[15:0]);
        end
        write_idle();
        @(posedge clk);

        // Start reading at addr 0, writing at the current wr_ptr position
        // Read side reads a moving address, write side writes a new sample
        rd_en = 1'b1;
        for (integer i = 0; i < 16; i++) begin
            write_sample(16'hE000 + i[15:0]);
            shadow_write(16'hE000 + i[15:0]);
            @(negedge clk);
            rd_addr = i[AW-1:0];        // reading the i-th old sample
            @(posedge clk);
            @(posedge clk);
            check($sformatf("read-during-write [%0d] = 0x%h (shadow 0x%h)",
                            i, rd_data, shadow_read(i[AW-1:0])),
                  rd_data == shadow_read(i[AW-1:0]));
        end
        write_idle();
        @(negedge clk);
        rd_en = 1'b0;

        $display("");

        // ---------------------------------------------------------------------
        // Test 5: max_fill watermark
        // ---------------------------------------------------------------------
        $display("--- Test 5: max_fill watermark ---");
        reset_dut();

        // Pre-fill: write 32 samples, then stop
        for (integer i = 0; i < 32; i++) begin
            write_sample(16'hF000 + i[15:0]);
        end
        write_idle();
        @(posedge clk);

        // Read with a delay so fill level = wr_ptr (32) - rd_addr (stays at 0)
        rd_en = 1'b1;
        rd_addr = 6'd0;
        repeat (4) @(posedge clk);
        check("max_fill = 32 (word_count field)", dbg_info.word_count == 16'd32);

        @(negedge clk);
        rd_en = 1'b0;

        $display("");

        // ---------------------------------------------------------------------
        // Test 6: Collision detection
        // ---------------------------------------------------------------------
        $display("--- Test 6: Collision detection ---");
        reset_dut();

        // Pre-fill: write 8 samples (wr_ptr = 8)
        for (integer i = 0; i < 8; i++) begin
            write_sample(16'h1000 + i[15:0]);
        end
        write_idle();
        @(negedge clk);

        // Start reading at addr 5. Then write enough samples to wrap around
        // and collide. Need wr_ptr to reach 5, starting from 8 in DEPTH=64:
        // 8 -> 63 (55 steps) -> 0 (1 step) -> 5 (5 steps) = 61 writes.
        rd_en = 1'b1;
        rd_addr = 6'd5;
        @(posedge clk);   // BRAM latches rd_addr
        @(negedge clk);   // rd_addr_r <= 5
        // Write 65 samples to definitely trigger collision
        for (integer i = 0; i < 65; i++) begin
            write_sample(16'h2000 + i[15:0]);
        end
        write_idle();
        @(negedge clk);

        check("collision flag set",   dbg_info.error     == 1'b1);
        check("error_id = 1 (collision)", dbg_info.error_id == 8'd1);

        @(negedge clk);
        rd_en = 1'b0;

        $display("");

        // ---------------------------------------------------------------------
        // Test 7: dbg_if state reflects rd_en
        // ---------------------------------------------------------------------
        $display("--- Test 7: dbg_if state ---");
        reset_dut();

        check("state = 0 when idle",     dbg_info.state == 4'd0);
        check("bypass_mode = 0",         dbg_info.bypass_mode == 1'b0);

        rd_en = 1'b1;
        rd_addr = 6'd0;
        @(posedge clk);
        @(posedge clk);
        check("state = 1 (BURST) when rd_en", dbg_info.state == 4'd1);

        @(negedge clk);
        rd_en = 1'b0;

        $display("");

        // ---------------------------------------------------------------------
        // Test 8: Reset clears all state
        // ---------------------------------------------------------------------
        $display("--- Test 8: Reset ---");
        // Set up some state, then reset
        for (integer i = 0; i < 30; i++) write_sample(16'h3000 + i[15:0]);
        write_idle();
        @(posedge clk);
        reset_dut();

        check("wr_ptr = 0 after reset",  wr_ptr == 6'd0);
        check("wrap_count = 0",          dbg_info.event_count == 16'd0);
        check("collision cleared",       dbg_info.error == 1'b0);

        $display("");

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_circular_buffer FAILED ***");
            $fatal(1, "FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("  ** tb_circular_buffer PASSED **");
        end

        $finish;
    end

    // Timeout watchdog (60 ms = 6_000_000 ns)
    initial begin
        #60_000_000;
        $display("  *** tb_circular_buffer TIMEOUT ***");
        $fatal(1, "Testbench timed out");
    end

endmodule : tb_circular_buffer
