//------------------------------------------------------------------------------
// top_pipeline.sv
//
// Phase 2.7 — FULL EVENT PIPELINE INTEGRATION
//
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Complete data path:
//   ADC (105 MSPS, 14-bit) → IDDR (adc_interface) → CDC FIFO (dco_clk→sys_clk)
//     → Glitch Filter → Circular Buffer (8192×16, capture memory)
//     → Trigger (LEADING_EDGE) → Descriptor FIFO (160-bit FWFT, event metadata)
//     → Waveform Reader (burst read, 1800 samples/window)
//     → TX Waveform FIFO (dual-clock, sys_clk→ft_clk, 4096×16)
//     → Drain FSM (byte splitter, packet builder)
//     → comm_dpti (DPTI sync FIFO to FT232H) → Host PC
//
// Key invariants (Issue 001 §0.4):
//   - Circular buffer write pointer (Port A) advances UNCONDITIONALLY
//   - DPTI / USB backpressure NEVER reaches the ADC
//   - TX FIFO may stall the waveform reader, never the buffer
//
// Event window: 1800 samples (600 pre-trigger + 1200 post-trigger = 17.14 µs
// @ 105 MSPS). Per-event packet to host: A5 5A + event_id + 1800 × 2 bytes
// (MSB first, then LSB per sample).
//
// Architecture reference: Architecture.md (all sections), implementation_strategy.md §Phase 2
// Pin constraints: hardware_spec/USB104_A7_Zmod_ADC1410.xdc
// Timing constraints: constraints/timing.xdc
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

import dbg_pkg::*;

module top_pipeline (
    // --- 100 MHz On-Board Oscillator ---
    input  wire       clk,            // E3, LVCMOS33

    // --- Zmod ADC 1410 Interface (SYZYGY) ---
    input  wire [13:0] adc_data,      // ADC_DATA_0[13:0] (LVCMOS18)
    input  wire       adc_dco,        // ADC data clock out (LVCMOS18)
    output wire       adc_clk_p,      // ADC sample clock P (DIFF_SSTL18_I)
    output wire       adc_clk_n,      // ADC sample clock N (DIFF_SSTL18_I)

    // --- Analog Front-End Control ---
    output wire       ch1_ac_h,
    output wire       ch1_ac_l,
    output wire       ch1_gain_h,
    output wire       ch1_gain_l,
    output wire       ch2_ac_h,
    output wire       ch2_ac_l,
    output wire       ch2_gain_h,
    output wire       ch2_gain_l,
    output wire       com_couple_h,
    output wire       com_couple_l,

    // --- SPI for ADC Internal Registers ---
    output wire       adc_spi_sdio,
    output wire       adc_spi_sclk,
    output wire       adc_spi_cs,

    // --- I2C for Zmod Front-End (CDCE6214) ---
    inout  wire       adc_scl,
    inout  wire       adc_sda,

    // --- Board I/O ---
    output wire [3:0] led,

    // --- DPTI (FT232H Synchronous FIFO) ---
    input  wire       dpti_clk,       // prog_clko = 60 MHz (P17)
    inout  wire [7:0] dpti_data,      // prog_d[7:0]
    input  wire       dpti_txen,      // prog_txen (active low)
    input  wire       dpti_rxen,      // prog_rxen (active low)
    output wire       dpti_wrn,       // prog_wrn (active low)
    output wire       dpti_rdn,       // prog_rdn (active low)
    output wire       dpti_oen,       // prog_oen (active low)
    output wire       dpti_siwun,     // prog_siwun
    output wire       dpti_spien      // prog_spien
);

    // =========================================================================
    // Event window parameters
    // =========================================================================
    localparam [10:0] PRE_SAMPLES   = 11'd600;
    localparam [10:0] POST_SAMPLES  = 11'd1200;
    localparam [10:0] TOTAL_SAMPLES = PRE_SAMPLES + POST_SAMPLES;  // 1800
    // Localparam for descriptor width (matches pipeline_pkg::descriptor_t).
    localparam DW = 160;

    // Trigger config (adaptive negative-edge on chA, 14-bit)
    //   CFG_THRESHOLD / CFG_HYSTERESIS: legacy fallback used only when the
    //     host sends the adaptive-bypass command (0x09). Default = adaptive.
    //   CFG_HOLDOFF = 6000 (60 µs): spans the ~50 µs pulse decay so the
    //     baseline/sigma EMAs (frozen during HOLDOFF) cannot chase the tail.
    //     At 1 kHz pulser this leaves 940 µs of re-arm window — ample.
    localparam [15:0] CFG_THRESHOLD  = 16'd6000;   // bypass-mode fallback (below baseline ~8400)
    localparam [15:0] CFG_HYSTERESIS = 16'd100;
    localparam [23:0] CFG_HOLDOFF    = 24'd6000;   // 60 µs (covers 50 µs decay + margin)
    localparam        CFG_POLARITY   = 1'b1;       // 0 = positive edge, 1 = negative (signal inverts negative)

    // Adaptive trigger parameters (spec: Downloads/fpga_trigger_upgrade_spec.md)
    localparam        CFG_BOXCAR_N   = 8;          // boxcar depth (power-of-2)
    localparam        CFG_K_SIGMA    = 5;          // threshold = baseline - k·sigma
    localparam        CFG_EMA_SHIFT  = 8;          // EMA constant 1/256
    localparam        CFG_WARMUP     = 1024;       // ~10 µs baseline/sigma settle
    localparam        CFG_VALIDATE_N = 16;         // post-crossing shape validation
    localparam [12:0] CFG_VALIDATE_BACKSTEP = CFG_VALIDATE_N[12:0];

    // Glitch filter threshold — SEPARATE from the trigger threshold.
    // Architecture.md §3: AD9648 0x0C98 glitch jump = 1376–4968 counts,
    // normal slew max 135 counts/sample → detection threshold = 500.
    // (Was wrongly wired to CFG_THRESHOLD = 8000, which disabled the filter
    //  and let the 0x0C98 value 3224 < 8000 fire the trigger on every glitch.)
    localparam [15:0] CFG_GLITCH_THRESHOLD = 16'd500;

    // =========================================================================
    // Clock generation
    // =========================================================================
    wire sys_clk = clk;

    // BUFG the DCO for downstream CDC
    wire dco_clk;
    BUFG u_dco_bufg (.I(adc_dco), .O(dco_clk));

    // OBUFDS for ADC sample clock
    OBUFDS #(.IOSTANDARD("DIFF_SSTL18_I"), .SLEW("SLOW"))
    u_adc_clk_obuf (.O(adc_clk_p), .OB(adc_clk_n), .I(sys_clk));

    // =========================================================================
    // Power-on reset
    // =========================================================================
    reg [3:0] rst_cnt;
    reg       rst_n;
    always @(posedge sys_clk) begin
        if (&rst_cnt) rst_n <= 1'b1;
        else begin rst_cnt <= rst_cnt + 1'b1; rst_n <= 1'b0; end
    end

    // =========================================================================
    // Front-end settings (AC coupling, high gain)
    // =========================================================================
    assign ch1_ac_h     = 1'b1;
    assign ch1_ac_l     = 1'b0;
    assign ch1_gain_h   = 1'b1;
    assign ch1_gain_l   = 1'b0;
    assign ch2_ac_h     = 1'b1;
    assign ch2_ac_l     = 1'b0;
    assign ch2_gain_h   = 1'b1;
    assign ch2_gain_l   = 1'b0;
    assign com_couple_h = 1'b1;
    assign com_couple_l = 1'b0;

    // ---- dbg_info_t wires for all pipeline blocks (connected to audit_aggregator) ----
    dbg_info_t  adc_dbg_info;
    dbg_info_t  cdc_dbg_info;
    dbg_info_t  glitch_dbg_info;
    wire [15:0] glitch_dbg_max_delta;
    dbg_info_t  cbuf_dbg_info;
    dbg_info_t  desc_dbg_info;
    dbg_info_t  reader_dbg_info;
    dbg_info_t  tx_dbg_info;
    dbg_info_t  dpti_dbg_info;

    // =========================================================================
    // ADC init (I2C + SPI) — kept from Phase 1
    // =========================================================================
    wire cdce_init_done;
    cdce_iic_init u_cdce_init (
        .clk(sys_clk), .rst_n(rst_n),
        .i2c_scl(adc_scl), .i2c_sda(adc_sda),
        .init_done(cdce_init_done)
    );
    wire adc_init_done;
    adc_spi_init u_adc_init (
        .clk(sys_clk), .rst_n(rst_n && cdce_init_done),
        .spi_sdio(adc_spi_sdio), .spi_sclk(adc_spi_sclk), .spi_cs(adc_spi_cs),
        .init_done(adc_init_done)
    );

    // =========================================================================
    // ADC Interface (IDDR + channel mux, on dco_clk domain)
    // =========================================================================
    wire [15:0] ch_a_data, ch_b_data;
    wire        adc_dv_dco;
    wire        adc_ch_sel = 1'b0;  // 0 = chA (Phase 2 single-channel)
    wire        dco_loss;
    wire        dco_clk_out;

    adc_interface u_adc_if (
        .adc_dco    (adc_dco),
        .sys_clk    (sys_clk),
        .sys_rst_n  (rst_n),
        .dco_clk_out(dco_clk_out),
        .adc_data   (adc_data),
        .ch_a_data  (ch_a_data),
        .ch_b_data  (ch_b_data),
        .data_valid (adc_dv_dco),
        .channel_sel(adc_ch_sel),
        .dbg_info   (adc_dbg_info)
    );

    // =========================================================================
    // CDC FIFO (dco_clk → sys_clk)
    // =========================================================================
    wire [31:0] cdc_dout;
    wire        cdc_empty;
    cdc_fifo u_cdc_fifo (
        .wr_clk    (dco_clk_out),
        .wr_rst_n  (rst_n),
        .wr_en     (adc_dv_dco),
        .din       ({ch_b_data, ch_a_data}),
        .full      (),
        .rd_clk    (sys_clk),
        .rd_rst_n  (rst_n),
        .rd_en     (!cdc_empty),
        .dout      (cdc_dout),
        .empty     (cdc_empty),
        .dbg_info  (cdc_dbg_info)
    );

    // =========================================================================
    // Channel select + 16-bit data into the pipeline
    // =========================================================================
    wire [15:0] adc_data_sys = cdc_dout[15:0];  // chA (lower 16 bits, 14-bit zero-padded)

    // =========================================================================
    // Glitch filter
    // =========================================================================
    wire [15:0] glitch_out;
    wire        glitch_dv;
    reg         glitch_filter_en = 1'b1;
    wire        glitch_bypass = !glitch_filter_en;
    glitch_filter u_glitch (
        .clk     (sys_clk),
        .rst_n   (rst_n),
        .din     (adc_data_sys),
        .din_valid(!cdc_empty),
        .dout    (glitch_out),
        .dout_valid(glitch_dv),
        .threshold(CFG_GLITCH_THRESHOLD),
        .bypass  (glitch_bypass),
        .dbg_info(glitch_dbg_info),
        .dbg_max_delta(glitch_dbg_max_delta),
        .heartbeat()  // not exposed externally in Phase 2.7
    );

    // =========================================================================
    // 48-bit free-running sample counter (timestamp source)
    // =========================================================================
    reg [47:0] sample_counter;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) sample_counter <= 48'd0;
        else if (glitch_dv) sample_counter <= sample_counter + 1'b1;
    end

    // =========================================================================
    // Event counter (latched at trigger for descriptor event_id)
    // =========================================================================
    wire trigger_pulse;
    reg  event_arm = 1'b0;
    wire trigger_capture_ready;
    reg  desc_pending;
    wire desc_fifo_full;
    wire desc_fifo_empty;
    wire reader_busy;
    reg  event_active;
    reg  new_event_pending;

    reg [15:0] event_counter;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) event_counter <= 16'd0;
        else if (event_arm && trigger_pulse) event_counter <= event_counter + 1'b1;
    end

    // =========================================================================
    // 64-bit free-running run timestamp (for audit_aggregator system registers)
    // =========================================================================
    reg [63:0] run_timestamp;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) run_timestamp <= 64'd0;
        else run_timestamp <= run_timestamp + 1'b1;
    end

    // =========================================================================
    // Trigger (LEADING_EDGE only)
    // =========================================================================
    wire armed;
    wire triggered;
    wire [47:0] event_timestamp;
    wire [15:0] dbg_baseline;
    wire [15:0] dbg_sigma;
    dbg_info_t  trigger_dbg_info;

    reg  adaptive_bypass = 1'b0;   // 0 = adaptive (default), 1 = legacy fixed-threshold
    trigger #(
        .BOXCAR_N  (CFG_BOXCAR_N),
        .K_SIGMA   (CFG_K_SIGMA),
        .EMA_SHIFT (CFG_EMA_SHIFT),
        .WARMUP    (CFG_WARMUP),
        .VALIDATE_N(CFG_VALIDATE_N)
    ) u_trigger (
        .clk            (sys_clk),
        .rst_n          (rst_n),
        .arm            (trigger_capture_ready),
        .adc_data       (glitch_out),
        .adc_dv         (glitch_dv),
        .cfg_threshold  (CFG_THRESHOLD),
        .cfg_hysteresis (CFG_HYSTERESIS),
        .cfg_holdoff    (CFG_HOLDOFF),
        .cfg_polarity   (CFG_POLARITY),
        .cfg_adaptive_bypass(adaptive_bypass),
        .sample_count   (sample_counter),
        .trigger_pulse  (trigger_pulse),
        .armed          (armed),
        .triggered      (triggered),
        .event_timestamp(event_timestamp),
        .dbg_baseline   (dbg_baseline),
        .dbg_sigma      (dbg_sigma),
        .dbg_info       (trigger_dbg_info)
    );

    // =========================================================================
    // Circular buffer (8192 × 16, Port A write always-on)
    // =========================================================================
    wire [12:0] cbuf_wr_ptr;
    wire [12:0] cbuf_rd_addr;
    wire [15:0] cbuf_rd_data;
    wire        cbuf_rd_en;
    wire        cbuf_collision;

    circular_buffer u_cbuf (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .wr_en    (glitch_dv),
        .wr_data  (glitch_out),
        .wr_ptr   (cbuf_wr_ptr),
        .rd_en    (cbuf_rd_en),
        .rd_addr  (cbuf_rd_addr),
        .rd_data  (cbuf_rd_data),
        .dbg_info (cbuf_dbg_info)
    );

    // =========================================================================
    // Event FSM: capture trigger data, build descriptor, push to FIFO
    // =========================================================================
    // Cycle 1: trigger fires → snapshot wr_ptr, event_id, timestamp
    // Cycle 2: push descriptor to FIFO
    // =========================================================================
    reg [12:0] trig_ptr_cap;
    reg [15:0] event_id_cap;
    reg [47:0] ts_cap;
    reg        desc_push;
    reg [15:0] lost_event_counter;

    // 160-bit descriptor
    wire [12:0] start_addr = trig_ptr_cap - PRE_SAMPLES;  // 13-bit wrap
    wire [DW-1:0] descriptor;
    assign descriptor = {
        ts_cap,                  // [159:112] timestamp (48-bit)
        16'd0,                   // [111:96]  amplitude (TODO: compute from waveform)
        16'd0,                   // [95:80]   energy (TODO: compute from waveform)
        2'b00,                   // [79:78]   trigger_type = LEADING_EDGE
        start_addr,              // [77:65]   waveform_offset
        TOTAL_SAMPLES,           // [64:54]   waveform_length
        1'b0,                    // [53]      channel_id = 0 (chA)
        event_id_cap,            // [52:37]   event_id (overloads board_id slot for packet header)
        32'h2026_0701,           // [36:5]    firmware_version (YYYYMMDD)
        5'd0                     // [4:0]     diag_snapshot
    };

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            desc_pending  <= 1'b0;
            desc_push     <= 1'b0;
            trig_ptr_cap  <= 13'd0;
            event_id_cap  <= 16'd0;
            ts_cap        <= 48'd0;
            lost_event_counter <= 16'd0;
        end else begin
            desc_push <= 1'b0;
            // Cycle 1: capture trigger data
            if (trigger_pulse) begin
                if (desc_fifo_full) begin
                    lost_event_counter <= lost_event_counter + 1'b1;
                end else begin
                    trig_ptr_cap <= cbuf_wr_ptr -
                                    (adaptive_bypass ? 13'd0 : CFG_VALIDATE_BACKSTEP);
                    event_id_cap <= event_counter;
                    ts_cap       <= event_timestamp;
                    desc_pending <= 1'b1;
                end
            end
            // Cycle 2: push the descriptor
            if (desc_pending) begin
                desc_push    <= 1'b1;
                desc_pending <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Descriptor FIFO (64×160 FWFT)
    // =========================================================================
    wire [DW-1:0] desc_fifo_data;
    wire          desc_pop_req;
    wire [7:0]    desc_count;
    wire          desc_lost_pulse;

    event_descriptor_fifo u_desc_fifo (
        .clk             (sys_clk),
        .rst_n           (rst_n),
        .push_req        (desc_push),
        .push_data       (descriptor),
        .full            (desc_fifo_full),
        .pop_req         (desc_pop_req),
        .pop_data        (desc_fifo_data),
        .empty           (desc_fifo_empty),
        .count           (desc_count),
        .lost_event_pulse(desc_lost_pulse),
        .dbg_info        (desc_dbg_info)
    );

    // =========================================================================
    // TX Waveform FIFO signals
    // The drain FSM and comm_dpti sys-side handshake are both in sys_clk, so the
    // FIFO read side is also sys_clk. comm_dpti performs the sys_clk→dpti_clk CDC.
    // =========================================================================
    wire [15:0] tx_fifo_pop_data;
    wire        tx_fifo_empty;
    wire [12:0] tx_fifo_count;
    wire        tx_fifo_full;
    wire [12:0] tx_fifo_wr_count;

    // =========================================================================
    // Drain FSM state is declared before waveform_reader/status logic because
    // reader throttling and status snapshots both reference these live fields.
    // =========================================================================
    reg [3:0]  dr_state;
    reg [15:0] dr_sample_buf;
    reg [11:0] dr_sample_cnt;
    reg        drain_rd_req;
    reg [7:0]  dr_tx_byte;
    reg        dr_tx_valid;
    reg [15:0] dr_event_id;
    reg [11:0] dr_event_length;

    reg [15:0] pending_event_id;
    reg [11:0] pending_length;

    // =========================================================================
    // Waveform reader (bursts 1800 samples from circular buffer)
    // =========================================================================
    wire reader_sample_valid;
    wire [15:0] reader_sample_data;
    wire        reader_burst_start;
    wire [DW-1:0] reader_burst_descriptor;
    wire [10:0] reader_burst_remaining;
    wire        reader_desc_empty = desc_fifo_empty | new_event_pending | event_active;
    assign trigger_capture_ready = event_arm && adc_init_done &&
                                   !desc_pending && desc_fifo_empty &&
                                   !reader_busy && !new_event_pending &&
                                   !event_active;

    waveform_reader u_reader (
        .clk             (sys_clk),
        .rst_n           (rst_n),
        .desc_empty      (reader_desc_empty),
        .desc_data       (desc_fifo_data),
        .desc_pop_req    (desc_pop_req),
        .cbuf_rd_addr    (cbuf_rd_addr),
        .cbuf_rd_data    (cbuf_rd_data),
        .sample_valid    (reader_sample_valid),
        .sample_data     (reader_sample_data),
        .tx_full         (tx_fifo_full),
        .burst_start     (reader_burst_start),
        .burst_descriptor(reader_burst_descriptor),
        .burst_remaining (reader_burst_remaining),
        .busy            (reader_busy),
        .dbg_info        (reader_dbg_info)
    );

    // =========================================================================
    // TX Waveform FIFO
    // =========================================================================
    tx_wave_fifo u_tx_fifo (
        .wr_clk  (sys_clk),
        .wr_rst_n(rst_n),
        .wr_req  (reader_sample_valid),
        .wr_data (reader_sample_data),
        .full    (tx_fifo_full),
        .rd_clk  (sys_clk),
        .rd_rst_n(rst_n),
        .rd_req  (drain_rd_req),
        .pop_data(tx_fifo_pop_data),
        .empty   (tx_fifo_empty),
        .wr_count(tx_fifo_wr_count),
        .dbg_info(tx_dbg_info)
    );

    // =========================================================================
    // DPTI interface (comm_dpti)
    // =========================================================================
    wire [7:0] dpti_tx_data;
    wire       dpti_tx_wr;
    wire       dpti_tx_rdy;
    wire [7:0] dpti_rx_data;
    wire       dpti_rx_vld;
    wire       dpti_rx_rd;

    comm_dpti u_comm_dpti (
        .sys_clk    (sys_clk),
        .sys_rst_n  (rst_n),
        .sys_tx_data(dpti_tx_data),
        .sys_tx_wr  (dpti_tx_wr),
        .sys_tx_rdy (dpti_tx_rdy),
        .sys_rx_data(dpti_rx_data),
        .sys_rx_vld (dpti_rx_vld),
        .sys_rx_rd  (dpti_rx_rd),
        .dpti_clk   (dpti_clk),
        .dpti_data  (dpti_data),
        .dpti_txen  (dpti_txen),
        .dpti_rxen  (dpti_rxen),
        .dpti_wrn   (dpti_wrn),
        .dpti_rdn   (dpti_rdn),
        .dpti_oen   (dpti_oen),
        .dpti_siwun (dpti_siwun),
        .dpti_spien (dpti_spien),
        .dbg_info   (dpti_dbg_info)
    );

    // =========================================================================
    // Debug status response
    // Host command 0x0B snapshots key health signals and returns a 32-byte
    // packet over the same DPTI TX path:
    //   D1 6D 01 20, flags[15:0], {trigger_state,dr_state}, desc_count,
    //   sample_count[15:0], event_counter, baseline, sigma, cbuf_wr_ptr,
    //   tx_fifo_wr_count, reader_remaining, lost_events, crossing_count,
    //   trigger_count, live_flags, dr_sample_cnt, status_seq, checksum.
    // =========================================================================
    localparam [7:0] STATUS_SYNC_HI = 8'hD1;
    localparam [7:0] STATUS_SYNC_LO = 8'h6D;
    localparam [7:0] STATUS_VERSION = 8'h01;
    localparam [7:0] STATUS_LEN     = 8'd32;

    reg        status_req;
    reg        status_cmd_pulse;
    reg        status_active;
    reg [4:0]  status_idx;
    reg [7:0]  status_seq;

    reg [15:0] st_flags;
    reg [3:0]  st_trigger_state;
    reg [3:0]  st_dr_state;
    reg [7:0]  st_desc_count;
    reg [15:0] st_sample_count;
    reg [15:0] st_event_counter;
    reg [15:0] st_baseline;
    reg [15:0] st_sigma;
    reg [15:0] st_cbuf_wr_ptr;
    reg [15:0] st_tx_fifo_wr_count;
    reg [15:0] st_reader_remaining;
    reg [15:0] st_lost_event_counter;
    reg [15:0] st_crossing_count;
    reg [15:0] st_trigger_count;
    reg [7:0]  st_live_flags;
    reg [7:0]  st_dr_sample_cnt;

    wire [7:0] status_checksum =
        STATUS_SYNC_HI ^ STATUS_SYNC_LO ^ STATUS_VERSION ^ STATUS_LEN ^
        st_flags[15:8] ^ st_flags[7:0] ^
        {st_trigger_state, st_dr_state} ^ st_desc_count ^
        st_sample_count[15:8] ^ st_sample_count[7:0] ^
        st_event_counter[15:8] ^ st_event_counter[7:0] ^
        st_baseline[15:8] ^ st_baseline[7:0] ^
        st_sigma[15:8] ^ st_sigma[7:0] ^
        st_cbuf_wr_ptr[15:8] ^ st_cbuf_wr_ptr[7:0] ^
        st_tx_fifo_wr_count[15:8] ^ st_tx_fifo_wr_count[7:0] ^
        st_reader_remaining[15:8] ^ st_reader_remaining[7:0] ^
        st_lost_event_counter[15:8] ^ st_lost_event_counter[7:0] ^
        st_crossing_count[15:8] ^ st_crossing_count[7:0] ^
        st_trigger_count[15:8] ^ st_trigger_count[7:0] ^
        st_live_flags ^ st_dr_sample_cnt ^ status_seq;

    function automatic [7:0] status_byte(input [4:0] idx);
        begin
            case (idx)
                5'd0:  status_byte = STATUS_SYNC_HI;
                5'd1:  status_byte = STATUS_SYNC_LO;
                5'd2:  status_byte = STATUS_VERSION;
                5'd3:  status_byte = STATUS_LEN;
                5'd4:  status_byte = st_flags[15:8];
                5'd5:  status_byte = st_flags[7:0];
                5'd6:  status_byte = {st_trigger_state, st_dr_state};
                5'd7:  status_byte = st_desc_count;
                5'd8:  status_byte = st_sample_count[15:8];
                5'd9:  status_byte = st_sample_count[7:0];
                5'd10: status_byte = st_event_counter[15:8];
                5'd11: status_byte = st_event_counter[7:0];
                5'd12: status_byte = st_baseline[15:8];
                5'd13: status_byte = st_baseline[7:0];
                5'd14: status_byte = st_sigma[15:8];
                5'd15: status_byte = st_sigma[7:0];
                5'd16: status_byte = st_cbuf_wr_ptr[15:8];
                5'd17: status_byte = st_cbuf_wr_ptr[7:0];
                5'd18: status_byte = st_tx_fifo_wr_count[15:8];
                5'd19: status_byte = st_tx_fifo_wr_count[7:0];
                5'd20: status_byte = st_reader_remaining[15:8];
                5'd21: status_byte = st_reader_remaining[7:0];
                5'd22: status_byte = st_lost_event_counter[15:8];
                5'd23: status_byte = st_lost_event_counter[7:0];
                5'd24: status_byte = st_crossing_count[15:8];
                5'd25: status_byte = st_crossing_count[7:0];
                5'd26: status_byte = st_trigger_count[15:8];
                5'd27: status_byte = st_trigger_count[7:0];
                5'd28: status_byte = st_live_flags;
                5'd29: status_byte = st_dr_sample_cnt;
                5'd30: status_byte = status_seq;
                5'd31: status_byte = status_checksum;
                default: status_byte = 8'h00;
            endcase
        end
    endfunction

    wire [7:0] status_tx_byte = status_byte(status_idx);

    // =========================================================================
    // Drain FSM (byte splitter, packet builder)
    // Per event: A5 5A <event_id[15:8]> <event_id[7:0]> <sample[15:8]><sample[7:0]>...
    // Backward-compatible with sig_recorder wire format.
    // =========================================================================
    // Latch event metadata from burst_start
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            new_event_pending <= 1'b0;
            pending_event_id  <= 16'd0;
            pending_length    <= 12'd0;
        end else if (reader_burst_start) begin
            pending_event_id  <= reader_burst_descriptor[52:37];  // event_id from descriptor
            pending_length    <= reader_burst_descriptor[64:54];  // waveform_length
            new_event_pending <= 1'b1;
        end else if (dr_state == 4'd4 && dpti_tx_rdy) begin
            new_event_pending <= 1'b0;
        end
    end

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            dr_event_id     <= 16'd0;
            dr_event_length <= 12'd0;
        end else if (dr_state == 4'd0 && new_event_pending && !tx_fifo_empty) begin
            dr_event_id     <= pending_event_id;
            dr_event_length <= pending_length;
        end
    end

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            dr_state      <= 4'd0;
            dr_sample_buf <= 16'd0;
            dr_sample_cnt <= 12'd0;
            drain_rd_req  <= 1'b0;
            dr_tx_byte    <= 8'd0;
            dr_tx_valid   <= 1'b0;
            event_active  <= 1'b0;
        end else begin
            dr_tx_valid  <= 1'b0;
            drain_rd_req <= 1'b0;

            case (dr_state)
                4'd0: begin  // IDLE
                    event_active <= 1'b0;
                    if (!status_active && !status_req && new_event_pending && !tx_fifo_empty) begin
                        dr_tx_byte    <= 8'hA5;
                        dr_tx_valid   <= 1'b1;
                        event_active  <= 1'b1;
                        dr_state      <= 4'd1;
                    end
                end
                4'd1: begin  // A5
                    event_active <= 1'b1;
                    dr_tx_valid  <= 1'b1;
                    if (dpti_tx_rdy) begin
                        dr_tx_byte <= 8'h5A;
                        dr_state   <= 4'd2;
                    end
                end
                4'd2: begin  // 5A
                    event_active <= 1'b1;
                    dr_tx_valid  <= 1'b1;
                    if (dpti_tx_rdy) begin
                        dr_tx_byte <= dr_event_id[15:8];
                        dr_state   <= 4'd3;
                    end
                end
                4'd3: begin  // event_id[15:8]
                    event_active <= 1'b1;
                    dr_tx_valid  <= 1'b1;
                    if (dpti_tx_rdy) begin
                        dr_tx_byte <= dr_event_id[7:0];
                        dr_state   <= 4'd4;
                    end
                end
                4'd4: begin  // event_id[7:0] then read sample
                    event_active <= 1'b1;
                    dr_tx_valid  <= 1'b1;
                    if (dpti_tx_rdy) begin
                        dr_sample_cnt <= 12'd0;
                        dr_sample_buf <= tx_fifo_pop_data;
                        drain_rd_req  <= 1'b1;
                        dr_state      <= 4'd5;
                    end
                end
                4'd5: begin  // MSB
                    event_active <= 1'b1;
                    dr_tx_byte   <= dr_sample_buf[15:8];
                    dr_tx_valid  <= 1'b1;
                    if (dpti_tx_rdy) dr_state <= 4'd6;
                end
                4'd6: begin  // LSB
                    event_active <= 1'b1;
                    dr_tx_byte   <= dr_sample_buf[7:0];
                    dr_tx_valid  <= 1'b1;
                    if (dpti_tx_rdy) begin
                        dr_sample_cnt <= dr_sample_cnt + 1'b1;
                        if (dr_sample_cnt >= (dr_event_length - 1'b1)) begin
                            // FIX 2026-07-01: do NOT clear event_active here — the
                            // LSB of the last sample is being driven on dr_tx_byte
                            // right now; clearing event_active in the same cycle
                            // would cause dpti_tx_wr to de-assert, dropping the
                            // final byte. State 4'd0 clears event_active next cycle.
                            dr_state     <= 4'd0;
                        end else begin
                            dr_sample_buf <= tx_fifo_pop_data;
                            drain_rd_req  <= 1'b1;
                            dr_state      <= 4'd5;
                        end
                    end
                end
                default: dr_state <= 4'd0;
            endcase
        end
    end

    // =========================================================================
    // Register read response declarations (Phase 3A Debug Infrastructure)
    // =========================================================================
    localparam [7:0] REG_READ_RESP_TAG = 8'h15;

    reg        reg_read_req;
    reg        reg_read_active;
    reg [2:0]  reg_read_idx;    // 7-byte response: 0=tag, 1=addr_hi, 2=addr_lo, 3-6=data
    reg [7:0]  reg_read_tx_byte;
    reg [15:0] reg_read_addr_latched;
    reg [31:0] reg_read_data_latched;

    wire [31:0] u_audit_agg_reg_rdata;

    // Register-read response has highest priority, then status, then event data
    assign dpti_tx_data = reg_read_active ? reg_read_tx_byte :
                          status_active  ? status_tx_byte :
                          event_active   ? dr_tx_byte :
                                           8'd0;
    assign dpti_tx_wr   = reg_read_active | status_active | (event_active & dr_tx_valid);

    // =========================================================================
    // Command decoder (0x00=stop, 0x02=arm, 0x10/0x11=set reg_addr, 0x14=read)
    // Multi-byte commands use cmd_state to capture subsequent data bytes.
    // =========================================================================
    reg        stream_enable = 1'b0;

    // Register read address latch (Phase 3A Debug Infrastructure)
    reg [1:0]  cmd_state;           // 0=idle, 1=expect_addr_hi, 2=expect_addr_lo
    reg [15:0] dbg_reg_addr;
    reg        dbg_reg_read_pulse;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_enable     <= 1'b0;
            event_arm         <= 1'b0;
            glitch_filter_en  <= 1'b1;
            adaptive_bypass   <= 1'b0;   // adaptive trigger by default
            status_cmd_pulse  <= 1'b0;
            cmd_state         <= 2'd0;
            dbg_reg_addr      <= 16'd0;
            dbg_reg_read_pulse <= 1'b0;
        end else begin
            status_cmd_pulse  <= 1'b0;
            dbg_reg_read_pulse <= 1'b0;

            if (dpti_rx_vld) begin
                case (cmd_state)
                    2'd0: begin  // idle — expect single-byte command or prefix
                        case (dpti_rx_data)
                        8'h00: begin stream_enable <= 1'b0; event_arm <= 1'b0; end
                        8'h01: begin stream_enable <= 1'b1; event_arm <= 1'b0; end
                        8'h02: begin stream_enable <= 1'b0; event_arm <= 1'b1; end
                        8'h07: glitch_filter_en <= 1'b0;
                        8'h08: glitch_filter_en <= 1'b1;
                        8'h09: adaptive_bypass <= 1'b1;   // legacy fixed-threshold trigger
                        8'h0A: adaptive_bypass <= 1'b0;   // adaptive trigger (default)
                        8'h0B: begin
                            status_cmd_pulse       <= 1'b1;
                            st_flags               <= {
                                rst_n,
                                cdce_init_done,
                                adc_init_done,
                                event_arm,
                                adaptive_bypass,
                                glitch_filter_en,
                                adc_dv_dco,
                                !cdc_empty,
                                glitch_dv,
                                armed,
                                triggered,
                                desc_fifo_full,
                                desc_fifo_empty,
                                reader_busy,
                                tx_fifo_full,
                                tx_fifo_empty
                            };
                            st_trigger_state       <= trigger_dbg_info.state;
                            st_dr_state            <= dr_state;
                            st_desc_count          <= desc_count;
                            st_sample_count        <= sample_counter[15:0];
                            st_event_counter       <= event_counter;
                            st_baseline            <= dbg_baseline;
                            st_sigma               <= dbg_sigma;
                            st_cbuf_wr_ptr         <= {3'b000, cbuf_wr_ptr};
                            st_tx_fifo_wr_count    <= {3'b000, tx_fifo_wr_count};
                            st_reader_remaining    <= {5'b00000, reader_burst_remaining};
                            st_lost_event_counter  <= lost_event_counter;
                            st_crossing_count      <= trigger_dbg_info.word_count;
                            st_trigger_count       <= trigger_dbg_info.event_count;
                            st_live_flags          <= {
                                new_event_pending,
                                event_active,
                                desc_pending,
                                desc_push,
                                reader_burst_start,
                                reader_sample_valid,
                                dpti_tx_rdy,
                                dpti_rx_vld
                            };
                            st_dr_sample_cnt       <= dr_sample_cnt[7:0];
                        end
                        8'h10: cmd_state <= 2'd1;  // expect addr_hi next
                        8'h11: cmd_state <= 2'd2;  // expect addr_lo next
                        8'h14: dbg_reg_read_pulse <= 1'b1;  // read current addr
                        default: ;
                        endcase
                    end
                    2'd1: begin  // expect addr_hi
                        dbg_reg_addr[15:8] <= dpti_rx_data;
                        cmd_state <= 2'd0;
                    end
                    2'd2: begin  // expect addr_lo
                        dbg_reg_addr[7:0] <= dpti_rx_data;
                        cmd_state <= 2'd0;
                    end
                    default: cmd_state <= 2'd0;
                endcase
            end
        end
    end
    assign dpti_rx_rd = dpti_rx_vld;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            status_active <= 1'b0;
            status_idx    <= 5'd0;
            status_seq    <= 8'd0;
            status_req    <= 1'b0;
        end else begin
            if (status_cmd_pulse) begin
                status_req <= 1'b1;
            end

            if (!status_active && status_req && !event_active && !reg_read_active) begin
                status_active <= 1'b1;
                status_idx    <= 5'd0;
                status_seq    <= status_seq + 1'b1;
                status_req    <= 1'b0;
            end else if (status_active && dpti_tx_rdy) begin
                if (status_idx == 5'd31) begin
                    status_active <= 1'b0;
                    status_idx    <= 5'd0;
                end else begin
                    status_idx <= status_idx + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Register read response FSM (Phase 3A Debug Infrastructure)
    //
    // Protocol (host→FPGA):
    //   0x10 <addr_hi>   — set register address high byte
    //   0x11 <addr_lo>   — set register address low byte
    //   0x14             — read selected register
    //
    // FPGA→host response (7 bytes):
    //   0x15 <addr_hi> <addr_lo> <data[31:24]> <data[23:16]> <data[15:8]> <data[7:0]>
    //
    // Priority: reg_read > status > event data
    // =========================================================================
    // During a queued read, hold the aggregator on the requested address so the
    // echoed address and data cannot diverge if the host updates dbg_reg_addr.
    wire [15:0] audit_reg_addr = reg_read_req ? reg_read_addr_latched : dbg_reg_addr;
    wire [31:0] reg_read_data  = u_audit_agg_reg_rdata;

    // Select byte from the latched response data
    always @(*) begin
        case (reg_read_idx)
            3'd0: reg_read_tx_byte = REG_READ_RESP_TAG;
            3'd1: reg_read_tx_byte = reg_read_addr_latched[15:8];
            3'd2: reg_read_tx_byte = reg_read_addr_latched[7:0];
            3'd3: reg_read_tx_byte = reg_read_data_latched[31:24];
            3'd4: reg_read_tx_byte = reg_read_data_latched[23:16];
            3'd5: reg_read_tx_byte = reg_read_data_latched[15:8];
            3'd6: reg_read_tx_byte = reg_read_data_latched[7:0];
            default: reg_read_tx_byte = 8'h00;
        endcase
    end

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_read_req          <= 1'b0;
            reg_read_active       <= 1'b0;
            reg_read_idx          <= 3'd0;
            reg_read_addr_latched <= 16'd0;
            reg_read_data_latched <= 32'd0;
        end else begin
            if (dbg_reg_read_pulse) begin
                reg_read_req <= 1'b1;
                reg_read_addr_latched <= dbg_reg_addr;
            end

            if (!reg_read_active && reg_read_req && !event_active && !status_active) begin
                reg_read_active       <= 1'b1;
                reg_read_idx          <= 3'd0;
                reg_read_data_latched <= reg_read_data;  // latch value from aggregator
                reg_read_req          <= 1'b0;
            end else if (reg_read_active && dpti_tx_rdy) begin
                if (reg_read_idx == 3'd6) begin
                    reg_read_active <= 1'b0;
                    reg_read_idx    <= 3'd0;
                end else begin
                    reg_read_idx <= reg_read_idx + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Audit Aggregator (Phase 3A — Read-Only Debug Register Map)
    // Collects all block dbg_info_t signals and block-specific signals into a
    // flat 16-bit address space accessible via DPTI register-read commands.
    // =========================================================================
    audit_aggregator u_audit_agg (
        .clk                  (sys_clk),
        .rst_n                (rst_n),
        .reg_addr             (audit_reg_addr),
        .reg_rdata            (u_audit_agg_reg_rdata),

        .adc_dbg              (adc_dbg_info),
        .cdc_dbg              (cdc_dbg_info),
        .glitch_dbg           (glitch_dbg_info),
        .cbuf_dbg             (cbuf_dbg_info),
        .trigger_dbg          (trigger_dbg_info),
        .desc_dbg             (desc_dbg_info),
        .reader_dbg           (reader_dbg_info),
        .tx_dbg               (tx_dbg_info),
        .dpti_dbg             (dpti_dbg_info),

        .glitch_max_delta     (glitch_dbg_max_delta),
        .glitch_threshold     (CFG_GLITCH_THRESHOLD),
        .cbuf_wr_ptr          (cbuf_wr_ptr),
        .cbuf_rd_ptr          (cbuf_rd_addr),     // rd_addr from waveform_reader
        .cbuf_collision       (cbuf_collision),
        .cbuf_watermark       (13'd0),            // TODO: wire from circular_buffer
        .trigger_threshold    (CFG_THRESHOLD),
        .trigger_cross_rate   (trigger_dbg_info.word_count),  // crossing count
        .trigger_holdoff_remaining({8'd0, trigger_dbg_info.stall_cycles}),  // live holdoff, pad to 16-bit
        .trigger_armed        (armed),
        .desc_fill_level      (desc_count[5:0]),
        .desc_watermark       (desc_dbg_info.event_count[5:0]),  // watermark from dbg
        .desc_lost_event_count(lost_event_counter),
        .reader_remaining     ({5'd0, reader_burst_remaining}),
        .reader_wrap_handled  (reader_dbg_info.word_count),
        .tx_fill_level        (tx_fifo_wr_count[11:0]),
        .tx_watermark         (tx_dbg_info.event_count[11:0]),
        .tx_dpti_stall        ({8'd0, tx_dbg_info.stall_cycles}),  // stall from dbg, pad to 16-bit
        .dpti_rx_cmd_count    (dpti_dbg_info.event_count),
        .dpti_bus_turnarounds (dpti_dbg_info.word_count),

        .sys_firmware_version (32'h0003_0001),  // v3.1 (Phase 3A)
        .sys_board_id         (32'h0000_0104),  // USB104 A7
        .sys_run_timestamp_lo (run_timestamp[31:0]),
        .sys_run_timestamp_hi (run_timestamp[63:32]),
        .sys_reset_cause      (32'd0),
        .sys_ctrl             (32'd0)
    );

    // =========================================================================
    // LEDs: armed, reader_busy, !tx_fifo_empty, trigger_pulse (during init)
    // =========================================================================
    assign led = ~adc_init_done ? 4'b0000 :
                 {armed, reader_busy, !tx_fifo_empty, trigger_pulse};

endmodule : top_pipeline
