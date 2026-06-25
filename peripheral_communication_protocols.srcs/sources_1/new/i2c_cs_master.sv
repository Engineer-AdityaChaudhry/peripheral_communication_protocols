`timescale 1ns / 1ps

// ============================================================
// I2C Master with Clock-Stretching Support
//
// Supported transactions:
//   Write: START -> address+W -> ACK -> one byte -> ACK -> STOP
//   Read : START -> address+R -> ACK -> one byte -> NACK -> STOP
//
// Clock stretching:
//   Whenever the master releases SCL for a high phase, it waits
//   until the actual shared SCL bus becomes high.
// ============================================================

module i2c_cs_master (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,
    input  logic [6:0]  addr_i,
    input  logic        rw_i,               // 0 = write, 1 = read
    input  logic [7:0]  tx_data_i,

    // Number of system-clock cycles in one SCL half-period.
    input  logic [15:0] scl_half_period_i,

    inout  wire         scl,
    inout  wire         sda,

    output logic [7:0]  rx_data_o,
    output logic        busy_o,
    output logic        done_o,
    output logic        ack_error_o
);

    typedef enum logic [4:0] {
        IDLE,

        START_BUS_FREE,
        START_CONDITION,
        START_PULL_SCL_LOW,

        TX_SETUP,
        TX_RAISE_WAIT,
        TX_HIGH_HOLD,

        ACK_SETUP,
        ACK_RAISE_WAIT,
        ACK_HIGH_HOLD,

        READ_SETUP,
        READ_RAISE_WAIT,
        READ_HIGH_HOLD,

        MASTER_NACK_SETUP,
        MASTER_NACK_RAISE_WAIT,
        MASTER_NACK_HIGH_HOLD,

        STOP_LOW_SETUP,
        STOP_RAISE_WAIT,
        STOP_HIGH_HOLD,
        STOP_RELEASE_SDA
    } state_t;

    state_t state;

    logic scl_drive_low;
    logic sda_drive_low;

    logic [15:0] half_period_latched;
    logic [15:0] phase_count;
    logic        phase_tick;

    logic [7:0] tx_byte;
    logic [7:0] tx_data_latched;
    logic [7:0] rx_shift;

    logic       rw_latched;
    logic       sending_address;

    logic [2:0] bit_index;
    logic [2:0] read_bit_index;

    logic start_d;
    logic start_pulse;

    assign start_pulse = start && !start_d;

    assign phase_tick =
        (phase_count == (half_period_latched - 16'd1));

    // Open-drain I2C outputs.
    assign scl = scl_drive_low ? 1'b0 : 1'bz;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state               <= IDLE;

            scl_drive_low       <= 1'b0;
            sda_drive_low       <= 1'b0;

            half_period_latched <= 16'd1;
            phase_count         <= 16'd0;

            tx_byte             <= 8'h00;
            tx_data_latched     <= 8'h00;
            rx_shift            <= 8'h00;
            rx_data_o           <= 8'h00;

            rw_latched          <= 1'b0;
            sending_address     <= 1'b0;

            bit_index           <= 3'd0;
            read_bit_index      <= 3'd0;

            start_d             <= 1'b0;

            busy_o              <= 1'b0;
            done_o              <= 1'b0;
            ack_error_o         <= 1'b0;
        end
        else begin
            start_d <= start;
            done_o  <= 1'b0;

            case (state)

                // ------------------------------------------------
                // Idle bus: both I2C lines are released.
                // ------------------------------------------------
                IDLE: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    phase_count   <= 16'd0;
                    busy_o        <= 1'b0;

                    if (start_pulse) begin
                        tx_byte         <= {addr_i, rw_i};
                        tx_data_latched <= tx_data_i;
                        rw_latched      <= rw_i;

                        sending_address <= 1'b1;
                        bit_index       <= 3'd7;
                        read_bit_index  <= 3'd7;
                        rx_shift        <= 8'h00;

                        if (scl_half_period_i == 16'd0)
                            half_period_latched <= 16'd1;
                        else
                            half_period_latched <= scl_half_period_i;

                        busy_o      <= 1'b1;
                        ack_error_o <= 1'b0;
                        state       <= START_BUS_FREE;
                    end
                end

                // ------------------------------------------------
                // Leave bus released before START.
                // ------------------------------------------------
                START_BUS_FREE: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= START_CONDITION;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // START: SDA falls while SCL is high.
                // ------------------------------------------------
                START_CONDITION: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b1;

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= START_PULL_SCL_LOW;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // Begin first address-bit low phase.
                // ------------------------------------------------
                START_PULL_SCL_LOW: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= ~tx_byte[7];

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= TX_RAISE_WAIT;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // SCL low: present the next transmitted bit.
                // ------------------------------------------------
                TX_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= ~tx_byte[bit_index];

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= TX_RAISE_WAIT;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // Release SCL and wait for actual bus SCL = 1.
                // A slave can hold SCL low here.
                // ------------------------------------------------
                TX_RAISE_WAIT: begin
                    scl_drive_low <= 1'b0;

                    if (scl === 1'b1) begin
                        phase_count <= 16'd0;
                        state       <= TX_HIGH_HOLD;
                    end
                    else begin
                        phase_count <= 16'd0;
                    end
                end

                // ------------------------------------------------
                // Hold SCL high so receiver can sample SDA.
                // ------------------------------------------------
                TX_HIGH_HOLD: begin
                    scl_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count   <= 16'd0;
                        scl_drive_low <= 1'b1;

                        if (bit_index == 3'd0) begin
                            sda_drive_low <= 1'b0;
                            state         <= ACK_SETUP;
                        end
                        else begin
                            bit_index <= bit_index - 3'd1;
                            state     <= TX_SETUP;
                        end
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // Ninth bit: release SDA so receiver can ACK/NACK.
                // ------------------------------------------------
                ACK_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= ACK_RAISE_WAIT;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // Clock-stretch-aware ACK clock raise.
                ACK_RAISE_WAIT: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;

                    if (scl === 1'b1) begin
                        phase_count <= 16'd0;
                        state       <= ACK_HIGH_HOLD;
                    end
                    else begin
                        phase_count <= 16'd0;
                    end
                end

                // Sample ACK/NACK near the end of SCL-high.
                ACK_HIGH_HOLD: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count   <= 16'd0;
                        scl_drive_low <= 1'b1;

                        if (sda === 1'b0) begin
                            if (sending_address) begin
                                sending_address <= 1'b0;

                                if (rw_latched) begin
                                    read_bit_index <= 3'd7;
                                    state          <= READ_SETUP;
                                end
                                else begin
                                    tx_byte   <= tx_data_latched;
                                    bit_index <= 3'd7;
                                    state     <= TX_SETUP;
                                end
                            end
                            else begin
                                state <= STOP_LOW_SETUP;
                            end
                        end
                        else begin
                            ack_error_o <= 1'b1;
                            state       <= STOP_LOW_SETUP;
                        end
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // Read: SDA released; slave drives one data bit.
                // ------------------------------------------------
                READ_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= READ_RAISE_WAIT;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                READ_RAISE_WAIT: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;

                    if (scl === 1'b1) begin
                        phase_count <= 16'd0;
                        state       <= READ_HIGH_HOLD;
                    end
                    else begin
                        phase_count <= 16'd0;
                    end
                end

                READ_HIGH_HOLD: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count   <= 16'd0;
                        scl_drive_low <= 1'b1;
                        rx_shift      <= {rx_shift[6:0], sda};

                        if (read_bit_index == 3'd0) begin
                            rx_data_o <= {rx_shift[6:0], sda};
                            state     <= MASTER_NACK_SETUP;
                        end
                        else begin
                            read_bit_index <= read_bit_index - 3'd1;
                            state          <= READ_SETUP;
                        end
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // Final read-byte response: master sends NACK.
                // ------------------------------------------------
                MASTER_NACK_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= MASTER_NACK_RAISE_WAIT;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                MASTER_NACK_RAISE_WAIT: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;

                    if (scl === 1'b1) begin
                        phase_count <= 16'd0;
                        state       <= MASTER_NACK_HIGH_HOLD;
                    end
                    else begin
                        phase_count <= 16'd0;
                    end
                end

                MASTER_NACK_HIGH_HOLD: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count   <= 16'd0;
                        scl_drive_low <= 1'b1;
                        state         <= STOP_LOW_SETUP;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // ------------------------------------------------
                // STOP setup: both lines are low.
                // ------------------------------------------------
                STOP_LOW_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b1;

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= STOP_RAISE_WAIT;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // Release SCL and allow stretching before STOP.
                STOP_RAISE_WAIT: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b1;

                    if (scl === 1'b1) begin
                        phase_count <= 16'd0;
                        state       <= STOP_HIGH_HOLD;
                    end
                    else begin
                        phase_count <= 16'd0;
                    end
                end

                STOP_HIGH_HOLD: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b1;

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        state       <= STOP_RELEASE_SDA;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                // STOP: SDA rises while SCL remains high.
                STOP_RELEASE_SDA: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;

                    if (phase_tick) begin
                        phase_count <= 16'd0;
                        busy_o      <= 1'b0;
                        done_o      <= 1'b1;
                        state       <= IDLE;
                    end
                    else begin
                        phase_count <= phase_count + 16'd1;
                    end
                end

                default: begin
                    state         <= IDLE;
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    busy_o        <= 1'b0;
                end

            endcase
        end
    end

endmodule

