//------------------------------------------------------------------------------
// register_map_pkg.sv
//
// Register address map constants for the data_engine acquisition pipeline.
// Defines block base addresses (0x20 spacing = 8 registers per block) and
// common register offsets used by the Audit Aggregator and host software.
//
// Architecture reference: Architecture.md §12.4 (Audit Aggregator & Register Map)
// Authoritative field layout: docs/debug_register_map.md
//
// All three must match: Architecture.md, docs/debug_register_map.md, and this file.
//------------------------------------------------------------------------------
// Copyright (c) 2026 Tran Hai Nam
// This is a non-commercial academic/research project.
// Contact thnam@dnri.vn for commercial licensing.
//------------------------------------------------------------------------------

package register_map_pkg;

    // ===========================================================================
    // Block Base Addresses
    // ===========================================================================
    // 16-bit register address space. Each block occupies 0x20 bytes = 8 × 32-bit
    // registers. Blocks span 0x000 through 0x1FF (11 blocks × 0x20 = 0x160).
    // Reserved space from 0x160 to 0x1DF for future blocks.

    localparam logic [15:0] SYS_BASE          = 16'h000;  // System control & status
    localparam logic [15:0] ADC_IF_BASE       = 16'h020;  // ADC Interface
    localparam logic [15:0] CDC_FIFO_BASE     = 16'h040;  // CDC FIFO
    localparam logic [15:0] GLITCH_FILTER_BASE = 16'h060; // Glitch Filter
    localparam logic [15:0] CIRC_BUF_BASE     = 16'h080;  // Circular Buffer
    localparam logic [15:0] TRIGGER_BASE      = 16'h0A0;  // Trigger Logic
    localparam logic [15:0] CONT_CAP_BASE     = 16'h0C0;  // Continuous Capture (deferred)
    localparam logic [15:0] DESC_FIFO_BASE    = 16'h0E0;  // Descriptor FIFO
    localparam logic [15:0] WF_READER_BASE    = 16'h100;  // Waveform Reader
    localparam logic [15:0] TX_FIFO_BASE      = 16'h120;  // TX FIFO
    localparam logic [15:0] DPTI_BASE         = 16'h140;  // DPTI Bridge
    // 0x160–0x1DF: reserved for future pipeline blocks
    localparam logic [15:0] BIST_BASE         = 16'h1E0;  // BIST Control

    // ===========================================================================
    // Common Register Offsets (within each block)
    // ===========================================================================
    // Every pipeline block has 4 common registers (mapping to dbg_info_t) plus
    // 4 block-specific registers.

    localparam logic [15:0] DBG_COMMON_0      = 16'h00;  // state[3:0], cycle_count[15:0], stall_cycles[7:0]
    localparam logic [15:0] DBG_COMMON_1      = 16'h04;  // error, error_id[7:0], bypass_mode
    localparam logic [15:0] DBG_COMMON_2      = 16'h08;  // event_count[15:0]
    localparam logic [15:0] DBG_COMMON_3      = 16'h0C;  // word_count[15:0]
    localparam logic [15:0] DBG_SPECIFIC_0    = 16'h10;  // Block-specific register 0
    localparam logic [15:0] DBG_SPECIFIC_1    = 16'h14;  // Block-specific register 1
    localparam logic [15:0] DBG_SPECIFIC_2    = 16'h18;  // Block-specific register 2
    localparam logic [15:0] DBG_SPECIFIC_3    = 16'h1C;  // Block-specific register 3

    // ===========================================================================
    // System Block Register Offsets (SYS_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] SYS_FIRMWARE_VERSION  = SYS_BASE + 16'h00;
    localparam logic [15:0] SYS_BOARD_ID          = SYS_BASE + 16'h04;
    localparam logic [15:0] SYS_RUN_TIMESTAMP_LO  = SYS_BASE + 16'h08;
    localparam logic [15:0] SYS_RUN_TIMESTAMP_HI  = SYS_BASE + 16'h0C;
    localparam logic [15:0] SYS_RESET_CAUSE       = SYS_BASE + 16'h10;
    localparam logic [15:0] SYS_CTRL              = SYS_BASE + 16'h14;

    // ===========================================================================
    // ADC Interface Block Register Offsets (ADC_IF_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] ADC_IDDR_CAL_STATE   = ADC_IF_BASE + 16'h10;
    localparam logic [15:0] ADC_CHA_SYNC_COUNT   = ADC_IF_BASE + 16'h14;
    localparam logic [15:0] ADC_CHB_SYNC_COUNT   = ADC_IF_BASE + 16'h18;

    // ===========================================================================
    // CDC FIFO Block Register Offsets (CDC_FIFO_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] CDC_FILL_LEVEL  = CDC_FIFO_BASE + 16'h10;
    localparam logic [15:0] CDC_WATERMARK   = CDC_FIFO_BASE + 16'h14;

    // ===========================================================================
    // Glitch Filter Block Register Offsets (GLITCH_FILTER_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] GLT_MAX_DELTA   = GLITCH_FILTER_BASE + 16'h10;
    localparam logic [15:0] GLT_THRESHOLD   = GLITCH_FILTER_BASE + 16'h14;

    // ===========================================================================
    // Circular Buffer Block Register Offsets (CIRC_BUF_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] BUF_WR_PTR      = CIRC_BUF_BASE + 16'h10;
    localparam logic [15:0] BUF_RD_PTR      = CIRC_BUF_BASE + 16'h14;
    localparam logic [15:0] BUF_COLLISION   = CIRC_BUF_BASE + 16'h18;
    localparam logic [15:0] BUF_WATERMARK   = CIRC_BUF_BASE + 16'h1C;

    // ===========================================================================
    // Trigger Block Register Offsets (TRIGGER_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] TRIG_THRESHOLD          = TRIGGER_BASE + 16'h10;
    localparam logic [15:0] TRIG_THRESHOLD_CROSS_RATE = TRIGGER_BASE + 16'h14;
    localparam logic [15:0] TRIG_HOLDOFF_REMAINING  = TRIGGER_BASE + 16'h18;
    localparam logic [15:0] TRIG_ARMED              = TRIGGER_BASE + 16'h1C;

    // ===========================================================================
    // Continuous Capture Block Register Offsets (CONT_CAP_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] CAP_ACTIVE              = CONT_CAP_BASE + 16'h10;
    localparam logic [15:0] CAP_DROPPED_BLOCK_COUNT = CONT_CAP_BASE + 16'h14;

    // ===========================================================================
    // Descriptor FIFO Block Register Offsets (DESC_FIFO_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] DESC_FILL_LEVEL      = DESC_FIFO_BASE + 16'h10;
    localparam logic [15:0] DESC_WATERMARK       = DESC_FIFO_BASE + 16'h14;
    localparam logic [15:0] DESC_LOST_EVENT_CNT  = DESC_FIFO_BASE + 16'h18;

    // ===========================================================================
    // Waveform Reader Block Register Offsets (WF_READER_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] WFR_REMAINING     = WF_READER_BASE + 16'h10;
    localparam logic [15:0] WFR_WRAP_HANDLED  = WF_READER_BASE + 16'h14;

    // ===========================================================================
    // TX FIFO Block Register Offsets (TX_FIFO_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] TX_FILL_LEVEL  = TX_FIFO_BASE + 16'h10;
    localparam logic [15:0] TX_WATERMARK   = TX_FIFO_BASE + 16'h14;
    localparam logic [15:0] TX_DPTI_STALL  = TX_FIFO_BASE + 16'h18;

    // ===========================================================================
    // DPTI Bridge Block Register Offsets (DPTI_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] DPTI_RX_CMD_CNT      = DPTI_BASE + 16'h10;
    localparam logic [15:0] DPTI_BUS_TURNAROUNDS = DPTI_BASE + 16'h14;

    // ===========================================================================
    // BIST Control Block Register Offsets (BIST_BASE + offset)
    // ===========================================================================
    localparam logic [15:0] BIST_MODE         = BIST_BASE + 16'h00;  // Override: uses common offset
    localparam logic [15:0] BIST_PATTERN      = BIST_BASE + 16'h04;
    localparam logic [15:0] BIST_ERROR_MASK   = BIST_BASE + 16'h08;
    localparam logic [15:0] BIST_RESULT       = BIST_BASE + 16'h0C;
    localparam logic [15:0] BIST_CYCLE_COUNT  = BIST_BASE + 16'h10;

    // ===========================================================================
    // Utility: Block spacing constant
    // ===========================================================================
    localparam int BLOCK_SPACING = 8'h20;  // 32 bytes (8 registers) per block

endpackage : register_map_pkg
