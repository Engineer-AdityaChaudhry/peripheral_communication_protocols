`timescale 1ns / 1ps

// ============================================================
// SPI Slave - Mode 0
//
// Mode 0:
//   CPOL = 0 : SCLK idle low
//   CPHA = 0 : sample MOSI on rising edge
//              update MISO after falling edge
//
// Architecture:
// - SCLK, CS_n, and MOSI are synchronized into clk domain.
// - tx_data_i must be stable before CS_n becomes low.
// - miso_o + miso_oe_o are separate so a top-level wrapper
//   can handle the shared MISO tri-state line safely.
//
// Integration requirement:
//   clk must be sufficiently faster than SCLK.
//   Use spi_master clk_div_i >= 4 for this project.
// ============================================================

module spi_slave #(
    parameter int unsigned DATA_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  rst,

    // Parallel data to return during the next SPI transaction.
    input  logic [DATA_WIDTH-1:0] tx_data_i,

    // SPI pins from master
    input  logic                  sclk_i,
    input  logic                  cs_n_i,
    input  logic                  mosi_i,

    // MISO output data and output-enable
    output logic                  miso_o,
    output logic                  miso_oe_o,

    // Received parallel data
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

    logic [DATA_WIDTH-1:0] tx_shift;
    logic [DATA_WIDTH-1:0] rx_shift;

    logic [BIT_COUNT_WIDTH-1:0] bit_count;
    logic                        miso_oe_reg;

    logic cs_fall;
    logic sclk_rise;
    logic sclk_fall;

    assign cs_fall   =  cs_prev && !cs_sync;
    assign sclk_rise = !sclk_prev &&  sclk_sync;
    assign sclk_fall =  sclk_prev && !sclk_sync;

    // Immediately release MISO when the external chip select rises.
    always_comb begin
        miso_oe_o = !cs_n_i && miso_oe_reg;
    end

    // --------------------------------------------------------
    // Synchronize the external SPI signals into clk domain.
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
    // SPI Mode 0 transaction logic.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_shift    <= '0;
            rx_shift    <= '0;
            rx_data_o   <= '0;
            rx_valid_o  <= 1'b0;

            bit_count   <= '0;

            miso_o      <= 1'b0;
            miso_oe_reg <= 1'b0;
        end
        else begin
            // A new CS assertion starts a fresh SPI frame.
            if (cs_fall) begin
                tx_shift    <= tx_data_i;
                rx_shift    <= '0;
                bit_count   <= '0;
                rx_valid_o  <= 1'b0;

                // Mode 0 requires MISO bit 7 before first SCLK rise.
                miso_o      <= tx_data_i[DATA_WIDTH-1];
                miso_oe_reg <= 1'b1;
            end

            // Slave is inactive while CS_n is high.
            else if (cs_sync) begin
                miso_oe_reg <= 1'b0;
            end

            else begin
                miso_oe_reg <= 1'b1;

                // Mode 0: sample incoming MOSI on rising SCLK edge.
                if (sclk_rise) begin
                    rx_shift <= {rx_shift[DATA_WIDTH-2:0], mosi_sync};

                    if (bit_count == DATA_WIDTH-1) begin
                        rx_data_o  <= {rx_shift[DATA_WIDTH-2:0], mosi_sync};
                        rx_valid_o <= 1'b1;
                    end

                    bit_count <= bit_count + 1'b1;
                end

                // Mode 0: update outgoing MISO after falling edge.
                if (sclk_fall && (bit_count < DATA_WIDTH)) begin
                    // Drive bit 6 after bit 7, then bit 5, etc.
                    miso_o   <= tx_shift[DATA_WIDTH-2];
                    tx_shift <= {tx_shift[DATA_WIDTH-2:0], 1'b0};
                end
            end
        end
    end

endmodule

