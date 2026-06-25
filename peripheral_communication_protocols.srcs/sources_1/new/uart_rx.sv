`timescale 1ns / 1ps

// ============================================================
// 16550A-inspired UART Receiver
//
// Input timing:
// baud16_tick = one-clock enable pulse at 16x baud rate.
//
// LCR mapping:
// LCR[1:0] = word length select
// LCR[2]   = stop-bit configuration
// LCR[3]   = parity enable
// LCR[4]   = even parity select
// LCR[5]   = stick parity
// ============================================================

module uart_rx (
    input  logic       clk,
    input  logic       rst,
    input  logic       baud16_tick,

    // UART serial input
    input  logic       rx,

    // RX FIFO interface
    input  logic       rx_fifo_full,
    output logic [7:0] rx_fifo_din,
    output logic       rx_fifo_push,

    // Line Control Register
    input  logic [7:0] lcr,

    // One-clock error pulses
    output logic       parity_error,
    output logic       framing_error,
    output logic       break_interrupt,
    output logic       overrun
);

    typedef enum logic [2:0] {
        IDLE,
        START_CHECK,
        DATA,
        PARITY,
        STOP
    } state_t;

    state_t state;

    // Two-flop synchronizer for the asynchronous RX input.
    logic rx_meta;
    logic rx_sync;

    // Received byte.
    logic [7:0] shift_reg;

    // Latched LCR fields for the active frame.
    logic [1:0] wls_latched;
    logic       pen_latched;
    logic       eps_latched;
    logic       sp_latched;

    logic [3:0] data_bits_latched;
    logic [3:0] bit_index;
    logic [4:0] tick_count;

    // --------------------------------------------------------
    // Convert LCR word-length field to number of bits.
    // --------------------------------------------------------
    function automatic logic [3:0] data_bits_from_wls(
        input logic [1:0] wls
    );
        case (wls)
            2'b00:  data_bits_from_wls = 4'd5;
            2'b01:  data_bits_from_wls = 4'd6;
            2'b10:  data_bits_from_wls = 4'd7;
            default: data_bits_from_wls = 4'd8;
        endcase
    endfunction

    // --------------------------------------------------------
    // Expected parity from received data and latched LCR.
    // --------------------------------------------------------
    function automatic logic expected_parity(
        input logic [7:0] data,
        input logic [1:0] wls,
        input logic       eps,
        input logic       sp
    );
        logic data_xor;

        begin
            case (wls)
                2'b00:  data_xor = ^data[4:0];
                2'b01:  data_xor = ^data[5:0];
                2'b10:  data_xor = ^data[6:0];
                default: data_xor = ^data[7:0];
            endcase

            // Stick parity:
            // SP=1, EPS=0 -> mark parity: force high.
            // SP=1, EPS=1 -> space parity: force low.
            if (sp)
                expected_parity = eps ? 1'b0 : 1'b1;

            // Normal even parity.
            else if (eps)
                expected_parity = data_xor;

            // Normal odd parity.
            else
                expected_parity = ~data_xor;
        end
    endfunction

    // --------------------------------------------------------
    // Synchronize RX serial pin.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end
        else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    // --------------------------------------------------------
    // UART receiver FSM.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state             <= IDLE;

            shift_reg         <= 8'h00;
            rx_fifo_din       <= 8'h00;
            rx_fifo_push      <= 1'b0;

            parity_error      <= 1'b0;
            framing_error     <= 1'b0;
            break_interrupt   <= 1'b0;
            overrun           <= 1'b0;

            wls_latched       <= 2'b11;
            pen_latched       <= 1'b0;
            eps_latched       <= 1'b0;
            sp_latched        <= 1'b0;

            data_bits_latched <= 4'd8;
            bit_index         <= 4'd0;
            tick_count        <= 5'd0;
        end
        else begin
            // Outputs are one-clock pulses.
            rx_fifo_push    <= 1'b0;
            parity_error    <= 1'b0;
            framing_error   <= 1'b0;
            break_interrupt <= 1'b0;
            overrun         <= 1'b0;

            if (baud16_tick) begin
                case (state)

                    // --------------------------------------------
                    // Wait for a possible start bit.
                    // --------------------------------------------
                    IDLE: begin
                        tick_count <= 5'd0;

                        if (rx_sync == 1'b0)
                            state <= START_CHECK;
                    end

                    // --------------------------------------------
                    // Confirm the start bit at its midpoint:
                    // wait 8 ticks and verify RX remains low.
                    // --------------------------------------------
                    START_CHECK: begin
                        if (tick_count == 5'd7) begin
                            tick_count <= 5'd0;

                            if (rx_sync == 1'b0) begin
                                // Accept frame and latch its format.
                                wls_latched       <= lcr[1:0];
                                pen_latched       <= lcr[3];
                                eps_latched       <= lcr[4];
                                sp_latched        <= lcr[5];

                                data_bits_latched <= data_bits_from_wls(lcr[1:0]);
                                bit_index         <= 4'd0;
                                shift_reg         <= 8'h00;

                                state <= DATA;
                            end
                            else begin
                                // Low glitch: reject false start.
                                state <= IDLE;
                            end
                        end
                        else begin
                            tick_count <= tick_count + 5'd1;
                        end
                    end

                    // --------------------------------------------
                    // Sample data bits at the center of each bit.
                    //
                    // Data bit 0 is sampled 16 ticks after start
                    // midpoint confirmation. All later bits are
                    // sampled every 16 ticks.
                    // --------------------------------------------
                    DATA: begin
                        if (tick_count == 5'd15) begin
                            tick_count          <= 5'd0;
                            shift_reg[bit_index] <= rx_sync;

                            if (bit_index == (data_bits_latched - 4'd1)) begin
                                if (pen_latched)
                                    state <= PARITY;
                                else
                                    state <= STOP;
                            end
                            else begin
                                bit_index <= bit_index + 4'd1;
                            end
                        end
                        else begin
                            tick_count <= tick_count + 5'd1;
                        end
                    end

                    // --------------------------------------------
                    // Sample and validate parity bit.
                    // --------------------------------------------
                    PARITY: begin
                        if (tick_count == 5'd15) begin
                            tick_count <= 5'd0;

                            parity_error <=
                                (rx_sync != expected_parity(
                                    shift_reg,
                                    wls_latched,
                                    eps_latched,
                                    sp_latched
                                ));

                            state <= STOP;
                        end
                        else begin
                            tick_count <= tick_count + 5'd1;
                        end
                    end

                    // --------------------------------------------
                    // Validate the first stop bit.
                    //
                    // A low sample means a framing error.
                    // --------------------------------------------
                    STOP: begin
                        if (tick_count == 5'd15) begin
                            tick_count  <= 5'd0;
                            rx_fifo_din <= shift_reg;

                            framing_error <= ~rx_sync;

                            // Simple break indication:
                            // zero data and a low stop-bit sample.
                            break_interrupt <=
                                (~rx_sync && (shift_reg == 8'h00));

                            if (rx_fifo_full) begin
                                overrun <= 1'b1;
                            end
                            else begin
                                rx_fifo_push <= 1'b1;
                            end

                            state <= IDLE;
                        end
                        else begin
                            tick_count <= tick_count + 5'd1;
                        end
                    end

                    default: begin
                        state      <= IDLE;
                        tick_count <= 5'd0;
                    end

                endcase
            end
        end
    end

endmodule