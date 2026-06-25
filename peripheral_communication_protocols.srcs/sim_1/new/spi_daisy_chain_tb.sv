`timescale 1ns / 1ps

// ============================================================
// SPI Daisy-Chain Integration Testbench
//
// Chain topology:
//
// Master MOSI -> Slave 0 SDI
// Slave 0 SDO -> Slave 1 SDI
// Slave 1 SDO -> Slave 2 SDI
// Slave 2 SDO -> Master MISO
//
// Configuration:
//   NUM_SLAVES = 3
//   DATA_WIDTH = 8
//   SPI Mode 0
//
// One 24-bit transaction:
//   Master TX = A5 | 5A | 96
//
// Expected final received bytes:
//   Slave 2 = A5   (farthest slave)
//   Slave 1 = 5A
//   Slave 0 = 96   (nearest slave)
//
// Slave preload data:
//   Slave 2 = C3
//   Slave 1 = A5
//   Slave 0 = 3C
//
// Expected master RX = C3 | A5 | 3C
// ============================================================

module spi_daisy_chain_tb;

    localparam int unsigned NUM_SLAVES = 3;
    localparam int unsigned DATA_WIDTH = 8;
    localparam int unsigned FRAME_WIDTH = NUM_SLAVES * DATA_WIDTH;

    localparam int unsigned CLK_PERIOD = 10;
    localparam logic [15:0] CLK_DIV = 16'd16;

    localparam logic [FRAME_WIDTH-1:0] MASTER_TX =
        24'hA5_5A_96;

    localparam logic [FRAME_WIDTH-1:0] EXPECTED_MASTER_RX =
        24'hC3_A5_3C;

    // --------------------------------------------------------
    // Clock/reset
    // --------------------------------------------------------
    logic clk;
    logic rst;

    // --------------------------------------------------------
    // Master interface
    // --------------------------------------------------------
    logic                   start;
    logic [FRAME_WIDTH-1:0] tx_data;
    logic [15:0]            clk_div_i;

    logic                   sclk;
    logic                   mosi;
    logic                   cs_n;
    logic                   miso;

    logic [FRAME_WIDTH-1:0] master_rx_data;
    logic                   master_busy;
    logic                   master_done;

    // --------------------------------------------------------
    // Slave parallel preload values
    // --------------------------------------------------------
    logic [DATA_WIDTH-1:0] slave0_preload;
    logic [DATA_WIDTH-1:0] slave1_preload;
    logic [DATA_WIDTH-1:0] slave2_preload;

    // --------------------------------------------------------
    // Slave serial connections
    // --------------------------------------------------------
    logic slave0_sdo;
    logic slave1_sdo;
    logic slave2_sdo;

    // --------------------------------------------------------
    // Slave received-data outputs
    // --------------------------------------------------------
    logic [DATA_WIDTH-1:0] slave0_rx_data;
    logic [DATA_WIDTH-1:0] slave1_rx_data;
    logic [DATA_WIDTH-1:0] slave2_rx_data;

    logic slave0_rx_valid;
    logic slave1_rx_valid;
    logic slave2_rx_valid;

    logic slave0_active;
    logic slave1_active;
    logic slave2_active;

    // --------------------------------------------------------
    // Monitor/counters
    // --------------------------------------------------------
    integer checks;
    integer failures;

    integer cs_assert_count;
    integer sclk_rise_count;
    integer sclk_fall_count;

    logic [FRAME_WIDTH-1:0] monitored_mosi_frame;
    logic [FRAME_WIDTH-1:0] monitored_miso_frame;
    integer monitored_bits;

    // --------------------------------------------------------
    // Master
    // --------------------------------------------------------
    spi_daisy_chain_master #(
        .NUM_SLAVES (NUM_SLAVES),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_master (
        .clk       (clk),
        .rst       (rst),

        .start     (start),
        .tx_data_i (tx_data),
        .clk_div_i (clk_div_i),

        .miso_i    (miso),

        .sclk_o    (sclk),
        .mosi_o    (mosi),
        .cs_n_o    (cs_n),

        .rx_data_o (master_rx_data),

        .busy_o    (master_busy),
        .done_o    (master_done)
    );

    // --------------------------------------------------------
    // Slave 0: nearest to master
    // --------------------------------------------------------
    spi_daisy_chain_slave #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_slave0 (
        .clk             (clk),
        .rst             (rst),

        .parallel_load_i (slave0_preload),

        .sclk_i          (sclk),
        .cs_n_i          (cs_n),
        .sdi_i           (mosi),

        .sdo_o           (slave0_sdo),

        .rx_data_o       (slave0_rx_data),
        .rx_valid_o      (slave0_rx_valid),
        .active_o        (slave0_active)
    );

    // --------------------------------------------------------
    // Slave 1: middle
    // --------------------------------------------------------
    spi_daisy_chain_slave #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_slave1 (
        .clk             (clk),
        .rst             (rst),

        .parallel_load_i (slave1_preload),

        .sclk_i          (sclk),
        .cs_n_i          (cs_n),
        .sdi_i           (slave0_sdo),

        .sdo_o           (slave1_sdo),

        .rx_data_o       (slave1_rx_data),
        .rx_valid_o      (slave1_rx_valid),
        .active_o        (slave1_active)
    );

    // --------------------------------------------------------
    // Slave 2: farthest from master
    // --------------------------------------------------------
    spi_daisy_chain_slave #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_slave2 (
        .clk             (clk),
        .rst             (rst),

        .parallel_load_i (slave2_preload),

        .sclk_i          (sclk),
        .cs_n_i          (cs_n),
        .sdi_i           (slave1_sdo),

        .sdo_o           (slave2_sdo),

        .rx_data_o       (slave2_rx_data),
        .rx_valid_o      (slave2_rx_valid),
        .active_o        (slave2_active)
    );

    assign miso = slave2_sdo;

    // --------------------------------------------------------
    // 100 MHz system clock
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --------------------------------------------------------
    // Daisy-chain transaction monitor
    //
    // Both MOSI and MISO are sampled at Mode 0 rising edges.
    // --------------------------------------------------------
    always @(negedge cs_n) begin
        cs_assert_count     = cs_assert_count + 1;
        sclk_rise_count     = 0;
        sclk_fall_count     = 0;
        monitored_bits      = 0;
        monitored_mosi_frame = '0;
        monitored_miso_frame = '0;
    end

    always @(posedge sclk) begin
        if (!cs_n) begin
            sclk_rise_count = sclk_rise_count + 1;
            monitored_bits  = monitored_bits + 1;

            monitored_mosi_frame = {
                monitored_mosi_frame[FRAME_WIDTH-2:0],
                mosi
            };

            monitored_miso_frame = {
                monitored_miso_frame[FRAME_WIDTH-2:0],
                miso
            };
        end
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
    // Reset
    // --------------------------------------------------------
    task automatic apply_reset;
        begin
            @(negedge clk);

            rst            = 1'b1;
            start          = 1'b0;
            tx_data        = '0;
            clk_div_i      = CLK_DIV;

            slave0_preload = 8'h00;
            slave1_preload = 8'h00;
            slave2_preload = 8'h00;

            repeat (4) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            repeat (4) @(posedge clk);
            #1;
        end
    endtask

    // --------------------------------------------------------
    // Launch one full daisy-chain transaction
    // --------------------------------------------------------
    task automatic launch_transaction;
        begin
            @(negedge clk);

            tx_data        = MASTER_TX;
            clk_div_i      = CLK_DIV;

            slave0_preload = 8'h3C;
            slave1_preload = 8'hA5;
            slave2_preload = 8'hC3;

            start = 1'b1;

            @(posedge clk);
            #1;

            check(
                master_busy == 1'b1,
                "Master asserts busy after start"
            );

            check(
                cs_n == 1'b0,
                "Shared CS_n is asserted low"
            );

            check(
                sclk == 1'b0,
                "SCLK begins at Mode 0 idle low"
            );

            check(
                mosi == MASTER_TX[FRAME_WIDTH-1],
                "Master preloads first MOSI bit before first rising edge"
            );

            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // Wait for master completion and delayed slave commits
    // --------------------------------------------------------
    task automatic wait_for_completion;
        integer timeout;
        logic done_seen;

        begin
            timeout   = 0;
            done_seen = 1'b0;

            while (
                !(
                    done_seen &&
                    slave0_rx_valid &&
                    slave1_rx_valid &&
                    slave2_rx_valid
                ) &&
                (timeout < 20000)
            ) begin
                @(posedge clk);
                #1;

                if (master_done)
                    done_seen = 1'b1;

                timeout = timeout + 1;
            end

            check(
                done_seen == 1'b1,
                "Master completes transaction and pulses done"
            );

            check(
                slave0_rx_valid == 1'b1,
                "Slave 0 commits received byte"
            );

            check(
                slave1_rx_valid == 1'b1,
                "Slave 1 commits received byte"
            );

            check(
                slave2_rx_valid == 1'b1,
                "Slave 2 commits received byte"
            );
        end
    endtask

    // --------------------------------------------------------
    // Global watchdog
    // --------------------------------------------------------
    initial begin
        #2_000_000;
        $fatal(1, "Global timeout: daisy-chain testbench did not finish.");
    end

    // --------------------------------------------------------
    // Main test
    // --------------------------------------------------------
    initial begin
        checks          = 0;
        failures        = 0;
        cs_assert_count = 0;
        sclk_rise_count = 0;
        sclk_fall_count = 0;
        monitored_bits  = 0;

        $display("\n========== TEST 1: RESET ==========");
        apply_reset();

        check(cs_n == 1'b1, "CS_n resets high");
        check(sclk == 1'b0, "SCLK resets low");
        check(mosi == 1'b0, "MOSI resets low");
        check(master_busy == 1'b0, "Master busy resets low");
        check(master_done == 1'b0, "Master done resets low");

        check(slave0_rx_valid == 1'b0, "Slave 0 RX valid resets low");
        check(slave1_rx_valid == 1'b0, "Slave 1 RX valid resets low");
        check(slave2_rx_valid == 1'b0, "Slave 2 RX valid resets low");

        $display("\n========== TEST 2: THREE-SLAVE DAISY CHAIN ==========");

        launch_transaction();
        wait_for_completion();

        // ----------------------------------------------------
        // Bus/frame checks
        // ----------------------------------------------------
        check(
            cs_assert_count == 1,
            "Exactly one shared CS_n assertion occurs"
        );

        check(
            sclk_rise_count == FRAME_WIDTH,
            "Master generates 24 SCLK rising edges"
        );

        check(
            sclk_fall_count == FRAME_WIDTH,
            "Master generates 24 SCLK falling edges"
        );

        check(
            monitored_bits == FRAME_WIDTH,
            "Monitor samples 24 serial bits"
        );

        check(
            monitored_mosi_frame == MASTER_TX,
            "MOSI stream matches complete master transmit frame"
        );

        check(
            monitored_miso_frame == EXPECTED_MASTER_RX,
            "MISO stream returns preload bytes in chain order"
        );

        check(
            master_rx_data == EXPECTED_MASTER_RX,
            "Master RX data matches expected daisy-chain return frame"
        );

        check(
            cs_n == 1'b1,
            "CS_n releases after the complete 24-clock frame"
        );

        check(
            sclk == 1'b0,
            "SCLK returns to Mode 0 idle level"
        );

        check(
            master_busy == 1'b0,
            "Master clears busy after completion"
        );

        // ----------------------------------------------------
        // Forward-path mapping checks
        // ----------------------------------------------------
        check(
            slave0_rx_data == 8'h96,
            "Nearest Slave 0 receives final byte 0x96"
        );

        check(
            slave1_rx_data == 8'h5A,
            "Middle Slave 1 receives middle byte 0x5A"
        );

        check(
            slave2_rx_data == 8'hA5,
            "Farthest Slave 2 receives first byte 0xA5"
        );

        check(
            slave0_active == 1'b0 &&
            slave1_active == 1'b0 &&
            slave2_active == 1'b0,
            "All slaves leave active state after CS_n rises"
        );

        @(posedge clk);
        #1;

        check(
            master_done == 1'b0,
            "Master done is one clock wide"
        );

        $display("\n========================================");

        if (failures == 0)
            $display(
                "ALL SPI DAISY-CHAIN TESTS PASSED. Checks: %0d",
                checks
            );
        else
            $display(
                "SPI DAISY-CHAIN TESTS FAILED. Failures: %0d / %0d",
                failures,
                checks
            );

        $display("========================================\n");

        #100;
        $finish;
    end

endmodule

