//------------------------------------------------------------------------------
// audit_aggregator.sv
//
// Phase 3A — Read-Only Audit Aggregator
//
// Central module that collects all dbg_info_t debug signals from every pipeline
// block plus block-specific signals, and maps them to a flat 16-bit register
// address space (32-bit data per register).
//
// Register map:
//   - System registers (0x000–0x01F): firmware version, board ID, timestamps
//   - Per-block common registers (+0x00..+0x0C): dbg_info_t 4-register slice
//   - Per-block specific registers (+0x10..+0x1C): block-defined fields
//   - Deferred blocks (continuous capture 0x0C0–0x0DF, BIST 0x1E0–0x1FF): return 0
//   - Invalid/reserved addresses: return 32'hDEAD_BAAD
//
// Architecture reference: Architecture.md §12.4
// Register map: docs/debug_register_map.md
// Constants: rtl/pkg/register_map_pkg.sv
//------------------------------------------------------------------------------
// Copyright (c) 2026 Tran Hai Nam
// This is a non-commercial academic/research project.
// Contact thnam@dnri.vn for commercial licensing.
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

import dbg_pkg::*;
import register_map_pkg::*;

module audit_aggregator (
    input  wire                 clk,
    input  wire                 rst_n,

    // Register address (combinatorial read)
    input  wire [15:0]          reg_addr,
    output reg  [31:0]          reg_rdata,

    // ---- Block debug info inputs (dbg_info_t, 128-bit each) ----
    input  dbg_info_t           adc_dbg,
    input  dbg_info_t           cdc_dbg,
    input  dbg_info_t           glitch_dbg,
    input  dbg_info_t           cbuf_dbg,
    input  dbg_info_t           trigger_dbg,
    input  dbg_info_t           desc_dbg,
    input  dbg_info_t           reader_dbg,
    input  dbg_info_t           tx_dbg,
    input  dbg_info_t           dpti_dbg,

    // ---- Block-specific signals ----
    // Glitch Filter
    input  wire [15:0]          glitch_max_delta,
    input  wire [15:0]          glitch_threshold,
    // Circular Buffer
    input  wire [12:0]          cbuf_wr_ptr,
    input  wire [12:0]          cbuf_rd_ptr,
    input  wire                 cbuf_collision,
    input  wire [12:0]          cbuf_watermark,
    // Trigger
    input  wire [15:0]          trigger_threshold,
    input  wire [15:0]          trigger_cross_rate,
    input  wire [15:0]          trigger_holdoff_remaining,
    input  wire                 trigger_armed,
    // Descriptor FIFO
    input  wire [5:0]           desc_fill_level,
    input  wire [5:0]           desc_watermark,
    input  wire [15:0]          desc_lost_event_count,
    // Waveform Reader
    input  wire [15:0]          reader_remaining,
    input  wire [15:0]          reader_wrap_handled,
    // TX FIFO
    input  wire [11:0]          tx_fill_level,
    input  wire [11:0]          tx_watermark,
    input  wire [15:0]          tx_dpti_stall,
    // DPTI Bridge
    input  wire [15:0]          dpti_rx_cmd_count,
    input  wire [15:0]          dpti_bus_turnarounds,

    // ---- System registers ----
    input  wire [31:0]          sys_firmware_version,
    input  wire [31:0]          sys_board_id,
    input  wire [31:0]          sys_run_timestamp_lo,
    input  wire [31:0]          sys_run_timestamp_hi,
    input  wire [31:0]          sys_reset_cause,
    input  wire [31:0]          sys_ctrl
);

    // =========================================================================
    // Read mux — combinatorial decode
    // =========================================================================
    // dbg_info_t slice helpers: return the 32-bit slice for a given offset
    function automatic logic [31:0] dbg_slice(input dbg_info_t info, input [1:0] offset);
        case (offset)
            2'd0: dbg_slice = info[127:96];   // COMMON_0: state, cycle_count, stall_cycles
            2'd1: dbg_slice = info[95:64];    // COMMON_1: error, error_id, bypass_mode
            2'd2: dbg_slice = info[63:32];    // COMMON_2: event_count
            2'd3: dbg_slice = info[31:0];     // COMMON_3: word_count
        endcase
    endfunction

    // Register address ranges (for decode)
    localparam [15:0] SYS_END       = SYS_BASE       + 5'h1F;
    localparam [15:0] ADC_IF_END    = ADC_IF_BASE    + 5'h1F;
    localparam [15:0] CDC_FIFO_END  = CDC_FIFO_BASE  + 5'h1F;
    localparam [15:0] GLT_END       = GLITCH_FILTER_BASE + 5'h1F;
    localparam [15:0] CBUF_END      = CIRC_BUF_BASE  + 5'h1F;
    localparam [15:0] TRIG_END      = TRIGGER_BASE   + 5'h1F;
    localparam [15:0] CONT_CAP_END  = CONT_CAP_BASE  + 5'h1F;
    localparam [15:0] DESC_END      = DESC_FIFO_BASE + 5'h1F;
    localparam [15:0] READER_END    = WF_READER_BASE + 5'h1F;
    localparam [15:0] TX_END        = TX_FIFO_BASE   + 5'h1F;
    localparam [15:0] DPTI_END      = DPTI_BASE      + 5'h1F;
    localparam [15:0] BIST_END      = BIST_BASE      + 5'h1F;

    // Internal offset-within-block (bits [4:0])
    wire [4:0] blk_ofs = reg_addr[4:0];

    always @(*) begin
        reg_rdata = 32'hDEAD_BAAD;  // default: invalid address

        // ---- System Registers (0x000–0x01F) ----
        if (reg_addr >= SYS_BASE && reg_addr <= SYS_END) begin
            case (reg_addr)
                SYS_FIRMWARE_VERSION: reg_rdata = sys_firmware_version;
                SYS_BOARD_ID:         reg_rdata = sys_board_id;
                SYS_RUN_TIMESTAMP_LO: reg_rdata = sys_run_timestamp_lo;
                SYS_RUN_TIMESTAMP_HI: reg_rdata = sys_run_timestamp_hi;
                SYS_RESET_CAUSE:      reg_rdata = sys_reset_cause;
                SYS_CTRL:             reg_rdata = sys_ctrl;
                default:              reg_rdata = 32'hDEAD_BAAD;
            endcase
        end

        // ---- ADC Interface (0x020–0x03F) ----
        else if (reg_addr >= ADC_IF_BASE && reg_addr <= ADC_IF_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(adc_dbg, blk_ofs[3:2]);
            end else begin
                // Block-specific registers
                // ADC: 0x30 = iddr_cal_state, 0x34 = cha_sync_count, 0x38 = chb_sync_count
                case (reg_addr)
                    ADC_IDDR_CAL_STATE: reg_rdata = {28'd0, adc_dbg.state};  // placeholder
                    default:            reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- CDC FIFO (0x040–0x05F) ----
        else if (reg_addr >= CDC_FIFO_BASE && reg_addr <= CDC_FIFO_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(cdc_dbg, blk_ofs[3:2]);
            end else begin
                // CDC: 0x50 = fill_level[5:0], 0x54 = watermark[5:0]
                case (reg_addr)
                    CDC_FILL_LEVEL: reg_rdata = {26'd0, cdc_dbg.event_count[5:0]};  // placeholder
                    CDC_WATERMARK:  reg_rdata = {26'd0, cdc_dbg.event_count[5:0]};  // placeholder
                    default:        reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- Glitch Filter (0x060–0x07F) ----
        else if (reg_addr >= GLITCH_FILTER_BASE && reg_addr <= GLT_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(glitch_dbg, blk_ofs[3:2]);
            end else begin
                case (reg_addr)
                    GLT_MAX_DELTA: reg_rdata = {16'd0, glitch_max_delta};
                    GLT_THRESHOLD: reg_rdata = {16'd0, glitch_threshold};
                    default:       reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- Circular Buffer (0x080–0x09F) ----
        else if (reg_addr >= CIRC_BUF_BASE && reg_addr <= CBUF_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(cbuf_dbg, blk_ofs[3:2]);
            end else begin
                case (reg_addr)
                    BUF_WR_PTR:    reg_rdata = {19'd0, cbuf_wr_ptr};
                    BUF_RD_PTR:    reg_rdata = {19'd0, cbuf_rd_ptr};
                    BUF_COLLISION: reg_rdata = {31'd0, cbuf_collision};
                    BUF_WATERMARK: reg_rdata = {19'd0, cbuf_watermark};
                    default:       reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- Trigger (0x0A0–0x0BF) ----
        else if (reg_addr >= TRIGGER_BASE && reg_addr <= TRIG_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(trigger_dbg, blk_ofs[3:2]);
            end else begin
                case (reg_addr)
                    TRIG_THRESHOLD:           reg_rdata = {16'd0, trigger_threshold};
                    TRIG_THRESHOLD_CROSS_RATE: reg_rdata = {16'd0, trigger_cross_rate};
                    TRIG_HOLDOFF_REMAINING:   reg_rdata = {16'd0, trigger_holdoff_remaining};
                    TRIG_ARMED:               reg_rdata = {31'd0, trigger_armed};
                    default:                  reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- Continuous Capture (0x0C0–0x0DF) — DEFERRED, return zero ----
        else if (reg_addr >= CONT_CAP_BASE && reg_addr <= CONT_CAP_END) begin
            reg_rdata = 32'd0;  // deferred block — not yet implemented
        end

        // ---- Descriptor FIFO (0x0E0–0x0FF) ----
        else if (reg_addr >= DESC_FIFO_BASE && reg_addr <= DESC_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(desc_dbg, blk_ofs[3:2]);
            end else begin
                case (reg_addr)
                    DESC_FILL_LEVEL:     reg_rdata = {26'd0, desc_fill_level};
                    DESC_WATERMARK:      reg_rdata = {26'd0, desc_watermark};
                    DESC_LOST_EVENT_CNT: reg_rdata = {16'd0, desc_lost_event_count};
                    default:             reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- Waveform Reader (0x100–0x11F) ----
        else if (reg_addr >= WF_READER_BASE && reg_addr <= READER_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(reader_dbg, blk_ofs[3:2]);
            end else begin
                case (reg_addr)
                    WFR_REMAINING:    reg_rdata = {16'd0, reader_remaining};
                    WFR_WRAP_HANDLED: reg_rdata = {16'd0, reader_wrap_handled};
                    default:          reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- TX FIFO (0x120–0x13F) ----
        else if (reg_addr >= TX_FIFO_BASE && reg_addr <= TX_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(tx_dbg, blk_ofs[3:2]);
            end else begin
                case (reg_addr)
                    TX_FILL_LEVEL: reg_rdata = {20'd0, tx_fill_level};
                    TX_WATERMARK:  reg_rdata = {20'd0, tx_watermark};
                    TX_DPTI_STALL: reg_rdata = {16'd0, tx_dpti_stall};
                    default:       reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- DPTI Bridge (0x140–0x15F) ----
        else if (reg_addr >= DPTI_BASE && reg_addr <= DPTI_END) begin
            if (blk_ofs < DBG_SPECIFIC_0[4:0]) begin
                reg_rdata = dbg_slice(dpti_dbg, blk_ofs[3:2]);
            end else begin
                case (reg_addr)
                    DPTI_RX_CMD_CNT:      reg_rdata = {16'd0, dpti_rx_cmd_count};
                    DPTI_BUS_TURNAROUNDS: reg_rdata = {16'd0, dpti_bus_turnarounds};
                    default:              reg_rdata = 32'hDEAD_BAAD;
                endcase
            end
        end

        // ---- BIST Control (0x1E0–0x1FF) — DEFERRED, return zero ----
        else if (reg_addr >= BIST_BASE && reg_addr <= BIST_END) begin
            reg_rdata = 32'd0;  // deferred block — not yet implemented
        end
    end

endmodule : audit_aggregator
