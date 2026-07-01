//------------------------------------------------------------------------------
// trigger.sv
//
// Adaptive Negative-Pulse Trigger with Boxcar Prefilter and Baseline/Noise
// Tracking (data_engine — Phase 2.3b upgrade, 2026-07-01).
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Replaces the fixed-threshold leading-edge trigger of Phase 2.3 with an
// adaptive scheme per `Downloads/fpga_trigger_upgrade_spec.md`:
//
//   ADC samples → boxcar moving sum → compare vs adaptive threshold → fire
//                                              ↑
//                          baseline/σ EMA tracker (gated by HOLDOFF)
//
// Two operating modes (selected by cfg_adaptive_bypass):
//
//   cfg_adaptive_bypass = 0  (ADAPTIVE, default)
//     - 1-add/1-sub sliding boxcar (depth BOXCAR_N) low-passes the sample
//       stream (SNR gain ~√N) before the threshold test.
//     - Threshold = baseline ± k·σ, where:
//         baseline = EMA of the (glitch-filtered) input   (shift EMA_SHIFT)
//         σ        = EMA of |sample − baseline| (MAD)      (shift EMA_SHIFT)
//       MAD (mean absolute deviation) is used instead of variance so no
//       hardware multiplier is needed (Q2 = MAD choice).
//     - Baseline & σ EMAs are FROZEN while the FSM is in HOLDOFF (the
//       "busy" flag) so they cannot chase the pulse itself. This gating is
//       mandatory per the spec; CFG_HOLDOFF must therefore be >= the pulse
//       decay time (set to 60 µs in top_pipeline for the 50 µs decay).
//     - The boxcar AVERAGE (sum >> log2 N) is compared — keeps threshold in
//       single-sample units so baseline/σ are directly comparable.
//
//   cfg_adaptive_bypass = 1  (LEGACY / DEBUG)
//     - Raw adc_data compared against cfg_threshold (original Phase 2.3
//       behaviour). Used by the fixed-threshold unit tests and the
//       top_pipeline integration testbench (positive-edge pulse).
//
// Edge detection (both modes):
//   above_d1 now tracks above_threshold on EVERY adc_dv cycle (not only
//   inside DETECT), so above_rise = above_threshold && !above_d1 is a true
//   level-crossing edge. This removes the arm-time spurious-fire bug of the
//   previous version (which only updated above_d1 in DETECT and mis-seeded
//   it on entry, firing immediately when armed on a signal already past
//   threshold — the "fires on baseline at ARM" HW symptom).
//
// FSM states (unchanged from Phase 2.3):
//   0 IDLE      — waiting for arm
//   1 DETECT    — looking for threshold crossing
//   2 ACQUIRE   — reserved (sig_recorder does not use this state)
//   3 HOLDOFF   — post-trigger, preventing re-trigger + baseline freeze
//
// Parameters:
//   WIDTH         — ADC sample width (16; 14-bit ADC zero-padded)
//   BOXCAR_N      — boxcar window depth, MUST be a power of 2 (default 8)
//   K_SIGMA       — threshold = baseline ± k·σ (default 5; tune 4–6)
//   EMA_SHIFT     — EMA averaging constant = 1/2^shift (default 8 → 1/256)
//   WARMUP        — samples tracked before adaptive trigger may fire
//                   (lets baseline/σ converge; default 1024 ≈ 10 µs)
//
// Debug outputs:
//   dbg_baseline  — current EMA baseline (adaptive mode)
//   dbg_sigma     — current EMA MAD noise estimate (adaptive mode)
//   dbg_info      — state, trigger_count, holdoff_remaining, crossing_count,
//                   rejected_count, bypass_mode, baseline, sigma
//------------------------------------------------------------------------------

`default_nettype none

module trigger #(
    parameter WIDTH      = 16,     // ADC sample width
    parameter BOXCAR_N   = 8,      // boxcar depth (MUST be power of 2)
    parameter K_SIGMA    = 5,      // threshold = baseline ± k·sigma
    parameter EMA_SHIFT  = 8,      // EMA constant = 1/2^EMA_SHIFT
    parameter WARMUP     = 1024    // warmup samples before adaptive fire
) (
    input  wire              clk,            // 100 MHz system clock
    input  wire              rst_n,          // active-low reset

    // ---- Arm + sample stream ----
    input  wire              arm,            // 1 = enable trigger detection
    input  wire [WIDTH-1:0]  adc_data,       // ADC data (glitch-filtered)
    input  wire              adc_dv,         // data valid strobe

    // ---- Configuration (from register map) ----
    input  wire [WIDTH-1:0]  cfg_threshold,     // trigger level (bypass mode)
    input  wire [WIDTH-1:0]  cfg_hysteresis,    // (reserved, bypass-mode legacy)
    input  wire [23:0]       cfg_holdoff,       // hold-off cycles + baseline freeze
    input  wire              cfg_polarity,      // 0 = positive edge, 1 = negative
    input  wire              cfg_adaptive_bypass, // 1=fixed-thr legacy, 0=adaptive

    // ---- Global sample counter (48-bit) for event timestamps ----
    input  wire [47:0]       sample_count,

    // ---- Outputs ----
    output reg               trigger_pulse,  // 1-cycle pulse on trigger event
    output reg               armed,          // 1 = ready to detect, 0 = in hold-off
    output reg               triggered,      // 1 = trigger occurred, in acquisition
    output reg  [47:0]       event_timestamp,// latched sample_count at trigger_pulse

    // ---- Debug interface ----
    output wire [15:0]       dbg_baseline,   // EMA baseline (adaptive)
    output wire [15:0]       dbg_sigma,      // EMA MAD noise (adaptive)
    output dbg_pkg::dbg_info_t dbg_info
);

    import dbg_pkg::*;

    // =========================================================================
    // Boxcar moving-sum prefilter
    //   sum_new = sum_old + sample_in - sample_out   (1 add + 1 sub / clock)
    //   delay_line[0]      = newest sample (1 cycle ago)
    //   delay_line[N-1]    = oldest sample (N cycles ago) — leaves the window
    //   A fill counter gates the output until the window is full.
    // =========================================================================
    localparam BOXCAR_SHIFT = $clog2(BOXCAR_N);        // log2(N)
    localparam SUMW         = WIDTH + BOXCAR_SHIFT + 1;// sum width (+1 headroom)

    reg [WIDTH-1:0] delay_line [0:BOXCAR_N-1];
    reg [SUMW-1:0]  boxcar_sum;
    reg [BOXCAR_SHIFT:0] fill_cnt;        // 0..BOXCAR_N (saturates at N)

    wire boxcar_valid = (fill_cnt == BOXCAR_N);

    integer k;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boxcar_sum <= {SUMW{1'b0}};
            fill_cnt   <= {(BOXCAR_SHIFT+1){1'b0}};
            for (k = 0; k < BOXCAR_N; k = k + 1)
                delay_line[k] <= {WIDTH{1'b0}};
        end else if (adc_dv) begin
            // shift in newest, drop oldest
            delay_line[0] <= adc_data;
            for (k = 1; k < BOXCAR_N; k = k + 1)
                delay_line[k] <= delay_line[k-1];
            // sliding sum
            if (boxcar_valid)
                boxcar_sum <= boxcar_sum + adc_data - delay_line[BOXCAR_N-1];
            else
                boxcar_sum <= boxcar_sum + adc_data;
            // fill counter (saturates at BOXCAR_N)
            if (fill_cnt < BOXCAR_N)
                fill_cnt <= fill_cnt + 1'b1;
        end
    end

    // Boxcar average = sum >> log2(N)  (back to single-sample units)
    wire [WIDTH-1:0] boxcar_avg = boxcar_sum[SUMW-1:BOXCAR_SHIFT];

    // =========================================================================
    // Baseline + noise (MAD) EMA trackers — gated by HOLDOFF (the "busy" flag)
    //   baseline <- baseline + (sample - baseline) >> EMA_SHIFT
    //   sigma    <- sigma    + (|sample-baseline| - sigma) >> EMA_SHIFT
    // Frozen while state == HOLDOFF so they cannot chase the pulse tail.
    // Disabled in bypass mode (not needed for fixed-threshold detection).
    // =========================================================================
    // Fixed-point accumulators (EMA_SHIFT fractional bits). Retaining the
    // fractional residue is essential: a naive (sample-baseline)>>>SHIFT step
    // truncates to integer and stalls within ±2^SHIFT of the target (±256 at
    // SHIFT=8) — far too coarse for a 14-bit signal. Fixed point converges to
    // within ±1 LSB of the integer extract.
    localparam FPW = WIDTH + EMA_SHIFT + 1;          // +1 sign bit

    reg signed [FPW-1:0] baseline_fp;                // baseline * 2^EMA_SHIFT
    reg signed [FPW-1:0] sigma_fp;                   // sigma    * 2^EMA_SHIFT

    // Integer extracts (for threshold compare + debug output)
    wire [WIDTH-1:0] baseline  = baseline_fp[WIDTH+EMA_SHIFT-1 : EMA_SHIFT];
    wire [WIDTH-1:0] sigma_mad = sigma_fp   [WIDTH+EMA_SHIFT-1 : EMA_SHIFT];

    // Sample scaled to fixed-point units
    wire signed [FPW-1:0] sample_fp =
        $signed({{(FPW-WIDTH){1'b0}}, adc_data}) <<< EMA_SHIFT;

    // Baseline EMA step (accumulator keeps fractional residue)
    wire signed [FPW-1:0] b_err  = sample_fp - baseline_fp;
    wire signed [FPW-1:0] b_step = b_err >>> EMA_SHIFT;
    wire signed [FPW-1:0] b_new  = baseline_fp + b_step;

    // Sigma (MAD) EMA step: |sample - baseline_int| scaled, accumulated
    wire signed [WIDTH+1:0] diff_int = $signed({2'b0, adc_data}) -
                                       $signed({2'b0, baseline});
    wire signed [WIDTH+1:0] abs_int  = diff_int[WIDTH+1] ? -diff_int : diff_int;
    wire signed [FPW-1:0]   abs_fp   =
        $signed({{(FPW-WIDTH-2){1'b0}}, abs_int}) <<< EMA_SHIFT;
    wire signed [FPW-1:0]   m_err    = abs_fp - sigma_fp;
    wire signed [FPW-1:0]   m_step   = m_err >>> EMA_SHIFT;
    wire signed [FPW-1:0]   m_new    = sigma_fp + m_step;

    // Freeze baseline/sigma while the FSM is busy (HOLDOFF). Forward-declared
    // wire driven by an assign below the FSM.
    wire baseline_freeze;
    wire en_track = adc_dv && !cfg_adaptive_bypass && !baseline_freeze;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baseline_fp <= {FPW{1'b0}};
            sigma_fp    <= {FPW{1'b0}};
        end else if (en_track) begin
            baseline_fp <= b_new;
            sigma_fp    <= m_new;
        end
    end

    // =========================================================================
    // Adaptive threshold:  thr = baseline ± k·sigma
    // =========================================================================
    wire signed [22:0] baseline_s = $signed({7'b0, baseline});
    wire signed [22:0] sigma_s    = $signed({7'b0, sigma_mad});
    wire signed [22:0] k_sigma    = K_SIGMA * sigma_s;
    wire signed [22:0] thr_neg    = baseline_s - k_sigma;   // negative-edge
    wire signed [22:0] thr_pos    = baseline_s + k_sigma;   // positive-edge
    wire signed [22:0] adaptive_thr = cfg_polarity ? thr_neg : thr_pos;

    // =========================================================================
    // Warmup counter — adaptive trigger may only fire after WARMUP samples
    // after arm goes high (lets baseline/sigma converge). arm_rise resets the
    // counter so the tracker converges fresh on every ARM.
    // =========================================================================
    reg        arm_d1;
    wire       arm_rise;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) arm_d1 <= 1'b0;
        else        arm_d1 <= arm;
    end
    assign arm_rise = arm && !arm_d1;

    reg [15:0] warmup_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                warmup_cnt <= 16'd0;
        else if (arm_rise)                         warmup_cnt <= 16'd0;
        else if (adc_dv && warmup_cnt < WARMUP)      warmup_cnt <= warmup_cnt + 1'b1;
    end
    wire adaptive_ready = (warmup_cnt >= WARMUP) && boxcar_valid;

    // =========================================================================
    // Level-crossing comparison
    //   bypass   : raw adc_data   vs cfg_threshold
    //   adaptive : boxcar_avg     vs adaptive_thr  (baseline ± k·sigma)
    // =========================================================================
    wire signed [22:0] adc_s        = $signed({7'b0, adc_data});
    wire signed [22:0] boxcar_avg_s = $signed({7'b0, boxcar_avg});
    wire signed [22:0] thr_fixed    = $signed({7'b0, cfg_threshold});

    wire cross_adaptive = cfg_polarity ? (boxcar_avg_s < adaptive_thr)
                                       : (boxcar_avg_s > adaptive_thr);
    wire cross_fixed    = cfg_polarity ? (adc_s < thr_fixed)
                                       : (adc_s > thr_fixed);

    wire above_threshold = cfg_adaptive_bypass ? cross_fixed : cross_adaptive;

    // Fire enable: bypass needs only adc_dv; adaptive needs the boxcar full and
    // warmup elapsed.
    wire trigger_enable = cfg_adaptive_bypass ? adc_dv
                                              : (adc_dv && adaptive_ready);

    // =========================================================================
    // Edge detection — above_d1 tracks above_threshold on EVERY adc_dv cycle
    // (continuous, not only in DETECT). above_rise is therefore a true
    // level-crossing edge with no arm-time spurious fire.
    // =========================================================================
    reg above_d1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        above_d1 <= 1'b0;
        else if (adc_dv)   above_d1 <= above_threshold;
    end
    wire above_rise = above_threshold && !above_d1 && trigger_enable;

    // =========================================================================
    // FSM
    // =========================================================================
    localparam [1:0] IDLE    = 2'd0,
                     DETECT  = 2'd1,
                     ACQUIRE = 2'd2,   // reserved (not used)
                     HOLDOFF = 2'd3;

    reg [1:0]  state;
    reg [23:0] holdoff_cnt;

    // baseline_freeze = busy flag (HOLDOFF). Declared as wire above; driven here.
    // (Verilog allows forward use of a wire that is driven by an assign below.)
    // -------------------------------------------------------------------------
    // Main state machine + outputs
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            trigger_pulse    <= 1'b0;
            armed            <= 1'b0;
            triggered        <= 1'b0;
            holdoff_cnt      <= 24'd0;
            event_timestamp  <= 48'd0;
        end else begin
            trigger_pulse <= 1'b0;        // default: 1-cycle pulse

            case (state)
                // ----------------------------------------------------------------
                // IDLE: waiting for arm
                // ----------------------------------------------------------------
                IDLE: begin
                    armed     <= 1'b0;
                    triggered <= 1'b0;
                    if (arm) state <= DETECT;
                end

                // ----------------------------------------------------------------
                // DETECT: looking for threshold crossing
                // ----------------------------------------------------------------
                DETECT: begin
                    armed     <= 1'b1;
                    triggered <= 1'b0;
                    if (!arm) begin
                        state <= IDLE;
                    end else if (above_rise) begin
                        trigger_pulse   <= 1'b1;
                        triggered       <= 1'b1;
                        holdoff_cnt     <= 24'd0;
                        event_timestamp <= sample_count;
                        state           <= HOLDOFF;
                    end
                end

                // ----------------------------------------------------------------
                // HOLDOFF: no triggers allowed + baseline/sigma frozen
                // Prevents re-triggering on the same pulse tail.
                // ----------------------------------------------------------------
                HOLDOFF: begin
                    armed     <= 1'b0;
                    triggered <= 1'b0;
                    if (!arm) begin
                        state <= IDLE;
                    end else if (adc_dv) begin
                        if (holdoff_cnt >= cfg_holdoff) begin
                            state <= DETECT;
                        end else begin
                            holdoff_cnt <= holdoff_cnt + 1'b1;
                        end
                    end
                end

                // ----------------------------------------------------------------
                // ACQUIRE: reserved (safety: don't get stuck)
                // ----------------------------------------------------------------
                ACQUIRE: begin
                    armed     <= 1'b1;
                    triggered <= 1'b0;
                    if (!arm) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // baseline_freeze = 1 in IDLE or HOLDOFF. Prevents the tracker from chasing
    // pulses that arrive before ARM (IDLE) or during post-trigger (HOLDOFF).
    // The tracker only runs while actively searching in DETECT.
    assign baseline_freeze = (state == IDLE) || (state == HOLDOFF);

    // =========================================================================
    // Debug counters
    // =========================================================================
    reg [15:0] trigger_count;      // total triggers accepted
    reg [15:0] rejected_count;     // crossings seen during HOLDOFF (rejected)
    reg [15:0] crossing_count;     // raw level crossings (for rate calc)
    reg [23:0] holdoff_remaining;  // live hold-off counter

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trigger_count     <= 16'd0;
            rejected_count    <= 16'd0;
            crossing_count    <= 16'd0;
            holdoff_remaining <= 24'd0;
        end else begin
            // Live holdoff remaining
            if (state == HOLDOFF)
                holdoff_remaining <= cfg_holdoff - holdoff_cnt;
            else
                holdoff_remaining <= 24'd0;

            // Count level crossings (any time adc_dv && above_threshold)
            if (adc_dv && above_threshold)
                crossing_count <= crossing_count + 1'b1;

            // Count accepted triggers
            if (trigger_pulse)
                trigger_count <= trigger_count + 1'b1;

            // Count rejected attempts (above_threshold while in HOLDOFF)
            if (adc_dv && above_threshold && state == HOLDOFF && !trigger_pulse)
                rejected_count <= rejected_count + 1'b1;
        end
    end

    assign dbg_baseline = baseline;
    assign dbg_sigma    = sigma_mad;

    // =========================================================================
    // dbg_info output (positional concatenation for iverilog compat).
    // Layout (Architecture.md §5 + dbg_pkg.sv):
    //   [127:124] state           — 0=IDLE,1=DETECT,2=ACQUIRE,3=HOLDOFF
    //   [123:108] cycle_count     — trigger_count
    //   [107:100] stall_cycles    — holdoff_remaining (low 8 bits)
    //   [99:96]   reserved
    //   [95]      error           — 0
    //   [94:87]   error_id        — 0
    //   [86]      bypass_mode     — cfg_adaptive_bypass
    //   [85:80]   reserved
    //   [79:64]   baseline[15:0]  — EMA baseline (adaptive)
    //   [63:48]   event_count     — trigger_count
    //   [47:32]   reserved_2      — sigma_mad (MAD noise estimate)
    //   [31:16]   word_count      — crossing_count
    //   [15:0]    reserved_3      — rejected_count
    // =========================================================================
    assign dbg_info = {
        state,                         // [127:124] FSM state
        trigger_count,                 // [123:108] trigger_count
        holdoff_remaining[7:0],        // [107:100] holdoff remaining (low 8)
        4'd0,                          // [99:96]   reserved
        1'b0,                          // [95]      error
        8'd0,                          // [94:87]   error_id
        cfg_adaptive_bypass,           // [86]      bypass_mode
        6'd0,                          // [85:80]   reserved
        baseline,                      // [79:64]   EMA baseline
        trigger_count,                 // [63:48]   event_count
        sigma_mad,                     // [47:32]   MAD noise estimate
        crossing_count,                // [31:16]   word_count (crossings)
        rejected_count                 // [15:0]    rejected count
    };

endmodule : trigger

`default_nettype wire
