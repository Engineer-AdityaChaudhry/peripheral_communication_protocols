`timescale 1ns / 1ps

// ============================================================
// I2C Slave: One-Byte Read/Write, No Clock Stretching
//
// Supported transactions:
//
// Write:
//   START -> {7-bit address, W=0} -> ACK
//         -> 8-bit data             -> ACK -> STOP
//
// Read:
//   START -> {7-bit address, R=1} -> ACK
//         -> transmit stored byte  -> master NACK -> STOP
//
// Notes:
// - SDA is open-drain.
// - The slave never drives a logic 1.
// - SCL is synchronized into clk domain.
// - Use a sufficiently slow master divider in integration:
//   scl_half_period_i >= 8 is recommended.
// ============================================================

module i2c_slave #(
    parameter logic [6:0] SLAVE_ADDR = 7'h50
) (
    input  logic       clk,
    input  logic       rst,

    input  wire        scl,
    inout  wire        sda,

    output logic [7:0] data_reg_o,
    output logic       write_valid_o,
    output logic       selected_o,
    output logic       read_nack_o
);

    typedef enum logic [3:0] {
        IDLE,
        RECV_ADDR,
        ACK_ADDR,
        RECV_WRITE,
        ACK_WRITE,
        SEND_READ,
        WAIT_MASTER_NACK,
        WAIT_STOP,
        IGNORE_TRANSACTION
    } state_t;

    state_t state;

    // --------------------------------------------------------
    // Open-drain SDA control.
    // 1 -> pull SDA low
    // 0 -> release SDA
    // --------------------------------------------------------
    logic sda_drive_low;

    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    // --------------------------------------------------------
    // Synchronizers for externally visible I2C bus lines.
    // --------------------------------------------------------
    logic scl_meta;
    logic scl_sync;
    logic scl_sync_d;

    logic sda_meta;
    logic sda_sync;
    logic sda_sync_d;

    logic scl_rise;
    logic scl_fall;
    logic start_cond;
    logic stop_cond;

    assign scl_rise  =  scl_sync && !scl_sync_d;
    assign scl_fall  = !scl_sync &&  scl_sync_d;

    // START: SDA falls while SCL is high.
    assign start_cond =  scl_sync &&  sda_sync_d && !sda_sync;

    // STOP: SDA rises while SCL is high.
    assign stop_cond  =  scl_sync && !sda_sync_d &&  sda_sync;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            scl_meta   <= 1'b1;
            scl_sync   <= 1'b1;
            scl_sync_d <= 1'b1;

            sda_meta   <= 1'b1;
            sda_sync   <= 1'b1;
            sda_sync_d <= 1'b1;
        end
        else begin
            scl_meta   <= scl;
            scl_sync   <= scl_meta;
            scl_sync_d <= scl_sync;

            sda_meta   <= sda;
            sda_sync   <= sda_meta;
            sda_sync_d <= sda_sync;
        end
    end

    // --------------------------------------------------------
    // Protocol registers.
    // --------------------------------------------------------
    logic [7:0] rx_shift;
    logic [7:0] rx_byte_next;
    logic [2:0] bit_count;

    logic       rw_latched;
    logic       ack_active;

    logic [2:0] tx_bit_index;

    assign rx_byte_next = {rx_shift[6:0], sda_sync};

    // --------------------------------------------------------
    // I2C slave state machine.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= IDLE;

            sda_drive_low  <= 1'b0;

            rx_shift       <= 8'h00;
            bit_count      <= 3'd0;

            rw_latched     <= 1'b0;
            ack_active     <= 1'b0;
            tx_bit_index   <= 3'd7;

            data_reg_o     <= 8'h00;
            write_valid_o  <= 1'b0;
            selected_o     <= 1'b0;
            read_nack_o    <= 1'b0;
        end
        else begin
            // One-clock pulse when a write byte is accepted.
            write_valid_o <= 1'b0;

            // A START restarts address reception.
            if (start_cond) begin
                state         <= RECV_ADDR;
                sda_drive_low <= 1'b0;

                rx_shift      <= 8'h00;
                bit_count     <= 3'd0;

                rw_latched    <= 1'b0;
                ack_active    <= 1'b0;

                selected_o    <= 1'b0;
                read_nack_o   <= 1'b0;
            end

            // STOP returns the slave to idle but preserves data.
            else if (stop_cond) begin
                state         <= IDLE;
                sda_drive_low <= 1'b0;

                bit_count     <= 3'd0;
                ack_active    <= 1'b0;
                selected_o    <= 1'b0;
            end

            else begin
                case (state)

                    // ------------------------------------------------
                    // Wait for a START condition.
                    // ------------------------------------------------
                    IDLE: begin
                        sda_drive_low <= 1'b0;
                    end

                    // ------------------------------------------------
                    // Receive address byte:
                    // [A6 A5 A4 A3 A2 A1 A0 R/W]
                    // ------------------------------------------------
                    RECV_ADDR: begin
                        sda_drive_low <= 1'b0;

                        if (scl_rise) begin
                            rx_shift <= rx_byte_next;

                            if (bit_count == 3'd7) begin
                                bit_count  <= 3'd0;
                                rw_latched <= rx_byte_next[0];

                                if (rx_byte_next[7:1] == SLAVE_ADDR) begin
                                    selected_o <= 1'b1;
                                    ack_active <= 1'b0;
                                    state      <= ACK_ADDR;
                                end
                                else begin
                                    selected_o <= 1'b0;
                                    state      <= IGNORE_TRANSACTION;
                                end
                            end
                            else begin
                                bit_count <= bit_count + 3'd1;
                            end
                        end
                    end

                    // ------------------------------------------------
                    // Drive ACK for matching address.
                    // ------------------------------------------------
                    ACK_ADDR: begin
                        if (scl_fall) begin
                            if (!ack_active) begin
                                // Beginning of ninth clock: ACK = SDA low.
                                sda_drive_low <= 1'b1;
                                ack_active    <= 1'b1;
                            end
                            else begin
                                // End of ACK clock: release SDA.
                                ack_active <= 1'b0;

                                if (rw_latched) begin
                                    // Read transaction: prepare MSB first.
                                    tx_bit_index  <= 3'd7;
                                    sda_drive_low <= ~data_reg_o[7];
                                    state         <= SEND_READ;
                                end
                                else begin
                                    // Write transaction: receive data byte.
                                    sda_drive_low <= 1'b0;
                                    rx_shift      <= 8'h00;
                                    bit_count     <= 3'd0;
                                    state         <= RECV_WRITE;
                                end
                            end
                        end
                    end

                    // ------------------------------------------------
                    // Receive one data byte during a write transaction.
                    // ------------------------------------------------
                    RECV_WRITE: begin
                        sda_drive_low <= 1'b0;

                        if (scl_rise) begin
                            rx_shift <= rx_byte_next;

                            if (bit_count == 3'd7) begin
                                data_reg_o    <= rx_byte_next;
                                write_valid_o <= 1'b1;

                                bit_count     <= 3'd0;
                                ack_active    <= 1'b0;
                                state         <= ACK_WRITE;
                            end
                            else begin
                                bit_count <= bit_count + 3'd1;
                            end
                        end
                    end

                    // ------------------------------------------------
                    // ACK received write byte.
                    // ------------------------------------------------
                    ACK_WRITE: begin
                        if (scl_fall) begin
                            if (!ack_active) begin
                                sda_drive_low <= 1'b1;
                                ack_active    <= 1'b1;
                            end
                            else begin
                                sda_drive_low <= 1'b0;
                                ack_active    <= 1'b0;
                                state         <= WAIT_STOP;
                            end
                        end
                    end

                    // ------------------------------------------------
                    // Send stored data MSB-first during a read.
                    // Data is stable while SCL is high.
                    // ------------------------------------------------
                    SEND_READ: begin
                        if (scl_fall) begin
                            if (tx_bit_index == 3'd0) begin
                                // Last data bit was sampled.
                                // Release SDA for master's ACK/NACK bit.
                                sda_drive_low <= 1'b0;
                                state         <= WAIT_MASTER_NACK;
                            end
                            else begin
                                tx_bit_index   <= tx_bit_index - 3'd1;
                                sda_drive_low  <= ~data_reg_o[tx_bit_index - 3'd1];
                            end
                        end
                    end

                    // ------------------------------------------------
                    // Master sends NACK after final read byte.
                    // SDA=1 means final byte accepted.
                    // ------------------------------------------------
                    WAIT_MASTER_NACK: begin
                        sda_drive_low <= 1'b0;

                        if (scl_rise) begin
                            read_nack_o <= sda_sync;
                            state       <= WAIT_STOP;
                        end
                    end

                    // ------------------------------------------------
                    // Transaction has completed. Wait for STOP.
                    // ------------------------------------------------
                    WAIT_STOP: begin
                        sda_drive_low <= 1'b0;
                    end

                    // ------------------------------------------------
                    // Wrong address: do not ACK; wait for STOP.
                    // ------------------------------------------------
                    IGNORE_TRANSACTION: begin
                        sda_drive_low <= 1'b0;
                    end

                    default: begin
                        state         <= IDLE;
                        sda_drive_low <= 1'b0;
                        selected_o    <= 1'b0;
                    end

                endcase
            end
        end
    end

endmodule

