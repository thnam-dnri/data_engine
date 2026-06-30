//------------------------------------------------------------------------------
// tb_comm_dpti.sv
//
// Testbench for comm_dpti — DPTI bridge (sys_clk ↔ dpti_clk CDC).
//
// Tests:
//   1. TX path: sys_clk → dpti_clk → FT232H write
//   2. TX stall: dpti_txen high (= FIFO full) delays write
//   3. RX path: FT232H → sys_clk domain
//   4. Round-robin arbitration
//
// Architecture reference: Architecture.md §11
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_comm_dpti;

    // =========================================================================
    // Clock generation
    // =========================================================================
    reg sys_clk = 0;
    always #5 sys_clk = ~sys_clk;      // 100 MHz

    reg dpti_clk = 0;
    always #8.333 dpti_clk = ~dpti_clk;  // 60 MHz

    // =========================================================================
    // DPTI PHY signals
    // =========================================================================
    wire [7:0] dpti_data;
    reg        dpti_txen = 1'b1;   // active low: 0 = space available
    reg        dpti_rxen = 1'b1;   // active low: 0 = data available
    wire       dpti_wrn;
    wire       dpti_rdn;
    wire       dpti_oen;

    // DPTI data bus: driven by host (FPGA reads when oen=0)
    reg [7:0] dpti_data_in = 8'hFF;
    assign dpti_data = dpti_oen ? 8'bZ : dpti_data_in;

    // =========================================================================
    // DUT
    // =========================================================================
    reg        sys_rst_n = 0;
    reg [7:0]  sys_tx_data = 8'd0;
    reg        sys_tx_wr = 0;
    wire       sys_tx_rdy;
    wire [7:0] sys_rx_data;
    wire       sys_rx_vld;
    reg        sys_rx_rd = 0;

    comm_dpti u_dut (
        .sys_clk     (sys_clk),
        .sys_rst_n   (sys_rst_n),
        .sys_tx_data (sys_tx_data),
        .sys_tx_wr   (sys_tx_wr),
        .sys_tx_rdy  (sys_tx_rdy),
        .sys_rx_data (sys_rx_data),
        .sys_rx_vld  (sys_rx_vld),
        .sys_rx_rd   (sys_rx_rd),
        .dpti_clk    (dpti_clk),
        .dpti_data   (dpti_data),
        .dpti_txen   (dpti_txen),
        .dpti_rxen   (dpti_rxen),
        .dpti_wrn    (dpti_wrn),
        .dpti_rdn    (dpti_rdn),
        .dpti_oen    (dpti_oen),
        .dpti_siwun  (),
        .dpti_spien  (),
        .dbg_info    ()
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

    // -------------------------------------------------------------------
    // Helper: Monitor DPTI write strobe
    // -------------------------------------------------------------------
    reg wrn_fell = 0;
    always @(negedge dpti_wrn) wrn_fell <= 1'b1;

    // =========================================================================
    // Main test
    // =========================================================================
    initial begin
        $display("");
        $display("========================================================================");
        $display("  tb_comm_dpti — Phase 1 DPTI Bridge Testbench");
        $display("========================================================================");
        $display("");

        // -------------------------------------------------------------------
        // Reset
        // -------------------------------------------------------------------
        sys_rst_n = 0;
        repeat (10) @(posedge sys_clk);
        sys_rst_n = 1;
        repeat (20) @(posedge sys_clk);
        repeat (10) @(posedge dpti_clk);

        // -------------------------------------------------------------------
        // Test 1: Basic TX — single byte with FIFO ready
        // -------------------------------------------------------------------
        $display("--- Test 1: TX Single Byte (FIFO ready) ---");

        // Make TX FIFO space available
        dpti_txen = 1'b0;

        // Write one byte from sys_clk side
        @(posedge sys_clk);
        sys_tx_data = 8'hA5;
        sys_tx_wr   = 1'b1;
        @(posedge sys_clk);
        sys_tx_wr = 1'b0;

        // Wait for toggle-handshake CDC to propagate and PHY to complete
        // sys_clk (100 MHz) → CDC → dpti_clk (60 MHz) → PHY → ack back → sys_clk
        repeat (30) @(posedge sys_clk);

        // Check that sys_tx_rdy is high (ready for next byte)
        check("sys_tx_rdy returned high after TX",
               sys_tx_rdy == 1'b1);

        $display("");

        // -------------------------------------------------------------------
        // Test 2: TX with stall (FIFO full)
        // -------------------------------------------------------------------
        $display("--- Test 2: TX Stall Handling ---");

        // Clear wrn_fell flag
        wrn_fell = 0;

        // Set TX FIFO full (dpti_txen high)
        dpti_txen = 1'b1;

        @(posedge sys_clk);
        sys_tx_data = 8'h5A;
        sys_tx_wr   = 1'b1;
        @(posedge sys_clk);
        sys_tx_wr = 1'b0;

        // Wait for CDC to propagate to dpti domain
        repeat (20) @(posedge sys_clk);

        // Now release stall
        dpti_txen = 1'b0;
        repeat (30) @(posedge sys_clk);

        // After stall release, the byte should be sent
        check("sys_tx_rdy returned high after stall release",
               sys_tx_rdy == 1'b1);

        $display("");

        // -------------------------------------------------------------------
        // Test 3: Multiple bytes in sequence
        // -------------------------------------------------------------------
        $display("--- Test 3: Multiple Bytes ---");

        // Reset monitor
        wrn_fell = 0;

        // Send 3 bytes as fast as possible
        for (int i = 0; i < 3; i++) begin
            @(posedge sys_clk);
            while (!sys_tx_rdy) @(posedge sys_clk);
            sys_tx_data = 8'hA0 + i;
            sys_tx_wr   = 1'b1;
            @(posedge sys_clk);
            sys_tx_wr = 1'b0;
        end

        // Wait for all to complete
        repeat (50) @(posedge sys_clk);

        check("Multiple TX complete (sys_tx_rdy high)",
               sys_tx_rdy == 1'b1);

        $display("");

        // -------------------------------------------------------------------
        // Test 4: RX path — host sends data to FPGA
        // -------------------------------------------------------------------
        $display("--- Test 4: RX Path ---");

        // Host asserts data available
        dpti_rxen = 1'b0;
        dpti_data_in = 8'hC3;

        // Wait for DPTI to detect rxen, drive rd_n, and sample data
        repeat (30) @(posedge dpti_clk);
        repeat (20) @(posedge sys_clk);

        // Check if rx_vld appeared
        if (sys_rx_vld) begin
            check("RX byte received", sys_rx_data == 8'hC3);
        end else begin
            // Might need more cycles for CDC
            @(posedge sys_rx_vld);
            @(posedge sys_clk);
            check("RX byte received (sync)", sys_rx_data == 8'hC3);
        end

        // Send another byte
        @(posedge sys_clk);
        sys_rx_rd = 1'b1;  // ack the first byte
        @(posedge sys_clk);
        sys_rx_rd = 1'b0;

        dpti_data_in = 8'h3C;
        repeat (30) @(posedge dpti_clk);
        repeat (10) @(posedge sys_clk);

        check("Second RX byte received",
               sys_rx_vld && sys_rx_data == 8'h3C);

        $display("");

        // -------------------------------------------------------------------
        // Test 5: Concurrent TX + RX (arbitration)
        // -------------------------------------------------------------------
        $display("--- Test 5: Concurrent TX+RX Arbitration ---");

        // Allow both directions
        dpti_txen = 1'b0;
        dpti_rxen = 1'b0;
        dpti_data_in = 8'hAA;

        // Send TX
        @(posedge sys_clk);
        sys_tx_data = 8'hBB;
        sys_tx_wr   = 1'b1;
        @(posedge sys_clk);
        sys_tx_wr = 1'b0;

        repeat (40) @(posedge sys_clk);

        check("TX completed during concurrent RX",
               sys_tx_rdy == 1'b1);

        $display("");

        // -------------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------------
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_comm_dpti FAILED ***");
            $fatal(1, "FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("  ** tb_comm_dpti PASSED **");
        end

        $finish;
    end

endmodule : tb_comm_dpti
