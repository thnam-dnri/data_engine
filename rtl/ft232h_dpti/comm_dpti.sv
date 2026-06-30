//------------------------------------------------------------------------------
// comm_dpti.sv
//
// DPTI (Digilent Parallel Transfer Interface) Bridge — FT232H synchronous FIFO
//
// Ported from sig_recorder (hardware-verified on USB104 A7).
// Handles clock domain crossing between sys_clk (100 MHz) and dpti_clk (60 MHz)
// using toggle-handshake CDC. No separate TX FIFO needed for Phase 1 —
// the toggle-handshake CDC + byte-level holding register is sufficient.
//
// Changes vs sig_recorder original:
//   - Converted to SystemVerilog (.sv) with explicit port types
//   - Added dbg_if debug port (state, error, bytes_sent, rx_commands)
//   - Internal logic identical to hardware-verified comm_dpti.v
//
// Architecture reference: Architecture.md §11
// Debug register map: docs/debug_register_map.md (DPTI Bridge, 0x140)
//------------------------------------------------------------------------------

`timescale 1ns / 1ps

import dbg_pkg::*;

module comm_dpti (
    // --- System Clock Domain (sys_clk, 100 MHz) ---
    input  wire       sys_clk,
    input  wire       sys_rst_n,
    input  wire [7:0] sys_tx_data,
    input  wire       sys_tx_wr,
    output wire       sys_tx_rdy,
    output wire [7:0] sys_rx_data,
    output wire       sys_rx_vld,
    input  wire       sys_rx_rd,

    // --- DPTI Clock Domain (dpti_clk, 60 MHz from FT232H) ---
    input  wire       dpti_clk,
    inout  wire [7:0] dpti_data,
    input  wire       dpti_txen,
    input  wire       dpti_rxen,
    output reg        dpti_wrn,
    output reg        dpti_rdn,
    output reg        dpti_oen,
    output wire       dpti_siwun,
    output wire       dpti_spien,

    // --- Debug Interface ---
    output dbg_info_t  dbg_info         // 128-bit packed debug data
);

    assign dpti_siwun = 1'b1;
    assign dpti_spien = 1'b1;

    // =========================================================================
    // Reset synchronizer: sys_rst_n → dpti_clk domain
    // =========================================================================
    reg dpti_rst_n_q, dpti_rst_n_r;
    always @(posedge dpti_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dpti_rst_n_q <= 1'b0;
            dpti_rst_n_r <= 1'b0;
        end else begin
            dpti_rst_n_q <= 1'b1;
            dpti_rst_n_r <= dpti_rst_n_q;
        end
    end

    // =========================================================================
    // TX path: sys_clk → dpti_clk → FT232H
    // Toggle-handshake CDC: tx_pend → dpti_clk, ack toggles back to sys_clk
    // Key fix from sig_recorder: tx_ack_tog toggles ONLY after PHY write completes
    // =========================================================================

    reg [7:0] tx_buf;        // holding register on sys_clk
    reg       tx_pend;        // 1 = data waiting to be sent
    reg [1:0] tx_pend_hold;   // counter to hold tx_pend LOW for CDC
    reg       tx_ack_s1, tx_ack_s2, tx_ack_s3;  // ack from dpti domain
    reg       tx_ack_last;    // previous value of tx_ack_s3 (for edge detect)

    assign sys_tx_rdy = !tx_pend && !(|tx_pend_hold);

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_buf        <= 8'b0;
            tx_pend       <= 1'b0;
            tx_pend_hold  <= 2'b00;
            tx_ack_last   <= 1'b0;
        end else begin
            // Hold counter: after ack, keep tx_pend LOW for 3 cycles
            // so the CDC to dpti_clk reliably sees the 1→0 transition
            if (tx_pend_hold != 2'b00) begin
                tx_pend_hold <= tx_pend_hold - 1'b1;
            end
            // Load new byte when ready
            if (sys_tx_wr && !tx_pend && tx_pend_hold == 2'b00) begin
                tx_buf  <= sys_tx_data;
                tx_pend <= 1'b1;
            end
            // Detect ANY toggle change (not just high state)
            // tx_ack_s3 toggles for every completed PHY transfer
            if (tx_ack_s3 != tx_ack_last) begin
                tx_pend      <= 1'b0;
                tx_pend_hold <= 2'b11;  // hold LOW for 3 sys_clk cycles
            end
            tx_ack_last <= tx_ack_s3;
        end
    end

    // Synchronize data to dpti_clk (2-stage per bit)
    reg [7:0] tx_buf_s1, tx_buf_s2;
    always @(posedge dpti_clk) begin
        tx_buf_s1 <= tx_buf;
        tx_buf_s2 <= tx_buf_s1;
    end

    // Pulse generator: tx_pend rising edge → dpti_clk domain
    reg tx_pend_d1, tx_pend_d2, tx_pend_d3;
    always @(posedge dpti_clk) begin
        tx_pend_d1 <= tx_pend;
        tx_pend_d2 <= tx_pend_d1;
        tx_pend_d3 <= tx_pend_d2;
    end

    reg tx_pend_prev;
    wire tx_pend_rise;
    always @(posedge dpti_clk or negedge dpti_rst_n_r) begin
        if (!dpti_rst_n_r) tx_pend_prev <= 1'b0;
        else               tx_pend_prev <= tx_pend_d3;
    end
    assign tx_pend_rise = tx_pend_d3 && !tx_pend_prev;

    // TX pending in dpti_clk domain (level, not pulse).
    // Set by tx_pend_rise, cleared when PHY completes the write.
    reg tx_pending;
    wire tx_write_done;  // combinatorial: PHY is finishing a write

    always @(posedge dpti_clk or negedge dpti_rst_n_r) begin
        if (!dpti_rst_n_r) begin
            tx_pending <= 1'b0;
        end else begin
            if (tx_pend_rise)
                tx_pending <= 1'b1;   // new byte to send
            else if (tx_write_done)
                tx_pending <= 1'b0;   // write completed
        end
    end

    // Ack toggle back to sys_clk — ONLY when write actually completes
    reg tx_ack_tog;
    always @(posedge dpti_clk or negedge dpti_rst_n_r) begin
        if (!dpti_rst_n_r) tx_ack_tog <= 1'b0;
        else if (tx_write_done) tx_ack_tog <= ~tx_ack_tog;
    end

    always @(posedge sys_clk) begin
        tx_ack_s1 <= tx_ack_tog;
        tx_ack_s2 <= tx_ack_s1;
        tx_ack_s3 <= tx_ack_s2;
    end

    // =========================================================================
    // RX path: FT232H → dpti_clk → sys_clk
    // =========================================================================

    reg [7:0] rx_buf;
    reg       rx_tog;        // toggled by dpti_clk when a byte arrives
    reg       rx_tog_s1, rx_tog_s2, rx_tog_s3;  // synced to sys_clk
    reg       rx_ack_tog;    // toggled by sys_clk after reading

    always @(posedge sys_clk) begin
        rx_tog_s1 <= rx_tog;
        rx_tog_s2 <= rx_tog_s1;
        rx_tog_s3 <= rx_tog_s2;
    end

    reg [7:0] rx_buf_s1, rx_buf_s2;
    always @(posedge sys_clk) begin
        rx_buf_s1 <= rx_buf;
        rx_buf_s2 <= rx_buf_s1;
    end

    reg rx_vld_r;
    assign sys_rx_data = rx_buf_s2;
    assign sys_rx_vld  = rx_vld_r;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_vld_r   <= 1'b0;
            rx_ack_tog <= 1'b0;
        end else begin
            if (rx_tog_s3 != rx_ack_tog) begin
                rx_vld_r <= 1'b1;
                if (sys_rx_rd) begin
                    rx_vld_r   <= 1'b0;
                    rx_ack_tog <= rx_tog_s3;
                end
            end else begin
                rx_vld_r <= 1'b0;
            end
        end
    end

    // Synchronize ack back to dpti_clk
    reg rx_ack_s1, rx_ack_s2, rx_ack_s3;
    always @(posedge dpti_clk) begin
        rx_ack_s1 <= rx_ack_tog;
        rx_ack_s2 <= rx_ack_s1;
        rx_ack_s3 <= rx_ack_s2;
    end

    // =========================================================================
    // DPTI PHY: synchronous FIFO interface to FT232H
    // =========================================================================

    reg [7:0] dpti_data_out;
    assign dpti_data = dpti_oen ? dpti_data_out : 8'bZ;

    localparam IDLE = 1'b0,
               SEND = 1'b1;

    reg state;

    wire want_write = tx_pending && !dpti_txen;
    wire want_read  = !dpti_rxen;

    assign tx_write_done = (state == SEND) && (!dpti_wrn);

    reg rx_priority;  // 0=write-first, 1=read-first

    always @(posedge dpti_clk or negedge dpti_rst_n_r) begin
        if (!dpti_rst_n_r) begin
            state         <= IDLE;
            dpti_wrn      <= 1'b1;
            dpti_rdn      <= 1'b1;
            dpti_oen      <= 1'b1;
            dpti_data_out <= 8'b0;
            rx_buf        <= 8'b0;
            rx_tog        <= 1'b0;
            rx_priority   <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    dpti_wrn      <= 1'b1;
                    dpti_rdn      <= 1'b1;
                    dpti_oen      <= 1'b1;
                    dpti_data_out <= 8'b0;

                    // Round-robin: alternate priority to prevent starvation
                    if (rx_priority) begin
                        // Read priority
                        if (want_read) begin
                            dpti_rdn <= 1'b0;
                            dpti_oen <= 1'b0;
                            state    <= SEND;
                        end else if (want_write) begin
                            dpti_wrn      <= 1'b0;
                            dpti_data_out <= tx_buf_s2;
                            state         <= SEND;
                        end
                        rx_priority <= 1'b0;
                    end else begin
                        // Write priority
                        if (want_write) begin
                            dpti_wrn      <= 1'b0;
                            dpti_data_out <= tx_buf_s2;
                            state         <= SEND;
                        end else if (want_read) begin
                            dpti_rdn <= 1'b0;
                            dpti_oen <= 1'b0;
                            state    <= SEND;
                        end
                        rx_priority <= 1'b1;
                    end
                end

                SEND: begin
                    if (!dpti_wrn) begin
                        // Finishing a write
                        dpti_wrn <= 1'b1;
                        state    <= IDLE;
                    end else if (!dpti_rdn) begin
                        // Finishing a read: data is valid now
                        dpti_wrn  <= 1'b1;
                        dpti_rdn  <= 1'b1;
                        dpti_oen  <= 1'b1;
                        rx_buf    <= dpti_data;
                        rx_tog    <= ~rx_tog;
                        state     <= IDLE;
                    end else begin
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // Debug interface (sys_clk domain)
    // =========================================================================
    logic [3:0]  dbg_state;
    logic [15:0] dbg_cycle_count;
    logic [7:0]  dbg_stall_cycles;
    logic        dbg_error;
    logic [7:0]  dbg_error_id;
    logic        dbg_bypass_mode;
    logic [15:0] dbg_event_count;
    logic [15:0] dbg_word_count;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dbg_state       <= 4'd0;
            dbg_cycle_count <= 16'd0;
            dbg_stall_cycles <= 8'd0;
            dbg_error       <= 1'b0;
            dbg_error_id    <= 8'd0;
            dbg_bypass_mode <= 1'b0;
            dbg_event_count <= 16'd0;
            dbg_word_count  <= 16'd0;
        end else begin
            dbg_cycle_count <= dbg_cycle_count + 1'b1;

            // State (approximate from known activity)
            dbg_state <= (sys_tx_wr || sys_rx_vld) ? 4'd1 : 4'd0;

            // Stall cycles: count when TX is pending but not ready
            if (sys_tx_wr && !sys_tx_rdy) begin
                if (dbg_stall_cycles < 8'hFF)
                    dbg_stall_cycles <= dbg_stall_cycles + 1'b1;
            end

            // Event count: bytes sent
            if (sys_tx_wr && sys_tx_rdy) begin
                dbg_event_count <= dbg_event_count + 1'b1;
            end

            // Word count: bytes received
            if (sys_rx_vld && sys_rx_rd) begin
                dbg_word_count <= dbg_word_count + 1'b1;
            end
        end
    end

    // Drive dbg_info output (positional concatenation)
    assign dbg_info = {
        dbg_state,           // [127:124]  4 bits
        dbg_cycle_count,     // [123:108] 16 bits
        dbg_stall_cycles,    // [107:100]  8 bits
        4'd0,                // [99:96]    4 bits reserved_0
        dbg_error,           // [95]       1 bit
        dbg_error_id,        // [94:87]    8 bits
        dbg_bypass_mode,     // [86]       1 bit
        22'd0,               // [85:64]   22 bits reserved_1
        dbg_event_count,     // [63:48]   16 bits
        16'd0,               // [47:32]   16 bits reserved_2
        dbg_word_count,      // [31:16]   16 bits
        16'd0                // [15:0]    16 bits reserved_3
    };

endmodule : comm_dpti
