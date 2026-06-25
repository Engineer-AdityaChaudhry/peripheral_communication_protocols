`timescale 1ns / 1ps

// ============================================================
// Configurable SPI Master-Slave Integration Testbench
//
// Tests all four SPI modes:
//
// Mode 0: CPOL=0, CPHA=0
// Mode 1: CPOL=0, CPHA=1
// Mode 2: CPOL=1, CPHA=0
// Mode 3: CPOL=1, CPHA=1
//
// Uses real spi_cpha_master and spi_cpha_slave RTL.
// ============================================================

module spi_cpha_master_slave_tb;

    localparam int unsigned DATA_WIDTH = 8;
    localparam int unsigned CLK_PERIOD = 10;

    // --------------------------------------------------------
    // Common clock/reset
    // --------------------------------------------------------
    logic clk;
    logic rst;

    // --------------------------------------------------------
    // Master control/configuration
    // --------------------------------------------------------
    logic                  start;
    logic [DATA_WIDTH-1:0] master_tx_data;
    logic [15:0]           clk_div_i;
    logic                  cpol_i;
    logic                  cpha_i;

    logic [DATA_WIDTH-1:0] master_rx_data;
    logic                  master_busy;
    logic                  master_done;

    // --------------------------------------------------------
    // Slave parallel data interface
    // --------------------------------------------------------
    logic [DATA_WIDTH-1:0] slave_tx_data;
    logic [DATA_WIDTH-1:0] slave_rx_data;
    logic                  slave_rx_valid;

    // --------------------------------------------------------
    // SPI serial signals
    // --------------------------------------------------------
    logic sclk;
    logic mosi;
    logic cs_n;

    logic slave_miso;
    logic slave_miso_oe;
    tri   miso;

    assign miso = slave_miso_oe ? slave_miso : 1'bz;

    // --------------------------------------------------------
    // Verification counters
    // --------------------------------------------------------
    integer checks;
    integer failures;

    integer sclk_rise_count;
    integer sclk_fall_count;
    integer cs_assert_count;

    // --------------------------------------------------------
    // DUT: Configurable SPI Master
    // --------------------------------------------------------
    spi_cpha_master #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_master (
        .clk       (clk),
        .rst       (rst),

        .start     (start),
        .tx_data   (master_tx_data),
        .clk_div_i (clk_div_i),
        .cpol_i    (cpol_i),
        .cpha_i    (cpha_i),

        .miso      (miso),

        .sclk      (sclk),
        .mosi      (mosi),
        .cs_n      (cs_n),

        .rx_data   (master_rx_data),
        .busy      (master_busy),
        .done      (master_done)
    );

    // --------------------------------------------------------
    // DUT: Configurable SPI Slave
    // --------------------------------------------------------
    spi_cpha_slave #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_slave (
        .clk        (clk),
        .rst        (rst),

        .tx_data_i  (slave_tx_data),

        .cpol_i     (cpol_i),
        .cpha_i     (cpha_i),

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
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --------------------------------------------------------
    // SPI signal monitors
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

            if (condition === 1'b1)
                $display("PASS [%0d] %s", checks, message);
            else begin
                failures = failures + 1;
                $display("FAIL [%0d] %s | time=%0t",
                         checks, message, $time);
            end
        end
    endtask

    // --------------------------------------------------------
    // Reset task
    // --------------------------------------------------------
    task automatic apply_reset;
        begin
            @(negedge clk);

            rst            = 1'b1;
            start          = 1'b0;
            master_tx_data = 8'h00;
            slave_tx_data  = 8'h00;
            clk_div_i      = 16'd12;
            cpol_i         = 1'b0;
            cpha_i         = 1'b0;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            repeat (3) @(posedge clk);
            #1;
        end
    endtask

    // --------------------------------------------------------
    // Wait for logical leading edge
    // CPOL=0: leading is rising
    // CPOL=1: leading is falling
    // --------------------------------------------------------
    task automatic wait_for_leading_edge(
        input logic cpol_value
    );
        begin
            if (cpol_value == 1'b0)
                @(posedge sclk);
            else
                @(negedge sclk);

            #1;
        end
    endtask

    // --------------------------------------------------------
    // Wait for logical trailing edge
    // CPOL=0: trailing is falling
    // CPOL=1: trailing is rising
    // --------------------------------------------------------
    task automatic wait_for_trailing_edge(
        input logic cpol_value
    );
        begin
            if (cpol_value == 1'b0)
                @(negedge sclk);
            else
                @(posedge sclk);

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
        input logic                  cpol_value,
        input logic                  cpha_value,
        input string                 test_name
    );
        begin
            slave_tx_data = slave_data;

            @(negedge clk);

            master_tx_data = master_data;
            clk_div_i      = divider;
            cpol_i         = cpol_value;
            cpha_i         = cpha_value;
            start          = 1'b1;

            @(posedge clk);
            #1;

            check(
                master_busy == 1'b1,
                $sformatf("%s asserts busy after start", test_name)
            );

            check(
                cs_n == 1'b0,
                $sformatf("%s asserts CS_n low", test_name)
            );

            check(
                sclk == cpol_value,
                $sformatf("%s starts SCLK at CPOL idle level", test_name)
            );

            // CPHA=0 preloads first MOSI bit before leading edge.
            if (cpha_value == 1'b0) begin
                check(
                    mosi == master_data[DATA_WIDTH-1],
                    $sformatf("%s preloads MOSI MSB before leading edge",
                              test_name)
                );
            end

            // CPHA=1 waits until the leading edge to launch bit 7.
            else begin
                check(
                    mosi == 1'b0,
                    $sformatf("%s waits to launch data until leading edge",
                              test_name)
                );
            end

            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // Verify first-bit timing for CPHA
    // --------------------------------------------------------
    task automatic check_first_bit_timing(
        input logic [DATA_WIDTH-1:0] master_data,
        input logic                  cpol_value,
        input logic                  cpha_value,
        input string                 test_name
    );
        begin
            wait_for_leading_edge(cpol_value);

            if (cpha_value == 1'b0) begin
                check(
                    mosi == master_data[DATA_WIDTH-1],
                    $sformatf("%s retains first MOSI bit at sample edge",
                              test_name)
                );
            end
            else begin
                check(
                    mosi == master_data[DATA_WIDTH-1],
                    $sformatf("%s launches first MOSI bit on leading edge",
                              test_name)
                );
            end
        end
    endtask

    // --------------------------------------------------------
    // Verify SCLK half-period
    // --------------------------------------------------------
    task automatic check_sclk_half_period(
        input integer expected_divider,
        input logic   cpol_value,
        input string  test_name
    );
        time leading_time;
        time trailing_time;

        begin
            wait_for_leading_edge(cpol_value);
            leading_time = $time;

            wait_for_trailing_edge(cpol_value);
            trailing_time = $time;

            check(
                (trailing_time - leading_time) ==
                (expected_divider * CLK_PERIOD),

                $sformatf("%s SCLK half-period matches divider",
                          test_name)
            );
        end
    endtask

    // --------------------------------------------------------
    // Wait for complete full-duplex transfer and verify result
    // --------------------------------------------------------
    task automatic wait_and_check_transfer(
        input logic [DATA_WIDTH-1:0] expected_master_rx,
        input logic [DATA_WIDTH-1:0] expected_slave_rx,
        input logic                  expected_cpol,
        input string                 test_name
    );
        integer timeout;
        logic master_done_seen;
        logic slave_valid_seen;
        logic slave_valid_cleared;

        begin
            timeout             = 0;
            master_done_seen    = 1'b0;
            slave_valid_seen    = 1'b0;
            slave_valid_cleared = (slave_rx_valid == 1'b0);

            while (
                !(master_done_seen && slave_valid_seen) &&
                (timeout < 20000)
            ) begin
                @(posedge clk);
                #1;

                if (master_done)
                    master_done_seen = 1'b1;

                if (!slave_rx_valid)
                    slave_valid_cleared = 1'b1;

                if (slave_valid_cleared && slave_rx_valid)
                    slave_valid_seen = 1'b1;

                timeout = timeout + 1;
            end

            check(
                master_done_seen == 1'b1,
                $sformatf("%s master completes and pulses done",
                          test_name)
            );

            check(
                slave_valid_seen == 1'b1,
                $sformatf("%s slave receives a complete byte",
                          test_name)
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
                $sformatf("%s generates eight rising SCLK edges",
                          test_name)
            );

            check(
                sclk_fall_count == DATA_WIDTH,
                $sformatf("%s generates eight falling SCLK edges",
                          test_name)
            );

            check(
                cs_assert_count == 1,
                $sformatf("%s creates one CS_n assertion",
                          test_name)
            );

            check(
                cs_n == 1'b1,
                $sformatf("%s releases CS_n at completion",
                          test_name)
            );

            check(
                sclk == expected_cpol,
                $sformatf("%s returns SCLK to CPOL idle level",
                          test_name)
            );

            check(
                master_busy == 1'b0,
                $sformatf("%s deasserts busy at completion",
                          test_name)
            );

            check(
                miso === 1'bz,
                $sformatf("%s slave releases MISO after CS_n rises",
                          test_name)
            );

            @(posedge clk);
            #1;

            check(
                master_done == 1'b0,
                $sformatf("%s done is a one-clock pulse",
                          test_name)
            );
        end
    endtask

    // --------------------------------------------------------
    // Run one complete mode-specific test
    // --------------------------------------------------------
    task automatic run_mode_test(
        input logic [DATA_WIDTH-1:0] master_data,
        input logic [DATA_WIDTH-1:0] slave_data,
        input logic [15:0]           divider,
        input logic                  cpol_value,
        input logic                  cpha_value,
        input string                 test_name
    );
        begin
            sclk_rise_count = 0;
            sclk_fall_count = 0;
            cs_assert_count = 0;

            launch_transfer(
                master_data,
                slave_data,
                divider,
                cpol_value,
                cpha_value,
                test_name
            );

            check_first_bit_timing(
                master_data,
                cpol_value,
                cpha_value,
                test_name
            );

            check_sclk_half_period(
                divider,
                cpol_value,
                test_name
            );

            wait_and_check_transfer(
                slave_data,
                master_data,
                cpol_value,
                test_name
            );
        end
    endtask

    // --------------------------------------------------------
    // Global watchdog
    // --------------------------------------------------------
    initial begin
        #800_000;
        $fatal(1,
            "Global timeout: configurable SPI master-slave TB did not finish."
        );
    end

    // --------------------------------------------------------
    // Main test sequence
    // --------------------------------------------------------
    initial begin
        checks          = 0;
        failures        = 0;
        sclk_rise_count = 0;
        sclk_fall_count = 0;
        cs_assert_count = 0;

        // ====================================================
        // TEST 1: Reset
        // ====================================================
        $display("\n========== TEST 1: RESET ==========");
        apply_reset();

        check(sclk == 1'b0, "SCLK resets low");
        check(cs_n == 1'b1, "CS_n resets high");
        check(mosi == 1'b0, "MOSI resets low");
        check(master_busy == 1'b0, "Master busy resets low");
        check(master_done == 1'b0, "Master done resets low");
        check(slave_miso_oe == 1'b0, "Slave MISO output-enable resets low");
        check(slave_rx_valid == 1'b0, "Slave RX valid resets low");
        check(miso === 1'bz, "MISO is high impedance while deselected");

        // ====================================================
        // TEST 2: SPI Mode 0
        // CPOL=0, CPHA=0
        // Sample leading/rising, launch trailing/falling.
        // ====================================================
        $display("\n========== TEST 2: MODE 0 ==========");

        run_mode_test(
            8'hA5,
            8'hBA,
            16'd12,
            1'b0,
            1'b0,
            "Mode 0 A5 <-> BA"
        );

        // ====================================================
        // TEST 3: SPI Mode 1
        // CPOL=0, CPHA=1
        // Launch leading/rising, sample trailing/falling.
        // ====================================================
        $display("\n========== TEST 3: MODE 1 ==========");

        run_mode_test(
            8'hC3,
            8'h3C,
            16'd12,
            1'b0,
            1'b1,
            "Mode 1 C3 <-> 3C"
        );

        // ====================================================
        // TEST 4: SPI Mode 2
        // CPOL=1, CPHA=0
        // Sample leading/falling, launch trailing/rising.
        // ====================================================
        $display("\n========== TEST 4: MODE 2 ==========");

        run_mode_test(
            8'h96,
            8'h69,
            16'd12,
            1'b1,
            1'b0,
            "Mode 2 96 <-> 69"
        );

        // ====================================================
        // TEST 5: SPI Mode 3
        // CPOL=1, CPHA=1
        // Launch leading/falling, sample trailing/rising.
        // ====================================================
        $display("\n========== TEST 5: MODE 3 ==========");

        run_mode_test(
            8'hF0,
            8'h0F,
            16'd12,
            1'b1,
            1'b1,
            "Mode 3 F0 <-> 0F"
        );

        // ====================================================
        // TEST 6: Start while busy
        // ====================================================
        $display("\n========== TEST 6: START WHILE BUSY ==========");

        sclk_rise_count = 0;
        sclk_fall_count = 0;
        cs_assert_count = 0;

        launch_transfer(
            8'h5A,
            8'hA5,
            16'd12,
            1'b0,
            1'b0,
            "Busy-protection transfer"
        );

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

        check_first_bit_timing(
            8'h5A,
            1'b0,
            1'b0,
            "Busy-protection transfer"
        );

        check_sclk_half_period(
            12,
            1'b0,
            "Busy-protection transfer"
        );

        wait_and_check_transfer(
            8'hA5,
            8'h5A,
            1'b0,
            "Busy-protection transfer"
        );

        // ====================================================
        // Final summary
        // ====================================================
        $display("\n========================================");

        if (failures == 0)
            $display(
                "ALL CONFIGURABLE SPI MASTER-SLAVE TESTS PASSED. Checks: %0d",
                checks
            );
        else
            $display(
                "CONFIGURABLE SPI TESTS FAILED. Failures: %0d / %0d",
                failures,
                checks
            );

        $display("========================================\n");

        #100;
        $finish;
    end

endmodule