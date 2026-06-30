//------------------------------------------------------------------------------
// dbg_pkg.sv
//
// Debug package for the data_engine acquisition pipeline.
// Defines the standard debug interface types used by every pipeline block.
//
// Architecture reference: Architecture.md §12.1 (dbg_info_t), §12.4 (register map)
// Debug register map: docs/debug_register_map.md (authoritative field layout)
//------------------------------------------------------------------------------
// Copyright (c) 2026 Tran Hai Nam
// This is a non-commercial academic/research project.
// Contact thnam@dnri.vn for commercial licensing.
//------------------------------------------------------------------------------

package dbg_pkg;

    // ---------------------------------------------------------------------------
    // Debug Info Struct (128-bit packed = 4 × 32-bit registers)
    // Common to all pipeline blocks. Maps directly to COMMON_0..COMMON_3 registers
    // in the Audit Aggregator register map.
    //
    // Layout (MSB first, 32-bit-aligned for clean 4-register access):
    //
    // Reg+0x00 (bits 127:96) — FSM state & cycle counters
    //   [127:124] state         — FSM state (0 = IDLE, block-specific encoding)
    //   [123:108] cycle_count   — cycles since reset (16-bit, wraps)
    //   [107:100] stall_cycles  — cycles waiting on backpressure (8-bit, saturating)
    //   [99:96]   reserved_0    — zero
    //
    // Reg+0x04 (bits 95:64) — Error & bypass
    //   [95]     error         — sticky error flag (write 1 to clear)
    //   [94:87]  error_id      — which error fired (block-specific, 0 = no error)
    //   [86]     bypass_mode   — 1 = block bypassed (pass-through)
    //   [85:64]  reserved_1    — zero
    //
    // Reg+0x08 (bits 63:32) — Event count
    //   [63:48]  event_count   — events processed by this block (write 1 to clear)
    //   [47:32]  reserved_2    — zero
    //
    // Reg+0x0C (bits 31:0) — Word count
    //   [31:16]  word_count    — words consumed/produced (write 1 to clear)
    //   [15:0]   reserved_3    — zero
    // ---------------------------------------------------------------------------
    typedef struct packed {
        // Reg+0x00
        logic [3:0]  state;           // [127:124] FSM state
        logic [15:0] cycle_count;     // [123:108] cycles since reset
        logic [7:0]  stall_cycles;    // [107:100] stall cycles
        logic [3:0]  reserved_0;      // [99:96]   reserved

        // Reg+0x04
        logic        error;           // [95]    sticky error flag
        logic [7:0]  error_id;        // [94:87] error identifier
        logic        bypass_mode;     // [86]    bypass mode flag
        logic [21:0] reserved_1;      // [85:64] reserved

        // Reg+0x08
        logic [15:0] event_count;     // [63:48] events processed
        logic [15:0] reserved_2;      // [47:32] reserved

        // Reg+0x0C
        logic [15:0] word_count;      // [31:16] words consumed/produced
        logic [15:0] reserved_3;      // [15:0]  reserved
    } dbg_info_t;                     // Total: 128 bits = 4 × 32-bit registers

    // ---------------------------------------------------------------------------
    // Debug Monitor Struct (optional)
    // Collects all block debug states for atomic snapshot by the Audit Aggregator.
    // Total: 10 blocks × 128 bits = 1280 bits.
    // ---------------------------------------------------------------------------
    typedef struct packed {
        dbg_info_t adc_interface;
        dbg_info_t cdc_fifo;
        dbg_info_t glitch_filter;
        dbg_info_t circular_buffer;
        dbg_info_t trigger;
        dbg_info_t continuous_capture;
        dbg_info_t descriptor_fifo;
        dbg_info_t waveform_reader;
        dbg_info_t tx_fifo;
        dbg_info_t dpti_bridge;
    } dbg_monitor_t;

endpackage : dbg_pkg

// ---------------------------------------------------------------------------
// Debug Interface (dbg_if)
// Standard debug port exposed by every pipeline block.
// When unconnected, the synthesiser optimises away the debug logic.
//
// Usage:
//   module my_block (
//       input  logic clk,
//       output dbg_if.db_source dbg  // block drives clk + info
//   );
//       dbg.info <= ...;
//       dbg.clk  <= clk;
//   endmodule
// ---------------------------------------------------------------------------
interface dbg_if;
    logic                clk;    // module's clock domain
    dbg_pkg::dbg_info_t  info;   // 128-bit packed debug data

    modport source (output clk, output info);
    modport monitor (input clk, input info);
endinterface : dbg_if
