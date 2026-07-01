//------------------------------------------------------------------------------
// tb_trigger.sv
//
// Testbench for trigger — Phase 2.3b (adaptive boxcar + MAD baseline/noise).
//
// Two test groups:
//   LEGACY (cfg_adaptive_bypass = 1): fixed-threshold leading-edge behaviour,
//     backwards-compatible with the original Phase 2.3 trigger. Verifies the
//     continuous above_d1 edge detection (no arm-time spurious fire).
//   ADAPTIVE (cfg_adaptive_bypass = 0): boxcar prefilter, baseline EMA, MAD
//     sigma EMA, adaptive threshold = baseline - k*sigma, HOLDOFF freeze,
//     warmup gating, real negative-pulse trigger.
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_trigger;

    localparam WIDTH = 16;

    // DUT clock
    reg clk = 1'b0;
    always #5 clk = ~clk;       // 100 MHz

    reg rst_n;

    // DUT signals
    reg              arm;
    reg  [WIDTH-1:0] adc_data;
    reg              adc_dv;

    reg  [WIDTH-1:0] cfg_threshold;
    reg  [WIDTH-1:0] cfg_hysteresis;
    reg  [23:0]      cfg_holdoff;
    reg              cfg_polarity;
    reg              cfg_adaptive_bypass;

    reg  [47:0]      sample_count;

    wire             trigger_pulse;
    wire             armed;
    wire             triggered;
    wire [47:0]      event_timestamp;
    wire [15:0]      dbg_baseline;
    wire [15:0]      dbg_sigma;

    dbg_pkg::dbg_info_t dbg_info;

    trigger #(
        .WIDTH(WIDTH),
        .BOXCAR_N(8),
        .K_SIGMA(5),
        .EMA_SHIFT(8),
        .WARMUP(1024)
    ) u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .arm            (arm),
        .adc_data       (adc_data),
        .adc_dv         (adc_dv),
        .cfg_threshold  (cfg_threshold),
        .cfg_hysteresis (cfg_hysteresis),
        .cfg_holdoff    (cfg_holdoff),
        .cfg_polarity   (cfg_polarity),
        .cfg_adaptive_bypass(cfg_adaptive_bypass),
        .sample_count   (sample_count),
        .trigger_pulse  (trigger_pulse),
        .armed          (armed),
        .triggered      (triggered),
        .event_timestamp(event_timestamp),
        .dbg_baseline   (dbg_baseline),
        .dbg_sigma      (dbg_sigma),
        .dbg_info       (dbg_info)
    );

    // -------------------------------------------------------------------------
    // Sticky latches for 1-cycle signals
    // -------------------------------------------------------------------------
    reg saw_trigger;
    reg saw_triggered;

    always @(posedge clk) begin
        if (trigger_pulse)  saw_trigger   <= 1'b1;
        if (triggered)      saw_triggered <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // Test infrastructure
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
            $display("  %0d. FAIL: %s  (got state=%0d base=%0d sig=%0d trig=%0d)",
                     test_id, name, dbg_info.state, dbg_baseline, dbg_sigma, dbg_info.event_count);
            fail_count++;
        end
    endtask

    task send_seq(input int n, input [WIDTH-1:0] vals []);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                adc_data = vals[i];
                adc_dv   = 1'b1;
                @(posedge clk);
            end
            @(negedge clk);
            adc_dv   = 1'b0;
        end
    endtask

    // Feed n samples of a constant value
    task send_const(input int n, input [WIDTH-1:0] val);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                adc_data = val;
                adc_dv   = 1'b1;
                @(posedge clk);
            end
            @(negedge clk);
            adc_dv = 1'b0;
        end
    endtask

    // Feed n samples of baseline +/- amp (alternating) — deterministic noise
    task send_noise(input int n, input [WIDTH-1:0] base, input [WIDTH-1:0] amp);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                adc_data = (i[0]) ? (base - amp) : (base + amp);
                adc_dv   = 1'b1;
                @(posedge clk);
            end
            @(negedge clk);
            adc_dv = 1'b0;
        end
    endtask

    // Feed a negative-going pulse: ramp from base down to depth over ramp_n,
    // then hold depth for hold_n samples.
    task send_neg_pulse(input [WIDTH-1:0] base, input [WIDTH-1:0] depth,
                        input int ramp_n, input int hold_n);
        integer i;
        reg [WIDTH-1:0] step;
        begin
            step = (base - depth) / ramp_n;
            for (i = 0; i < ramp_n; i = i + 1) begin
                @(negedge clk);
                adc_data = base - (step * i);
                adc_dv   = 1'b1;
                @(posedge clk);
            end
            for (i = 0; i < hold_n; i = i + 1) begin
                @(negedge clk);
                adc_data = depth;
                adc_dv   = 1'b1;
                @(posedge clk);
            end
            @(negedge clk);
            adc_dv = 1'b0;
        end
    endtask

    task reset_dut();
        begin
            rst_n               = 1'b0;
            arm                 = 1'b0;
            adc_dv              = 1'b0;
            cfg_threshold       = 16'd0;
            cfg_hysteresis      = 16'd0;
            cfg_holdoff         = 24'd0;
            cfg_polarity        = 1'b0;
            cfg_adaptive_bypass = 1'b1;   // legacy default
            sample_count        = 48'd0;
            saw_trigger         = 1'b0;
            saw_triggered       = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task clear_latches();
        begin
            saw_trigger   = 1'b0;
            saw_triggered = 1'b0;
        end
    endtask

    function automatic [15:0] trig_count();
        return dbg_info.event_count;
    endfunction

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("========================================================================");
        $display("  tb_trigger — Phase 2.3b (adaptive boxcar + MAD)");
        $display("========================================================================");
        $display("");

        // =====================================================================
        // LEGACY GROUP (bypass = 1) — fixed-threshold leading edge
        // =====================================================================

        // ---------------------------------------------------------------------
        // Test 1: IDLE state — no trigger when !arm
        // ---------------------------------------------------------------------
        $display("--- Test 1: IDLE state (bypass) ---");
        reset_dut();
        cfg_threshold  = 16'd1000;
        cfg_hysteresis = 16'd100;
        cfg_holdoff    = 24'd20;
        cfg_polarity   = 1'b0;
        cfg_adaptive_bypass = 1'b1;

        arm = 1'b0;
        send_seq(5, '{16'd500, 16'd1500, 16'd2000, 16'd2500, 16'd3000});
        @(negedge clk);

        check("state = IDLE (0)",          dbg_info.state == 4'd0);
        check("armed = 0",                 armed          == 1'b0);
        check("trigger_pulse = 0",         trigger_pulse  == 1'b0);
        check("trigger_count = 0",         trig_count()   == 16'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 2: DETECT — trigger fires on rising edge
        // ---------------------------------------------------------------------
        $display("--- Test 2: DETECT rising edge (bypass) ---");
        reset_dut();
        cfg_threshold  = 16'd1000;
        cfg_hysteresis = 16'd100;
        cfg_holdoff    = 24'd20;
        cfg_polarity   = 1'b0;
        cfg_adaptive_bypass = 1'b1;

        clear_latches();
        arm = 1'b1;
        sample_count = 48'd12345;
        send_seq(4, '{16'd500, 16'd800, 16'd900, 16'd1500});
        @(negedge clk);

        check("saw_trigger = 1",            saw_trigger  == 1'b1);
        check("state = HOLDOFF (3)",        dbg_info.state == 4'd3);
        check("armed = 0 (in holdoff)",     armed         == 1'b0);
        check("trigger_count = 1",          trig_count()  == 16'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 3: HOLDOFF — no re-trigger during hold-off
        // ---------------------------------------------------------------------
        $display("--- Test 3: HOLDOFF no re-trigger (bypass) ---");
        clear_latches();
        send_seq(10, '{16'd2000, 16'd3000, 16'd4000, 16'd5000, 16'd6000,
                       16'd7000, 16'd8000, 16'd9000, 16'd10000, 16'd11000});
        @(negedge clk);

        check("saw_trigger = 0 (no re-trigger)", saw_trigger == 1'b0);
        check("trigger_count still 1",           trig_count() == 16'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 4: Re-arm after hold-off
        // ---------------------------------------------------------------------
        $display("--- Test 4: Re-arm after hold-off (bypass) ---");
        clear_latches();
        send_const(25, 16'd50);
        @(negedge clk);

        check("state = DETECT (1) after holdoff", dbg_info.state == 4'd1);
        check("armed = 1",                        armed         == 1'b1);

        sample_count = 48'd67890;
        send_seq(3, '{16'd500, 16'd800, 16'd2000});
        @(negedge clk);

        check("saw_trigger (re-arm)",          saw_trigger  == 1'b1);
        check("trigger_count = 2",             trig_count() == 16'd2);
        check("state = HOLDOFF after re-trigger", dbg_info.state == 4'd3);

        $display("");

        // ---------------------------------------------------------------------
        // Test 5: Disarm during detection
        // ---------------------------------------------------------------------
        $display("--- Test 5: Disarm (bypass) ---");
        clear_latches();
        send_const(25, 16'd50);
        @(negedge clk);

        check("state = DETECT",  dbg_info.state == 4'd1);
        check("armed = 1",       armed         == 1'b1);

        arm = 1'b0;
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        check("state = IDLE after disarm", dbg_info.state == 4'd0);
        check("armed = 0 after disarm",    armed         == 1'b0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 6: Negative-edge polarity (bypass)
        // ---------------------------------------------------------------------
        $display("--- Test 6: Negative-edge polarity (bypass) ---");
        reset_dut();
        cfg_threshold  = 16'd5000;
        cfg_hysteresis = 16'd100;
        cfg_holdoff    = 24'd20;
        cfg_polarity   = 1'b1;
        cfg_adaptive_bypass = 1'b1;

        clear_latches();
        arm = 1'b1;
        send_seq(4, '{16'd8000, 16'd7000, 16'd6000, 16'd4000});
        @(negedge clk);

        check("saw_trigger (neg edge)",          saw_trigger == 1'b1);
        check("trigger_count = 1 (neg edge)",    trig_count() == 16'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 7: No arm-time spurious fire when signal already past threshold
        // (regression for the old above_d1 mis-seed bug)
        // ---------------------------------------------------------------------
        $display("--- Test 7: no spurious fire at ARM (bypass) ---");
        reset_dut();
        cfg_threshold  = 16'd5000;
        cfg_hysteresis = 16'd100;
        cfg_holdoff    = 24'd20;
        cfg_polarity   = 1'b1;        // neg edge: above = (adc < 5000)
        cfg_adaptive_bypass = 1'b1;

        // Establish a signal already BELOW threshold (4000 < 5000) while !arm
        send_const(5, 16'd4000);
        @(negedge clk);
        clear_latches();
        // Now arm — must NOT fire immediately (above_d1 already = 1 from 4000)
        arm = 1'b1;
        send_const(5, 16'd4000);
        @(negedge clk);

        check("no spurious trigger at arm", saw_trigger == 1'b0);
        check("state = DETECT (armed, no fire)", dbg_info.state == 4'd1);
        check("trigger_count = 0",          trig_count() == 16'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 8: Timestamp latches sample_count (bypass)
        // ---------------------------------------------------------------------
        $display("--- Test 8: Timestamp (bypass) ---");
        reset_dut();
        cfg_threshold  = 16'd1000;
        cfg_hysteresis = 16'd100;
        cfg_holdoff    = 24'd20;
        cfg_polarity   = 1'b0;
        cfg_adaptive_bypass = 1'b1;

        clear_latches();
        arm = 1'b1;
        sample_count = 48'd2000;
        send_seq(3, '{16'd500, 16'd800, 16'd1500});
        @(negedge clk);

        check("event_timestamp non-zero",     event_timestamp != 48'd0);
        check("event_timestamp < 48'h100000", event_timestamp < 48'h100000);

        $display("");

        // ---------------------------------------------------------------------
        // Test 9: dbg_if fields (bypass mode)
        // ---------------------------------------------------------------------
        $display("--- Test 9: dbg_if fields (bypass) ---");
        reset_dut();
        cfg_adaptive_bypass = 1'b1;
        check("dbg state = IDLE",       dbg_info.state       == 4'd0);
        check("dbg bypass_mode = 1",    dbg_info.bypass_mode == 1'b1);
        check("dbg event_count = 0",    dbg_info.event_count == 16'd0);
        check("dbg word_count = 0",     dbg_info.word_count  == 16'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 10: Reset
        // ---------------------------------------------------------------------
        $display("--- Test 10: Reset ---");
        arm = 1'b1;
        cfg_threshold = 16'd1000;
        cfg_adaptive_bypass = 1'b1;
        send_seq(3, '{16'd500, 16'd800, 16'd1500});
        @(negedge clk);
        reset_dut();

        check("state = IDLE after reset",     dbg_info.state == 4'd0);
        check("event_count = 0 after reset",  dbg_info.event_count == 16'd0);
        check("word_count = 0 after reset",   dbg_info.word_count  == 16'd0);
        check("armed = 0 after reset",        armed == 1'b0);

        $display("");

        // =====================================================================
        // ADAPTIVE GROUP (bypass = 0) — boxcar + baseline/sigma EMA
        // =====================================================================

        // ---------------------------------------------------------------------
        // Test 11: Baseline EMA converges to signal baseline
        // ---------------------------------------------------------------------
        $display("--- Test 11: baseline EMA convergence (adaptive) ---");
        reset_dut();
        cfg_threshold       = 16'd8000;
        cfg_hysteresis      = 16'd100;
        cfg_holdoff         = 24'd300;     // long enough to span pulse + freeze check
        cfg_polarity        = 1'b1;     // negative edge
        cfg_adaptive_bypass = 1'b0;

        arm = 1'b1;
        // 4000 samples of baseline 8400 +/- 4 → baseline -> 8400, sigma -> 4
        send_noise(4000, 16'd8400, 16'd4);
        @(negedge clk);

        check("baseline ~= 8400 (within 50)",  (dbg_baseline >= 16'd8350) && (dbg_baseline <= 16'd8450));
        check("sigma ~= 4 (within 2)",         (dbg_sigma     >= 16'd3)   && (dbg_sigma     <= 16'd6));
        check("no trigger during baseline",    trig_count() == 16'd0);
        check("state = DETECT (armed, no fire)", dbg_info.state == 4'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 12: Adaptive negative-pulse trigger fires
        // ---------------------------------------------------------------------
        $display("--- Test 12: adaptive neg-pulse fires ---");
        // Continue from Test 11 (armed, baseline converged, no trigger yet)
        clear_latches();
        // Negative pulse: 8400 -> 4000 over 40 samples, hold 50
        send_neg_pulse(16'd8400, 16'd4000, 40, 50);
        @(negedge clk);

        check("saw_trigger on neg pulse",       saw_trigger == 1'b1);
        check("trigger_count = 1",              trig_count() == 16'd1);
        check("state = HOLDOFF after fire",     dbg_info.state == 4'd3);

        $display("");

        // ---------------------------------------------------------------------
        // Test 13: Baseline/sigma FROZEN during HOLDOFF (no pulse chase)
        // ---------------------------------------------------------------------
        $display("--- Test 13: baseline frozen during HOLDOFF ---");
        // Capture baseline right after trigger (frozen during HOLDOFF)
        // cfg_holdoff = 100. Feed 50 samples at 4000 (off baseline) while in
        // HOLDOFF — baseline must NOT move toward 4000.
        clear_latches();
        send_const(50, 16'd4000);
        @(negedge clk);

        check("baseline still ~= 8400 (frozen)", (dbg_baseline >= 16'd8350) && (dbg_baseline <= 16'd8450));
        check("still in HOLDOFF",                 dbg_info.state == 4'd3);

        $display("");

        // ---------------------------------------------------------------------
        // Test 14: Baseline resumes tracking after HOLDOFF expires
        //          (demonstrates the freeze is HOLDOFF-gated, not permanent)
        // ---------------------------------------------------------------------
        $display("--- Test 14: baseline resumes after HOLDOFF ---");
        // Feed enough 4000-samples to expire holdoff (300) and start chasing.
        // After holdoff expires, baseline EMA moves toward 4000.
        send_const(600, 16'd4000);
        @(negedge clk);

        check("baseline dropped toward 4000 (tracking resumed)",
              dbg_baseline < 16'd7000);
        check("state = DETECT (holdoff expired)", dbg_info.state == 4'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 15: Warmup gating — no fire before WARMUP samples
        // ---------------------------------------------------------------------
        $display("--- Test 15: warmup gating (no early fire) ---");
        reset_dut();
        cfg_threshold       = 16'd8000;
        cfg_hysteresis      = 16'd100;
        cfg_holdoff         = 24'd100;
        cfg_polarity        = 1'b1;
        cfg_adaptive_bypass = 1'b0;

        clear_latches();
        arm = 1'b1;
        // Immediately send a strong negative pulse (only 50 samples << 1024)
        send_neg_pulse(16'd8400, 16'd2000, 10, 40);
        @(negedge clk);

        check("no trigger before warmup",       saw_trigger == 1'b0);
        check("trigger_count = 0 (warmup)",     trig_count() == 16'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 16: Adaptive fires after warmup completes
        // ---------------------------------------------------------------------
        $display("--- Test 16: adaptive fires after warmup ---");
        // Feed enough baseline to pass warmup (1024) and converge, then pulse.
        clear_latches();
        send_noise(2000, 16'd8400, 16'd4);
        send_neg_pulse(16'd8400, 16'd3000, 20, 50);
        @(negedge clk);

        check("saw_trigger after warmup+pulse", saw_trigger == 1'b1);
        check("trigger_count = 1",              trig_count() == 16'd1);

        $display("");

        // ---------------------------------------------------------------------
        // Test 17: dbg_if fields (adaptive mode)
        // ---------------------------------------------------------------------
        $display("--- Test 17: dbg_if fields (adaptive) ---");
        reset_dut();
        cfg_adaptive_bypass = 1'b0;
        check("dbg bypass_mode = 0 (adaptive)", dbg_info.bypass_mode == 1'b0);
        check("dbg state = IDLE",               dbg_info.state       == 4'd0);

        $display("");

        // ---------------------------------------------------------------------
        // Test 18: Reset clears adaptive state
        // ---------------------------------------------------------------------
        $display("--- Test 18: Reset (adaptive) ---");
        arm = 1'b1;
        cfg_adaptive_bypass = 1'b0;
        cfg_polarity = 1'b1;
        send_noise(2000, 16'd8400, 16'd4);
        send_neg_pulse(16'd8400, 16'd3000, 20, 50);
        @(negedge clk);
        reset_dut();

        check("state = IDLE after reset",      dbg_info.state == 4'd0);
        check("event_count = 0 after reset",   dbg_info.event_count == 16'd0);
        check("baseline = 0 after reset",      dbg_baseline == 16'd0);
        check("sigma = 0 after reset",         dbg_sigma == 16'd0);

        $display("");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("  *** tb_trigger FAILED ***");
            $fatal(1, "FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("  ** tb_trigger PASSED **");
        end

        $finish;
    end

    // Timeout watchdog (200 ms — adaptive tests run ~20k samples)
    initial begin
        #200_000_000;
        $display("  *** tb_trigger TIMEOUT ***");
        $fatal(1, "Testbench timed out");
    end

    // Free-running sample counter — increments while adc_dv=1.
    initial begin
        sample_count = 48'd0;
        forever begin
            @(posedge clk);
            if (adc_dv) sample_count <= sample_count + 1'b1;
        end
    end

endmodule : tb_trigger
