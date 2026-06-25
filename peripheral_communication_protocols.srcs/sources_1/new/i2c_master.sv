`timescale 1ns / 1ps

// ============================================================
// I2C Master: One-Byte Read/Write, No Clock Stretching
//
// Supported write transaction:
//   START -> {7-bit address, W=0} -> ACK
//         -> 8-bit data             -> ACK -> STOP
//
// Supported read transaction:
//   START -> {7-bit address, R=1} -> ACK
//         -> receive 8-bit data   -> NACK -> STOP
//
// I2C bus requirements:
//   - SDA and SCL are open-drain.
//   - Logic 0: actively pull line low.
//   - Logic 1: release line; external pull-up makes it high.
// ============================================================

module i2c_master (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,
    input  logic [6:0]  addr_i,
    input  logic        rw_i,               // 0 = write, 1 = read
    input  logic [7:0]  tx_data_i,

    // Number of system-clock cycles in one SCL half-period.
    // f_scl = f_clk / (2 * scl_half_period_i)
    input  logic [15:0] scl_half_period_i,

    inout  wire         scl,
    inout  wire         sda,

    output logic [7:0]  rx_data_o,
    output logic        busy_o,
    output logic        done_o,
    output logic        ack_error_o
);

    typedef enum logic [3:0] {
        IDLE,
        START_BUS_FREE,
        START_CONDITION,
        START_PULL_SCL_LOW,

        TX_BIT_HIGH,
        TX_BIT_FALL,
        ACK_HIGH,
        ACK_FALL,

        READ_BIT_HIGH,
        READ_BIT_FALL,
        MASTER_NACK_HIGH,
        MASTER_NACK_FALL,

        STOP_SCL_HIGH,
        STOP_SDA_HIGH
    } state_t;

    state_t state;

    logic scl_drive_low;
    logic sda_drive_low;

    logic [15:0] clk_div_latched;
    logic [15:0] div_count;

    logic [7:0] addr_rw_latched;
    logic [7:0] tx_data_latched;
    logic [7:0] tx_byte;
    logic [7:0] rx_shift;

    logic       rw_latched;
    logic       sending_address;
    logic [2:0] bit_index;
    logic [2:0] read_bit_count;

    logic start_d;
    logic start_pulse;

    assign start_pulse = start && !start_d;

    // Open-drain I2C outputs.
    assign scl = scl_drive_low ? 1'b0 : 1'bz;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state               <= IDLE;

            scl_drive_low       <= 1'b0;
            sda_drive_low       <= 1'b0;

            clk_div_latched     <= 16'd1;
            div_count           <= 16'd0;

            addr_rw_latched     <= 8'h00;
            tx_data_latched     <= 8'h00;
            tx_byte             <= 8'h00;
            rx_shift            <= 8'h00;
            rx_data_o           <= 8'h00;

            rw_latched          <= 1'b0;
            sending_address     <= 1'b0;
            bit_index           <= 3'd0;
            read_bit_count      <= 3'd0;

            start_d             <= 1'b0;

            busy_o              <= 1'b0;
            done_o              <= 1'b0;
            ack_error_o         <= 1'b0;
        end
        else begin
            start_d <= start;

            // done_o is a one-system-clock completion pulse.
            done_o <= 1'b0;

            // ------------------------------------------------
            // IDLE accepts a rising-edge start request.
            // ------------------------------------------------
            if (state == IDLE) begin
                scl_drive_low <= 1'b0;
                sda_drive_low <= 1'b0;
                div_count     <= 16'd0;
                busy_o        <= 1'b0;

                if (start_pulse) begin
                    addr_rw_latched <= {addr_i, rw_i};
                    tx_data_latched <= tx_data_i;
                    tx_byte         <= {addr_i, rw_i};

                    rw_latched      <= rw_i;
                    sending_address <= 1'b1;
                    bit_index       <= 3'd7;
                    read_bit_count  <= 3'd0;
                    rx_shift        <= 8'h00;

                    if (scl_half_period_i == 16'd0)
                        clk_div_latched <= 16'd1;
                    else
                        clk_div_latched <= scl_half_period_i;

                    busy_o      <= 1'b1;
                    ack_error_o <= 1'b0;
                    state       <= START_BUS_FREE;
                end
            end

            // ------------------------------------------------
            // Every non-idle state advances once per half-SCL
            // interval. No clock-stretching wait is included.
            // ------------------------------------------------
            else if (div_count == (clk_div_latched - 16'd1)) begin
                div_count <= 16'd0;

                case (state)

                    // Ensure both bus lines are released.
                    START_BUS_FREE: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        state         <= START_CONDITION;
                    end

                    // START: SDA transitions high-to-low while
                    // SCL remains high.
                    START_CONDITION: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b1;
                        state         <= START_PULL_SCL_LOW;
                    end

                    // Pull SCL low and set up address MSB.
                    START_PULL_SCL_LOW: begin
                        scl_drive_low <= 1'b1;
                        sda_drive_low <= ~addr_rw_latched[7];
                        bit_index     <= 3'd7;
                        state         <= TX_BIT_HIGH;
                    end

                    // Raise SCL. Receiver samples SDA while high.
                    TX_BIT_HIGH: begin
                        scl_drive_low <= 1'b0;
                        state         <= TX_BIT_FALL;
                    end

                    // Lower SCL and either prepare the next bit
                    // or release SDA for the ACK clock.
                    TX_BIT_FALL: begin
                        scl_drive_low <= 1'b1;

                        if (bit_index == 3'd0) begin
                            sda_drive_low <= 1'b0;
                            state         <= ACK_HIGH;
                        end
                        else begin
                            bit_index     <= bit_index - 3'd1;
                            sda_drive_low <= ~tx_byte[bit_index - 3'd1];
                            state         <= TX_BIT_HIGH;
                        end
                    end

                    // Ninth SCL pulse: receiver drives ACK/NACK.
                    ACK_HIGH: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        state         <= ACK_FALL;
                    end

                    // Sample ACK near end of SCL-high interval.
                    ACK_FALL: begin
                        scl_drive_low <= 1'b1;

                        if (sda === 1'b0) begin
                            // Address ACK received.
                            if (sending_address) begin
                                if (rw_latched) begin
                                    // Begin one-byte read.
                                    sda_drive_low  <= 1'b0;
                                    read_bit_count <= 3'd0;
                                    state          <= READ_BIT_HIGH;
                                end
                                else begin
                                    // Begin one-byte write.
                                    tx_byte         <= tx_data_latched;
                                    bit_index       <= 3'd7;
                                    sending_address <= 1'b0;
                                    sda_drive_low   <= ~tx_data_latched[7];
                                    state           <= TX_BIT_HIGH;
                                end
                            end
                            else begin
                                // Data-byte ACK received.
                                sda_drive_low <= 1'b1;
                                state         <= STOP_SCL_HIGH;
                            end
                        end
                        else begin
                            // NACK after address or data.
                            ack_error_o   <= 1'b1;
                            sda_drive_low <= 1'b1;
                            state         <= STOP_SCL_HIGH;
                        end
                    end

                    // Read byte: SDA is released; slave drives it.
                    READ_BIT_HIGH: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        state         <= READ_BIT_FALL;
                    end

                    READ_BIT_FALL: begin
                        scl_drive_low <= 1'b1;
                        sda_drive_low <= 1'b0;

                        rx_shift <= {rx_shift[6:0], sda};

                        if (read_bit_count == 3'd7) begin
                            rx_data_o <= {rx_shift[6:0], sda};
                            state     <= MASTER_NACK_HIGH;
                        end
                        else begin
                            read_bit_count <= read_bit_count + 3'd1;
                            state          <= READ_BIT_HIGH;
                        end
                    end

                    // Final one-byte read response: master leaves
                    // SDA released, which is a NACK.
                    MASTER_NACK_HIGH: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        state         <= MASTER_NACK_FALL;
                    end

                    MASTER_NACK_FALL: begin
                        scl_drive_low <= 1'b1;
                        sda_drive_low <= 1'b1;
                        state         <= STOP_SCL_HIGH;
                    end

                    // STOP setup: SDA is low, then SCL rises.
                    STOP_SCL_HIGH: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b1;
                        state         <= STOP_SDA_HIGH;
                    end

                    // STOP: SDA transitions low-to-high while
                    // SCL is high.
                    STOP_SDA_HIGH: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;

                        busy_o        <= 1'b0;
                        done_o        <= 1'b1;
                        state         <= IDLE;
                    end

                    default: begin
                        state         <= IDLE;
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        busy_o        <= 1'b0;
                    end

                endcase
            end
            else begin
                div_count <= div_count + 16'd1;
            end
        end
    end

endmodule

