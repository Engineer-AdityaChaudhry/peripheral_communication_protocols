`timescale 1ns / 1ps

// ============================================================
// 16550A-inspired UART Transmitter
//
// baud16_tick must be a one-clock-cycle enable at 16x baud rate.
//
// LCR mapping:
//   LCR[1:0] = WLS  : word length select
//   LCR[2]   = STB  : stop-bit select
//   LCR[3]   = PEN  : parity enable
//   LCR[4]   = EPS  : even parity select
//   LCR[5]   = SP   : stick parity
//   LCR[6]   = BC   : break control
//   LCR[7]   = DLAB : not used by transmitter
// ============================================================

module uart_tx (
    input  logic       clk,
    input  logic       rst,
    input  logic       baud16_tick,

    // TX FIFO interface
    input  logic       tx_fifo_empty,
    input  logic [7:0] tx_fifo_dout,
    output logic       tx_fifo_pop,

    // Line Control Register
    input  logic [7:0] lcr,

    // UART outputs/status
    output logic       tx,
    output logic       sreg_empty
);

    typedef enum logic [2:0] {
        IDLE,
        START,
        DATA,
        PARITY,
        STOP
    } state_t;

    state_t state;

    logic [7:0] shift_reg;
    logic       tx_data;

    logic [3:0] data_bits_latched;
    logic [3:0] bit_index;
    logic [5:0] tick_count;
    logic [5:0] stop_ticks_latched;

    logic pen_latched;
    logic parity_bit_latched;

    // --------------------------------------------------------
    // LCR helper functions
    // --------------------------------------------------------

    function automatic logic [3:0] data_bits_from_wls(
        input logic [1:0] wls
    );
        case (wls)
            2'b00: data_bits_from_wls = 4'd5;
            2'b01: data_bits_from_wls = 4'd6;
            2'b10: data_bits_from_wls = 4'd7;
            default: data_bits_from_wls = 4'd8;
        endcase
    endfunction

    function automatic logic [5:0] stop_ticks_from_lcr(
        input logic       stb,
        input logic [1:0] wls
    );
        if (!stb)
            stop_ticks_from_lcr = 6'd16; // 1 stop bit
        else if (wls == 2'b00)
            stop_ticks_from_lcr = 6'd24; // 1.5 stop bits
        else
            stop_ticks_from_lcr = 6'd32; // 2 stop bits
    endfunction

    function automatic logic parity_from_lcr(
        input logic [7:0] data,
        input logic [1:0] wls,
        input logic       eps,
        input logic       sp
    );
        logic data_xor;

        begin
            case (wls)
                2'b00: data_xor = ^data[4:0];
                2'b01: data_xor = ^data[5:0];
                2'b10: data_xor = ^data[6:0];
                default: data_xor = ^data[7:0];
            endcase

            // Stick parity
            if (sp)
                parity_from_lcr = eps ? 1'b0 : 1'b1;

            // Normal even parity
            else if (eps)
                parity_from_lcr = data_xor;

            // Normal odd parity
            else
                parity_from_lcr = ~data_xor;
        end
    endfunction

    // Break control: force TX low whenever LCR[6] is set.
    always_comb begin
        tx = lcr[6] ? 1'b0 : tx_data;
    end

    // --------------------------------------------------------
    // Transmitter FSM
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state              <= IDLE;
            shift_reg          <= 8'h00;
            tx_data            <= 1'b1;
            tx_fifo_pop        <= 1'b0;
            sreg_empty         <= 1'b1;

            data_bits_latched  <= 4'd8;
            bit_index          <= 4'd0;
            tick_count         <= 6'd0;
            stop_ticks_latched <= 6'd16;

            pen_latched        <= 1'b0;
            parity_bit_latched <= 1'b0;
        end
        else begin
            // Default: FIFO pop is exactly one system-clock pulse.
            tx_fifo_pop <= 1'b0;

            if (baud16_tick) begin
                case (state)

                    // ----------------------------------------
                    IDLE: begin
                        tx_data    <= 1'b1;
                        sreg_empty <= 1'b1;
                        tick_count <= 6'd0;

                        if (!tx_fifo_empty) begin
                            // Pop exactly one FIFO byte.
                            tx_fifo_pop <= 1'b1;

                            // Latch data and frame configuration.
                            shift_reg          <= tx_fifo_dout;
                            data_bits_latched  <= data_bits_from_wls(lcr[1:0]);
                            stop_ticks_latched <= stop_ticks_from_lcr(
                                                      lcr[2], lcr[1:0]
                                                  );
                            pen_latched        <= lcr[3];
                            parity_bit_latched <= parity_from_lcr(
                                                      tx_fifo_dout,
                                                      lcr[1:0],
                                                      lcr[4],
                                                      lcr[5]
                                                  );

                            bit_index  <= 4'd0;
                            sreg_empty <= 1'b0;

                            // Begin start bit.
                            tx_data <= 1'b0;
                            state   <= START;
                        end
                    end

                    // ----------------------------------------
                    START: begin
                        if (tick_count == 6'd15) begin
                            tick_count <= 6'd0;

                            // Start transmitting data bit 0, LSB first.
                            tx_data   <= shift_reg[0];
                            shift_reg <= {1'b0, shift_reg[7:1]};
                            bit_index <= 4'd0;
                            state     <= DATA;
                        end
                        else begin
                            tick_count <= tick_count + 1'b1;
                        end
                    end

                    // ----------------------------------------
                    DATA: begin
                        if (tick_count == 6'd15) begin
                            tick_count <= 6'd0;

                            if (bit_index == (data_bits_latched - 1'b1)) begin
                                // Final data bit has completed.
                                if (pen_latched) begin
                                    tx_data <= parity_bit_latched;
                                    state   <= PARITY;
                                end
                                else begin
                                    tx_data <= 1'b1;
                                    state   <= STOP;
                                end
                            end
                            else begin
                                // Send next LSB from shift register.
                                bit_index <= bit_index + 1'b1;
                                tx_data   <= shift_reg[0];
                                shift_reg <= {1'b0, shift_reg[7:1]};
                            end
                        end
                        else begin
                            tick_count <= tick_count + 1'b1;
                        end
                    end

                    // ----------------------------------------
                    PARITY: begin
                        if (tick_count == 6'd15) begin
                            tick_count <= 6'd0;
                            tx_data    <= 1'b1;
                            state      <= STOP;
                        end
                        else begin
                            tick_count <= tick_count + 1'b1;
                        end
                    end

                    // ----------------------------------------
                    STOP: begin
                        if (tick_count == (stop_ticks_latched - 1'b1)) begin
                            tick_count <= 6'd0;

                            // Start the next byte immediately when available.
                            if (!tx_fifo_empty) begin
                                tx_fifo_pop <= 1'b1;

                                shift_reg          <= tx_fifo_dout;
                                data_bits_latched  <= data_bits_from_wls(lcr[1:0]);
                                stop_ticks_latched <= stop_ticks_from_lcr(
                                                          lcr[2], lcr[1:0]
                                                      );
                                pen_latched        <= lcr[3];
                                parity_bit_latched <= parity_from_lcr(
                                                          tx_fifo_dout,
                                                          lcr[1:0],
                                                          lcr[4],
                                                          lcr[5]
                                                      );

                                bit_index  <= 4'd0;
                                sreg_empty <= 1'b0;

                                tx_data <= 1'b0;
                                state   <= START;
                            end
                            else begin
                                tx_data    <= 1'b1;
                                sreg_empty <= 1'b1;
                                state      <= IDLE;
                            end
                        end
                        else begin
                            tick_count <= tick_count + 1'b1;
                        end
                    end

                    default: begin
                        state      <= IDLE;
                        tx_data    <= 1'b1;
                        sreg_empty <= 1'b1;
                        tick_count <= 6'd0;
                    end

                endcase
            end
        end
    end

endmodule