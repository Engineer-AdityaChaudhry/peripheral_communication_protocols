module uart_top #(
    parameter integer CLK_FREQ  = 1000000,
    parameter integer BAUD_RATE = 9600
)(
    input  wire       clk,
    input  wire       rst,

    // External UART receive line
    input  wire       rx,

    // Data and control for UART transmitter
    input  wire [7:0] dintx,
    input  wire       newd,

    // UART transmit serial line
    output wire       tx,

    // Data received by UART receiver
    output wire [7:0] doutrx,

    // TX and RX completion flags
    output wire       donetx,
    output wire       donerx,

    // Optional error output from improved UART receiver
    output wire       framing_error
);

    // ------------------------------------------------------------
    // UART Transmitter Instance
    // ------------------------------------------------------------
    uarttx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uarttx (
        .clk     (clk),
        .rst     (rst),
        .newd    (newd),
        .tx_data (dintx),
        .tx      (tx),
        .donetx  (donetx)
    );

    // ------------------------------------------------------------
    // UART Receiver Instance
    // ------------------------------------------------------------
    uartrx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uartrx (
        .clk           (clk),
        .rst           (rst),
        .rx            (rx),
        .done          (donerx),
        .rxdata        (doutrx),
        .framing_error (framing_error)
    );

endmodule