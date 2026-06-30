//=============================================================================
// adc_spi_init.v — AD9648 SPI Initialization Controller
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Sends the 20-step AD9648 initialization sequence via 2-wire SPI.
// After init completes, asserts init_done and holds CS high, SCLK low.
//
// SPI format (AD9648, 16-bit instruction + 8-bit data):
//   Instruction: {R/W, W1:W0[1:0], A[12:0]}  (MSB first)
//   Data:        8-bit register value          (MSB first)
//   R/W = 0 for write, 1 for read
//   W1:W0 = 00 for 1-byte transfer
//
// SCLK = clk / 8 = 12.5 MHz (max AD9648 SCLK = 25 MHz)
//=============================================================================

module adc_spi_init (
    input  wire       clk,          // 100 MHz system clock
    input  wire       rst_n,        // active-low reset
    output reg        spi_sdio,     // SPI data (write-only, output)
    output reg        spi_sclk,     // SPI clock
    output reg        spi_cs,       // SPI chip select (active low)
    output reg        init_done     // high when init complete
);

    //=========================================================================
    // SPI clock divider: SCLK = clk / 8 = 12.5 MHz
    // Each SCLK half-cycle = 4 clk cycles = 40 ns
    //=========================================================================
    localparam SCLK_DIV = 4;  // divide clk by 2*SCLK_DIV to get SCLK

    reg [2:0] sclk_cnt;  // 0..SCLK_DIV-1
    wire sclk_tick = (sclk_cnt == SCLK_DIV - 1);
    wire sclk_fall = sclk_tick && spi_sclk;
    wire sclk_rise = sclk_tick && !spi_sclk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_cnt <= 3'd0;
            spi_sclk <= 1'b0;
        end else if (sclk_tick) begin
            sclk_cnt <= 3'd0;
            spi_sclk <= ~spi_sclk;
        end else begin
            sclk_cnt <= sclk_cnt + 1'b1;
        end
    end

    //=========================================================================
    // Init sequence ROM: 20 commands
    // Each entry: {reg_addr[7:0], reg_data[7:0]}
    //=========================================================================
    localparam NUM_CMDS = 20;

    // For step 2 (chip ID read), we use a dummy write to check.
    // Actually, step 2 is a read — we skip verification and rely on
    // the write operations. The sequence is writes-only.
    // We replace read with a NOP/dummy or simply skip it.
    // The 20-step sequence (all writes, chip ID read skipped):
    //
    // 1.  Soft reset:              W 0x00, 0x3C
    // 2.  (skip Chip ID read)
    // 3.  Select CHA:              W 0x05, 0x01
    // 4.  Digital reset CHA:       W 0x08, 0x03
    // 5.  Output mode CHA:         W 0x14, 0x21  (no invert, 2's comp, CMOS, interleaved)
    // 6.  Select CHB:              W 0x05, 0x02
    // 7.  Digital reset CHB:       W 0x08, 0x03
    // 8.  Output mode CHB:         W 0x14, 0x21  (no invert, 2's comp, CMOS, interleaved)
    // 9.  Deselect both:           W 0x05, 0x00
    // 10. Clock phase:             W 0x16, 0x80
    // 11. Clock divide:            W 0x0B, 0x01  (div-by-1 for 100 MHz)
    // 12. Overrange control:       W 0x2A, 0x00
    // 13. Output adjust:           W 0x15, 0x00
    // 14. Output delay:            W 0x17, 0x81
    // 15. Sync control:            W 0x3A, 0x00  (disabled — avoids periodic output glitch)
    // 16. Select CHA:              W 0x05, 0x01
    // 17. Power CHA normal:        W 0x08, 0x00
    // 18. Select CHB:              W 0x05, 0x02
    // 19. Power CHB normal:        W 0x08, 0x00
    // 20. Deselect both:           W 0x05, 0x00

    // Store as packed register pairs
    wire [7:0] cmd_addr [0:NUM_CMDS-1];
    wire [7:0] cmd_data [0:NUM_CMDS-1];

    assign cmd_addr[0]  = 8'h00; assign cmd_data[0]  = 8'h3C;  // Soft reset
    assign cmd_addr[1]  = 8'h05; assign cmd_data[1]  = 8'h01;  // Select CHA
    assign cmd_addr[2]  = 8'h08; assign cmd_data[2]  = 8'h03;  // Digital reset CHA
    assign cmd_addr[3]  = 8'h14; assign cmd_data[3]  = 8'h21;  // Output mode CHA (bit4=0: no invert, 2's comp, CMOS, interleaved)
    assign cmd_addr[4]  = 8'h05; assign cmd_data[4]  = 8'h02;  // Select CHB
    assign cmd_addr[5]  = 8'h08; assign cmd_data[5]  = 8'h03;  // Digital reset CHB
    assign cmd_addr[6]  = 8'h14; assign cmd_data[6]  = 8'h21;  // Output mode CHB (bit4=0: no invert, 2's comp, CMOS, interleaved)
    assign cmd_addr[7]  = 8'h05; assign cmd_data[7]  = 8'h00;  // Deselect both
    assign cmd_addr[8]  = 8'h16; assign cmd_data[8]  = 8'h80;  // Clock phase (invert DCO)
    assign cmd_addr[9]  = 8'h0B; assign cmd_data[9]  = 8'h01;  // Clock divide
    assign cmd_addr[10] = 8'h2A; assign cmd_data[10] = 8'h00;  // Overrange disable
    assign cmd_addr[11] = 8'h15; assign cmd_data[11] = 8'h00;  // Output adjust
    assign cmd_addr[12] = 8'h17; assign cmd_data[12] = 8'h81;  // Output delay
    assign cmd_addr[13] = 8'h3A; assign cmd_data[13] = 8'h00;  // Sync control (disabled — avoids periodic output glitch)
    assign cmd_addr[14] = 8'h05; assign cmd_data[14] = 8'h01;  // Select CHA
    assign cmd_addr[15] = 8'h08; assign cmd_data[15] = 8'h00;  // Power CHA normal
    assign cmd_addr[16] = 8'h05; assign cmd_data[16] = 8'h02;  // Select CHB
    assign cmd_addr[17] = 8'h08; assign cmd_data[17] = 8'h00;  // Power CHB normal
    assign cmd_addr[18] = 8'h05; assign cmd_data[18] = 8'h00;  // Deselect both
    assign cmd_addr[19] = 8'hFF; assign cmd_data[19] = 8'h00;  // END marker

    //=========================================================================
    // State machine
    //=========================================================================
    localparam S_IDLE           = 4'd0,
               S_CS_SETUP       = 4'd1,   // assert CS, load command
               S_INSTR          = 4'd2,   // shift 16-bit instruction
               S_DATA           = 4'd3,   // shift 8-bit data
               S_CS_HOLD        = 4'd4,   // de-assert CS, wait settling
               S_POST_RESET_WAIT= 4'd5,   // wait 5ms after soft reset
               S_NEXT_CMD       = 4'd6,   // advance to next command
               S_DONE           = 4'd7;

    reg [3:0]  state;
    reg [4:0]  cmd_idx;       // 0..19, current command
    reg [23:0] shift_reg;     // {16-bit instr, 8-bit data}
    reg [4:0]  bit_cnt;       // bits remaining to shift (0..23)
    reg [7:0]  cs_wait;       // wait counter after CS de-assert
    reg [18:0] reset_wait;    // 5 ms post-reset counter (500k cycles @ 100 MHz)

    // Build instruction word: {1'b0, 2'b00, addr[12:0]}
    // addr is 8-bit, so instruction = {1'b0, 2'b00, 5'b00000, addr[7:0]}
    // = {8'h00, addr}
    wire [15:0] instruction = {8'h00, cmd_addr[cmd_idx]};
    wire [23:0] full_word   = {instruction, cmd_data[cmd_idx]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cmd_idx   <= 5'd0;
            shift_reg <= 24'd0;
            bit_cnt   <= 5'd0;
            cs_wait   <= 8'd0;
            spi_cs    <= 1'b1;
            spi_sdio  <= 1'b0;
            init_done <= 1'b0;
        end else begin
            case (state)
                //---------------------------------------------------------
                // S_IDLE: wait a few cycles after reset, then start
                //---------------------------------------------------------
                S_IDLE: begin
                    spi_cs    <= 1'b1;
                    spi_sdio <= 1'b0;
                    if (cs_wait < 8'd100) begin
                        cs_wait <= cs_wait + 1'b1;
                    end else begin
                        cs_wait  <= 8'd0;
                        cmd_idx  <= 5'd0;
                        state    <= S_CS_SETUP;
                    end
                end

                //---------------------------------------------------------
                // S_CS_SETUP: assert CS, load command word
                //---------------------------------------------------------
                S_CS_SETUP: begin
                    spi_cs    <= 1'b0;              // assert CS low
                    shift_reg <= full_word;          // {16-bit instr, 8-bit data}
                    bit_cnt   <= 5'd23;             // 24 bits to shift (0-indexed)
                    spi_sdio  <= full_word[23];     // pre-load MSB
                    state     <= S_INSTR;
                end

                //---------------------------------------------------------
                // S_INSTR / S_DATA: shift bits on falling SCLK edge
                // AD9648 samples on rising edge → we change data on falling
                //---------------------------------------------------------
                S_INSTR, S_DATA: begin
                    if (sclk_fall) begin
                        if (bit_cnt > 5'd0) begin
                            bit_cnt  <= bit_cnt - 1'b1;
                            spi_sdio <= shift_reg[bit_cnt - 1'b1];
                        end else begin
                            // Last bit shifted on this falling edge
                            // Next state depends: after instr → data, after data → CS hold
                            if (state == S_INSTR) begin
                                // Just finished 16-bit instruction (bit_cnt was 0)
                                // Now start 8-bit data — reload bit_cnt
                                // Wait for SCLK to go low and high again for the transition
                                spi_sdio <= cmd_data[cmd_idx][7]; // MSB of data
                                bit_cnt  <= 5'd7;
                                state    <= S_DATA;
                            end else begin
                                // Finished data phase
                                state <= S_CS_HOLD;
                            end
                        end
                    end
                end

                //---------------------------------------------------------
                // S_CS_HOLD: de-assert CS, wait settling period
                // After soft reset (cmd 0), go to post-reset wait.
                //---------------------------------------------------------
                S_CS_HOLD: begin
                    spi_cs <= 1'b1;
                    if (sclk_tick) begin
                        if (cs_wait < 8'd20) begin
                            cs_wait <= cs_wait + 1'b1;
                        end else begin
                            cs_wait <= 8'd0;
                            if (cmd_idx == 5'd0) begin
                                // Soft reset complete — wait 5 ms for ADC recovery
                                reset_wait <= 19'd0;
                                state      <= S_POST_RESET_WAIT;
                            end else begin
                                state <= S_NEXT_CMD;
                            end
                        end
                    end
                end

                //---------------------------------------------------------
                // S_POST_RESET_WAIT: 5 ms delay after soft reset
                // AD9648 requires ~5 ms to recover after soft reset.
                // Without this delay, subsequent SPI writes may be
                // ignored or corrupted, leading to partial config.
                //---------------------------------------------------------
                S_POST_RESET_WAIT: begin
                    reset_wait <= reset_wait + 1'b1;
                    // 500,000 cycles @ 100 MHz = 5 ms
                    if (reset_wait >= 19'd499999) begin
                        state <= S_NEXT_CMD;
                    end
                end

                //---------------------------------------------------------
                // S_NEXT_CMD: advance to next command
                //---------------------------------------------------------
                S_NEXT_CMD: begin
                    if (cmd_idx < (NUM_CMDS - 1)) begin
                        cmd_idx <= cmd_idx + 1'b1;
                        state   <= S_CS_SETUP;
                    end else begin
                        state <= S_DONE;
                    end
                end

                //---------------------------------------------------------
                // S_DONE: init complete, hold forever
                //---------------------------------------------------------
                S_DONE: begin
                    init_done <= 1'b1;
                    spi_cs    <= 1'b1;
                    spi_sdio  <= 1'b0;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
