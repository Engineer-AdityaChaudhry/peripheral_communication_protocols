`timescale 1ns / 1ps

// ============================================================
// I2C Slave with Clock-Stretching Demonstration Support
//
// Supported transactions:
//   Write: START -> address+W -> ACK -> one byte -> ACK -> STOP
//   Read : START -> address+R -> ACK -> one byte -> NACK -> STOP
//
// stretch_enable_i:
//   Test/demo input. When high, the slave holds SCL low after
//   receiving the address byte and before sending its ACK.
// ============================================================

module i2c_cs_slave #(
    parameter logic [6:0] SLAVE_ADDR = 7'h50
) (
    input  logic       clk,
    input  logic       rst,

    input  logic       stretch_enable_i,

    inout  wire        scl,
    inout  wire        sda,

    output logic [7:0] data_reg_o,
    output logic       write_valid_o,
    output logic       selected_o,
    output logic       read_nack_o,
    output logic       stretch_active_o
);

    typedef enum logic [3:0] {
        IDLE,
        RECV_ADDR,
        ADDR_DONE_WAIT_FALL,
        STRETCH_ADDR_ACK,
        ACK_ADDR_WAIT_RISE,
        ACK_ADDR_WAIT_FALL,

        RECV_WRITE,
        WRITE_DONE_WAIT_FALL,
        ACK_WRITE_WAIT_RISE,
        ACK_WRITE_WAIT_FALL,

        SEND_READ_WAIT_RISE,
        SEND_READ_WAIT_FALL,
        WAIT_MASTER_NACK_RISE,

        WAIT_STOP,
        IGNORE_TRANSACTION
    } state_t;

    state_t state;

    logic sda_drive_low;
    logic scl_drive_low;

    // Open-drain outputs.
    assign sda = sda_drive_low ? 1'b0 : 1'bz;
    assign scl = scl_drive_low ? 1'b0 : 1'bz;

    // --------------------------------------------------------
    // Synchronize bus signals into clk domain.
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

    assign scl_rise =  scl_sync && !scl_sync_d;
    assign scl_fall = !scl_sync &&  scl_sync_d;

    assign start_cond = scl_sync &&  sda_sync_d && !sda_sync;
    assign stop_cond  = scl_sync && !sda_sync_d &&  sda_sync;

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

    logic [7:0] rx_shift;
    logic [7:0] rx_byte_next;

    logic [2:0] bit_count;
    logic [2:0] tx_bit_index;

    logic rw_latched;

    assign rx_byte_next = {rx_shift[6:0], sda_sync};

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= IDLE;

            sda_drive_low    <= 1'b0;
            scl_drive_low    <= 1'b0;

            rx_shift         <= 8'h00;
            bit_count        <= 3'd0;
            tx_bit_index     <= 3'd7;
            rw_latched       <= 1'b0;

            data_reg_o       <= 8'h00;
            write_valid_o    <= 1'b0;
            selected_o       <= 1'b0;
            read_nack_o      <= 1'b0;
            stretch_active_o <= 1'b0;
        end
        else begin
            write_valid_o <= 1'b0;

            // A START restarts address reception.
            if (start_cond) begin
                state            <= RECV_ADDR;

                sda_drive_low    <= 1'b0;
                scl_drive_low    <= 1'b0;

                rx_shift         <= 8'h00;
                bit_count        <= 3'd0;
                rw_latched       <= 1'b0;

                selected_o       <= 1'b0;
                read_nack_o      <= 1'b0;
                stretch_active_o <= 1'b0;
            end

            // STOP ends the active transaction.
            else if (stop_cond) begin
                state            <= IDLE;

                sda_drive_low    <= 1'b0;
                scl_drive_low    <= 1'b0;

                bit_count        <= 3'd0;
                selected_o       <= 1'b0;
                stretch_active_o <= 1'b0;
            end

            else begin
                case (state)

                    IDLE: begin
                        sda_drive_low    <= 1'b0;
                        scl_drive_low    <= 1'b0;
                        stretch_active_o <= 1'b0;
                    end

                    // Receive [A6 A5 A4 A3 A2 A1 A0 R/W].
                    RECV_ADDR: begin
                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;

                        if (scl_rise) begin
                            rx_shift <= rx_byte_next;

                            if (bit_count == 3'd7) begin
                                bit_count  <= 3'd0;
                                rw_latched <= rx_byte_next[0];
                                state      <= ADDR_DONE_WAIT_FALL;
                            end
                            else begin
                                bit_count <= bit_count + 3'd1;
                            end
                        end
                    end

                    // Wait until address byte clock falls.
                    ADDR_DONE_WAIT_FALL: begin
                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;

                        if (scl_fall) begin
                            if (rx_shift[7:1] == SLAVE_ADDR) begin
                                selected_o    <= 1'b1;
                                sda_drive_low <= 1'b1; // ACK

                                if (stretch_enable_i) begin
                                    scl_drive_low    <= 1'b1;
                                    stretch_active_o <= 1'b1;
                                    state            <= STRETCH_ADDR_ACK;
                                end
                                else begin
                                    state <= ACK_ADDR_WAIT_RISE;
                                end
                            end
                            else begin
                                selected_o <= 1'b0;
                                state      <= IGNORE_TRANSACTION;
                            end
                        end
                    end

                    // Keep SCL low until testbench/device releases
                    // stretch_enable_i.
                    STRETCH_ADDR_ACK: begin
                        sda_drive_low    <= 1'b1;
                        scl_drive_low    <= 1'b1;
                        stretch_active_o <= 1'b1;

                        if (!stretch_enable_i) begin
                            scl_drive_low    <= 1'b0;
                            stretch_active_o <= 1'b0;
                            state            <= ACK_ADDR_WAIT_RISE;
                        end
                    end

                    // Slave is driving ACK. Wait for actual SCL rise.
                    ACK_ADDR_WAIT_RISE: begin
                        sda_drive_low <= 1'b1;
                        scl_drive_low <= 1'b0;

                        if (scl_rise)
                            state <= ACK_ADDR_WAIT_FALL;
                    end

                    // End address ACK and select write/read direction.
                    ACK_ADDR_WAIT_FALL: begin
                        sda_drive_low <= 1'b1;
                        scl_drive_low <= 1'b0;

                        if (scl_fall) begin
                            if (rw_latched) begin
                                tx_bit_index  <= 3'd7;
                                sda_drive_low <= ~data_reg_o[7];
                                state         <= SEND_READ_WAIT_RISE;
                            end
                            else begin
                                sda_drive_low <= 1'b0;
                                rx_shift      <= 8'h00;
                                bit_count     <= 3'd0;
                                state         <= RECV_WRITE;
                            end
                        end
                    end

                    // Receive one write byte.
                    RECV_WRITE: begin
                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;

                        if (scl_rise) begin
                            rx_shift <= rx_byte_next;

                            if (bit_count == 3'd7) begin
                                data_reg_o    <= rx_byte_next;
                                write_valid_o <= 1'b1;
                                bit_count     <= 3'd0;
                                state         <= WRITE_DONE_WAIT_FALL;
                            end
                            else begin
                                bit_count <= bit_count + 3'd1;
                            end
                        end
                    end

                    // Drive ACK after receiving write data.
                    WRITE_DONE_WAIT_FALL: begin
                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;

                        if (scl_fall) begin
                            sda_drive_low <= 1'b1;
                            state         <= ACK_WRITE_WAIT_RISE;
                        end
                    end

                    ACK_WRITE_WAIT_RISE: begin
                        sda_drive_low <= 1'b1;
                        scl_drive_low <= 1'b0;

                        if (scl_rise)
                            state <= ACK_WRITE_WAIT_FALL;
                    end

                    ACK_WRITE_WAIT_FALL: begin
                        sda_drive_low <= 1'b1;
                        scl_drive_low <= 1'b0;

                        if (scl_fall) begin
                            sda_drive_low <= 1'b0;
                            state         <= WAIT_STOP;
                        end
                    end

                    // Slave sends read data; data is stable before
                    // each SCL rising edge.
                    SEND_READ_WAIT_RISE: begin
                        scl_drive_low <= 1'b0;

                        if (scl_rise)
                            state <= SEND_READ_WAIT_FALL;
                    end

                    SEND_READ_WAIT_FALL: begin
                        scl_drive_low <= 1'b0;

                        if (scl_fall) begin
                            if (tx_bit_index == 3'd0) begin
                                sda_drive_low <= 1'b0;
                                state         <= WAIT_MASTER_NACK_RISE;
                            end
                            else begin
                                tx_bit_index  <= tx_bit_index - 3'd1;
                                sda_drive_low <=
                                    ~data_reg_o[tx_bit_index - 3'd1];
                                state <= SEND_READ_WAIT_RISE;
                            end
                        end
                    end

                    // Master must NACK final one-byte read.
                    WAIT_MASTER_NACK_RISE: begin
                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;

                        if (scl_rise) begin
                            read_nack_o <= sda_sync;
                            state       <= WAIT_STOP;
                        end
                    end

                    WAIT_STOP: begin
                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;
                    end

                    // Wrong address: never ACK and wait for STOP.
                    IGNORE_TRANSACTION: begin
                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;
                    end

                    default: begin
                        state         <= IDLE;
                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;
                    end

                endcase
            end
        end
    end

endmodule
