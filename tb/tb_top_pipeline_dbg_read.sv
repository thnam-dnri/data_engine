//------------------------------------------------------------------------------
// tb_top_pipeline_dbg_read.sv
//
// Focused Phase 3A top-level test for the DPTI register-read command path.
// The FT232H/DPTI PHY is bypassed with hierarchical forces so this test can
// exercise top_pipeline's command decoder, audit_aggregator wiring, and
// response byte ordering without simulating the external synchronous FIFO bus.
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_top_pipeline_dbg_read;

    reg clk = 1'b0;
    reg adc_dco = 1'b0;
    reg dpti_clk = 1'b0;

    always #5 clk = ~clk;
    always #5 adc_dco = ~adc_dco;
    always #5 dpti_clk = ~dpti_clk;

    reg [13:0] adc_data = 14'd0;
    wire adc_clk_p;
    wire adc_clk_n;
    wire ch1_ac_h;
    wire ch1_ac_l;
    wire ch1_gain_h;
    wire ch1_gain_l;
    wire ch2_ac_h;
    wire ch2_ac_l;
    wire ch2_gain_h;
    wire ch2_gain_l;
    wire com_couple_h;
    wire com_couple_l;
    wire adc_spi_sdio;
    wire adc_spi_sclk;
    wire adc_spi_cs;
    wire adc_scl;
    wire adc_sda;
    wire [3:0] led;
    wire [7:0] dpti_data;
    wire dpti_wrn;
    wire dpti_rdn;
    wire dpti_oen;
    wire dpti_siwun;
    wire dpti_spien;

    reg forced_rx_vld = 1'b0;
    reg [7:0] forced_rx_data = 8'd0;

    top_pipeline u_dut (
        .clk(clk),
        .adc_data(adc_data),
        .adc_dco(adc_dco),
        .adc_clk_p(adc_clk_p),
        .adc_clk_n(adc_clk_n),
        .ch1_ac_h(ch1_ac_h),
        .ch1_ac_l(ch1_ac_l),
        .ch1_gain_h(ch1_gain_h),
        .ch1_gain_l(ch1_gain_l),
        .ch2_ac_h(ch2_ac_h),
        .ch2_ac_l(ch2_ac_l),
        .ch2_gain_h(ch2_gain_h),
        .ch2_gain_l(ch2_gain_l),
        .com_couple_h(com_couple_h),
        .com_couple_l(com_couple_l),
        .adc_spi_sdio(adc_spi_sdio),
        .adc_spi_sclk(adc_spi_sclk),
        .adc_spi_cs(adc_spi_cs),
        .adc_scl(adc_scl),
        .adc_sda(adc_sda),
        .led(led),
        .dpti_clk(dpti_clk),
        .dpti_data(dpti_data),
        .dpti_txen(1'b0),
        .dpti_rxen(1'b1),
        .dpti_wrn(dpti_wrn),
        .dpti_rdn(dpti_rdn),
        .dpti_oen(dpti_oen),
        .dpti_siwun(dpti_siwun),
        .dpti_spien(dpti_spien)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_id = 0;

    task check(input string name, input logic condition);
        begin
            test_id = test_id + 1;
            if (condition) begin
                pass_count = pass_count + 1;
                $display("  %0d. PASS: %s", test_id, name);
            end else begin
                fail_count = fail_count + 1;
                $display("  %0d. FAIL: %s", test_id, name);
            end
        end
    endtask

    task send_byte(input [7:0] value);
        begin
            @(posedge clk);
            forced_rx_data <= value;
            forced_rx_vld  <= 1'b1;
            @(posedge clk);
            forced_rx_vld  <= 1'b0;
            forced_rx_data <= 8'd0;
            repeat (2) @(posedge clk);
        end
    endtask

    task read_reg(input [15:0] addr, output [31:0] data, output [15:0] echo_addr);
        reg [7:0] resp [0:6];
        integer count;
        integer cycles;
        begin
            count = 0;
            cycles = 0;

            send_byte(8'h10);
            send_byte(addr[15:8]);
            send_byte(8'h11);
            send_byte(addr[7:0]);
            send_byte(8'h14);

            while (count < 7 && cycles < 100) begin
                @(posedge clk);
                if (u_dut.dpti_tx_wr) begin
                    resp[count] = u_dut.dpti_tx_data;
                    count = count + 1;
                end
                cycles = cycles + 1;
            end

            check("response length is 7 bytes", count == 7);
            check("response tag is 0x15", resp[0] == 8'h15);
            echo_addr = {resp[1], resp[2]};
            data = {resp[3], resp[4], resp[5], resp[6]};
        end
    endtask

    reg [31:0] rdata;
    reg [15:0] raddr;

    initial begin
        $display("========================================================================");
        $display("  tb_top_pipeline_dbg_read — Phase 3A register-read command path");
        $display("========================================================================");

        force u_dut.dpti_rx_vld = forced_rx_vld;
        force u_dut.dpti_rx_data = forced_rx_data;
        force u_dut.dpti_tx_rdy = 1'b1;
        force u_dut.rst_cnt = 4'd0;
        force u_dut.rst_n = 1'b0;

        repeat (2) @(posedge clk);
        release u_dut.rst_cnt;
        release u_dut.rst_n;

        repeat (40) @(posedge clk);

        $display("");
        $display("--- Test 1: firmware_version read ---");
        read_reg(16'h0000, rdata, raddr);
        check("echo address 0x0000", raddr == 16'h0000);
        check("firmware_version = 0x00030001", rdata == 32'h0003_0001);

        $display("");
        $display("--- Test 2: board_id read ---");
        read_reg(16'h0004, rdata, raddr);
        check("echo address 0x0004", raddr == 16'h0004);
        check("board_id = 0x00000104", rdata == 32'h0000_0104);

        $display("");
        $display("--- Test 3: invalid address read ---");
        read_reg(16'h0160, rdata, raddr);
        check("echo address 0x0160", raddr == 16'h0160);
        check("invalid address returns DEAD_BAAD", rdata == 32'hDEAD_BAAD);

        $display("");
        $display("========================================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL out of %0d checks", pass_count, fail_count, test_id);
        $display("========================================================================");

        if (fail_count == 0)
            $display("  ** tb_top_pipeline_dbg_read PASSED **");
        else
            $fatal(1, "tb_top_pipeline_dbg_read failed");

        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "tb_top_pipeline_dbg_read timed out");
    end

endmodule : tb_top_pipeline_dbg_read
