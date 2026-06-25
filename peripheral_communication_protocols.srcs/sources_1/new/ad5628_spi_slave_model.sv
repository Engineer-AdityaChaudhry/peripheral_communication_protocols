`timescale 1ns / 1ps

// ============================================================
// AD5628 SPI DAC Behavioral Slave Model
//
// Testbench model only: do not synthesize.
//
// Serial interface:
//   SYNC_n low  -> begin 32-bit transaction
//   SCLK falling edge -> sample DIN/MOSI
//   32nd falling edge -> execute command
//
// Implemented commands:
//   4'b1000 : Set internal reference register
//   4'b0011 : Write and update DAC channel n
//
// SPI timing:
//   CPOL = 0
//   CPHA = 1
//   MOSI changes on rising edges
//   AD5628 samples MOSI on falling edges
// ============================================================

module ad5628_spi_slave_model (
    input  logic        rst,

    // SPI write-only interface from master
    input  logic        sync_n_i,
    input  logic        sclk_i,
    input  logic        mosi_i,

    // DAC state visible to the testbench
    output logic        internal_ref_enabled_o,

    output logic [11:0] dac_a_code_o,
    output logic [11:0] dac_b_code_o,
    output logic [11:0] dac_c_code_o,
    output logic [11:0] dac_d_code_o,
    output logic [11:0] dac_e_code_o,
    output logic [11:0] dac_f_code_o,
    output logic [11:0] dac_g_code_o,
    output logic [11:0] dac_h_code_o,

    // Verification/status outputs
    output logic [31:0] last_frame_o,
    output logic [5:0]  received_bits_o,

    output logic        frame_done_o,
    output logic        frame_valid_o,
    output logic        frame_error_o,
    output logic        command_executed_o,
    output logic        unsupported_command_o
);

    logic [31:0] shift_reg;

    logic        selected;
    logic        frame_complete;

    logic [31:0] frame_after_sample;

    assign frame_after_sample = {shift_reg[30:0], mosi_i};

    // --------------------------------------------------------
    // One event-driven process models the external DAC pins.
    //
    // negedge sync_n_i : begin a new SPI frame
    // negedge sclk_i   : sample one MOSI bit
    // posedge sync_n_i : finish frame or flag an abort
    // --------------------------------------------------------
    always @(negedge sync_n_i or negedge sclk_i or posedge sync_n_i or posedge rst) begin
        if (rst) begin
            shift_reg              <= 32'h0000_0000;

            selected               <= 1'b0;
            frame_complete         <= 1'b0;

            internal_ref_enabled_o <= 1'b0;

            dac_a_code_o           <= 12'h000;
            dac_b_code_o           <= 12'h000;
            dac_c_code_o           <= 12'h000;
            dac_d_code_o           <= 12'h000;
            dac_e_code_o           <= 12'h000;
            dac_f_code_o           <= 12'h000;
            dac_g_code_o           <= 12'h000;
            dac_h_code_o           <= 12'h000;

            last_frame_o           <= 32'h0000_0000;
            received_bits_o        <= 6'd0;

            frame_done_o           <= 1'b0;
            frame_valid_o          <= 1'b0;
            frame_error_o          <= 1'b0;
            command_executed_o     <= 1'b0;
            unsupported_command_o  <= 1'b0;
        end

        // ----------------------------------------------------
        // SYNC_n falling edge: start a fresh 32-bit frame.
        // ----------------------------------------------------
        else if (!sync_n_i && !selected) begin
            shift_reg             <= 32'h0000_0000;
            received_bits_o       <= 6'd0;

            selected              <= 1'b1;
            frame_complete        <= 1'b0;

            frame_done_o          <= 1'b0;
            frame_valid_o         <= 1'b0;
            frame_error_o         <= 1'b0;
            command_executed_o    <= 1'b0;
            unsupported_command_o <= 1'b0;
        end

        // ----------------------------------------------------
        // SYNC_n rising edge: incomplete frame is invalid.
        // ----------------------------------------------------
        else if (sync_n_i && selected) begin
            if (!frame_complete) begin
                frame_error_o <= 1'b1;
            end

            selected <= 1'b0;
        end

        // ----------------------------------------------------
        // SCLK falling edge while selected: sample MOSI.
        // ----------------------------------------------------
        else if (!sync_n_i && selected && !frame_complete) begin
            shift_reg <= frame_after_sample;

            // First 31 falling edges only shift the frame.
            if (received_bits_o < 6'd31) begin
                received_bits_o <= received_bits_o + 1'b1;
            end

            // 32nd falling edge: execute the 32-bit command.
            else begin
                received_bits_o <= 6'd32;
                last_frame_o   <= frame_after_sample;

                frame_complete <= 1'b1;
                frame_done_o   <= 1'b1;
                frame_valid_o  <= 1'b1;

                case (frame_after_sample[27:24])

                    // ----------------------------------------
                    // Command 1000:
                    // Set up internal reference register.
                    // DB0 = 1 enables internal reference.
                    // ----------------------------------------
                    4'b1000: begin
                        internal_ref_enabled_o <= frame_after_sample[0];
                        command_executed_o     <= 1'b1;
                    end

                    // ----------------------------------------
                    // Command 0011:
                    // Write and update DAC channel n.
                    // ----------------------------------------
                    4'b0011: begin
                        command_executed_o <= 1'b1;

                        case (frame_after_sample[23:20])

                            4'h0: dac_a_code_o <= frame_after_sample[19:8];
                            4'h1: dac_b_code_o <= frame_after_sample[19:8];
                            4'h2: dac_c_code_o <= frame_after_sample[19:8];
                            4'h3: dac_d_code_o <= frame_after_sample[19:8];
                            4'h4: dac_e_code_o <= frame_after_sample[19:8];
                            4'h5: dac_f_code_o <= frame_after_sample[19:8];
                            4'h6: dac_g_code_o <= frame_after_sample[19:8];
                            4'h7: dac_h_code_o <= frame_after_sample[19:8];

                            // Address 1111 = all DACs.
                            4'hF: begin
                                dac_a_code_o <= frame_after_sample[19:8];
                                dac_b_code_o <= frame_after_sample[19:8];
                                dac_c_code_o <= frame_after_sample[19:8];
                                dac_d_code_o <= frame_after_sample[19:8];
                                dac_e_code_o <= frame_after_sample[19:8];
                                dac_f_code_o <= frame_after_sample[19:8];
                                dac_g_code_o <= frame_after_sample[19:8];
                                dac_h_code_o <= frame_after_sample[19:8];
                            end

                            default: begin
                                command_executed_o    <= 1'b0;
                                unsupported_command_o <= 1'b1;
                            end
                        endcase
                    end

                    // ----------------------------------------
                    // Other commands are not modeled here.
                    // ----------------------------------------
                    default: begin
                        unsupported_command_o <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule

