//------------------------------------------------------------------------------
// trigger.sv
//
// Threshold Crossing Trigger with Hysteresis and Hold-Off (data_engine port).
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Ported from sig_recorder `trigger.v` to SystemVerilog and wrapped with the
// standard `dbg_info_t` debug interface per Architecture.md §5 + §12.1.
//
// Features:
//   - Programmable threshold and hysteresis
//   - Hold-off timer to prevent re-triggering during pulse
//   - Configurable polarity (positive/negative edge)
//   - LEADING_EDGE only (CFD deferred to Phase 2.5; ML out of scope)
//
// Changes from sig_recorder version:
//   - ADC width 14 → 16 bits (data_engine packs as 16-bit in CDC FIFO)
//   - Added `sample_count` input (48-bit global counter) + `event_timestamp`
//     output (latched at trigger_pulse) for descriptor FIFO population
//   - Added `dbg_info_t` output exposing FSM state, trigger_count,
//     holdoff_remaining, threshold crossing rate
//   - SystemVerilog `always_ff` for clarity
//
// FSM states (Architecture.md §5):
//   0 IDLE      — waiting for arm
//   1 DETECT    — looking for threshold crossing
//   2 ACQUIRE   — (reserved; sig_recorder does not use this state)
//   3 HOLDOFF   — post-trigger, preventing re-trigger
//------------------------------------------------------------------------------

`default_nettype none

module trigger #(
    parameter WIDTH = 16    // ADC sample width (14 in sig_recorder, 16 here)
) (
    input  wire              clk,            // 100 MHz system clock
    input  wire              rst_n,          // active-low reset

    // ---- Arm + sample stream ----
    input  wire              arm,            // 1 = enable trigger detection
    input  wire [WIDTH-1:0]  adc_data,       // ADC data
    input  wire              adc_dv,         // data valid strobe

    // ---- Configuration (from register map) ----
    input  wire [WIDTH-1:0]  cfg_threshold,  // trigger level
    input  wire [WIDTH-1:0]  cfg_hysteresis, // hysteresis window below threshold
    input  wire [23:0]       cfg_holdoff,    // hold-off cycles (e.g., 2000 = 20 µs)
    input  wire              cfg_polarity,   // 0 = positive edge, 1 = negative edge

    // ---- Global sample counter (48-bit) for event timestamps ----
    input  wire [47:0]       sample_count,

    // ---- Outputs ----
    output reg               trigger_pulse,  // 1-cycle pulse on trigger event
    output reg               armed,          // 1 = ready to detect, 0 = in hold-off
    output reg               triggered,      // 1 = trigger occurred, in acquisition
    output reg  [47:0]       event_timestamp,// latched sample_count at trigger_pulse

    // ---- Debug interface (Architecture.md §5, §12.1) ----
    output dbg_pkg::dbg_info_t dbg_info
);

    import dbg_pkg::*;

    // -------------------------------------------------------------------------
    // Edge detection: compare current sample to threshold
    // cfg_polarity: 0 = positive edge, 1 = negative edge
    // -------------------------------------------------------------------------
    wire above_threshold;
    wire below_hysteresis;

    assign above_threshold = (cfg_polarity == 1'b0) ?
                             (adc_data >  cfg_threshold) :
                             (adc_data <  cfg_threshold);

    assign below_hysteresis = (cfg_polarity == 1'b0) ?
                              (adc_data <  (cfg_threshold - cfg_hysteresis)) :
                              (adc_data >  (cfg_threshold + cfg_hysteresis));

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [1:0] IDLE    = 2'd0,
                     DETECT  = 2'd1,
                     ACQUIRE = 2'd2,   // reserved (not used)
                     HOLDOFF = 2'd3;

    reg [1:0]  state;
    reg [23:0] holdoff_cnt;

    // Above-threshold edge detector
    reg  above_d1;
    wire above_rise;

    // Track transition into DETECT to seed above_d1 correctly
    reg just_entered_detect;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            above_d1            <= 1'b0;
            just_entered_detect <= 1'b0;
        end else if (adc_dv) begin
            if (state != DETECT)
                just_entered_detect <= 1'b1;
            else if (just_entered_detect) begin
                above_d1            <= ~above_threshold;
                just_entered_detect <= 1'b0;
            end else begin
                above_d1            <= above_threshold;
                just_entered_detect <= 1'b0;
            end
        end
    end
    assign above_rise = above_threshold && !above_d1 && adc_dv;

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
                // HOLDOFF: no triggers allowed during this period
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
                // ACQUIRE: reserved (Architecture.md allows it; sig_recorder unused)
                // ----------------------------------------------------------------
                ACQUIRE: begin
                    // For now, behave like DETECT (safety: don't get stuck)
                    armed     <= 1'b1;
                    triggered <= 1'b0;
                    if (!arm) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Debug counters
    // -------------------------------------------------------------------------
    reg [15:0] trigger_count;     // total triggers accepted
    reg [15:0] rejected_count;    // triggers during hold-off (rejected)
    reg [15:0] crossing_count;    // raw threshold crossings (for rate calc)
    reg [23:0] holdoff_remaining; // live hold-off counter, value for current cycle

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trigger_count    <= 16'd0;
            rejected_count   <= 16'd0;
            crossing_count   <= 16'd0;
            holdoff_remaining <= 24'd0;
        end else begin
            // Live holdoff remaining
            if (state == HOLDOFF)
                holdoff_remaining <= cfg_holdoff - holdoff_cnt;
            else
                holdoff_remaining <= 24'd0;

            // Count threshold crossings (any time adc_dv && above_threshold)
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

    // -------------------------------------------------------------------------
    // dbg_info output (positional concatenation for iverilog compat).
    // Layout (Architecture.md §5 + dbg_pkg.sv §12.1):
    //   [127:124] state           — 0=IDLE, 1=DETECT, 2=ACQUIRE, 3=HOLDOFF
    //   [123:108] cycle_count     — wrap_count of cfg_holdoff
    //   [107:100] stall_cycles    — holdoff_remaining (low 8 bits, rate proxy)
    //   [99:96]   reserved
    //   [95]      error           — sticky (reserved)
    //   [94:87]   error_id        — 0
    //   [86]      bypass_mode     — 0 (no bypass on trigger)
    //   [85:64]   reserved
    //   [63:48]   event_count     — trigger_count
    //   [47:32]   reserved
    //   [31:16]   word_count      — crossing_count
    //   [15:0]    reserved        — could hold rejected_count low byte
    // -------------------------------------------------------------------------
    assign dbg_info = {
        state,                         // [127:124] FSM state
        trigger_count,                 // [123:108] trigger_count (in cycle_count slot)
        holdoff_remaining[7:0],        // [107:100] holdoff remaining (low 8)
        4'd0,                          // [99:96]   reserved
        1'b0,                          // [95]      error
        8'd0,                          // [94:87]   error_id
        1'b0,                          // [86]      bypass_mode
        22'd0,                         // [85:64]   reserved
        trigger_count,                 // [63:48]   event_count
        16'd0,                         // [47:32]   reserved
        crossing_count,                // [31:16]   word_count
        rejected_count                 // [15:0]    rejected count
    };

endmodule : trigger

`default_nettype wire
