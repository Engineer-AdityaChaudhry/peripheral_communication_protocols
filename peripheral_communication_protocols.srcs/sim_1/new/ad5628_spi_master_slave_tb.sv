`timescale 1ns / 1ps

// ============================================================
// AD5628 SPI Master + DAC Model Integration Testbench
//
// One end-to-end DAC scenario:
//   1. Enable internal reference: 0x0800_0001
//   2. Write/update DAC A with 12'hAAA: 0x030A_AA00
//
// SPI mode:
//   CPOL = 0
//   CPHA = 1
//   SCLK rising edge  -> master launches MOSI
//   SCLK falling edge -> DAC model samples MOSI
// ============================================================

module ad5628_spi_master_slave_tb;

    localparam int unsigned CLK_PERIOD = 10;   // 100 MHz
    localparam logic [15:0] CLK_DIV   = 16'd4;

    localparam logic [31:0] REF_ENABLE_FRAME = 32'h0800_0001;
    localparam logic [31:0] DAC_A_AAA_FRAME  = 32'h030A_AA00;

    // --------------------------------------------------------
    // Clock and reset
    // --------------------------------------------------------
    logic clk;
    logic rst;

    // --------------------------------------------------------
    // Master control interface
    // --------------------------------------------------------
    logic        start;
    logic [31:0] frame_i;
    logic [15:0] clk_div_i;

    logic        sync_n;
    logic        sclk;
    logic        mosi;
    logic        busy;
    logic        done;

    // --------------------------------------------------------
    // DAC model outputs
    // --------------------------------------------------------
    logic        internal_ref_enabled;

    logic [11:0] dac_a_code;
    logic [11:0] dac_b_code;
    logic [11:0] dac_c_code;
    logic [11:0] dac_d_code;
    logic [11:0] dac_e_code;
    logic [11:0] dac_f_code;
    logic [11:0] dac_g_code;
    logic [11:0] dac_h_code;

    logic [31:0] last_frame;
    logic [5:0]  received_bits;

    logic frame_done;
    logic frame_valid;
    logic frame_error;
    logic command_executed;
    logic unsupported_command;

    // --------------------------------------------------------
    // Testbench counters and frame monitor
    // --------------------------------------------------------
    integer checks;
    integer failures;

    integer sclk_rise_count;
    integer sclk_fall_count;
    integer monitored_bit_count;

    logic        monitor_active;
    logic [31:0] monitored_frame;

    // --------------------------------------------------------
    // DUT: AD5628 dedicated SPI master
    // --------------------------------------------------------
    ad5628_spi_master u_master (
        .clk       (clk),
        .rst       (rst),

        .start     (start),
        .frame_i   (frame_i),
        .clk_div_i (clk_div_i),

        .sync_n_o  (sync_n),
        .sclk_o    (sclk),
        .mosi_o    (mosi),

        .busy_o    (busy),
        .done_o    (done)
    );

    // --------------------------------------------------------
    // DAC behavioral slave model
    // --------------------------------------------------------
    ad5628_spi_slave_model u_dac_model (
        .rst                    (rst),

        .sync_n_i               (sync_n),
        .sclk_i                 (sclk),
        .mosi_i                 (mosi),

        .internal_ref_enabled_o (internal_ref_enabled),

        .dac_a_code_o           (dac_a_code),
        .dac_b_code_o           (dac_b_code),
        .dac_c_code_o           (dac_c_code),
        .dac_d_code_o           (dac_d_code),
        .dac_e_code_o           (dac_e_code),
        .dac_f_code_o           (dac_f_code),
        .dac_g_code_o           (dac_g_code),
        .dac_h_code_o           (dac_h_code),

        .last_frame_o           (last_frame),
        .received_bits_o        (received_bits),

        .frame_done_o           (frame_done),
        .frame_valid_o          (frame_valid),
        .frame_error_o          (frame_error),
        .command_executed_o     (command_executed),
        .unsupported_command_o  (unsupported_command)
    );

    // --------------------------------------------------------
    // 100 MHz system clock
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --------------------------------------------------------
    // SPI frame monitor
    // --------------------------------------------------------
    always @(negedge sync_n) begin
        monitor_active      = 1'b1;
        sclk_rise_count     = 0;
        sclk_fall_count     = 0;
        monitored_bit_count = 0;
        monitored_frame     = 32'h0000_0000;
    end

    always @(posedge sclk) begin
        if (monitor_active && !sync_n)
            sclk_rise_count = sclk_rise_count + 1;
    end

    always @(negedge sclk) begin
        if (monitor_active && !sync_n) begin
            sclk_fall_count     = sclk_fall_count + 1;
            monitored_bit_count = monitored_bit_count + 1;
            monitored_frame     = {monitored_frame[30:0], mosi};
        end
    end

    always @(posedge sync_n) begin
        monitor_active = 1'b0;
    end

    // --------------------------------------------------------
    // PASS / FAIL helper
    // --------------------------------------------------------
    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;

            if (condition === 1'b1)
                $display("PASS [%0d] %s", checks, message);
            else begin
                failures = failures + 1;
                $display(
                    "FAIL [%0d] %s | time=%0t",
                    checks,
                    message,
                    $time
                );
            end
        end
    endtask

    // --------------------------------------------------------
    // Reset task
    // --------------------------------------------------------
    task automatic apply_reset;
        begin
            @(negedge clk);

            rst       = 1'b1;
            start     = 1'b0;
            frame_i   = 32'h0000_0000;
            clk_div_i = CLK_DIV;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            repeat (3) @(posedge clk);
            #1;
        end
    endtask

    // --------------------------------------------------------
    // Launch one frame and verify transport behavior.
    // --------------------------------------------------------
    task automatic send_and_check_frame(
        input logic [31:0] expected_frame,
        input string       test_name
    );
        integer timeout;

        begin
            // AD5628 requires SYNC high between frames.
            repeat (2) @(posedge clk);

            @(negedge clk);
            frame_i = expected_frame;
            start   = 1'b1;

            @(posedge clk);
            #1;

            check(
                busy == 1'b1,
                $sformatf("%s asserts busy", test_name)
            );

            check(
                sync_n == 1'b0,
                $sformatf("%s asserts SYNC_n low", test_name)
            );

            check(
                sclk == 1'b0,
                $sformatf("%s starts with idle-low SCLK", test_name)
            );

            check(
                mosi == 1'b0,
                $sformatf("%s waits for first rising edge before MOSI launch",
                          test_name)
            );

            @(negedge clk);
            start = 1'b0;

            timeout = 0;

            while (!done && (timeout < 5000)) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end

            check(
                done == 1'b1,
                $sformatf("%s master pulses done", test_name)
            );

            check(
                frame_done == 1'b1,
                $sformatf("%s DAC model completes frame", test_name)
            );

            check(
                frame_valid == 1'b1,
                $sformatf("%s DAC model marks frame valid", test_name)
            );

            check(
                frame_error == 1'b0,
                $sformatf("%s has no premature-SYNC frame error",
                          test_name)
            );

            check(
                unsupported_command == 1'b0,
                $sformatf("%s command is supported", test_name)
            );

            check(
                command_executed == 1'b1,
                $sformatf("%s executes command", test_name)
            );

            check(
                received_bits == 6'd32,
                $sformatf("%s DAC samples exactly 32 bits", test_name)
            );

            check(
                monitored_bit_count == 32,
                $sformatf("%s monitor captures 32 MOSI bits", test_name)
            );

            check(
                monitored_frame == expected_frame,
                $sformatf("%s monitor captures expected 32-bit frame",
                          test_name)
            );

            check(
                last_frame == expected_frame,
                $sformatf("%s DAC model records expected frame",
                          test_name)
            );

            check(
                sclk_rise_count == 32,
                $sformatf("%s generates 32 SCLK rising edges", test_name)
            );

            check(
                sclk_fall_count == 32,
                $sformatf("%s generates 32 SCLK falling edges", test_name)
            );

            check(
                sync_n == 1'b1,
                $sformatf("%s releases SYNC_n after transfer", test_name)
            );

            check(
                sclk == 1'b0,
                $sformatf("%s returns SCLK to idle low", test_name)
            );

            check(
                busy == 1'b0,
                $sformatf("%s clears busy after transfer", test_name)
            );

            @(posedge clk);
            #1;

            check(
                done == 1'b0,
                $sformatf("%s done is one clock wide", test_name)
            );
        end
    endtask

    // --------------------------------------------------------
    // Main scenario
    // --------------------------------------------------------
    initial begin
        checks          = 0;
        failures        = 0;
        monitor_active  = 1'b0;
        monitored_frame = 32'h0000_0000;

        $display("\n========== TEST 1: RESET ==========");
        apply_reset();

        check(sync_n == 1'b1, "SYNC_n resets high");
        check(sclk == 1'b0, "SCLK resets low");
        check(mosi == 1'b0, "MOSI resets low");
        check(busy == 1'b0, "Master busy resets low");
        check(done == 1'b0, "Master done resets low");

        check(
            internal_ref_enabled == 1'b0,
            "Internal reference starts disabled"
        );

        check(dac_a_code == 12'h000, "DAC A resets to zero");
        check(dac_h_code == 12'h000, "DAC H resets to zero");

        // ----------------------------------------------------
        // One complete AD5628 DAC sequence
        // ----------------------------------------------------
        $display("\n========== TEST 2: AD5628 DAC WRITE ==========");

        send_and_check_frame(
            REF_ENABLE_FRAME,
            "Internal-reference enable frame"
        );

        check(
            internal_ref_enabled == 1'b1,
            "Internal reference enables after 0x0800_0001"
        );

        check(
            dac_a_code == 12'h000,
            "Reference command does not modify DAC A"
        );

        send_and_check_frame(
            DAC_A_AAA_FRAME,
            "DAC A write-and-update frame"
        );

        check(
            internal_ref_enabled == 1'b1,
            "Internal reference remains enabled"
        );

        check(
            dac_a_code == 12'hAAA,
            "DAC A updates to 12'hAAA"
        );

        check(dac_b_code == 12'h000, "DAC B remains unchanged");
        check(dac_c_code == 12'h000, "DAC C remains unchanged");
        check(dac_d_code == 12'h000, "DAC D remains unchanged");
        check(dac_e_code == 12'h000, "DAC E remains unchanged");
        check(dac_f_code == 12'h000, "DAC F remains unchanged");
        check(dac_g_code == 12'h000, "DAC G remains unchanged");
        check(dac_h_code == 12'h000, "DAC H remains unchanged");

        $display("\n========================================");

        if (failures == 0)
            $display(
                "ALL AD5628 DAC SPI TESTS PASSED. Checks: %0d",
                checks
            );
        else
            $display(
                "AD5628 DAC SPI TESTS FAILED. Failures: %0d / %0d",
                failures,
                checks
            );

        $display("========================================\n");

        #100;
        $finish;
    end

    // --------------------------------------------------------
    // Global watchdog
    // --------------------------------------------------------
    initial begin
        #2_000_000;
        $fatal(
            1,
            "Global timeout: AD5628 SPI testbench did not finish."
        );
    end

endmodule

