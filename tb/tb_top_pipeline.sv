//------------------------------------------------------------------------------
// tb_top_pipeline.sv
//
// Integration testbench for top_pipeline.
//
// Uses tb_top_pipeline_lite wrapper that instantiates all event-pipeline
// modules but skips the CDCE I2C + ADC SPI init (which takes ~7 ms and is
// impractical for iverilog simulation). The full integration with init is
// verified on hardware via `make synth && make program`.
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_pipeline;

    // ---- DUT clocks ----
    reg sys_clk = 1'b0;
    reg dco_clk = 1'b0;
    reg dpti_clk = 1'b0;
    always #5 sys_clk  = ~sys_clk;     // 100 MHz
    always #5 dco_clk  = ~dco_clk;     // 100 MHz (same phase for test)
    always #5 dpti_clk = ~dpti_clk;    // 60 MHz (test only checks ready)

    // ---- ADC interface (directly into the pipeline) ----
    reg [15:0] adc_data_in = 16'd0;
    reg        adc_dv_in   = 1'b0;

    // ---- DPTI side ----
    wire [7:0] dpti_tx_byte;
    wire       dpti_tx_active;
    reg [7:0]  dpti_rx_byte = 8'd0;
    reg        dpti_rx_valid = 1'b0;
    wire       dpti_rx_ready;
    wire       event_arm_probe;

    // ---- DUT instance ----
    // Expose event_arm for testing
    wire trigger_pulse_probe;
    wire armed_probe;
    wire reader_busy_probe;
    wire [7:0] desc_count_probe;
    wire [15:0] trigger_count_probe;
    wire [15:0] glitch_out_probe;
    tb_top_pipeline_lite u_dut (
        .sys_clk      (sys_clk),
        .dco_clk      (dco_clk),
        .dpti_clk     (dpti_clk),
        .adc_data_in  (adc_data_in),
        .adc_dv_in    (adc_dv_in),
        .dpti_tx_byte (dpti_tx_byte),
        .dpti_tx_active(dpti_tx_active),
        .dpti_rx_byte (dpti_rx_byte),
        .dpti_rx_valid(dpti_rx_valid),
        .dpti_rx_ready(dpti_rx_ready),
        .event_arm_out(event_arm_probe),
        .trigger_pulse_out(trigger_pulse_probe),
        .armed_out    (armed_probe),
        .reader_busy_out(reader_busy_probe),
        .desc_count_out(desc_count_probe),
        .trigger_count_out(trigger_count_probe),
        .glitch_out_dbg(glitch_out_probe)
    );

    // -------------------------------------------------------------------------
    // ADC sample stream (drives the pipeline directly)
    // -------------------------------------------------------------------------
    reg [15:0] test_pattern [0:4095];
    integer    pattern_len = 0;
    integer    pattern_idx = 0;

    // 1800 samples / event × 1.5 for safety = 2700 cycles to drain

    // -------------------------------------------------------------------------
    // DPTI TX capture
    // -------------------------------------------------------------------------
    reg [7:0]  tx_log [0:8191];
    integer    tx_count = 0;

    always @(posedge sys_clk) begin
        if (dpti_tx_active) begin
            if (tx_count < 8192) begin
                tx_log[tx_count] = dpti_tx_byte;
                tx_count = tx_count + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // DPTI command sender (testbench → FPGA)
    // -------------------------------------------------------------------------
    task send_cmd(input [7:0] cmd_byte);
        begin
            @(posedge sys_clk);
            dpti_rx_byte  <= cmd_byte;
            dpti_rx_valid <= 1'b1;
            @(posedge sys_clk);
            // Hold valid for a few cycles so the FPGA can read
            repeat (3) @(posedge sys_clk);
            dpti_rx_valid <= 1'b0;
            dpti_rx_byte  <= 8'd0;
        end
    endtask

    // -------------------------------------------------------------------------
    // ADC stream driver
    // -------------------------------------------------------------------------
    always @(posedge sys_clk) begin
        if (adc_dv_in) begin
            if (pattern_idx < pattern_len) begin
                adc_data_in <= test_pattern[pattern_idx];
                pattern_idx <= pattern_idx + 1;
            end else begin
                adc_dv_in <= 1'b0;
            end
        end
    end

    task start_stream();
        begin
            pattern_idx = 0;
            adc_data_in <= test_pattern[0];
            adc_dv_in   <= 1'b1;
        end
    endtask

    task stop_stream();
        begin
            adc_dv_in <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test infrastructure
    // -------------------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;
    int test_id    = 0;

    task check(input string name, input logic condition);
        test_id++;
        if (condition) begin
            $display("  %0d. PASS: %s", test_id, name);
            pass_count++;
        end else begin
            $display("  %0d. FAIL: %s", test_id, name);
            fail_count++;
        end
    endtask

    // -------------------------------------------------------------------------
    // Build pulse patterns
    // -------------------------------------------------------------------------
    task build_single_pulse();
        integer i;
        begin
            pattern_len = 0;
            // Pre-pulse: 1000 baseline samples at 0x1000
            for (i = 0; i < 1000; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000;
                pattern_len = pattern_len + 1;
            end
            // Rising edge: 50 samples ramping from 0x1000 to 0x6000
            for (i = 0; i < 50; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000 + (i[15:0] * 16'd200);
                pattern_len = pattern_len + 1;
            end
            // Peak: 100 samples at 0x7000
            for (i = 0; i < 100; i = i + 1) begin
                test_pattern[pattern_len] = 16'h7000;
                pattern_len = pattern_len + 1;
            end
            // Decay: 1000 samples dropping back to 0x1000
            for (i = 0; i < 1000; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000 + ((999 - i) * 16'd6);
                pattern_len = pattern_len + 1;
            end
            // Post: 2000 baseline samples
            for (i = 0; i < 2000; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000;
                pattern_len = pattern_len + 1;
            end
        end
    endtask

    task build_double_pulse();
        integer i;
        begin
            pattern_len = 0;
            for (i = 0; i < 1000; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000;
                pattern_len = pattern_len + 1;
            end
            // First pulse
            for (i = 0; i < 50; i = i + 1) test_pattern[pattern_len + i] = 16'h1000 + (i[15:0] * 16'd200);
            pattern_len = pattern_len + 50;
            for (i = 0; i < 100; i = i + 1) begin
                test_pattern[pattern_len] = 16'h7000;
                pattern_len = pattern_len + 1;
            end
            for (i = 0; i < 1000; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000 + ((999 - i) * 16'd6);
                pattern_len = pattern_len + 1;
            end
            // Gap: 1000 baseline
            for (i = 0; i < 1000; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000;
                pattern_len = pattern_len + 1;
            end
            // Second pulse
            for (i = 0; i < 50; i = i + 1) test_pattern[pattern_len + i] = 16'h1000 + (i[15:0] * 16'd200);
            pattern_len = pattern_len + 50;
            for (i = 0; i < 100; i = i + 1) begin
                test_pattern[pattern_len] = 16'h7000;
                pattern_len = pattern_len + 1;
            end
            for (i = 0; i < 1000; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000 + ((999 - i) * 16'd6);
                pattern_len = pattern_len + 1;
            end
            // Post
            for (i = 0; i < 1000; i = i + 1) begin
                test_pattern[pattern_len] = 16'h1000;
                pattern_len = pattern_len + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("========================================================================");
        $display("  tb_top_pipeline — Phase 2.7 (integration test, lite wrapper)");
        $display("========================================================================");
        $display("");

        // Reset
        repeat (100) @(posedge sys_clk);

        // ---- Test 1: arm command processed ----
        $display("--- Test 1: Arm command processed ---");
        $display("  Sending arm command (0x02)");
        send_cmd(8'h02);
        repeat (20) @(posedge sys_clk);
        check("event_arm set to 1", event_arm_probe == 1'b1);

        $display("");

        // ---- Test 2: Single pulse → single event packet ----
        $display("--- Test 2: Single pulse → single event packet ---");
        tx_count = 0;
        build_single_pulse();
        start_stream();
        $display("  Streaming %0d samples, waiting for event...", pattern_len);
        // Wait for the event to flow through
        for (integer w = 0; w < 12; w = w + 1) begin
            repeat (500) @(posedge sys_clk);
            $display("  [t=%0d] event_arm=%b, armed=%b, trigger_pulse=%b, trigger_count=%0d, glitch_out=0x%h, desc_count=%0d, tx_count=%0d",
                     w*500, event_arm_probe, armed_probe, trigger_pulse_probe, trigger_count_probe,
                     glitch_out_probe, desc_count_probe, tx_count);
        end
        stop_stream();
        // Wait for drain FSM to finish the last byte
        repeat (1000) @(posedge sys_clk);
        $display("  Total DPTI TX bytes: %0d", tx_count);
        check("event packet emitted (>= 3604 bytes)", tx_count >= 3604);

        if (tx_count >= 4) begin
            check("header byte 0 = 0xA5", tx_log[0] == 8'hA5);
            check("header byte 1 = 0x5A", tx_log[1] == 8'h5A);
            check("event_id[15:8] = 0x00", tx_log[2] == 8'h00);
            check("event_id[7:0] = 0x00", tx_log[3] == 8'h00);
        end

        $display("");

        // ---- Test 3: Stop command ----
        $display("--- Test 3: Stop command ---");
        tx_count = 0;
        send_cmd(8'h00);
        repeat (200) @(posedge sys_clk);
        check("no new events after stop", tx_count == 0);

        $display("");

        // ---- Test 4: Two pulses → two events ----
        $display("--- Test 4: Two pulses → two event packets ---");
        tx_count = 0;
        send_cmd(8'h02);
        repeat (20) @(posedge sys_clk);
        build_double_pulse();
        start_stream();
        $display("  Streaming %0d samples (2 pulses)...", pattern_len);
        // Two events: 2 × 3604 = 7208 bytes
        repeat (15000) @(posedge sys_clk);
        stop_stream();

        $display("  Total DPTI TX bytes: %0d", tx_count);
        check("two events emitted (>= 7208 bytes)", tx_count >= 7208);

        $display("");

        // ---- Summary ----
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_top_pipeline FAILED ***");
        end else begin
            $display("  ** tb_top_pipeline PASSED **");
            $display("");
            $display("  Note: this test uses a 'lite' wrapper that skips the");
            $display("  CDCE I2C + ADC SPI init sequences. Full hardware");
            $display("  integration is verified via 'make synth && make program'.");
        end

        $finish;
    end

    // Timeout watchdog (200 ms)
    initial begin
        #200_000_000;
        $display("  *** tb_top_pipeline TIMEOUT ***");
        $fatal(1, "Testbench timed out");
    end

endmodule : tb_top_pipeline
