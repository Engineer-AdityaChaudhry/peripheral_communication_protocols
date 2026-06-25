`timescale 1ns / 1ps

// ============================================================
// 16550A-inspired UART Top Module
//
// Integrates:
// - uart_register
// - TX FIFO
// - RX FIFO
// - uart_tx
// - uart_rx
// ============================================================

module uart_16550_top (
    input  logic       clk,
    input  logic       rst,

    // --------------------------------------------------------
    // Simple CPU-facing register interface
    // --------------------------------------------------------
    input  logic       wr_i,
    input  logic       rd_i,
    input  logic [2:0] addr_i,
    input  logic [7:0] din_i,
    output logic [7:0] dout_o,

    // --------------------------------------------------------
    // UART serial pins
    // --------------------------------------------------------
    input  logic       rx_i,
    output logic       tx_o,

    // --------------------------------------------------------
    // UART interrupt output
    // --------------------------------------------------------
    output logic       irq_o
);

    // ========================================================
    // Register-bank signals
    // ========================================================
    logic       tx_fifo_push;
    logic [7:0] tx_fifo_din;
    logic       rx_fifo_pop;

    logic       tx_fifo_clear;
    logic       rx_fifo_clear;
    logic       fifo_enable;
    logic [4:0] rx_fifo_threshold;

    logic [7:0]  lcr;
    logic [7:0]  mcr;
    logic [3:0]  ier;
    logic [15:0] divisor;
    logic        baud16_tick;

    logic [7:0] lsr;
    logic [7:0] iir;

    // ========================================================
    // TX FIFO signals
    // ========================================================
    logic [7:0] tx_fifo_dout;
    logic       tx_fifo_empty;
    logic       tx_fifo_full;
    logic [4:0] tx_fifo_count;

    logic       tx_fifo_overrun;
    logic       tx_fifo_underrun;
    logic       tx_fifo_threshold_hit;

    logic       tx_fifo_pop;
    logic       tx_sreg_empty;

    // ========================================================
    // RX FIFO signals
    // ========================================================
    logic [7:0] rx_fifo_din;
    logic [7:0] rx_fifo_dout;
    logic       rx_fifo_push;
    logic       rx_fifo_empty;
    logic       rx_fifo_full;
    logic [4:0] rx_fifo_count;

    logic       rx_fifo_overrun;
    logic       rx_fifo_underrun;
    logic       rx_fifo_threshold_hit;

    // ========================================================
    // RX error/status signals
    // ========================================================
    logic rx_overrun;
    logic rx_parity_error;
    logic rx_framing_error;
    logic rx_break_interrupt;

    // ========================================================
    // UART Register Bank
    // ========================================================
    uart_register u_uart_register (
        .clk                     (clk),
        .rst                     (rst),

        .wr_i                    (wr_i),
        .rd_i                    (rd_i),
        .addr_i                  (addr_i),
        .din_i                   (din_i),
        .dout_o                  (dout_o),

        // TX FIFO status/control
        .tx_fifo_push_o          (tx_fifo_push),
        .tx_fifo_din_o           (tx_fifo_din),
        .tx_fifo_empty_i         (tx_fifo_empty),
        .tx_fifo_full_i          (tx_fifo_full),
        .tx_sreg_empty_i         (tx_sreg_empty),

        // RX FIFO status/control
        .rx_fifo_pop_o           (rx_fifo_pop),
        .rx_fifo_dout_i          (rx_fifo_dout),
        .rx_fifo_empty_i         (rx_fifo_empty),
        .rx_fifo_threshold_hit_i (rx_fifo_threshold_hit),

        // RX error events
        .rx_oe_i                 (rx_overrun),
        .rx_pe_i                 (rx_parity_error),
        .rx_fe_i                 (rx_framing_error),
        .rx_bi_i                 (rx_break_interrupt),

        // FCR outputs
        .tx_fifo_clear_o         (tx_fifo_clear),
        .rx_fifo_clear_o         (rx_fifo_clear),
        .fifo_enable_o           (fifo_enable),
        .rx_fifo_threshold_o     (rx_fifo_threshold),

        // Configuration outputs
        .lcr_o                   (lcr),
        .mcr_o                   (mcr),
        .ier_o                   (ier),
        .divisor_o               (divisor),
        .baud16_tick_o           (baud16_tick),

        // Status and interrupt
        .lsr_o                   (lsr),
        .iir_o                   (iir),
        .irq_o                   (irq_o)
    );

    // ========================================================
    // TX FIFO
    //
    // FIFO is always enabled physically.
    // FCR FIFO-enable currently controls threshold/interrupt
    // behavior inside uart_register, not data storage itself.
    // ========================================================
    fifo_8x16 u_tx_fifo (
        .clk               (clk),
        .rst               (rst),
        .clear_i           (tx_fifo_clear),
        .en                (1'b1),

        .push_in           (tx_fifo_push),
        .din               (tx_fifo_din),

        .pop_in            (tx_fifo_pop),
        .dout              (tx_fifo_dout),

        .empty             (tx_fifo_empty),
        .full              (tx_fifo_full),
        .count             (tx_fifo_count),

        .overrun           (tx_fifo_overrun),
        .underrun          (tx_fifo_underrun),

        .threshold         (5'd0),
        .threshold_trigger (tx_fifo_threshold_hit)
    );

    // ========================================================
    // UART Transmitter
    // ========================================================
    uart_tx u_uart_tx (
        .clk           (clk),
        .rst           (rst),
        .baud16_tick   (baud16_tick),

        .tx_fifo_empty (tx_fifo_empty),
        .tx_fifo_dout  (tx_fifo_dout),
        .tx_fifo_pop   (tx_fifo_pop),

        .lcr           (lcr),

        .tx            (tx_o),
        .sreg_empty    (tx_sreg_empty)
    );

    // ========================================================
    // UART Receiver
    // ========================================================
    uart_rx u_uart_rx (
        .clk             (clk),
        .rst             (rst),
        .baud16_tick     (baud16_tick),

        .rx              (rx_i),

        .rx_fifo_full    (rx_fifo_full),
        .rx_fifo_din     (rx_fifo_din),
        .rx_fifo_push    (rx_fifo_push),

        .lcr             (lcr),

        .parity_error    (rx_parity_error),
        .framing_error   (rx_framing_error),
        .break_interrupt (rx_break_interrupt),
        .overrun         (rx_overrun)
    );

    // ========================================================
    // RX FIFO
    // ========================================================
    fifo_8x16 u_rx_fifo (
        .clk               (clk),
        .rst               (rst),
        .clear_i           (rx_fifo_clear),
        .en                (1'b1),

        .push_in           (rx_fifo_push),
        .din               (rx_fifo_din),

        .pop_in            (rx_fifo_pop),
        .dout              (rx_fifo_dout),

        .empty             (rx_fifo_empty),
        .full              (rx_fifo_full),
        .count             (rx_fifo_count),

        .overrun           (rx_fifo_overrun),
        .underrun          (rx_fifo_underrun),

        .threshold         (rx_fifo_threshold),
        .threshold_trigger (rx_fifo_threshold_hit)
    );

endmodule