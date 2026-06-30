//------------------------------------------------------------------------------
// top_stream.sv
//
// Phase 1 — MINIMUM VIABLE ACQUISITION PATH (streaming mode)
//
// Builds just enough to see real ADC data on the PC:
//   ADC → ADC Interface (IDDR) → CDC FIFO → Decimator (1:32) → DPTI Bridge → FT232H
//
// No trigger, no buffer, no glitch filter. 16-bit sample only (2 bytes LE on wire).
// Decimated streaming at ~6.5 MB/s validates the full data path at feasible rate.
//
// Clock domains:
//   adc_dco (~105 MHz) — ADC data capture
//   sys_clk (100 MHz)  — on-board oscillator (BUFG-buffered, no PLL)
//   ft_clk (60 MHz)    — FT232H prog_clko (generated internally by comm_dpti CDC)
//
// Architecture reference: Architecture.md, implementation_strategy.md § Phase 1
// Pin constraints: hardware_spec/USB104_A7_Zmod_ADC1410.xdc
// Timing constraints: constraints/timing.xdc
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module top_stream (
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
    input  wire       dpti_txen,      // prog_txen (M17)
    input  wire       dpti_rxen,      // prog_rxen (M16)
    output wire       dpti_wrn,       // prog_wrn (N16)
    output wire       dpti_rdn,       // prog_rdn (N15)
    output wire       dpti_oen,       // prog_oen (N17)
    output wire       dpti_siwun,     // prog_siwun (P18)
    output wire       dpti_spien      // prog_spien (L18)
);

    // =========================================================================
    // System clock — direct from on-board oscillator
    // =========================================================================
    wire sys_clk = clk;

    // =========================================================================
    // Power-on reset: hold rst_n low for 16 cycles after power-up
    // =========================================================================
    reg [3:0] rst_cnt;
    reg       rst_n;
    always @(posedge sys_clk) begin
        if (&rst_cnt) begin rst_n <= 1'b1; end
        else begin rst_cnt <= rst_cnt + 1'b1; rst_n <= 1'b0; end
    end

    // =========================================================================
    // ADC sample clock generation (ODDR + OBUFDS)
    // Driven from sys_clk (100 MHz) — same as sig_recorder
    // =========================================================================
    OBUFDS #(.IOSTANDARD("DIFF_SSTL18_I"), .SLEW("SLOW"))
    u_adc_clk_obuf (
        .O  (adc_clk_p),
        .OB (adc_clk_n),
        .I  (sys_clk)
    );

    // =========================================================================
    // Front-end controls (fixed, same as sig_recorder)
    // =========================================================================
    assign ch1_ac_h     = 1'b1;   // AC coupling
    assign ch1_ac_l     = 1'b0;
    assign ch1_gain_h   = 1'b1;   // High gain SET (inverted)
    assign ch1_gain_l   = 1'b0;
    assign ch2_ac_h     = 1'b1;   // AC coupling SET (inverted)
    assign ch2_ac_l     = 1'b0;
    assign ch2_gain_h   = 1'b1;   // High gain SET (inverted)
    assign ch2_gain_l   = 1'b0;
    assign com_couple_h = 1'b1;
    assign com_couple_l = 1'b0;

    // =========================================================================
    // CDCE6214 I2C init → ADC SPI init (sequential, same as sig_recorder)
    // =========================================================================
    wire cdce_init_done;
    cdce_iic_init u_cdce_init (
        .clk       (sys_clk),
        .rst_n     (rst_n),
        .i2c_scl   (adc_scl),
        .i2c_sda   (adc_sda),
        .init_done (cdce_init_done)
    );

    wire adc_init_done;
    adc_spi_init u_adc_init (
        .clk       (sys_clk),
        .rst_n     (rst_n && cdce_init_done),
        .spi_sdio  (adc_spi_sdio),
        .spi_sclk  (adc_spi_sclk),
        .spi_cs    (adc_spi_cs),
        .init_done (adc_init_done)
    );

    // =========================================================================
    // ADC Interface — IDDR deinterleaver
    // =========================================================================
    wire [15:0] adc_ch_a, adc_ch_b;
    wire        adc_data_valid;
    wire        channel_sel = 1'b0;  // Phase 1: always channel A

    dbg_if adc_dbg ();  // debug port (unused in Phase 1 top)

    adc_interface u_adc_interface (
        .adc_dco      (adc_dco),
        .sys_rst_n    (rst_n),
        .adc_data     (adc_data),
        .ch_a_data    (adc_ch_a),
        .ch_b_data    (adc_ch_b),
        .data_valid   (adc_data_valid),
        .channel_sel  (channel_sel),
        .dbg_info     ()
    );

    // =========================================================================
    // CDC FIFO — adc_dco → sys_clk (32-bit packed dual-channel)
    // =========================================================================
    wire        cdc_full, cdc_empty;
    wire [31:0] cdc_dout;

    dbg_if cdc_dbg ();

    cdc_fifo u_cdc_fifo (
        .wr_clk   (adc_dco),        // note: uses unbuffered adc_dco directly
        .wr_rst_n (rst_n),
        .wr_en    (adc_data_valid),
        .din      ({adc_ch_b, adc_ch_a}),  // {ch_b[15:0], ch_a[15:0]}
        .full     (cdc_full),
        .rd_clk   (sys_clk),
        .rd_rst_n (rst_n),
        .rd_en    (~cdc_empty),     // always read when data available (FWFT)
        .dout     (cdc_dout),
        .empty    (cdc_empty),
        .dbg_info     ()
    );

    // =========================================================================
    // Channel select + decimator (1:32)
    // =========================================================================
    // Selected channel data (lower 16 bits = ch_a when channel_sel=0)
    wire [15:0] sample_raw = channel_sel ? cdc_dout[31:16] : cdc_dout[15:0];
    wire        sample_avail = ~cdc_empty;

    reg [4:0]  dec_cnt;
    reg        dec_sample_valid;
    reg [15:0] dec_sample;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_cnt           <= 5'd0;
            dec_sample_valid  <= 1'b0;
            dec_sample        <= 16'd0;
        end else begin
            dec_sample_valid <= 1'b0;  // default: pulse

            if (sample_avail) begin
                if (dec_cnt == 5'd0) begin
                    // Take this sample
                    dec_sample       <= sample_raw;
                    dec_sample_valid <= 1'b1;
                end
                dec_cnt <= dec_cnt + 1'b1;
            end
        end
    end

    // =========================================================================
    // DPTI Bridge — send decimated 16-bit samples (2 bytes LE)
    // =========================================================================
    wire [7:0] dpti_tx_data;
    wire       dpti_tx_wr;
    wire       dpti_tx_rdy;
    wire [7:0] dpti_rx_data;
    wire       dpti_rx_vld;
    wire       dpti_rx_rd;

    comm_dpti u_comm_dpti (
        .sys_clk     (sys_clk),
        .sys_rst_n   (rst_n),
        .sys_tx_data (dpti_tx_data),
        .sys_tx_wr   (dpti_tx_wr),
        .sys_tx_rdy  (dpti_tx_rdy),
        .sys_rx_data (dpti_rx_data),
        .sys_rx_vld  (dpti_rx_vld),
        .sys_rx_rd   (dpti_rx_rd),
        .dpti_clk    (dpti_clk),
        .dpti_data   (dpti_data),
        .dpti_txen   (dpti_txen),
        .dpti_rxen   (dpti_rxen),
        .dpti_wrn    (dpti_wrn),
        .dpti_rdn    (dpti_rdn),
        .dpti_oen    (dpti_oen),
        .dpti_siwun  (dpti_siwun),
        .dpti_spien  (dpti_spien),
        .dbg_info    ()
    );

    // =========================================================================
    // TX byte sequencer: pack 16-bit sample → 2 bytes LE (LSB first)
    // =========================================================================
    localparam TX_IDLE = 2'd0,
               TX_LSB  = 2'd1,
               TX_MSB  = 2'd2;

    reg [1:0] tx_state;
    reg [7:0] tx_lsb;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= TX_IDLE;
            tx_lsb   <= 8'd0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    if (dec_sample_valid) begin
                        tx_lsb   <= dec_sample[7:0];
                        tx_state <= TX_LSB;
                    end
                end

                TX_LSB: begin
                    if (dpti_tx_rdy) begin
                        tx_state <= TX_MSB;
                    end
                end

                TX_MSB: begin
                    if (dpti_tx_rdy) begin
                        tx_state <= TX_IDLE;
                    end
                end
            endcase
        end
    end

    assign dpti_tx_data = (tx_state == TX_MSB) ? dec_sample[15:8] :
                          (tx_state == TX_LSB) ? tx_lsb :
                          8'd0;
    assign dpti_tx_wr   = (tx_state == TX_LSB || tx_state == TX_MSB);

    // =========================================================================
    // RX: ignore incoming commands in Phase 1 streaming mode
    // =========================================================================
    assign dpti_rx_rd = 1'b0;

    // =========================================================================
    // LEDs: status display
    //   LED[3] = adc_init_done
    //   LED[2] = ~cdc_empty (data flowing through CDC)
    //   LED[1] = dec_sample_valid (decimated data flowing)
    //   LED[0] = sys_clk divided by 2^24 (~6 Hz heartbeat)
    // =========================================================================
    reg [23:0] heartbeat;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) heartbeat <= 24'd0;
        else        heartbeat <= heartbeat + 1'b1;
    end

    assign led = {adc_init_done, ~cdc_empty, dec_sample_valid, heartbeat[23]};

endmodule : top_stream
