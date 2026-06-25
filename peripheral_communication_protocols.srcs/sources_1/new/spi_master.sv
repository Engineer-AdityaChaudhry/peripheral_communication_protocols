`timescale 1ns / 1ps

// ============================================================
// SPI Master - Mode 0
//
// Mode 0 timing:
//   CPOL = 0 : SCLK idles low
//   CPHA = 0 : sample MISO on rising edge
//              update MOSI on falling edge
//
// Features:
// - Full-duplex transfer
// - MSB-first
// - DATA_WIDTH bits per frame (default 8)
// - Active-low chip select
// - Runtime programmable SCLK half-period divider
// - start / busy / done handshake
//
// clk_div_i:
//   Number of system-clock cycles per SCLK half-period.
//   Example: clk_div_i = 4 gives one SCLK transition every
//   four clk cycles. A value of zero is treated as one.
// ============================================================

module spi_master #(
    parameter int unsigned DATA_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  rst,

    // Transfer-control interface
    input  logic                  start,
    input  logic [DATA_WIDTH-1:0] tx_data,
    input  logic [15:0]           clk_div_i,

    // SPI serial input from slave
    input  logic                  miso,

    // SPI outputs
    output logic                  sclk,
    output logic                  mosi,
    output logic                  cs_n,

    // Transfer status and received data
    output logic [DATA_WIDTH-1:0] rx_data,
    output logic                  busy,
    output logic                  done
);

    localparam int unsigned BIT_COUNT_WIDTH =
        (DATA_WIDTH <= 1) ? 1 : $clog2(DATA_WIDTH + 1);

    typedef enum logic [1:0] {
        IDLE,
        TRANSFER,
        FINISH
    } state_t;

    state_t state;

    logic [DATA_WIDTH-1:0] tx_shift;
    logic [DATA_WIDTH-1:0] rx_shift;

    logic [BIT_COUNT_WIDTH-1:0] bits_sampled;

    logic [15:0] clk_div_latched;
    logic [15:0] div_count;

    logic start_d;
    logic start_pulse;

    assign start_pulse = start && !start_d;

    initial begin
        if (DATA_WIDTH < 2)
            $error("spi_master requires DATA_WIDTH >= 2.");
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= IDLE;

            sclk            <= 1'b0;
            mosi            <= 1'b0;
            cs_n            <= 1'b1;

            tx_shift        <= '0;
            rx_shift        <= '0;
            rx_data         <= '0;

            bits_sampled    <= '0;
            clk_div_latched <= 16'd1;
            div_count       <= 16'd0;

            busy            <= 1'b0;
            done            <= 1'b0;

            start_d         <= 1'b0;
        end
        else begin
            // Edge-detect the start request.
            start_d <= start;

            // done is always a one-system-clock pulse.
            done <= 1'b0;

            case (state)

                // ------------------------------------------------
                // Wait for a new transfer request.
                // ------------------------------------------------
                IDLE: begin
                    sclk <= 1'b0;
                    cs_n <= 1'b1;
                    busy <= 1'b0;
                    mosi <= 1'b0;

                    div_count    <= 16'd0;
                    bits_sampled <= '0;

                    if (start_pulse) begin
                        // Latch all transaction inputs at start.
                        tx_shift <= tx_data;
                        rx_shift <= '0;

                        if (clk_div_i == 16'd0)
                            clk_div_latched <= 16'd1;
                        else
                            clk_div_latched <= clk_div_i;

                        // Mode 0 requirement:
                        // MOSI bit 7 must be valid before first SCLK rise.
                        mosi <= tx_data[DATA_WIDTH-1];

                        cs_n <= 1'b0;
                        busy <= 1'b1;

                        state <= TRANSFER;
                    end
                end

                // ------------------------------------------------
                // Generate SCLK and perform the SPI transfer.
                // ------------------------------------------------
                TRANSFER: begin
                    if (div_count == (clk_div_latched - 16'd1)) begin
                        div_count <= 16'd0;

                        if (sclk == 1'b0) begin
                            // Create a rising edge.
                            // Mode 0 samples incoming MISO here.
                            sclk         <= 1'b1;
                            rx_shift     <= {rx_shift[DATA_WIDTH-2:0], miso};
                            bits_sampled <= bits_sampled + 1'b1;
                        end
                        else begin
                            // Create a falling edge.
                            // Mode 0 changes outgoing MOSI here.
                            sclk <= 1'b0;

                            if (bits_sampled == DATA_WIDTH) begin
                                // All bits have already been sampled.
                                state <= FINISH;
                            end
                            else begin
                                // Shift toward MSB and drive next data bit.
                                tx_shift <= {tx_shift[DATA_WIDTH-2:0], 1'b0};
                                mosi     <= tx_shift[DATA_WIDTH-2];
                            end
                        end
                    end
                    else begin
                        div_count <= div_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // SCLK is low again; finish the transaction.
                // ------------------------------------------------
                FINISH: begin
                    sclk    <= 1'b0;
                    cs_n    <= 1'b1;
                    mosi    <= 1'b0;

                    rx_data <= rx_shift;
                    busy    <= 1'b0;
                    done    <= 1'b1;

                    state   <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule

