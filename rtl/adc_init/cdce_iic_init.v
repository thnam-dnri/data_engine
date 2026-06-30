//=============================================================================
// cdce_iic_init.v — CDCE6214-Q1 I2C Initialization Controller
// Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
//
// Sends 22 register writes to the CDCE6214-Q1 clock generator via I2C
// at address 0x67 (fall-back mode, 7-bit).
//
// SCL/SDA bit patterns pre-computed from cdce-mem.py (Pavel Demin) for
// 100 MHz ADC sampling. ROM encodes 16 I2C bit-times per 32-bit word
// as {SCL[15:0], SDA[15:0]}. A counter shifts bits out at SCL_DIV
// intervals (~100 kHz I2C ≈ 10 µs/bit).
//
// Total: 64 idle words + 68 data words = 132 ROM entries.
// init_done goes high after all words are sent (~7 ms total).
//=============================================================================

module cdce_iic_init (
    input  wire       clk,          // 100 MHz system clock
    input  wire       rst_n,        // active-low reset
    inout  wire       i2c_scl,      // I2C clock (open-drain, pulled up externally)
    inout  wire       i2c_sda,      // I2C data  (open-drain, pulled up externally)
    output reg        init_done     // high when all commands sent
);

    localparam SCL_DIV = 512;       // half-period in clk cycles (5.12 µs)
    localparam ROM_SIZE = 132;      // total ROM entries (64 padding + 68 data)

    //=========================================================================
    // ROM: pre-computed I2C bit patterns for CDCE6214 @ 100 MHz
    //=========================================================================
    wire [31:0] rom [0:ROM_SIZE-1];

    // Padding (64 entries = idle/high)
    generate
        genvar ri;
        for (ri = 0; ri < 64; ri = ri + 1) begin : g_pad
            assign rom[ri] = 32'hFFFFFFFF;
        end
    endgenerate

    // Data entries 64-131 from cdce_100.mem (68 words)
    assign rom[64]  = 32'hC000B3A0; assign rom[65]  = 32'h00001008;
    assign rom[66]  = 32'h00008412; assign rom[67]  = 32'hE000D9D0;
    assign rom[68]  = 32'h00000A7C; assign rom[69]  = 32'h00000A11;
    assign rom[70]  = 32'h70006CE8; assign rom[71]  = 32'h0000053A;
    assign rom[72]  = 32'h00000100; assign rom[73]  = 32'h3800B674;
    assign rom[74]  = 32'h00000299; assign rom[75]  = 32'h000001C4;
    assign rom[76]  = 32'h1C005B3A; assign rom[77]  = 32'h0000014B;
    assign rom[78]  = 32'h0000C042; assign rom[79]  = 32'h0E002D9D;
    assign rom[80]  = 32'h000000A4; assign rom[81]  = 32'h0000C420;
    assign rom[82]  = 32'h070016CE; assign rom[83]  = 32'h00008052;
    assign rom[84]  = 32'h00002010; assign rom[85]  = 32'h03806B67;
    assign rom[86]  = 32'h00004028; assign rom[87]  = 32'h00009108;
    assign rom[88]  = 32'h01C005B3; assign rom[89]  = 32'h0000A013;
    assign rom[90]  = 32'h0000F884; assign rom[91]  = 32'h00E002D9;
    assign rom[92]  = 32'h0000D009; assign rom[93]  = 32'h0000CC42;
    assign rom[94]  = 32'h0070016C; assign rom[95]  = 32'h0000E804;
    assign rom[96]  = 32'h0000CA0F; assign rom[97]  = 32'h0038C0B6;
    assign rom[98]  = 32'h00007402; assign rom[99]  = 32'h00006300;
    assign rom[100] = 32'h001C8FDB; assign rom[101] = 32'h00003A01;
    assign rom[102] = 32'h00003098; assign rom[103] = 32'h000E42AD;
    assign rom[104] = 32'h00009D00; assign rom[105] = 32'h000097C1;
    assign rom[106] = 32'h00076016; assign rom[107] = 32'h0000CE80;
    assign rom[108] = 32'h000047A0; assign rom[109] = 32'h000317DB;
    assign rom[110] = 32'h80006740; assign rom[111] = 32'h00002370;
    assign rom[112] = 32'h00010825; assign rom[113] = 32'hC000B3A0;
    assign rom[114] = 32'h00001198; assign rom[115] = 32'h0000240A;
    assign rom[116] = 32'hE000D9D0; assign rom[117] = 32'h000008C6;
    assign rom[118] = 32'h00005649; assign rom[119] = 32'h70006CE8;
    assign rom[120] = 32'h00000416; assign rom[121] = 32'h00000100;
    assign rom[122] = 32'h3800B674; assign rom[123] = 32'h00000209;
    assign rom[124] = 32'h000000B8; assign rom[125] = 32'h1C005B3A;
    assign rom[126] = 32'h00000102; assign rom[127] = 32'h00008040;
    assign rom[128] = 32'h0E00AD9D; assign rom[129] = 32'h00000080;
    assign rom[130] = 32'h00004420; assign rom[131] = 32'h07FF97FF;

    //=========================================================================
    // SCL divider and state machine
    //=========================================================================

    localparam S_IDLE   = 2'd0,
               S_ACTIVE = 2'd1,
               S_DONE   = 2'd2;

    reg [9:0]  scl_cnt;
    wire scl_tick = (scl_cnt == SCL_DIV - 1);

    reg [1:0]  state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_cnt <= 10'd0;
        end else if (state != S_IDLE && state != S_DONE) begin
            if (scl_tick)
                scl_cnt <= 10'd0;
            else
                scl_cnt <= scl_cnt + 1'b1;
        end else begin
            scl_cnt <= 10'd0;
        end
    end

    reg [7:0]  rom_addr;      // 0..131, points to NEXT word to load
    reg [3:0]  bit_idx;       // 15..0 within current word
    reg [31:0] current_word;  // current ROM word being shifted out
    reg [7:0]  idle_wait;
    reg        scl_reg, sda_reg;

    assign i2c_scl = scl_reg ? 1'bz : 1'b0;
    assign i2c_sda = sda_reg ? 1'bz : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            rom_addr     <= 8'd64;
            bit_idx      <= 4'd15;
            current_word <= 32'hFFFFFFFF;
            idle_wait    <= 8'd0;
            scl_reg      <= 1'b1;
            sda_reg      <= 1'b1;
            init_done    <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    scl_reg   <= 1'b1;
                    sda_reg   <= 1'b1;
                    init_done <= 1'b0;
                    rom_addr  <= 8'd64;
                    bit_idx   <= 4'd15;
                    if (idle_wait < 8'd250) begin
                        idle_wait <= idle_wait + 1'b1;
                    end else begin
                        idle_wait    <= 8'd0;
                        current_word <= rom[64];
                        rom_addr     <= 8'd65;
                        state        <= S_ACTIVE;
                    end
                end

                S_ACTIVE: begin
                    if (scl_tick) begin
                        scl_reg <= current_word[31];
                        sda_reg <= current_word[15];
                        current_word <= {current_word[30:16], 1'b1,
                                         current_word[14:0],  1'b1};
                        if (bit_idx > 0) begin
                            bit_idx <= bit_idx - 1'b1;
                        end else if (rom_addr < ROM_SIZE) begin
                            current_word <= rom[rom_addr];
                            rom_addr     <= rom_addr + 1'b1;
                            bit_idx      <= 4'd15;
                        end else begin
                            state   <= S_DONE;
                            scl_reg <= 1'b1;
                            sda_reg <= 1'b1;
                        end
                    end
                end

                S_DONE: begin
                    init_done <= 1'b1;
                    scl_reg   <= 1'b1;
                    sda_reg   <= 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
