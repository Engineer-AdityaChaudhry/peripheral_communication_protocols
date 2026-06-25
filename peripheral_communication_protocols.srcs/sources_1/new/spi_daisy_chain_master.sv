
`timescale 1ns / 1ps

// ============================================================
// Generic SPI Daisy-Chain Master
//
// Fixed initial SPI mode:
//   CPOL = 0
//   CPHA = 0
//   SCLK idle low
//   Rising edge  -> sample MISO
//   Falling edge -> launch next MOSI bit
//
// One transaction shifts NUM_SLAVES * DATA_WIDTH bits.
// The first bits transmitted travel to the farthest slave.
// ============================================================

module spi_daisy_chain_master #(
    parameter int unsigned NUM_SLAVES = 3,
    parameter int unsigned DATA_WIDTH = 8
) (
    input  logic                                      clk,
    input  logic                                      rst,

    // Transaction control
    input  logic                                      start,
    input  logic [(NUM_SLAVES*DATA_WIDTH)-1:0]       tx_data_i,
    input  logic [15:0]                              clk_div_i,

    // Serial return path from final slave in the chain
    input  logic                                      miso_i,

    // Shared SPI bus
    output logic                                      sclk_o,
    output logic                                      mosi_o,
    output logic                                      cs_n_o,

    // Received serial stream from the chain
    output logic [(NUM_SLAVES*DATA_WIDTH)-1:0]       rx_data_o,

    // Status
    output logic                                      busy_o,
    output logic                                      done_o
);

    localparam int unsigned FRAME_WIDTH = NUM_SLAVES * DATA_WIDTH;

    localparam int unsigned COUNT_WIDTH =
        (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH + 1);

    typedef enum logic [1:0] {
        IDLE,
        TRANSFER,
        FINISH
    } state_t;

    state_t state;

    logic [FRAME_WIDTH-1:0] tx_shift;
    logic [FRAME_WIDTH-1:0] rx_shift;

    logic [COUNT_WIDTH-1:0] bits_sampled;

    logic [15:0] clk_div_latched;
    logic [15:0] div_count;

    logic start_d;
    logic start_pulse;

    assign start_pulse = start && !start_d;

    initial begin
        if (NUM_SLAVES == 0)
            $error("NUM_SLAVES must be at least 1.");

        if (DATA_WIDTH < 2)
            $error("DATA_WIDTH must be at least 2.");
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= IDLE;

            sclk_o          <= 1'b0;
            mosi_o          <= 1'b0;
            cs_n_o          <= 1'b1;

            tx_shift        <= '0;
            rx_shift        <= '0;
            rx_data_o       <= '0;

            bits_sampled    <= '0;

            clk_div_latched <= 16'd1;
            div_count       <= 16'd0;

            busy_o          <= 1'b0;
            done_o          <= 1'b0;

            start_d         <= 1'b0;
        end
        else begin
            start_d <= start;

            // done_o is always one clk cycle wide.
            done_o <= 1'b0;

            case (state)

                // ------------------------------------------------
                // Shared bus inactive:
                // CS_n = 1, SCLK = 0
                // ------------------------------------------------
                IDLE: begin
                    sclk_o       <= 1'b0;
                    mosi_o       <= 1'b0;
                    cs_n_o       <= 1'b1;
                    busy_o       <= 1'b0;

                    div_count    <= 16'd0;
                    bits_sampled <= '0;

                    if (start_pulse) begin
                        if (clk_div_i == 16'd0)
                            clk_div_latched <= 16'd1;
                        else
                            clk_div_latched <= clk_div_i;

                        tx_shift <= {
                            tx_data_i[FRAME_WIDTH-2:0],
                            1'b0
                        };

                        rx_shift  <= '0;

                        // Mode 0 requires the first MOSI bit
                        // to be valid before the first rising edge.
                        mosi_o <= tx_data_i[FRAME_WIDTH-1];

                        cs_n_o <= 1'b0;
                        sclk_o <= 1'b0;
                        busy_o <= 1'b1;

                        state <= TRANSFER;
                    end
                end

                // ------------------------------------------------
                // Mode 0 transfer:
                //
                // Rising SCLK edge:
                //   master samples MISO
                //
                // Falling SCLK edge:
                //   master launches next MOSI bit
                // ------------------------------------------------
                TRANSFER: begin
                    if (div_count == (clk_div_latched - 16'd1)) begin
                        div_count <= 16'd0;

                        if (sclk_o == 1'b0) begin
                            // Leading/rising edge: sample MISO.
                            sclk_o   <= 1'b1;
                            rx_shift <= {
                                rx_shift[FRAME_WIDTH-2:0],
                                miso_i
                            };

                            if (bits_sampled == FRAME_WIDTH - 1) begin
                                rx_data_o <= {
                                    rx_shift[FRAME_WIDTH-2:0],
                                    miso_i
                                };
                            end

                            bits_sampled <= bits_sampled + 1'b1;
                        end
                        else begin
                            // Trailing/falling edge: launch MOSI.
                            sclk_o <= 1'b0;

                            if (bits_sampled == FRAME_WIDTH) begin
                                state <= FINISH;
                            end
                            else begin
                                mosi_o   <= tx_shift[FRAME_WIDTH-1];
                                tx_shift <= {
                                    tx_shift[FRAME_WIDTH-2:0],
                                    1'b0
                                };
                            end
                        end
                    end
                    else begin
                        div_count <= div_count + 1'b1;
                    end
                end

                // ------------------------------------------------
                // Final falling edge has occurred. End frame.
                // ------------------------------------------------
                FINISH: begin
                    cs_n_o <= 1'b1;
                    sclk_o <= 1'b0;
                    mosi_o <= 1'b0;

                    busy_o <= 1'b0;
                    done_o <= 1'b1;

                    state <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule

