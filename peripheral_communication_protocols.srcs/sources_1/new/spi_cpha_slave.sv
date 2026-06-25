`timescale 1ns / 1ps

// ============================================================
// Configurable SPI Slave
//
// Supports all four SPI modes:
//
// Mode 0: CPOL=0, CPHA=0
// Mode 1: CPOL=0, CPHA=1
// Mode 2: CPOL=1, CPHA=0
// Mode 3: CPOL=1, CPHA=1
//
// Rules:
//   CPHA=0:
//     sample on leading edge
//     launch data on trailing edge
//
//   CPHA=1:
//     launch data on leading edge
//     sample on trailing edge
//
// CPOL determines physical leading/trailing edges:
//   CPOL=0: leading=rising,  trailing=falling
//   CPOL=1: leading=falling, trailing=rising
//
// MISO is split into data + output-enable so the top-level
// integration can place it onto a tri-state shared MISO wire.
// ============================================================

module spi_cpha_slave #(
    parameter int unsigned DATA_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  rst,

    // Parallel byte to transmit during the next SPI frame.
    input  logic [DATA_WIDTH-1:0] tx_data_i,

    // SPI configuration. Must remain stable for one frame.
    input  logic                  cpol_i,
    input  logic                  cpha_i,

    // SPI signals from master.
    input  logic                  sclk_i,
    input  logic                  cs_n_i,
    input  logic                  mosi_i,

    // Slave MISO output and tri-state control.
    output logic                  miso_o,
    output logic                  miso_oe_o,

    // Received parallel data.
    output logic [DATA_WIDTH-1:0] rx_data_o,
    output logic                  rx_valid_o
);

    localparam int unsigned BIT_COUNT_WIDTH =
        (DATA_WIDTH <= 1) ? 1 : $clog2(DATA_WIDTH + 1);

    logic sclk_meta;
    logic sclk_sync;
    logic sclk_prev;

    logic cs_meta;
    logic cs_sync;
    logic cs_prev;

    logic mosi_meta;
    logic mosi_sync;

    logic cpol_latched;
    logic cpha_latched;

    logic [DATA_WIDTH-1:0] tx_shift;
    logic [DATA_WIDTH-1:0] rx_shift;

    logic [BIT_COUNT_WIDTH-1:0] bits_launched;
    logic [BIT_COUNT_WIDTH-1:0] bits_sampled;

    logic miso_oe_reg;

    logic cs_fall;
    logic sclk_rise;
    logic sclk_fall;
    logic leading_edge;
    logic trailing_edge;

    assign cs_fall   =  cs_prev && !cs_sync;
    assign sclk_rise = !sclk_prev &&  sclk_sync;
    assign sclk_fall =  sclk_prev && !sclk_sync;

    // Logical SPI edges depend on CPOL.
    assign leading_edge =
        (!cpol_latched && sclk_rise) ||
        ( cpol_latched && sclk_fall);

    assign trailing_edge =
        (!cpol_latched && sclk_fall) ||
        ( cpol_latched && sclk_rise);

    // Release MISO immediately when external CS_n rises.
    assign miso_oe_o = !cs_n_i && miso_oe_reg;

    initial begin
        if (DATA_WIDTH < 2)
            $error("spi_cpha_slave requires DATA_WIDTH >= 2.");
    end

    // --------------------------------------------------------
    // Synchronize external SPI pins into local clk domain.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            sclk_meta <= 1'b0;
            sclk_sync <= 1'b0;
            sclk_prev <= 1'b0;

            cs_meta   <= 1'b1;
            cs_sync   <= 1'b1;
            cs_prev   <= 1'b1;

            mosi_meta <= 1'b0;
            mosi_sync <= 1'b0;
        end
        else begin
            sclk_meta <= sclk_i;
            sclk_sync <= sclk_meta;
            sclk_prev <= sclk_sync;

            cs_meta   <= cs_n_i;
            cs_sync   <= cs_meta;
            cs_prev   <= cs_sync;

            mosi_meta <= mosi_i;
            mosi_sync <= mosi_meta;
        end
    end

    // --------------------------------------------------------
    // SPI transaction logic.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cpol_latched <= 1'b0;
            cpha_latched <= 1'b0;

            tx_shift      <= '0;
            rx_shift      <= '0;
            rx_data_o     <= '0;

            bits_launched <= '0;
            bits_sampled  <= '0;

            miso_o        <= 1'b0;
            miso_oe_reg   <= 1'b0;
            rx_valid_o    <= 1'b0;
        end
        else begin

            // ------------------------------------------------
            // New SPI transaction begins when CS_n falls.
            // ------------------------------------------------
            if (cs_fall) begin
                cpol_latched <= cpol_i;
                cpha_latched <= cpha_i;

                tx_shift      <= tx_data_i;
                rx_shift      <= '0;

                bits_launched <= '0;
                bits_sampled  <= '0;
                rx_valid_o    <= 1'b0;

                miso_oe_reg   <= 1'b1;

                // CPHA=0 requires first MISO bit to be valid
                // before the first leading SCLK edge.
                if (cpha_i == 1'b0) begin
                    miso_o        <= tx_data_i[DATA_WIDTH-1];
                    bits_launched <= 1;
                end
                else begin
                    // CPHA=1 launches first bit on first
                    // leading edge.
                    miso_o        <= 1'b0;
                    bits_launched <= '0;
                end
            end

            // ------------------------------------------------
            // Slave inactive when CS_n is high.
            // ------------------------------------------------
            else if (cs_sync) begin
                miso_oe_reg <= 1'b0;
            end

            // ------------------------------------------------
            // Active SPI frame.
            // ------------------------------------------------
            else begin
                miso_oe_reg <= 1'b1;

                // ============================================
                // CPHA = 0
                //
                // Leading edge  -> sample MOSI
                // Trailing edge -> launch next MISO bit
                // ============================================
                if (cpha_latched == 1'b0) begin

                    if (leading_edge && (bits_sampled < DATA_WIDTH)) begin
                        rx_shift <= {
                            rx_shift[DATA_WIDTH-2:0],
                            mosi_sync
                        };

                        if (bits_sampled == DATA_WIDTH-1) begin
                            rx_data_o  <= {
                                rx_shift[DATA_WIDTH-2:0],
                                mosi_sync
                            };
                            rx_valid_o <= 1'b1;
                        end

                        bits_sampled <= bits_sampled + 1'b1;
                    end

                    if (trailing_edge &&
                        (bits_launched < DATA_WIDTH)) begin

                        miso_o <= tx_shift[DATA_WIDTH-2];

                        tx_shift <= {
                            tx_shift[DATA_WIDTH-2:0],
                            1'b0
                        };

                        bits_launched <= bits_launched + 1'b1;
                    end
                end

                // ============================================
                // CPHA = 1
                //
                // Leading edge  -> launch next MISO bit
                // Trailing edge -> sample MOSI
                // ============================================
                else begin

                    if (leading_edge &&
                        (bits_launched < DATA_WIDTH)) begin

                        miso_o <= tx_shift[DATA_WIDTH-1];

                        tx_shift <= {
                            tx_shift[DATA_WIDTH-2:0],
                            1'b0
                        };

                        bits_launched <= bits_launched + 1'b1;
                    end

                    if (trailing_edge && (bits_sampled < DATA_WIDTH)) begin
                        rx_shift <= {
                            rx_shift[DATA_WIDTH-2:0],
                            mosi_sync
                        };

                        if (bits_sampled == DATA_WIDTH-1) begin
                            rx_data_o  <= {
                                rx_shift[DATA_WIDTH-2:0],
                                mosi_sync
                            };
                            rx_valid_o <= 1'b1;
                        end

                        bits_sampled <= bits_sampled + 1'b1;
                    end
                end
            end
        end
    end

endmodule

