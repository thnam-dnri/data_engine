//------------------------------------------------------------------------------
// tb_top_pipeline.sv
//
// Integration testbench for top_pipeline — the Phase 2.7 full event pipeline.
//
// Note: iverilog simulation of the full top_pipeline is impractical because
// the CDCE I2C + ADC SPI init takes ~7 ms (millions of cycles at 100 MHz).
// This testbench uses a "lite" wrapper that instantiates all the event-pipeline
// modules but with init_done=1 (skipping the actual I2C/SPI sequences).
//
// The full integration is verified on hardware via `make synth && make program`.
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_pipeline_lite (
    // ---- DUT clocks ----
    input  wire       sys_clk,
    input  wire       dco_clk,
    input  wire       dpti_clk,

    // ---- ADC interface (mocked: 16-bit directly on sys_clk, skip IDDR/CDC) ----
    input  wire [15:0] adc_data_in,    // directly into glitch_filter
    input  wire        adc_dv_in,

    // ---- DPTI side (mocked) ----
    output wire [7:0]  dpti_tx_byte,
    output wire        dpti_tx_active,
    input  wire [7:0]  dpti_rx_byte,
    input  wire        dpti_rx_valid,
    output wire        dpti_rx_ready,
    output wire        event_arm_out,  // exposed for testing
    output wire        trigger_pulse_out, // exposed for testing
    output wire        armed_out,        // exposed for testing
    output wire        reader_busy_out,  // exposed for testing
    output wire [7:0]  desc_count_out,   // exposed for testing
    output wire [15:0] trigger_count_out,// exposed for testing
    output wire [15:0] glitch_out_dbg    // exposed: current glitch filter output
);

    // ---- Wires ----
    wire [15:0] glitch_out;
    wire        glitch_dv;
    wire [12:0] cbuf_wr_ptr;
    wire [12:0] cbuf_rd_addr;
    wire [15:0] cbuf_rd_data;
    wire        trigger_pulse;
    wire        armed;
    wire        triggered;
    wire [47:0] event_timestamp;
    reg         event_arm = 1'b0;
    reg  [15:0] event_counter;
    reg  [47:0] sample_counter;
    wire        desc_fifo_full;
    wire        desc_fifo_empty;
    wire [159:0] desc_fifo_data;
    wire        desc_pop_req;
    wire [7:0]  desc_count;
    wire        desc_lost_pulse;
    wire        reader_sample_valid;
    wire [15:0] reader_sample_data;
    wire        reader_busy;
    wire        reader_burst_start;
    wire [159:0] reader_burst_descriptor;
    wire [10:0] reader_burst_remaining;
    wire        tx_fifo_full;
    wire [15:0] tx_fifo_pop_data;
    wire        tx_fifo_empty;
    wire [12:0] tx_fifo_wr_count;

    // ---- Power-on reset ----
    reg [3:0] rst_cnt = 4'd0;
    reg       rst_n = 1'b0;
    always @(posedge sys_clk) begin
        if (&rst_cnt) rst_n <= 1'b1;
        else begin rst_cnt <= rst_cnt + 1'b1; rst_n <= 1'b0; end
    end

    // ---- Sample counter ----
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) sample_counter <= 48'd0;
        else if (adc_dv_in) sample_counter <= sample_counter + 1'b1;
    end

    // ---- Event counter ----
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) event_counter <= 16'd0;
        else if (trigger_pulse) event_counter <= event_counter + 1'b1;
    end

    // Debug: force event_arm high to test trigger in isolation
    //reg force_arm = 1'b1;
    //assign event_arm = force_arm;

    // ---- Glitch filter ----
    glitch_filter u_glitch (
        .clk     (sys_clk),
        .rst_n   (rst_n),
        .din     (adc_data_in),
        .din_valid(adc_dv_in),
        .dout    (glitch_out),
        .dout_valid(glitch_dv),
        .threshold(16'd5000),
        .bypass  (1'b0),
        .dbg_info(),
        .dbg_max_delta(),
        .heartbeat()
    );

    // ---- Circular buffer ----
    circular_buffer #(.DEPTH(8192), .WIDTH(16), .AW(13)) u_cbuf (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .wr_en    (glitch_dv),
        .wr_data  (glitch_out),
        .wr_ptr   (cbuf_wr_ptr),
        .rd_en    (1'b1),  // always enabled (waveform_reader drives rd_addr)
        .rd_addr  (cbuf_rd_addr),
        .rd_data  (cbuf_rd_data),
        .dbg_info ()
    );

    // ---- Trigger ---- (legacy/bypass mode: fixed-threshold positive edge,
    //     unchanged from Phase 2.3 — keeps the integration test deterministic)
    trigger u_trigger (
        .clk            (sys_clk),
        .rst_n          (rst_n),
        .arm            (event_arm),
        .adc_data       (glitch_out),
        .adc_dv         (glitch_dv),
        .cfg_threshold  (16'd5000),
        .cfg_hysteresis (16'd100),
        .cfg_holdoff    (24'd2000),
        .cfg_polarity   (1'b0),    // 0 = positive edge, 1 = negative edge
        .cfg_adaptive_bypass(1'b1), // legacy fixed-threshold mode
        .sample_count   (sample_counter),
        .trigger_pulse  (trigger_pulse),
        .armed          (armed),
        .triggered      (triggered),
        .event_timestamp(event_timestamp),
        .dbg_baseline   (),
        .dbg_sigma      (),
        .dbg_info       ()
    );

    // ---- Event FSM (build descriptor on trigger) ----
    reg [12:0] trig_ptr_cap;
    reg [15:0] event_id_cap;
    reg [47:0] ts_cap;
    reg        desc_pending;
    reg        desc_push;
    reg [15:0] lost_event_counter;

    localparam [10:0] TOTAL_SAMPLES = 11'd1800;
    localparam DW = 160;

    wire [12:0] start_addr = trig_ptr_cap - 11'd600;  // 13-bit wrap
    wire [DW-1:0] descriptor = {
        ts_cap,                          // [159:112] timestamp (48-bit)
        16'd0,                           // [111:96]  amplitude (placeholder)
        16'd0,                           // [95:80]   energy (placeholder)
        2'b00,                           // [79:78]   trigger_type
        start_addr,                      // [77:65]   waveform_offset
        TOTAL_SAMPLES,                   // [64:54]   waveform_length
        1'b0,                            // [53]      channel_id
        event_id_cap,                    // [52:37]   event_id (board_id slot)
        32'h20260701,                    // [36:5]    firmware_version
        5'd0                             // [4:0]     diag_snapshot
    };

    always @(posedge sys_clk) begin
        desc_push <= 1'b0;
        if (trigger_pulse) begin
            if (desc_fifo_full) begin
                lost_event_counter <= lost_event_counter + 1'b1;
            end else begin
                trig_ptr_cap <= cbuf_wr_ptr;
                event_id_cap <= event_counter;
                ts_cap       <= event_timestamp;
                desc_pending <= 1'b1;
            end
        end
        if (desc_pending) begin
            desc_push    <= 1'b1;
            desc_pending <= 1'b0;
        end
    end

    // ---- Descriptor FIFO ----
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
        .dbg_info        ()
    );

    // ---- Waveform reader ----
    waveform_reader u_reader (
        .clk             (sys_clk),
        .rst_n           (rst_n),
        .desc_empty      (desc_fifo_empty),
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
        .dbg_info        ()
    );

    // ---- TX Waveform FIFO (dual-clock, but for test both clocks = sys_clk) ----
    tx_wave_fifo u_tx_fifo (
        .wr_clk  (sys_clk),
        .wr_rst_n(rst_n),
        .wr_req  (reader_sample_valid),
        .wr_data (reader_sample_data),
        .full    (tx_fifo_full),
        .rd_clk  (sys_clk),  // test simplification
        .rd_rst_n(rst_n),
        .rd_req  (drain_rd_req),
        .pop_data(tx_fifo_pop_data),
        .empty   (tx_fifo_empty),
        .wr_count(tx_fifo_wr_count),
        .dbg_info()
    );

    // ---- Drain FSM (byte splitter, packet builder) ----
    // dpti_tx_rdy is always 1 in simulation (lite wrapper skips comm_dpti CDC).
    // In the real top_pipeline, this comes from comm_dpti.sys_tx_rdy.
    wire        dpti_tx_rdy = 1'b1;

    reg [3:0]  dr_state;
    reg [15:0] dr_sample_buf;
    reg [11:0] dr_sample_cnt;
    reg        drain_rd_req;
    reg [7:0]  dr_tx_byte;
    reg        dr_tx_valid;
    reg        event_active;
    reg [15:0] dr_event_id;
    reg [11:0] dr_event_length;
    reg        new_event_pending;
    reg [15:0] pending_event_id;
    reg [11:0] pending_length;

    always @(posedge sys_clk) begin
        if (reader_burst_start) begin
            pending_event_id  <= reader_burst_descriptor[52:37];  // event_id from descriptor
            pending_length    <= reader_burst_descriptor[64:54];  // waveform_length
            new_event_pending <= 1'b1;
        end else if (dr_state == 4'd4 && dpti_tx_rdy) begin
            new_event_pending <= 1'b0;
        end
    end

    always @(posedge sys_clk) begin
        if (dr_state == 4'd0 && new_event_pending && !tx_fifo_empty) begin
            dr_event_id     <= pending_event_id;
            dr_event_length <= pending_length;
        end
    end

    always @(posedge sys_clk) begin
        dr_tx_valid  <= 1'b0;
        drain_rd_req <= 1'b0;
        case (dr_state)
            4'd0: begin
                event_active <= 1'b0;
                if (new_event_pending && !tx_fifo_empty) begin
                    dr_tx_byte    <= 8'hA5;
                    dr_tx_valid   <= 1'b1;
                    event_active  <= 1'b1;
                    dr_state      <= 4'd1;
                end
            end
            4'd1: begin
                event_active <= 1'b1;
                dr_tx_valid  <= 1'b1;
                if (dpti_tx_rdy) begin
                    dr_tx_byte <= 8'h5A;
                    dr_state   <= 4'd2;
                end
            end
            4'd2: begin
                event_active <= 1'b1;
                dr_tx_valid  <= 1'b1;
                if (dpti_tx_rdy) begin
                    dr_tx_byte <= dr_event_id[15:8];
                    dr_state   <= 4'd3;
                end
            end
            4'd3: begin
                event_active <= 1'b1;
                dr_tx_valid  <= 1'b1;
                if (dpti_tx_rdy) begin
                    dr_tx_byte <= dr_event_id[7:0];
                    dr_state   <= 4'd4;
                end
            end
            4'd4: begin
                event_active <= 1'b1;
                if (dpti_tx_rdy) begin
                    dr_sample_cnt <= 12'd0;
                    dr_sample_buf <= tx_fifo_pop_data;
                    drain_rd_req  <= 1'b1;
                    dr_state      <= 4'd5;
                end
            end
            4'd5: begin
                event_active <= 1'b1;
                dr_tx_byte   <= dr_sample_buf[15:8];
                dr_tx_valid  <= 1'b1;
                if (dpti_tx_rdy) dr_state <= 4'd6;
            end
            4'd6: begin
                event_active <= 1'b1;
                dr_tx_byte   <= dr_sample_buf[7:0];
                dr_tx_valid  <= 1'b1;
                if (dpti_tx_rdy) begin
                    dr_sample_cnt <= dr_sample_cnt + 1'b1;
                    if (dr_sample_cnt >= (dr_event_length - 1'b1)) begin
                        dr_state <= 4'd0;
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

    assign dpti_tx_byte  = event_active ? dr_tx_byte : 8'd0;
    assign dpti_tx_active = event_active & dr_tx_valid;

    // ---- Command decoder (simplified, no toggle-handshake CDC) ----
    reg [7:0] dpti_rx_byte_r;
    reg       dpti_rx_valid_r;
    always @(posedge sys_clk) begin
        dpti_rx_byte_r  <= dpti_rx_byte;
        dpti_rx_valid_r <= dpti_rx_valid;
    end
    assign dpti_rx_ready = dpti_rx_valid_r;
    assign event_arm_out    = event_arm;
    assign trigger_pulse_out = trigger_pulse;
    assign armed_out        = armed;
    assign reader_busy_out  = reader_busy;
    assign desc_count_out   = desc_count;
    assign trigger_count_out = u_trigger.dbg_info.event_count;
    assign glitch_out_dbg   = glitch_out;

    always @(posedge sys_clk) begin
        if (dpti_rx_valid_r) begin
            case (dpti_rx_byte_r)
                8'h00: begin event_arm <= 1'b0; end
                8'h02: begin event_arm <= 1'b1; end
                default: ;
            endcase
        end
    end

endmodule
