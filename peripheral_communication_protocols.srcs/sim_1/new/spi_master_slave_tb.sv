`timescale 1ns / 1ps

// ============================================================
// SPI Master + SPI Slave Integration Testbench
//
// SPI Mode 0:
//   CPOL = 0, CPHA = 0
//   MSB first, 8-bit full-duplex transfers
//
// DUTs:
//   spi_master.sv
//   spi_slave.sv
// ============================================================

module spi_master_slave_tb;

    localparam int unsigned DATA_WIDTH = 8;

    // --------------------------------------------------------
    // Common system clock and reset
    // --------------------------------------------------------
    logic clk;
    logic rst;

    // --------------------------------------------------------
    // Master control interface
    // --------------------------------------------------------
    logic                  start;
    logic [DATA_WIDTH-1:0] master_tx_data;
    logic [15:0]           clk_div_i;

    logic [DATA_WIDTH-1:0] master_rx_data;
    logic                  master_busy;
    logic                  master_done;

    // --------------------------------------------------------
    // Slave parallel interface
    // --------------------------------------------------------
    logic [DATA_WIDTH-1:0] slave_tx_data;
    logic [DATA_WIDTH-1:0] slave_rx_data;
    logic                  slave_rx_valid;

    // --------------------------------------------------------
    // SPI serial wires
    // --------------------------------------------------------
    logic sclk;
    logic mosi;
    logic cs_n;

    logic slave_miso;
    logic slave_miso_oe;
    tri   miso;

    // Slave drives MISO only while selected.
    assign miso = slave_miso_oe ? slave_miso : 1'bz;

    // --------------------------------------------------------
    // Verification variables
    // --------------------------------------------------------
    integer checks;
    integer failures;

    integer sclk_rise_count;
    integer sclk_fall_count;
    integer cs_assert_count;

    // --------------------------------------------------------
    // SPI Master
    // --------------------------------------------------------
    spi_master #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_master (
        .clk       (clk),
        .rst       (rst),

        .start     (start),
        .tx_data   (master_tx_data),
        .clk_div_i (clk_div_i),

        .miso      (miso),

        .sclk      (sclk),
        .mosi      (mosi),
        .cs_n      (cs_n),

        .rx_data   (master_rx_data),
        .busy      (master_busy),
        .done      (master_done)
    );

    // --------------------------------------------------------
    // SPI Slave
    // --------------------------------------------------------
    spi_slave #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_slave (
        .clk        (clk),
        .rst        (rst),

        .tx_data_i  (slave_tx_data),

        .sclk_i     (sclk),
        .cs_n_i     (cs_n),
        .mosi_i     (mosi),

        .miso_o     (slave_miso),
        .miso_oe_o  (slave_miso_oe),

        .rx_data_o  (slave_rx_data),
        .rx_valid_o (slave_rx_valid)
    );

    // --------------------------------------------------------
    // 100 MHz system clock
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // SPI transaction monitors
    // --------------------------------------------------------
    always @(negedge cs_n) begin
        cs_assert_count = cs_assert_count + 1;
    end

    always @(posedge sclk) begin
        if (!cs_n)
            sclk_rise_count = sclk_rise_count + 1;
    end

    always @(negedge sclk) begin
        if (!cs_n)
            sclk_fall_count = sclk_fall_count + 1;
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

            if (condition === 1'b1) begin
                $display("PASS [%0d] %s", checks, message);
            end
            else begin
                failures = failures + 1;
                $display("FAIL [%0d] %s | time=%0t",
                         checks, message, $time);
            end
        end
    endtask

    // --------------------------------------------------------
    // Reset
    // --------------------------------------------------------
    task automatic apply_reset;
        begin
            @(negedge clk);

            rst            = 1'b1;
            start          = 1'b0;
            master_tx_data = 8'h00;
            slave_tx_data  = 8'h00;
            clk_div_i      = 16'd8;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            repeat (3) @(posedge clk);
            #1;
        end
    endtask

    // --------------------------------------------------------
    // Start one SPI transaction
    // --------------------------------------------------------
    task automatic launch_transfer(
        input logic [DATA_WIDTH-1:0] master_data,
        input logic [DATA_WIDTH-1:0] slave_data,
        input logic [15:0]           divider,
        input string                 test_name
    );
        begin
            slave_tx_data = slave_data;

            @(negedge clk);
            master_tx_data = master_data;
            clk_div_i      = divider;
            start          = 1'b1;

            @(posedge clk);
            #1;

            check(
                master_busy == 1'b1,
                $sformatf("%s asserts master busy", test_name)
            );

            check(
                cs_n == 1'b0,
                $sformatf("%s asserts CS_n low", test_name)
            );

            check(
                sclk == 1'b0,
                $sformatf("%s starts with SCLK low for Mode 0", test_name)
            );

            check(
                mosi == master_data[DATA_WIDTH-1],
                $sformatf("%s places MOSI MSB before first SCLK rising edge",
                          test_name)
            );

            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // Verify SCLK half-period
    // --------------------------------------------------------
    task automatic check_sclk_half_period(
        input integer expected_divider,
        input string  test_name
    );
        time rise_time;
        time fall_time;

        begin
            @(posedge sclk);
            rise_time = $time;

            @(negedge sclk);
            fall_time = $time;

            check(
                (fall_time - rise_time) == (expected_divider * 10),
                $sformatf("%s SCLK half-period matches divider",
                          test_name)
            );
        end
    endtask

    // --------------------------------------------------------
    // Wait for both devices to complete transaction
    // --------------------------------------------------------
    task automatic wait_and_check_transfer(
        input logic [DATA_WIDTH-1:0] expected_master_rx,
        input logic [DATA_WIDTH-1:0] expected_slave_rx,
        input string                 test_name
    );
        integer timeout;
        logic   master_done_seen;
        logic   slave_clear_seen;
        logic   slave_valid_seen;

        begin
            timeout          = 0;
            master_done_seen = 1'b0;
            slave_clear_seen = (slave_rx_valid == 1'b0);
            slave_valid_seen = 1'b0;

            // Slave rx_valid remains high after a completed frame.
            // For each new transaction, wait until it clears and
            // then rises again with new received data.
            while (
                !(master_done_seen && slave_valid_seen) &&
                (timeout < 10000)
            ) begin
                @(posedge clk);
                #1;

                if (master_done == 1'b1)
                    master_done_seen = 1'b1;

                if (slave_rx_valid == 1'b0)
                    slave_clear_seen = 1'b1;

                if (slave_clear_seen && (slave_rx_valid == 1'b1))
                    slave_valid_seen = 1'b1;

                timeout = timeout + 1;
            end

            check(
                master_done_seen == 1'b1,
                $sformatf("%s master completes and pulses done", test_name)
            );

            check(
                slave_valid_seen == 1'b1,
                $sformatf("%s slave receives a complete frame", test_name)
            );

            #1;

            check(
                master_rx_data == expected_master_rx,
                $sformatf("%s master receives 0x%02h from slave",
                          test_name, expected_master_rx)
            );

            check(
                slave_rx_data == expected_slave_rx,
                $sformatf("%s slave receives 0x%02h from master",
                          test_name, expected_slave_rx)
            );

            check(
                sclk_rise_count == DATA_WIDTH,
                $sformatf("%s generates exactly eight SCLK rising edges",
                          test_name)
            );

            check(
                sclk_fall_count == DATA_WIDTH,
                $sformatf("%s generates exactly eight SCLK falling edges",
                          test_name)
            );

            check(
                cs_assert_count == 1,
                $sformatf("%s performs one CS_n assertion",
                          test_name)
            );

            check(
                cs_n == 1'b1,
                $sformatf("%s releases CS_n after transfer",
                          test_name)
            );

            check(
                sclk == 1'b0,
                $sformatf("%s returns SCLK low after transfer",
                          test_name)
            );

            check(
                master_busy == 1'b0,
                $sformatf("%s deasserts busy after transfer",
                          test_name)
            );

            check(
                miso === 1'bz,
                $sformatf("%s slave releases MISO after deselection",
                          test_name)
            );

            @(posedge clk);
            #1;

            check(
                master_done == 1'b0,
                $sformatf("%s done is one system-clock pulse",
                          test_name)
            );
        end
    endtask

    // --------------------------------------------------------
    // Run a complete transfer
    // --------------------------------------------------------
    task automatic run_transfer(
        input logic [DATA_WIDTH-1:0] master_data,
        input logic [DATA_WIDTH-1:0] slave_data,
        input logic [15:0]           divider,
        input string                 test_name
    );
        begin
            sclk_rise_count = 0;
            sclk_fall_count = 0;
            cs_assert_count = 0;

            launch_transfer(master_data, slave_data, divider, test_name);
            check_sclk_half_period(divider, test_name);

            wait_and_check_transfer(
                slave_data,
                master_data,
                test_name
            );
        end
    endtask

    // --------------------------------------------------------
    // Global watchdog
    // --------------------------------------------------------
    initial begin
        #300_000;
        $fatal(1, "Global timeout: SPI master-slave testbench did not finish.");
    end

    // --------------------------------------------------------
    // Main verification sequence
    // --------------------------------------------------------
    initial begin
        checks          = 0;
        failures        = 0;
        sclk_rise_count = 0;
        sclk_fall_count = 0;
        cs_assert_count = 0;

        // ====================================================
        // TEST 1: Reset / idle state
        // ====================================================
        $display("\n========== TEST 1: RESET / IDLE ==========");
        apply_reset();

        check(sclk == 1'b0, "Master SCLK resets low");
        check(cs_n == 1'b1, "Master CS_n resets high");
        check(mosi == 1'b0, "Master MOSI resets low");
        check(master_busy == 1'b0, "Master busy resets low");
        check(master_done == 1'b0, "Master done resets low");

        check(slave_miso_oe == 1'b0, "Slave MISO output-enable resets low");
        check(slave_rx_valid == 1'b0, "Slave receive-valid resets low");
        check(miso === 1'bz, "Shared MISO is high impedance while deselected");

        // ====================================================
        // TEST 2: Full-duplex A5 <-> BA
        // ====================================================
        $display("\n========== TEST 2: FULL-DUPLEX A5 <-> BA ==========");

        run_transfer(
            8'hA5,
            8'hBA,
            16'd8,
            "Transfer A5 <-> BA"
        );

        // ====================================================
        // TEST 3: Full-duplex 3C <-> C3
        // ====================================================
        $display("\n========== TEST 3: FULL-DUPLEX 3C <-> C3 ==========");

        run_transfer(
            8'h3C,
            8'hC3,
            16'd6,
            "Transfer 3C <-> C3"
        );

        // ====================================================
        // TEST 4: Start request while master is busy
        // ====================================================
        $display("\n========== TEST 4: START WHILE BUSY ==========");

        sclk_rise_count = 0;
        sclk_fall_count = 0;
        cs_assert_count = 0;

        launch_transfer(
            8'h96,
            8'h69,
            16'd5,
            "Busy-protection transfer 96 <-> 69"
        );

        // This second start request must be ignored because
        // master_busy is already high.
        @(negedge clk);
        master_tx_data = 8'hFF;
        start          = 1'b1;

        @(posedge clk);
        #1;

        check(
            master_busy == 1'b1,
            "Master remains busy during additional start request"
        );

        @(negedge clk);
        start = 1'b0;

        check_sclk_half_period(
            5,
            "Busy-protection transfer 96 <-> 69"
        );

        wait_and_check_transfer(
            8'h69,
            8'h96,
            "Busy-protection transfer 96 <-> 69"
        );

        // ====================================================
        // TEST 5: All-zero / all-one data patterns
        // ====================================================
        $display("\n========== TEST 5: EDGE DATA PATTERNS ==========");

        run_transfer(
            8'h00,
            8'hFF,
            16'd8,
            "Transfer 00 <-> FF"
        );

        run_transfer(
            8'hFF,
            8'h00,
            16'd8,
            "Transfer FF <-> 00"
        );

        // ====================================================
        // Final result
        // ====================================================
        $display("\n========================================");

        if (failures == 0)
            $display("ALL SPI MASTER-SLAVE TESTS PASSED. Checks: %0d",
                     checks);
        else
            $display("SPI MASTER-SLAVE TESTS FAILED. Failures: %0d / %0d",
                     failures, checks);

        $display("========================================\n");

        #100;
        $finish;
    end

endmodule

