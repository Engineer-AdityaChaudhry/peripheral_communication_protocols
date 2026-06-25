`timescale 1ns / 1ps

// ============================================================
// SPI CPHA Timing Demo
//
// Demonstrates MOSI launch timing for:
//   CPHA = 0: preload first bit before first leading edge
//   CPHA = 1: launch first bit on first leading edge
//
// CPOL determines SCLK idle level.
// ============================================================

module spi_cpha_demo;

    parameter int unsigned DATA_WIDTH      = 8;
    parameter int unsigned HALF_CLK_PERIOD = 2;

    localparam int unsigned DIV_WIDTH =
        (HALF_CLK_PERIOD <= 1) ? 1 : $clog2(HALF_CLK_PERIOD);

    typedef enum logic [1:0] {
        IDLE,
        TRANSFER,
        FINISH
    } state_t;

    state_t state;

    logic clk;
    logic rst;
    logic start;

    logic cpol;
    logic cpha;

    logic cpol_latched;
    logic cpha_latched;

    logic sclk;
    logic cs_n;
    logic mosi;

    logic ready;
    logic done;

    // One-system-clock pulses marking logical SPI edges.
    logic spi_l;   // leading edge
    logic spi_t;   // trailing edge

    logic [DATA_WIDTH-1:0] tx_data;
    logic [DATA_WIDTH-1:0] tx_shift;

    logic [DIV_WIDTH-1:0] half_count;
    logic [4:0]           edges_left;
    logic [3:0]           bits_launched;

    // --------------------------------------------------------
    // System clock
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // Stimulus
    //
    // First: Mode 0  (CPOL=0, CPHA=0), sends A5
    // Second: Mode 1 (CPOL=0, CPHA=1), sends 3C
    // --------------------------------------------------------
    initial begin
        rst     = 1'b1;
        start   = 1'b0;
        cpol    = 1'b0;
        cpha    = 1'b0;
        tx_data = 8'hA5;

        repeat (3) @(posedge clk);

        @(negedge clk);
        rst = 1'b0;

        // --------------------------------------------
        // Transaction 1: CPOL=0, CPHA=0
        // --------------------------------------------
        @(negedge clk);
        cpol    = 1'b0;
        cpha    = 1'b0;
        tx_data = 8'hA5;
        start   = 1'b1;

        @(negedge clk);
        start = 1'b0;

        @(posedge done);
        #20;

        // --------------------------------------------
        // Transaction 2: CPOL=0, CPHA=1
        // --------------------------------------------
        @(negedge clk);
        cpol    = 1'b0;
        cpha    = 1'b1;
        tx_data = 8'h3C;
        start   = 1'b1;

        @(negedge clk);
        start = 1'b0;

        @(posedge done);
        #20;

        $finish;
    end

    // --------------------------------------------------------
    // Clock, logical-edge, and MOSI launch control
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= IDLE;

            sclk           <= 1'b0;
            cs_n           <= 1'b1;
            mosi           <= 1'b0;

            ready          <= 1'b1;
            done           <= 1'b0;

            spi_l          <= 1'b0;
            spi_t          <= 1'b0;

            cpol_latched   <= 1'b0;
            cpha_latched   <= 1'b0;

            tx_shift       <= '0;
            half_count     <= '0;
            edges_left     <= 5'd0;
            bits_launched  <= 4'd0;
        end
        else begin
            // Default: edge strobes and done are one-clock pulses.
            spi_l <= 1'b0;
            spi_t <= 1'b0;
            done  <= 1'b0;

            case (state)

                // --------------------------------------------
                // Wait for transaction request.
                // --------------------------------------------
                IDLE: begin
                    ready      <= 1'b1;
                    cs_n       <= 1'b1;
                    sclk       <= cpol;
                    mosi       <= 1'b0;
                    half_count <= '0;

                    if (start) begin
                        ready        <= 1'b0;
                        cs_n         <= 1'b0;
                        sclk         <= cpol;

                        cpol_latched <= cpol;
                        cpha_latched <= cpha;

                        edges_left   <= 5'd16;
                        half_count   <= '0;

                        // CPHA = 0:
                        // First MOSI bit must be valid before
                        // the first leading SCLK edge.
                        if (cpha == 1'b0) begin
                            mosi          <= tx_data[DATA_WIDTH-1];
                            tx_shift      <= {tx_data[DATA_WIDTH-2:0], 1'b0};
                            bits_launched <= 4'd1;
                        end

                        // CPHA = 1:
                        // Do not preload MOSI. First bit is launched
                        // after the first leading SCLK edge.
                        else begin
                            mosi          <= 1'b0;
                            tx_shift      <= tx_data;
                            bits_launched <= 4'd0;
                        end

                        state <= TRANSFER;
                    end
                end

                // --------------------------------------------
                // Generate 16 SPI transitions.
                // --------------------------------------------
                TRANSFER: begin
                    if (half_count == HALF_CLK_PERIOD - 1) begin
                        half_count <= '0;

                        // If SCLK currently equals CPOL, toggling
                        // moves away from idle level: leading edge.
                        if (sclk == cpol_latched) begin
                            sclk  <= ~sclk;
                            spi_l <= 1'b1;

                            // CPHA=1 launches data on leading edge.
                            if ((cpha_latched == 1'b1) &&
                                (bits_launched < DATA_WIDTH)) begin

                                mosi          <= tx_shift[DATA_WIDTH-1];
                                tx_shift      <= {
                                    tx_shift[DATA_WIDTH-2:0], 1'b0
                                };
                                bits_launched <= bits_launched + 1'b1;
                            end
                        end

                        // Otherwise toggling returns to idle level:
                        // trailing edge.
                        else begin
                            sclk  <= ~sclk;
                            spi_t <= 1'b1;

                            // CPHA=0 launches data on trailing edge.
                            if ((cpha_latched == 1'b0) &&
                                (bits_launched < DATA_WIDTH)) begin

                                mosi          <= tx_shift[DATA_WIDTH-1];
                                tx_shift      <= {
                                    tx_shift[DATA_WIDTH-2:0], 1'b0
                                };
                                bits_launched <= bits_launched + 1'b1;
                            end
                        end

                        if (edges_left == 5'd1) begin
                            edges_left <= 5'd0;
                            state      <= FINISH;
                        end
                        else begin
                            edges_left <= edges_left - 1'b1;
                        end
                    end
                    else begin
                        half_count <= half_count + 1'b1;
                    end
                end

                // --------------------------------------------
                // Complete transaction.
                // --------------------------------------------
                FINISH: begin
                    sclk  <= cpol_latched;
                    cs_n  <= 1'b1;
                    mosi  <= 1'b0;
                    ready <= 1'b1;
                    done  <= 1'b1;

                    state <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end

            endcase
        end
    end

    always @(posedge done) begin
        $display(
            "Finished transfer: CPOL=%0b, CPHA=%0b, TX=%02h",
            cpol_latched,
            cpha_latched,
            tx_data
        );
    end

endmodule

