`timescale 1ns / 1ps

// ============================================================
// Configurable SPI Master
//
// Supports all four SPI modes:
//   Mode 0: CPOL=0, CPHA=0
//   Mode 1: CPOL=0, CPHA=1
//   Mode 2: CPOL=1, CPHA=0
//   Mode 3: CPOL=1, CPHA=1
//
// Protocol rules:
//   CPHA=0: sample on leading edge, launch on trailing edge.
//   CPHA=1: launch on leading edge, sample on trailing edge.
//
// CPOL determines the physical meaning of leading/trailing:
//   CPOL=0: leading=rising,  trailing=falling
//   CPOL=1: leading=falling, trailing=rising
//
// DATA_WIDTH must be at least 2.
// ============================================================

module spi_cpha_master #(
    parameter int unsigned DATA_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  rst,

    // Transaction control
    input  logic                  start,
    input  logic [DATA_WIDTH-1:0] tx_data,
    input  logic [15:0]           clk_div_i,
    input  logic                  cpol_i,
    input  logic                  cpha_i,

    // SPI input from slave
    input  logic                  miso,

    // SPI outputs
    output logic                  sclk,
    output logic                  mosi,
    output logic                  cs_n,

    // Status and received data
    output logic [DATA_WIDTH-1:0] rx_data,
    output logic                  busy,
    output logic                  done
);

    localparam int unsigned BIT_COUNT_WIDTH =
        (DATA_WIDTH <= 1) ? 1 : $clog2(DATA_WIDTH + 1);

    localparam int unsigned EDGE_COUNT_WIDTH =
        ((2 * DATA_WIDTH) <= 1) ? 1 : $clog2(2 * DATA_WIDTH);

    typedef enum logic [1:0] {
        IDLE,
        TRANSFER,
        FINISH
    } state_t;

    state_t state;

    logic [DATA_WIDTH-1:0] tx_shift;
    logic [DATA_WIDTH-1:0] rx_shift;

    logic [BIT_COUNT_WIDTH-1:0] bits_launched;
    logic [BIT_COUNT_WIDTH-1:0] bits_sampled;
    logic [EDGE_COUNT_WIDTH-1:0] edge_count;

    logic [15:0] clk_div_latched;
    logic [15:0] div_count;

    logic cpol_latched;
    logic cpha_latched;

    logic start_d;
    logic start_pulse;

    assign start_pulse = start && !start_d;

    initial begin
        if (DATA_WIDTH < 2)
            $error("DATA_WIDTH must be at least 2.");
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

            bits_launched   <= '0;
            bits_sampled    <= '0;
            edge_count      <= '0;

            clk_div_latched <= 16'd1;
            div_count       <= 16'd0;

            cpol_latched    <= 1'b0;
            cpha_latched    <= 1'b0;

            busy            <= 1'b0;
            done            <= 1'b0;

            start_d         <= 1'b0;
        end
        else begin
            start_d <= start;

            // done is always a single system-clock pulse.
            done <= 1'b0;

            case (state)

                // ------------------------------------------------
                // SCLK remains at the configured idle polarity.
                // ------------------------------------------------
                IDLE: begin
                    sclk <= cpol_i;
                    mosi <= 1'b0;
                    cs_n <= 1'b1;
                    busy <= 1'b0;

                    div_count     <= 16'd0;
                    edge_count    <= '0;
                    bits_launched <= '0;
                    bits_sampled  <= '0;

                    if (start_pulse) begin
                        cpol_latched <= cpol_i;
                        cpha_latched <= cpha_i;

                        tx_shift <= tx_data;
                        rx_shift <= '0;

                        if (clk_div_i == 16'd0)
                            clk_div_latched <= 16'd1;
                        else
                            clk_div_latched <= clk_div_i;

                        sclk <= cpol_i;
                        cs_n <= 1'b0;
                        busy <= 1'b1;

                        // CPHA=0 requires bit 7 before first
                        // leading clock edge.
                        if (cpha_i == 1'b0) begin
                            mosi          <= tx_data[DATA_WIDTH-1];
                            bits_launched <= 1;
                        end
                        else begin
                            // CPHA=1 launches first bit only on
                            // the first leading edge.
                            mosi          <= 1'b0;
                            bits_launched <= '0;
                        end

                        state <= TRANSFER;
                    end
                end

                // ------------------------------------------------
                // One SCLK transition occurs each clk_div_latched
                // system-clock cycles.
                // ------------------------------------------------
                TRANSFER: begin
                    if (div_count == (clk_div_latched - 16'd1)) begin
                        div_count <= 16'd0;

                        // When current SCLK equals CPOL, toggling
                        // moves away from idle: logical leading edge.
                        if (sclk == cpol_latched) begin
                            sclk <= ~sclk;

                            // CPHA=1 launches data on leading edge.
                            if ((cpha_latched == 1'b1) &&
                                (bits_launched < DATA_WIDTH)) begin

                                mosi          <= tx_shift[DATA_WIDTH-1];
                                tx_shift      <= {
                                    tx_shift[DATA_WIDTH-2:0], 1'b0
                                };
                                bits_launched <= bits_launched + 1'b1;
                            end

                            // CPHA=0 samples data on leading edge.
                            if (cpha_latched == 1'b0) begin
                                rx_shift <= {
                                    rx_shift[DATA_WIDTH-2:0], miso
                                };

                                if (bits_sampled == DATA_WIDTH-1)
                                    rx_data <= {
                                        rx_shift[DATA_WIDTH-2:0], miso
                                    };

                                bits_sampled <= bits_sampled + 1'b1;
                            end
                        end

                        // Toggling returns SCLK to idle level:
                        // logical trailing edge.
                        else begin
                            sclk <= ~sclk;

                            // CPHA=0 launches data on trailing edge.
                            if ((cpha_latched == 1'b0) &&
                                (bits_launched < DATA_WIDTH)) begin

                                mosi          <= tx_shift[DATA_WIDTH-2];
                                tx_shift      <= {
                                    tx_shift[DATA_WIDTH-2:0], 1'b0
                                };
                                bits_launched <= bits_launched + 1'b1;
                            end

                            // CPHA=1 samples data on trailing edge.
                            if (cpha_latched == 1'b1) begin
                                rx_shift <= {
                                    rx_shift[DATA_WIDTH-2:0], miso
                                };

                                if (bits_sampled == DATA_WIDTH-1)
                                    rx_data <= {
                                        rx_shift[DATA_WIDTH-2:0], miso
                                    };

                                bits_sampled <= bits_sampled + 1'b1;
                            end
                        end

                        // 8 bits require 16 SCLK transitions.
                        if (edge_count == (2 * DATA_WIDTH - 1)) begin
                            edge_count <= '0;
                            state      <= FINISH;
                        end
                        else begin
                            edge_count <= edge_count + 1'b1;
                        end
                    end
                    else begin
                        div_count <= div_count + 1'b1;
                    end
                end

                // ------------------------------------------------
                // SCLK has returned to CPOL-defined idle level.
                // ------------------------------------------------
                FINISH: begin
                    sclk    <= cpol_latched;
                    mosi    <= 1'b0;
                    cs_n    <= 1'b1;
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
