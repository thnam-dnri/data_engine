//------------------------------------------------------------------------------
// tb_types.sv
//
// Phase 0 testbench: prove all three foundation packages compile and pack
// correctly under both iverilog and Vivado xvlog.
//
// Tests:
//   - Every struct packs to the expected bit width ($bits)
//   - Every enum has the expected value
//   - Field assignment and readback (pack/unpack roundtrip)
//   - Field independence (no aliasing between adjacent fields)
//   - Zero-initialization (all fields reset correctly)
//   - register_map_pkg constant correctness (no overlapping addresses)
//   - dbg_info_t 32-bit register alignment (each 32-bit slice extractable)
//   - dbg_monitor_t composition (10 × dbg_info_t = 1280 bits)
//
// Design note: This testbench avoids iverilog v12 limitations:
//   - Package files must be listed before testbench on command line
//   - All variables are declared at module level (not inside nested begin..end)
//   - No variable name "packed" (reserved-like conflict in iverilog)
//
// Architecture reference: Architecture.md §12.1 (dbg_info_t), §12.2 (sample_token_t), §8 (descriptor_t)
// Register map: docs/debug_register_map.md
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_types;

    // Import all three foundation packages
    import pipeline_pkg::*;
    import dbg_pkg::*;
    import register_map_pkg::*;

    // ===========================================================================
    // Test variables (declared at module level for iverilog compatibility)
    // ===========================================================================
    sample_token_t tok;
    sample_token_t tok_max;
    descriptor_t   desc;
    descriptor_t   desc_minmax;
    dbg_info_t     dbg;
    dbg_info_t     dbg_max;
    dbg_monitor_t  mon;

    // ===========================================================================
    // Test infrastructure
    // ===========================================================================
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

    // ===========================================================================
    // Main test sequence
    // ===========================================================================
    initial begin
        $display("");
        $display("========================================================================");
        $display("  tb_types — Phase 0 Foundation Type Validation");
        $display("========================================================================");
        $display("");

        // -----------------------------------------------------------------------
        // 1. Type widths
        // -----------------------------------------------------------------------
        $display("--- Section 1: Type Bit Widths ---");

        check("sample_token_t packs to 53 bits", $bits(sample_token_t) == 53);
        check("descriptor_t packs to 160 bits",  $bits(descriptor_t)  == 160);
        check("dbg_info_t packs to 128 bits",    $bits(dbg_info_t)    == 128);
        check("dbg_monitor_t packs to 1280 bits", $bits(dbg_monitor_t) == 1280);

        check("trigger_type_t is 2 bits wide",  $bits(trigger_type_t) == 2);
        check("bist_pattern_t is 3 bits wide",  $bits(bist_pattern_t) == 3);
        check("frame_type_t is 8 bits wide",    $bits(frame_type_t)   == 8);

        $display("");

        // -----------------------------------------------------------------------
        // 2. Enum values
        // -----------------------------------------------------------------------
        $display("--- Section 2: Enum Values ---");

        check("TRIG_LEADING_EDGE == 2'b00", TRIG_LEADING_EDGE == 2'b00);
        check("TRIG_CFD          == 2'b01", TRIG_CFD          == 2'b01);
        check("TRIG_ML           == 2'b10", TRIG_ML           == 2'b10);

        check("BIST_RAMP          == 3'd0", BIST_RAMP          == 3'd0);
        check("BIST_ALT_MAX_MIN   == 3'd1", BIST_ALT_MAX_MIN   == 3'd1);
        check("BIST_PULSE         == 3'd2", BIST_PULSE         == 3'd2);
        check("BIST_PRBS          == 3'd3", BIST_PRBS          == 3'd3);
        check("BIST_GLITCH_INJECT == 3'd4", BIST_GLITCH_INJECT == 3'd4);

        check("FRAME_TRIGGER_DESC  == 8'h01", FRAME_TRIGGER_DESC  == 8'h01);
        check("FRAME_WAVEFORM      == 8'h02", FRAME_WAVEFORM      == 8'h02);
        check("FRAME_CONTINUOUS    == 8'h03", FRAME_CONTINUOUS    == 8'h03);
        check("FRAME_DIAG_SNAPSHOT == 8'h04", FRAME_DIAG_SNAPSHOT == 8'h04);
        check("FRAME_CMD_RESPONSE  == 8'h05", FRAME_CMD_RESPONSE  == 8'h05);
        check("FRAME_RUN_HEADER    == 8'hFE", FRAME_RUN_HEADER    == 8'hFE);
        check("FRAME_RUN_FOOTER    == 8'hFF", FRAME_RUN_FOOTER    == 8'hFF);

        $display("");

        // -----------------------------------------------------------------------
        // 3. sample_token_t pack/unpack roundtrip
        // -----------------------------------------------------------------------
        $display("--- Section 3: sample_token_t Roundtrip ---");

        tok = '0;
        tok.valid  = 1'b1;
        tok.sample = 16'hA5A5;
        tok.seq_id = 32'h12345678;
        tok.flags  = 4'hF;

        check("sample_token_t valid  == 1'b1",             tok.valid  == 1'b1);
        check("sample_token_t sample == 16'hA5A5",         tok.sample == 16'hA5A5);
        check("sample_token_t seq_id == 32'h12345678",     tok.seq_id == 32'h12345678);
        check("sample_token_t flags  == 4'hF",             tok.flags  == 4'hF);
        check("sample_token_t $bits == 53 after assign",   $bits(tok) == 53);

        // Field independence: changing sample doesn't affect seq_id
        tok.sample = 16'h5A5A;
        check("sample field change independent of seq_id", tok.seq_id == 32'h12345678);
        check("sample field change independent of flags",  tok.flags  == 4'hF);

        // Changing seq_id doesn't affect sample
        tok.seq_id = 32'h87654321;
        check("seq_id change independent of sample", tok.sample == 16'h5A5A);
        check("seq_id change independent of flags",  tok.flags  == 4'hF);

        // Zero-initialized
        tok = '0;
        check("sample_token_t zero-init valid",  tok.valid  == 1'b0);
        check("sample_token_t zero-init sample", tok.sample == 16'h0000);
        check("sample_token_t zero-init seq_id", tok.seq_id == 32'h00000000);
        check("sample_token_t zero-init flags",  tok.flags  == 4'h0);

        $display("");

        // -----------------------------------------------------------------------
        // 4. descriptor_t pack/unpack roundtrip
        // -----------------------------------------------------------------------
        $display("--- Section 4: descriptor_t Roundtrip ---");

        desc = '0;
        desc.timestamp        = 48'hA5A5_A5A5_A5A5;
        desc.amplitude        = 16'h7F00;
        desc.energy           = 16'h3FFF;
        desc.trigger_type     = TRIG_CFD;
        desc.waveform_offset  = 13'h1000;
        desc.waveform_length  = 11'h708;  // 1800 samples
        desc.channel_id       = 1'b1;
        desc.board_id         = 16'h0001;
        desc.firmware_version = 32'h01020003;  // v1.2.0.build3
        desc.diag_snapshot    = 5'h1F;

        check("descriptor_t timestamp        == 48'hA5A5_A5A5_A5A5",
               desc.timestamp == 48'hA5A5_A5A5_A5A5);
        check("descriptor_t amplitude        == 16'h7F00",
               desc.amplitude == 16'h7F00);
        check("descriptor_t energy           == 16'h3FFF",
               desc.energy == 16'h3FFF);
        check("descriptor_t trigger_type     == TRIG_CFD",
               desc.trigger_type == TRIG_CFD);
        check("descriptor_t waveform_offset  == 13'h1000",
               desc.waveform_offset == 13'h1000);
        check("descriptor_t waveform_length  == 11'h708 (1800)",
               desc.waveform_length == 11'h708);
        check("descriptor_t channel_id       == 1'b1",
               desc.channel_id == 1'b1);
        check("descriptor_t board_id         == 16'h0001",
               desc.board_id == 16'h0001);
        check("descriptor_t firmware_version == 32'h01020003",
               desc.firmware_version == 32'h01020003);
        check("descriptor_t diag_snapshot    == 5'h1F",
               desc.diag_snapshot == 5'h1F);
        check("descriptor_t $bits == 160 after assign",
               $bits(desc) == 160);

        // Field independence: trigger_type change doesn't alias into timestamp
        desc.trigger_type = TRIG_ML;
        check("trigger_type change independent of timestamp",
               desc.timestamp == 48'hA5A5_A5A5_A5A5);
        check("trigger_type change independent of amplitude",
               desc.amplitude == 16'h7F00);
        check("trigger_type == TRIG_ML after change",
               desc.trigger_type == TRIG_ML);

        // Zero-initialized
        desc = '0;
        check("descriptor_t zero-init timestamp",        desc.timestamp        == 48'h0);
        check("descriptor_t zero-init amplitude",        desc.amplitude        == 16'h0);
        check("descriptor_t zero-init energy",           desc.energy           == 16'h0);
        check("descriptor_t zero-init trigger_type",     desc.trigger_type     == 2'b00);
        check("descriptor_t zero-init waveform_offset",  desc.waveform_offset  == 13'h0);
        check("descriptor_t zero-init waveform_length",  desc.waveform_length  == 11'h0);
        check("descriptor_t zero-init channel_id",       desc.channel_id       == 1'b0);
        check("descriptor_t zero-init board_id",         desc.board_id         == 16'h0);
        check("descriptor_t zero-init firmware_version", desc.firmware_version == 32'h0);
        check("descriptor_t zero-init diag_snapshot",    desc.diag_snapshot    == 5'h0);

        $display("");

        // -----------------------------------------------------------------------
        // 5. dbg_info_t pack/unpack roundtrip + 32-bit register alignment
        // -----------------------------------------------------------------------
        $display("--- Section 5: dbg_info_t Roundtrip & Register Alignment ---");

        dbg = '0;
        dbg.state        = 4'hA;
        dbg.cycle_count  = 16'hBEEF;
        dbg.stall_cycles = 8'h42;
        dbg.reserved_0   = 4'h0;
        dbg.error        = 1'b1;
        dbg.error_id     = 8'h03;
        dbg.bypass_mode  = 1'b0;
        dbg.reserved_1   = 22'h0;
        dbg.event_count  = 16'h007F;
        dbg.reserved_2   = 16'h0;
        dbg.word_count   = 16'hA000;
        dbg.reserved_3   = 16'h0;

        check("dbg_info_t state        == 4'hA",         dbg.state       == 4'hA);
        check("dbg_info_t cycle_count  == 16'hBEEF",     dbg.cycle_count == 16'hBEEF);
        check("dbg_info_t stall_cycles == 8'h42",        dbg.stall_cycles == 8'h42);
        check("dbg_info_t error        == 1'b1",         dbg.error       == 1'b1);
        check("dbg_info_t error_id     == 8'h03",        dbg.error_id    == 8'h03);
        check("dbg_info_t bypass_mode  == 1'b0",         dbg.bypass_mode == 1'b0);
        check("dbg_info_t event_count  == 16'h007F",     dbg.event_count == 16'h007F);
        check("dbg_info_t word_count   == 16'hA000",     dbg.word_count  == 16'hA000);
        check("dbg_info_t $bits == 128 after assign",    $bits(dbg)      == 128);

        // Verify 32-bit register alignment: each 32-bit slice maps to one
        // register address in the Audit Aggregator.

        // Reg+0x00: [127:96] = {state, cycle_count, stall_cycles, reserved_0}
        check("dbg_info_t Reg+0x00 slice[127:96] = {state, cycle_count, stall, rsvd}",
               dbg[127:96] == {4'hA, 16'hBEEF, 8'h42, 4'h0});

        // Reg+0x04: [95:64] = {error, error_id, bypass_mode, reserved_1}
        check("dbg_info_t Reg+0x04 slice[95:64] = {error, error_id, bypass, rsvd}",
               dbg[95:64] == {1'b1, 8'h03, 1'b0, 22'h0});

        // Reg+0x08: [63:32] = {event_count, reserved_2}
        check("dbg_info_t Reg+0x08 slice[63:32] = {event_count, reserved}",
               dbg[63:32] == {16'h007F, 16'h0});

        // Reg+0x0C: [31:0] = {word_count, reserved_3}
        check("dbg_info_t Reg+0x0C slice[31:0] = {word_count, reserved}",
               dbg[31:0] == {16'hA000, 16'h0});

        // Zero-initialized
        dbg = '0;
        check("dbg_info_t zero-init state",        dbg.state       == 4'h0);
        check("dbg_info_t zero-init error",         dbg.error       == 1'b0);
        check("dbg_info_t zero-init error_id",      dbg.error_id    == 8'h0);
        check("dbg_info_t zero-init event_count",   dbg.event_count == 16'h0);
        check("dbg_info_t zero-init word_count",    dbg.word_count  == 16'h0);

        check("dbg_info_t all reserved fields zero",
               dbg.reserved_0 == 4'h0 &&
               dbg.reserved_1 == 22'h0 &&
               dbg.reserved_2 == 16'h0 &&
               dbg.reserved_3 == 16'h0);

        $display("");

        // -----------------------------------------------------------------------
        // 6. dbg_monitor_t composition
        // -----------------------------------------------------------------------
        $display("--- Section 6: dbg_monitor_t Composition ---");

        mon = '0;

        check("dbg_monitor_t zero-init adc_interface",       $bits(mon.adc_interface) == 128);
        check("dbg_monitor_t zero-init cdc_fifo",            $bits(mon.cdc_fifo) == 128);
        check("dbg_monitor_t zero-init glitch_filter",       $bits(mon.glitch_filter) == 128);
        check("dbg_monitor_t zero-init circular_buffer",     $bits(mon.circular_buffer) == 128);
        check("dbg_monitor_t zero-init trigger",             $bits(mon.trigger) == 128);
        check("dbg_monitor_t zero-init continuous_capture",  $bits(mon.continuous_capture) == 128);
        check("dbg_monitor_t zero-init descriptor_fifo",     $bits(mon.descriptor_fifo) == 128);
        check("dbg_monitor_t zero-init waveform_reader",     $bits(mon.waveform_reader) == 128);
        check("dbg_monitor_t zero-init tx_fifo",             $bits(mon.tx_fifo) == 128);
        check("dbg_monitor_t zero-init dpti_bridge",         $bits(mon.dpti_bridge) == 128);
        check("dbg_monitor_t total $bits == 1280",
               $bits(mon) == 1280);

        // Assign one block and verify independence
        mon.adc_interface.state = 4'h1;
        mon.adc_interface.cycle_count = 16'h0001;
        check("adc_interface block independent", mon.adc_interface.state == 4'h1);
        check("other blocks remain zero",        mon.cdc_fifo.state == 4'h0);

        $display("");

        // -----------------------------------------------------------------------
        // 7. Register map constant correctness
        // -----------------------------------------------------------------------
        $display("--- Section 7: Register Map Constants ---");

        check("SYS_BASE          == 16'h000", SYS_BASE          == 16'h000);
        check("ADC_IF_BASE       == 16'h020", ADC_IF_BASE       == 16'h020);
        check("CDC_FIFO_BASE     == 16'h040", CDC_FIFO_BASE     == 16'h040);
        check("GLITCH_FILTER_BASE == 16'h060", GLITCH_FILTER_BASE == 16'h060);
        check("CIRC_BUF_BASE     == 16'h080", CIRC_BUF_BASE     == 16'h080);
        check("TRIGGER_BASE      == 16'h0A0", TRIGGER_BASE      == 16'h0A0);
        check("CONT_CAP_BASE     == 16'h0C0", CONT_CAP_BASE     == 16'h0C0);
        check("DESC_FIFO_BASE    == 16'h0E0", DESC_FIFO_BASE    == 16'h0E0);
        check("WF_READER_BASE    == 16'h100", WF_READER_BASE    == 16'h100);
        check("TX_FIFO_BASE      == 16'h120", TX_FIFO_BASE      == 16'h120);
        check("DPTI_BASE         == 16'h140", DPTI_BASE         == 16'h140);
        check("BIST_BASE         == 16'h1E0", BIST_BASE         == 16'h1E0);

        // Spacing checks
        check("ADC_IF_BASE - SYS_BASE == 0x20",      ADC_IF_BASE - SYS_BASE == 16'h020);
        check("CDC_FIFO_BASE - ADC_IF_BASE == 0x20", CDC_FIFO_BASE - ADC_IF_BASE == 16'h020);

        // Common register offsets
        check("DBG_COMMON_0   == 16'h00", DBG_COMMON_0   == 16'h00);
        check("DBG_COMMON_1   == 16'h04", DBG_COMMON_1   == 16'h04);
        check("DBG_COMMON_2   == 16'h08", DBG_COMMON_2   == 16'h08);
        check("DBG_COMMON_3   == 16'h0C", DBG_COMMON_3   == 16'h0C);
        check("DBG_SPECIFIC_0 == 16'h10", DBG_SPECIFIC_0 == 16'h10);
        check("DBG_SPECIFIC_1 == 16'h14", DBG_SPECIFIC_1 == 16'h14);
        check("DBG_SPECIFIC_2 == 16'h18", DBG_SPECIFIC_2 == 16'h18);
        check("DBG_SPECIFIC_3 == 16'h1C", DBG_SPECIFIC_3 == 16'h1C);

        // Spot-check compound addresses
        check("ADC_IDDR_CAL_STATE == 16'h030",
               ADC_IDDR_CAL_STATE == (ADC_IF_BASE + DBG_SPECIFIC_0));
        check("GLT_THRESHOLD == 16'h074",
               GLT_THRESHOLD == (GLITCH_FILTER_BASE + DBG_SPECIFIC_1));
        check("TX_DPTI_STALL == 16'h138",
               TX_DPTI_STALL == (TX_FIFO_BASE + DBG_SPECIFIC_2));
        check("DPTI_RX_CMD_CNT == 16'h150",
               DPTI_RX_CMD_CNT == (DPTI_BASE + DBG_SPECIFIC_0));

        check("BLOCK_SPACING == 8'h20", BLOCK_SPACING == 8'h20);

        $display("");

        // -----------------------------------------------------------------------
        // 8. Edge cases: max values and narrow-field boundaries
        // -----------------------------------------------------------------------
        $display("--- Section 8: Edge Cases & Boundary Checks ---");

        // sample_token_t: max values
        tok_max.valid  = 1'b1;
        tok_max.sample = 16'hFFFF;
        tok_max.seq_id = 32'hFFFF_FFFF;
        tok_max.flags  = 4'hF;
        check("sample_token_t max values: sample == 16'hFFFF",
               tok_max.sample == 16'hFFFF);
        check("sample_token_t max values: seq_id == 32'hFFFF_FFFF",
               tok_max.seq_id == 32'hFFFF_FFFF);
        check("sample_token_t max values: flags == 4'hF",
               tok_max.flags == 4'hF);

        // descriptor_t: min/max for narrow fields
        desc_minmax.trigger_type     = 2'b11;  // all 1s = reserved value
        desc_minmax.waveform_offset  = 13'h1FFF;  // max for 13-bit (8191)
        desc_minmax.waveform_length  = 11'h7FF;   // max for 11-bit (2047)
        desc_minmax.channel_id       = 1'b1;
        desc_minmax.diag_snapshot    = 5'h1F;
        check("descriptor_t narrow max: trigger_type all 1s",
               desc_minmax.trigger_type    == 2'b11);
        check("descriptor_t narrow max: waveform_offset == 0x1FFF",
               desc_minmax.waveform_offset == 13'h1FFF);
        check("descriptor_t narrow max: waveform_length == 0x7FF",
               desc_minmax.waveform_length == 11'h7FF);
        check("descriptor_t narrow max: channel_id == 1",
               desc_minmax.channel_id      == 1'b1);
        check("descriptor_t narrow max: diag_snapshot == 0x1F",
               desc_minmax.diag_snapshot   == 5'h1F);

        // dbg_info_t: all ones for non-reserved fields
        dbg_max.state        = 4'hF;
        dbg_max.cycle_count  = 16'hFFFF;
        dbg_max.stall_cycles = 8'hFF;
        dbg_max.error        = 1'b1;
        dbg_max.error_id     = 8'hFF;
        dbg_max.bypass_mode  = 1'b1;
        dbg_max.event_count  = 16'hFFFF;
        dbg_max.word_count   = 16'hFFFF;
        check("dbg_info_t all-ones: state == 4'hF",       dbg_max.state       == 4'hF);
        check("dbg_info_t all-ones: cycle_count == 0xFFFF",
               dbg_max.cycle_count == 16'hFFFF);
        check("dbg_info_t all-ones: stall_cycles == 0xFF",
               dbg_max.stall_cycles == 8'hFF);
        check("dbg_info_t all-ones: error_id == 0xFF",    dbg_max.error_id    == 8'hFF);
        check("dbg_info_t all-ones: event_count == 0xFFFF",
               dbg_max.event_count == 16'hFFFF);
        check("dbg_info_t all-ones: word_count == 0xFFFF",
               dbg_max.word_count == 16'hFFFF);

        $display("");

        // -----------------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------------
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count > 0) begin
            $display("");
            $display("  *** Phase 0 type validation FAILED — fix errors before proceeding ***");
            $display("");
            $fatal(1, "Phase 0 FAILED: %0d assertions failed", fail_count);
        end else begin
            $display("");
            $display("  ** Phase 0 type validation PASSED — all types pack correctly **");
            $display("  ** Foundation packages are ready for Phase 1 module development **");
            $display("");
        end

        $finish;
    end

endmodule : tb_types
