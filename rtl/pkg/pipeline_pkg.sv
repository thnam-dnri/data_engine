//------------------------------------------------------------------------------
// pipeline_pkg.sv
//
// Shared type definitions for the data_engine acquisition pipeline.
// Defines the data token, descriptor, and enum types used by all pipeline stages.
//
// Architecture reference: Architecture.md §12.2 (sample_token_t), §8 (descriptor_t)
//                         §12.5 (bist_pattern_t)
//------------------------------------------------------------------------------
// Copyright (c) 2026 Tran Hai Nam
// This is a non-commercial academic/research project.
// Contact thnam@dnri.vn for commercial licensing.
//------------------------------------------------------------------------------

package pipeline_pkg;

    // ---------------------------------------------------------------------------
    // Sample Continuity Token (53-bit packed)
    // Propagated alongside every data sample through the pipeline.
    // seq_id must increment monotonically; a gap means a sample was dropped.
    //
    // Layout (MSB first):
    //   [52]    valid       — data valid
    //   [51:36] sample      — ADC sample (16-bit, zero-extended from 14-bit)
    //   [35:4]  seq_id      — monotonic sample sequence ID (32-bit)
    //   [3:0]   flags       — metadata flags
    // ---------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;     // [52]   data valid
        logic [15:0] sample;    // [51:36] ADC sample (16-bit, zero-extended from 14-bit)
        logic [31:0] seq_id;    // [35:4]  monotonic sample sequence ID
        logic [3:0]  flags;     // [3:0]   metadata flags
    } sample_token_t;           // Total: 53 bits

    // ---------------------------------------------------------------------------
    // Trigger Type Enum (2-bit)
    // ---------------------------------------------------------------------------
    typedef enum logic [1:0] {
        TRIG_LEADING_EDGE = 2'b00,
        TRIG_CFD          = 2'b01,
        TRIG_ML           = 2'b10
    } trigger_type_t;

    // ---------------------------------------------------------------------------
    // Frame Type Enum (8-bit)
    // Matches the frame type tags in the host interface packet format (§Host Interface).
    // ---------------------------------------------------------------------------
    typedef enum logic [7:0] {
        FRAME_TRIGGER_DESC      = 8'h01,  // Trigger descriptor (metadata only)
        FRAME_WAVEFORM          = 8'h02,  // Waveform payload (descriptor + sample array)
        FRAME_CONTINUOUS        = 8'h03,  // Continuous sample block (burst-only)
        FRAME_DIAG_SNAPSHOT     = 8'h04,  // Diagnostic snapshot (periodic provenance)
        FRAME_CMD_RESPONSE      = 8'h05,  // Command response (DPTI register access)
        FRAME_RUN_HEADER        = 8'hFE,  // Run header (start of acquisition)
        FRAME_RUN_FOOTER        = 8'hFF   // Run footer (end of acquisition)
    } frame_type_t;

    // ---------------------------------------------------------------------------
    // BIST Pattern Enum (3-bit)
    // Matches Architecture.md §12.5.
    // ---------------------------------------------------------------------------
    typedef enum logic [2:0] {
        BIST_RAMP           = 3'd0,  // Linear ramp 0..65535 (wrapping)
        BIST_ALT_MAX_MIN    = 3'd1,  // Alternating max/min (0, 65535, 0, ...)
        BIST_PULSE          = 3'd2,  // Single pulse with known rise time
        BIST_PRBS           = 3'd3,  // LFSR-16 pseudo-random bit sequence
        BIST_GLITCH_INJECT  = 3'd4   // Ramp + 0x0C98 glitch every 256 cycles
    } bist_pattern_t;

    // ---------------------------------------------------------------------------
    // Event Descriptor (160-bit packed)
    // Metadata for a single trigger event, pushed to the Descriptor FIFO.
    // Each waveform packet bundles the descriptor with its sample payload.
    //
    // Layout (MSB first):
    //   [159:112] timestamp         — sample counter at trigger point (48-bit)
    //   [111:96]  amplitude         — peak sample value (16-bit)
    //   [95:80]   energy            — integrated area under pulse (16-bit)
    //   [79:78]   trigger_type      — which trigger mode fired (2-bit)
    //   [77:65]   waveform_offset   — buffer address of pretrigger start (13-bit, 8192-depth)
    //   [64:54]   waveform_length   — number of samples to read (11-bit, up to 2048)
    //   [53]      channel_id        — which ADC channel triggered (1-bit)
    //   [52:37]   board_id          — unique board identifier (16-bit)
    //   [36:5]    firmware_version  — bitfile version (32-bit)
    //   [4:0]     diag_snapshot     — coprocessed status at trigger time (5-bit)
    // ---------------------------------------------------------------------------
    typedef struct packed {
        logic [47:0] timestamp;         // [159:112] sample counter at trigger point
        logic [15:0] amplitude;         // [111:96]  peak sample value (or CFD interpolated)
        logic [15:0] energy;            // [95:80]   integrated area under pulse
        logic [1:0]  trigger_type;      // [79:78]   which trigger mode fired
        logic [12:0] waveform_offset;   // [77:65]   buffer address of pretrigger start
        logic [10:0] waveform_length;   // [64:54]   number of samples to read (up to 2048)
        logic        channel_id;        // [53]      which ADC channel triggered
        logic [15:0] board_id;          // [52:37]   unique board identifier
        logic [31:0] firmware_version;  // [36:5]    bitfile version
        logic [4:0]  diag_snapshot;     // [4:0]     coprocessed status at trigger time
    } descriptor_t;                     // Total: 160 bits

endpackage : pipeline_pkg
