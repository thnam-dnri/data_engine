//------------------------------------------------------------------------------
// tb_audit_aggregator.sv
//
// Testbench for the Phase 3A read-only Audit Aggregator.
//
// Verifies:
//   - Reset/default system registers are readable with correct values
//   - Common register slicing for at least two fake dbg_info_t blocks
//   - Trigger block common registers (TRIGGER_BASE + 0x00..0x0C)
//   - Block-specific registers (GLT_MAX_DELTA, TRIG_THRESHOLD, DESC_LOST_EVENT_CNT,
//     TX_FILL_LEVEL)
//   - Deferred continuous-capture (0x0C0) and BIST (0x1E0) return zero
//   - Invalid address returns 32'hDEAD_BAAD
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

import dbg_pkg::*;
import register_map_pkg::*;

module tb_audit_aggregator;

    reg         clk;
    reg         rst_n;
    reg [15:0]  reg_addr;
    wire [31:0] reg_rdata;

    // ---- Block debug info inputs ----
    dbg_info_t adc_dbg;
    dbg_info_t cdc_dbg;
    dbg_info_t glitch_dbg;
    dbg_info_t cbuf_dbg;
    dbg_info_t trigger_dbg;
    dbg_info_t desc_dbg;
    dbg_info_t reader_dbg;
    dbg_info_t tx_dbg;
    dbg_info_t dpti_dbg;

    // ---- Block-specific signals ----
    reg [15:0] glitch_max_delta;
    reg [15:0] glitch_threshold;
    reg [12:0] cbuf_wr_ptr;
    reg [12:0] cbuf_rd_ptr;
    reg        cbuf_collision;
    reg [12:0] cbuf_watermark;
    reg [15:0] trigger_threshold;
    reg [15:0] trigger_cross_rate;
    reg [15:0] trigger_holdoff_remaining;
    reg        trigger_armed;
    reg [5:0]  desc_fill_level;
    reg [5:0]  desc_watermark;
    reg [15:0] desc_lost_event_count;
    reg [15:0] reader_remaining;
    reg [15:0] reader_wrap_handled;
    reg [11:0] tx_fill_level;
    reg [11:0] tx_watermark;
    reg [15:0] tx_dpti_stall;
    reg [15:0] dpti_rx_cmd_count;
    reg [15:0] dpti_bus_turnarounds;

    // ---- System registers ----
    reg [31:0] sys_firmware_version;
    reg [31:0] sys_board_id;
    reg [31:0] sys_run_timestamp_lo;
    reg [31:0] sys_run_timestamp_hi;
    reg [31:0] sys_reset_cause;
    reg [31:0] sys_ctrl;

    // ---- DUT ----
    audit_aggregator u_dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .reg_addr             (reg_addr),
        .reg_rdata            (reg_rdata),

        .adc_dbg              (adc_dbg),
        .cdc_dbg              (cdc_dbg),
        .glitch_dbg           (glitch_dbg),
        .cbuf_dbg             (cbuf_dbg),
        .trigger_dbg          (trigger_dbg),
        .desc_dbg             (desc_dbg),
        .reader_dbg           (reader_dbg),
        .tx_dbg               (tx_dbg),
        .dpti_dbg             (dpti_dbg),

        .glitch_max_delta     (glitch_max_delta),
        .glitch_threshold     (glitch_threshold),
        .cbuf_wr_ptr          (cbuf_wr_ptr),
        .cbuf_rd_ptr          (cbuf_rd_ptr),
        .cbuf_collision       (cbuf_collision),
        .cbuf_watermark       (cbuf_watermark),
        .trigger_threshold    (trigger_threshold),
        .trigger_cross_rate   (trigger_cross_rate),
        .trigger_holdoff_remaining(trigger_holdoff_remaining),
        .trigger_armed        (trigger_armed),
        .desc_fill_level      (desc_fill_level),
        .desc_watermark       (desc_watermark),
        .desc_lost_event_count(desc_lost_event_count),
        .reader_remaining     (reader_remaining),
        .reader_wrap_handled  (reader_wrap_handled),
        .tx_fill_level        (tx_fill_level),
        .tx_watermark         (tx_watermark),
        .tx_dpti_stall        (tx_dpti_stall),
        .dpti_rx_cmd_count    (dpti_rx_cmd_count),
        .dpti_bus_turnarounds (dpti_bus_turnarounds),

        .sys_firmware_version (sys_firmware_version),
        .sys_board_id         (sys_board_id),
        .sys_run_timestamp_lo (sys_run_timestamp_lo),
        .sys_run_timestamp_hi (sys_run_timestamp_hi),
        .sys_reset_cause      (sys_reset_cause),
        .sys_ctrl             (sys_ctrl)
    );

    // ---- Clock ----
    always #5 clk = ~clk;

    // ---- Test tracking ----
    integer pass_count = 0;
    integer fail_count = 0;

    // ---- Helper: check register read ----
    task check_reg(input [15:0] addr, input [31:0] expected, input string name);
        reg_addr = addr;
        #1;
        if (reg_rdata === expected) begin
            $display("  PASS: %s @ 0x%04X = 0x%08X", name, addr, reg_rdata);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %s @ 0x%04X = 0x%08X (expected 0x%08X)",
                     name, addr, reg_rdata, expected);
            fail_count = fail_count + 1;
        end
    endtask

    // ---- Helper: build a fake dbg_info_t ----
    // Positional concatenation for iverilog v12 compat (no named aggregate)
    function dbg_info_t make_dbg(
        input [3:0]  state,
        input [15:0] cycle_count,
        input [7:0]  stall_cycles,
        input        error,
        input [7:0]  error_id,
        input        bypass_mode,
        input [15:0] event_count,
        input [15:0] word_count
    );
        make_dbg = {
            state,          // [127:124]
            cycle_count,    // [123:108]
            stall_cycles,   // [107:100]
            4'd0,           // [99:96]   reserved_0
            error,          // [95]
            error_id,       // [94:87]
            bypass_mode,    // [86]
            22'd0,          // [85:64]   reserved_1
            event_count,    // [63:48]
            16'd0,          // [47:32]   reserved_2
            word_count,     // [31:16]
            16'd0           // [15:0]    reserved_3
        };
    endfunction

    // ---- Test sequence ----
    initial begin
        $display("=== tb_audit_aggregator START ===");
        $display("");

        // ---- Init ----
        clk = 1'b0;
        rst_n = 1'b0;

        // Default all inputs
        reg_addr = 16'd0;
        adc_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);
        cdc_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);
        glitch_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);
        cbuf_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);
        trigger_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);
        desc_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);
        reader_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);
        tx_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);
        dpti_dbg = make_dbg(4'd0, 16'd0, 8'd0, 1'b0, 8'd0, 1'b0, 16'd0, 16'd0);

        glitch_max_delta = 16'd0;
        glitch_threshold = 16'd0;
        cbuf_wr_ptr = 13'd0;
        cbuf_rd_ptr = 13'd0;
        cbuf_collision = 1'b0;
        cbuf_watermark = 13'd0;
        trigger_threshold = 16'd0;
        trigger_cross_rate = 16'd0;
        trigger_holdoff_remaining = 16'd0;
        trigger_armed = 1'b0;
        desc_fill_level = 6'd0;
        desc_watermark = 6'd0;
        desc_lost_event_count = 16'd0;
        reader_remaining = 16'd0;
        reader_wrap_handled = 16'd0;
        tx_fill_level = 12'd0;
        tx_watermark = 12'd0;
        tx_dpti_stall = 16'd0;
        dpti_rx_cmd_count = 16'd0;
        dpti_bus_turnarounds = 16'd0;

        sys_firmware_version = 32'h0003_0001;
        sys_board_id = 32'h0000_0104;
        sys_run_timestamp_lo = 32'h1234_5678;
        sys_run_timestamp_hi = 32'h9ABC_DEF0;
        sys_reset_cause = 32'd0;
        sys_ctrl = 32'd0;

        #20;
        rst_n = 1'b1;
        #10;

        // =====================================================================
        // Test 1: System registers
        // =====================================================================
        $display("--- Test 1: System registers ---");
        check_reg(SYS_FIRMWARE_VERSION, 32'h0003_0001, "firmware_version");
        check_reg(SYS_BOARD_ID,         32'h0000_0104, "board_id");
        check_reg(SYS_RUN_TIMESTAMP_LO, 32'h1234_5678, "run_timestamp_lo");
        check_reg(SYS_RUN_TIMESTAMP_HI, 32'h9ABC_DEF0, "run_timestamp_hi");
        check_reg(SYS_RESET_CAUSE,      32'd0,         "reset_cause");
        check_reg(SYS_CTRL,             32'd0,         "sys_ctrl");
        check_reg(SYS_BASE + 16'h18,    32'hDEAD_BAAD, "sys_reserved_0x18");
        check_reg(SYS_BASE + 16'h1C,    32'hDEAD_BAAD, "sys_reserved_0x1C");
        $display("");

        // =====================================================================
        // Test 2: Common register slicing with fake dbg_info_t
        // =====================================================================
        $display("--- Test 2: Common register slicing (glitch + trigger dbg) ---");

        // Set up glitch dbg: state=3, cycle_count=12345, stall=99,
        //   error=1, error_id=5, bypass=0,
        //   event_count=777, word_count=888
        glitch_dbg = make_dbg(4'd3, 16'd12345, 8'd99, 1'b1, 8'd5, 1'b0, 16'd777, 16'd888);

        // COMMON_0 = state[3:0], cycle_count[15:0], stall_cycles[7:0], reserved[3:0]
        // bits [31:28]=3, [27:12]=12345, [11:4]=99, [3:0]=0
        // 32'd12345 = 0x3039, 99 = 0x63
        // Expected: {4'h3, 16'd12345, 8'd99, 4'd0} = 0x33039630... wait let me compute
        // 4'h3 << 28 = 0x30000000
        // 16'd12345 = 0x3039, so 0x3039 << 12 = 0x03039000... let me compute carefully
        // [31:28] = 3 = 0x3
        // [27:12] = 12345 = 0x3039
        // [11:4]  = 99 = 0x63
        // [3:0]   = 0
        // Packed: {4'h3, 16'h3039, 8'h63, 4'h0} = 32'h3303_9630
        // Let me verify: 3 in 4 bits = 0011, 12345 = 0011_0000_0011_1001 = 0x3039
        // 99 = 0110_0011 = 0x63, 0 = 0000
        // As 32-bit: 0011_0011_0000_0011_1001_0110_0011_0000 = 0x3303_9630
        check_reg(GLITCH_FILTER_BASE + DBG_COMMON_0, 32'h3303_9630, "glitch_COMMON_0");

        // COMMON_1 = error, error_id[7:0], bypass_mode, reserved_1[21:0]
        // [31] = 1, [30:23] = 5, [22] = 0, [21:0] = 0
        // = {1'b1, 8'd5, 1'b0, 22'd0} = 32'h8000_0000 | (5 << 23) = 0x8280_0000
        // Actually: 1<<31 | 5<<23 = 0x80000000 | 0x02800000 = 0x82800000
        check_reg(GLITCH_FILTER_BASE + DBG_COMMON_1, 32'h8280_0000, "glitch_COMMON_1");

        // COMMON_2 = event_count[15:0], reserved_2[15:0]
        // 777 = 0x0309
        // = {16'd777, 16'd0} = 0x0309_0000
        check_reg(GLITCH_FILTER_BASE + DBG_COMMON_2, 32'h0309_0000, "glitch_COMMON_2");

        // COMMON_3 = word_count[15:0], reserved_3[15:0]
        // 888 = 0x0378
        // = {16'd888, 16'd0} = 0x0378_0000
        check_reg(GLITCH_FILTER_BASE + DBG_COMMON_3, 32'h0378_0000, "glitch_COMMON_3");

        // Set up trigger dbg
        trigger_dbg = make_dbg(4'd2, 16'd500, 8'd10, 1'b0, 8'd0, 1'b1, 16'd42, 16'd1000);
        // COMMON_0: state=2, cycle_count=500 (0x01F4), stall=10 (0x0A), reserved=0
        // = {4'h2, 16'h01F4, 8'h0A, 4'h0} = 0x201F_40A0
        check_reg(TRIGGER_BASE + DBG_COMMON_0, 32'h201F_40A0, "trigger_COMMON_0");
        // COMMON_1: error=0, error_id=0, bypass_mode=1, reserved=0
        // = {1'b0, 8'd0, 1'b1, 22'd0} = 0x0040_0000
        check_reg(TRIGGER_BASE + DBG_COMMON_1, 32'h0040_0000, "trigger_COMMON_1");
        // COMMON_2: event_count=42 (0x002A)
        check_reg(TRIGGER_BASE + DBG_COMMON_2, 32'h002A_0000, "trigger_COMMON_2");
        // COMMON_3: word_count=1000 (0x03E8)
        check_reg(TRIGGER_BASE + DBG_COMMON_3, 32'h03E8_0000, "trigger_COMMON_3");
        $display("");

        // =====================================================================
        // Test 3: Block-specific registers
        // =====================================================================
        $display("--- Test 3: Block-specific registers ---");

        glitch_max_delta = 16'h0ABC;
        glitch_threshold = 16'd500;
        check_reg(GLT_MAX_DELTA, 32'h0000_0ABC, "glitch_max_delta");
        check_reg(GLT_THRESHOLD, 32'h0000_01F4, "glitch_threshold");

        trigger_threshold = 16'd6000;
        trigger_cross_rate = 16'd100;
        trigger_holdoff_remaining = 16'd2000;
        trigger_armed = 1'b1;
        check_reg(TRIG_THRESHOLD,           32'h0000_1770, "trigger_threshold");
        check_reg(TRIG_THRESHOLD_CROSS_RATE, 32'h0000_0064, "trigger_cross_rate");
        check_reg(TRIG_HOLDOFF_REMAINING,   32'h0000_07D0, "trigger_holdoff_remaining");
        check_reg(TRIG_ARMED,                32'h0000_0001, "trigger_armed");

        desc_lost_event_count = 16'h00FF;
        check_reg(DESC_LOST_EVENT_CNT, 32'h0000_00FF, "desc_lost_event_count");

        tx_fill_level = 12'hABC;
        check_reg(TX_FILL_LEVEL, 32'h0000_0ABC, "tx_fill_level");

        reader_remaining = 16'h003F;
        reader_wrap_handled = 16'h0010;
        check_reg(WFR_REMAINING,    32'h0000_003F, "reader_remaining");
        check_reg(WFR_WRAP_HANDLED, 32'h0000_0010, "reader_wrap_handled");

        cbuf_wr_ptr = 13'h1234;
        cbuf_rd_ptr = 13'h0ABC;
        cbuf_collision = 1'b1;
        cbuf_watermark = 13'h07FF;
        check_reg(BUF_WR_PTR,    32'h0000_1234, "cbuf_wr_ptr");  // 13-bit, zero-extend
        check_reg(BUF_RD_PTR,    32'h0000_0ABC, "cbuf_rd_ptr");
        check_reg(BUF_COLLISION, 32'h0000_0001, "cbuf_collision");
        check_reg(BUF_WATERMARK, 32'h0000_07FF, "cbuf_watermark");

        tx_dpti_stall = 16'hCAFE;
        check_reg(TX_DPTI_STALL, 32'h0000_CAFE, "tx_dpti_stall");

        dpti_rx_cmd_count = 16'h00AA;
        dpti_bus_turnarounds = 16'h0011;
        check_reg(DPTI_RX_CMD_CNT,      32'h0000_00AA, "dpti_rx_cmd_count");
        check_reg(DPTI_BUS_TURNAROUNDS, 32'h0000_0011, "dpti_bus_turnarounds");
        $display("");

        // =====================================================================
        // Test 4: Deferred blocks return zero
        // =====================================================================
        $display("--- Test 4: Deferred blocks return zero ---");
        check_reg(CONT_CAP_BASE + 16'h00, 32'd0, "cont_cap_common_0 (deferred)");
        check_reg(CONT_CAP_BASE + 16'h10, 32'd0, "cont_cap_specific_0 (deferred)");
        check_reg(CONT_CAP_BASE + 16'h1C, 32'd0, "cont_cap_specific_3 (deferred)");
        check_reg(BIST_BASE + 16'h00,     32'd0, "bist_mode (deferred)");
        check_reg(BIST_BASE + 16'h10,     32'd0, "bist_cycle_count (deferred)");
        $display("");

        // =====================================================================
        // Test 5: Invalid address returns DEAD_BAAD
        // =====================================================================
        $display("--- Test 5: Invalid address returns DEAD_BAAD ---");
        check_reg(16'hFFFF, 32'hDEAD_BAAD, "invalid_0xFFFF");
        check_reg(16'h0160, 32'hDEAD_BAAD, "reserved_0x0160");
        check_reg(16'h01A0, 32'hDEAD_BAAD, "reserved_0x01A0");
        check_reg(16'h0001, 32'hDEAD_BAAD, "sys_reserved_0x0001");
        $display("");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("========================================");
        $display("  PASS: %0d, FAIL: %0d", pass_count, fail_count);
        $display("========================================");

        if (fail_count == 0)
            $display("=== tb_audit_aggregator: ALL TESTS PASSED ===");
        else
            $display("=== tb_audit_aggregator: %0d TESTS FAILED ===", fail_count);

        #20;
        $finish;
    end

endmodule : tb_audit_aggregator
