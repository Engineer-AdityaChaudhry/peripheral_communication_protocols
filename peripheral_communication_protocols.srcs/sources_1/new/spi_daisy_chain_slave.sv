`timescale 1ns / 1ps

// ============================================================
// Generic SPI Daisy-Chain Slave
//
// Initial SPI mode:
//   CPOL = 0
//   CPHA = 0
//
// Shared bus behavior:
//   CS_n low  -> participate in the daisy-chain frame
//   SCLK rise -> capture SDI and shift register contents
//
// Daisy-chain serial path:
//   SDI input  <- preceding device's SDO, or master MOSI
//   SDO output -> following device's SDI, or master MISO
//
// The slave shifts continuously for the whole shared-CS frame.
// Its rx_data_o holds the final DATA_WIDTH bits received before
// CS_n returns high.
// ============================================================

module spi_daisy_chain_slave #(
    parameter int unsigned DATA_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  rst,

    // Parallel value loaded into this slave at frame start.
    input  logic [DATA_WIDTH-1:0] parallel_load_i,

    // Shared SPI bus.
    input  logic                  sclk_i,
    input  logic                  cs_n_i,
    input  logic                  sdi_i,

    // Daisy-chain serial output.
    output logic                  sdo_o,

    // Final DATA_WIDTH bits received during the frame.
    output logic [DATA_WIDTH-1:0] rx_data_o,
    output logic                  rx_valid_o,

    // Debug/status visibility.
    output logic                  active_o
);

    logic sclk_meta;
    logic sclk_sync;
    logic sclk_prev;

    logic cs_meta;
    logic cs_sync;
    logic cs_prev;

    logic sdi_meta;
    logic sdi_sync;

    logic [DATA_WIDTH-1:0] shift_reg;
    logic [DATA_WIDTH-1:0] rx_shift;

    logic cs_fall;
    logic cs_rise;
    logic sclk_rise;

    assign cs_fall   =  cs_prev && !cs_sync;
    assign cs_rise   = !cs_prev &&  cs_sync;
    assign sclk_rise = !sclk_prev && sclk_sync;

    // While selected, expose the current MSB to the next device.
    // The next bit appears after the internal shift operation.
    assign sdo_o = active_o ? shift_reg[DATA_WIDTH-1] : 1'b0;

    initial begin
        if (DATA_WIDTH < 2)
            $error("spi_daisy_chain_slave requires DATA_WIDTH >= 2.");
    end

    // --------------------------------------------------------
    // Synchronize shared SPI inputs into the local clk domain.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            sclk_meta <= 1'b0;
            sclk_sync <= 1'b0;
            sclk_prev <= 1'b0;

            cs_meta   <= 1'b1;
            cs_sync   <= 1'b1;
            cs_prev   <= 1'b1;

            sdi_meta  <= 1'b0;
            sdi_sync  <= 1'b0;
        end
        else begin
            sclk_meta <= sclk_i;
            sclk_sync <= sclk_meta;
            sclk_prev <= sclk_sync;

            cs_meta   <= cs_n_i;
            cs_sync   <= cs_meta;
            cs_prev   <= cs_sync;

            sdi_meta  <= sdi_i;
            sdi_sync  <= sdi_meta;
        end
    end

    // --------------------------------------------------------
    // Daisy-chain shift-register behavior.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            shift_reg <= '0;
            rx_shift  <= '0;
            rx_data_o <= '0;
            rx_valid_o <= 1'b0;
            active_o  <= 1'b0;
        end
        else begin
            // New shared-CS transaction.
            if (cs_fall) begin
                shift_reg  <= parallel_load_i;
                rx_shift   <= '0;
                rx_valid_o <= 1'b0;
                active_o   <= 1'b1;
            end

            // Transaction ends. Commit the final received byte.
            else if (cs_rise) begin
                if (active_o) begin
                    rx_data_o  <= rx_shift;
                    rx_valid_o <= 1'b1;
                end

                active_o <= 1'b0;
            end

            // Mode 0 sample edge: receive SDI and shift the
            // complete daisy-chain register by one bit.
            else if (active_o && sclk_rise) begin
                shift_reg <= {
                    shift_reg[DATA_WIDTH-2:0],
                    sdi_sync
                };

                rx_shift <= {
                    rx_shift[DATA_WIDTH-2:0],
                    sdi_sync
                };
            end
        end
    end

endmodule

