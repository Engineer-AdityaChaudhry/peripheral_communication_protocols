`timescale 1ns / 1ps

// ============================================================
// Behavioral SPI Mode 0 slave model
//
// CPOL = 0, CPHA = 0
// - MISO is valid before each rising SCLK edge.
// - Slave samples MOSI on rising SCLK edge.
// - Slave changes MISO on falling SCLK edge.
// ============================================================
module spi_slave_mode0_model #(
    parameter int unsigned DATA_WIDTH = 8
) (
    input  logic                  cs_n,
    input  logic                  sclk,
    input  logic                  mosi,

    input  logic [DATA_WIDTH-1:0] tx_data,

    output wire                   miso,
    output logic [DATA_WIDTH-1:0] rx_data,
    output logic                  rx_valid
);

    logic [DATA_WIDTH-1:0] tx_shift;
    logic [DATA_WIDTH-1:0] rx_shift;
    logic                  miso_drive;

    integer sampled_bits;

    // The slave releases MISO when it is not selected.
    assign miso = (!cs_n) ? miso_drive : 1'bz;

    // Begin a new transaction when CS_n falls.
    always @(negedge cs_n) begin
        tx_shift     = tx_data;
        rx_shift     = '0;
        sampled_bits = 0;
        rx_valid     = 1'b0;

        // Mode 0: first MISO bit must be valid before first SCLK rise.
        miso_drive   = tx_data[DATA_WIDTH-1];
    end

    // Slave samples MOSI on rising edges.
    always @(posedge sclk) begin
        if (!cs_n) begin
            rx_shift = {rx_shift[DATA_WIDTH-2:0], mosi};

            if (sampled_bits == DATA_WIDTH-1) begin
                rx_data  = {rx_shift[DATA_WIDTH-2:0], mosi};
                rx_valid = 1'b1;
            end

            sampled_bits = sampled_bits + 1;
        end
    end

    // Slave changes MISO on falling edges.
    always @(negedge sclk) begin
        if (!cs_n && (sampled_bits < DATA_WIDTH)) begin
            tx_shift   = {tx_shift[DATA_WIDTH-2:0], 1'b0};
            miso_drive = tx_shift[DATA_WIDTH-2];
        end
    end

endmodule


// ============================================================
// Self-checking SPI Master Mode 0 Testbench
// ============================================================
module spi_master_tb;

    localparam int unsigned DATA_WIDTH = 8;

    logic                  clk;
    logic                  rst;

    logic                  start;
    logic [DATA_WIDTH-1:0] tx_data;
    logic [15:0]           clk_div_i;

    logic                  sclk;
    logic                  mosi;
    logic                  cs_n;

    tri                    miso;

    logic [DATA_WIDTH-1:0] rx_data;
    logic                  busy;
    logic                  done;

    // Behavioral-slave control and observed data.
    logic [DATA_WIDTH-1:0] slave_tx_data;
    logic [DATA_WIDTH-1:0] slave_rx_data;
    logic                  slave_rx_valid;

    integer checks;
    integer failures;

    integer sclk_rise_count;
    integer sclk_fall_count;
    integer cs_assert_count;

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------
    spi_master #(
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (
        .clk       (clk),
        .rst       (rst),

        .start     (start),
        .tx_data   (tx_data),
        .clk_div_i (clk_div_i),

        .miso      (miso),

        .sclk      (sclk),
        .mosi      (mosi),
        .cs_n      (cs_n),

        .rx_data   (rx_data),
        .busy      (busy),
        .done      (done)
    );

    // --------------------------------------------------------
    // Behavioral SPI slave
    // --------------------------------------------------------
    spi_slave_mode0_model #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_slave (
        .cs_n     (cs_n),
        .sclk     (sclk),
        .mosi     (mosi),

        .tx_data  (slave_tx_data),

        .miso     (miso),
        .rx_data  (slave_rx_data),
        .rx_valid (slave_rx_valid)
    );

    // --------------------------------------------------------
    // 100 MHz system clock
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // Transaction monitors
    // --------------------------------------------------------
    always @(negedge cs_n)
        cs_assert_count = cs_assert_count + 1;

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

            rst           = 1'b1;
            start         = 1'b0;
            tx_data       = 8'h00;
            slave_tx_data = 8'h00;
            clk_div_i     = 16'd4;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            repeat (2) @(posedge clk);
            #1;
        end
    endtask

    // --------------------------------------------------------
    // Start a transfer
    // --------------------------------------------------------
    task automatic start_transfer(
        input logic [DATA_WIDTH-1:0] master_data,
        input logic [DATA_WIDTH-1:0] slave_data,
        input logic [15:0]           divider,
        input string                 test_name
    );
        begin
            slave_tx_data = slave_data;

            @(negedge clk);

            tx_data   = master_data;
            clk_div_i = divider;
            start     = 1'b1;

            @(posedge clk);
            #1;

            check(busy == 1'b1,
                  $sformatf("%s asserts busy after start", test_name));

            check(cs_n == 1'b0,
                  $sformatf("%s asserts CS_n low", test_name));

            check(sclk == 1'b0,
                  $sformatf("%s keeps SCLK low at Mode 0 start", test_name));

            check(mosi == master_data[DATA_WIDTH-1],
                  $sformatf("%s places MOSI MSB before first clock rise",
                            test_name));

            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // Wait for done pulse
    // --------------------------------------------------------
    task automatic wait_for_done(
        input string test_name
    );
        integer timeout;

        begin
            timeout = 0;

            while ((done !== 1'b1) && (timeout < 5000)) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end

            check(done === 1'b1,
                  $sformatf("%s completes transfer and asserts done",
                            test_name));
        end
    endtask

    // --------------------------------------------------------
    // Check one full-duplex transaction
    // --------------------------------------------------------
    task automatic check_transfer(
        input logic [DATA_WIDTH-1:0] expected_master_rx,
        input logic [DATA_WIDTH-1:0] expected_slave_rx,
        input integer                expected_divider,
        input string                 test_name
    );
        time rising_time;
        time falling_time;

        begin
            // Verify a Mode 0 half-period:
            // rising edge to following falling edge.
            @(posedge sclk);
            rising_time = $time;

            @(negedge sclk);
            falling_time = $time;

            check(
                (falling_time - rising_time) == (expected_divider * 10),
                $sformatf("%s SCLK half-period matches divider", test_name)
            );

            wait_for_done(test_name);
            #1;

            check(
                rx_data == expected_master_rx,
                $sformatf("%s master receives 0x%02h from slave",
                          test_name, expected_master_rx)
            );

            check(
                slave_rx_valid == 1'b1,
                $sformatf("%s slave receives a complete byte", test_name)
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
                cs_n == 1'b1,
                $sformatf("%s releases CS_n after transfer", test_name)
            );

            check(
                sclk == 1'b0,
                $sformatf("%s returns SCLK to its Mode 0 idle-low state",
                          test_name)
            );

            check(
                busy == 1'b0,
                $sformatf("%s deasserts busy after transfer", test_name)
            );

            check(
                miso === 1'bz,
                $sformatf("%s slave releases MISO after CS_n rises",
                          test_name)
            );

            @(posedge clk);
            #1;

            check(
                done == 1'b0,
                $sformatf("%s done is a one-clock pulse", test_name)
            );
        end
    endtask

    // --------------------------------------------------------
    // Global timeout
    // --------------------------------------------------------
    initial begin
        #100_000;
        $fatal(1, "Global timeout: SPI master testbench did not finish.");
    end

    // --------------------------------------------------------
    // Main test sequence
    // --------------------------------------------------------
    initial begin
        checks           = 0;
        failures         = 0;
        sclk_rise_count  = 0;
        sclk_fall_count  = 0;
        cs_assert_count  = 0;

        // ====================================================
        // TEST 1: Reset and idle behavior
        // ====================================================
        $display("\n========== TEST 1: RESET / IDLE ==========");
        apply_reset();

        check(sclk == 1'b0, "SCLK resets low for SPI Mode 0");
        check(cs_n == 1'b1, "CS_n resets high");
        check(mosi == 1'b0, "MOSI resets low");
        check(busy == 1'b0, "busy resets low");
        check(done == 1'b0, "done resets low");
        check(miso === 1'bz, "Unselected slave releases MISO");

        // ====================================================
        // TEST 2: Full-duplex transfer, divider = 4
        //
        // Master sends A5 and should receive BA.
        // Slave should receive A5.
        // ====================================================
        $display("\n========== TEST 2: MODE 0 FULL-DUPLEX ==========");

        sclk_rise_count = 0;
        sclk_fall_count = 0;
        cs_assert_count = 0;

        start_transfer(8'hA5, 8'hBA, 16'd4,
                       "Mode 0 transfer A5 <-> BA");

        check_transfer(8'hBA, 8'hA5, 4,
                       "Mode 0 transfer A5 <-> BA");

        check(cs_assert_count == 1,
              "One transfer creates exactly one CS_n assertion");

        // ====================================================
        // TEST 3: Second transfer, divider = 2
        //
        // Confirms a new start pulse works after completion.
        // ====================================================
        $display("\n========== TEST 3: SECOND TRANSFER ==========");

        sclk_rise_count = 0;
        sclk_fall_count = 0;
        cs_assert_count = 0;

        start_transfer(8'h3C, 8'hC3, 16'd2,
                       "Second transfer 3C <-> C3");

        check_transfer(8'hC3, 8'h3C, 2,
                       "Second transfer 3C <-> C3");

        check(cs_assert_count == 1,
              "Second transaction creates one CS_n assertion");

        // ====================================================
        // TEST 4: Start request while busy is ignored
        // ====================================================
        $display("\n========== TEST 4: START WHILE BUSY ==========");

        sclk_rise_count = 0;
        sclk_fall_count = 0;
        cs_assert_count = 0;

        start_transfer(8'h96, 8'h69, 16'd3,
                       "Busy-protection transfer 96 <-> 69");

        // Attempt an extra start pulse while first transfer runs.
        @(negedge clk);
        tx_data = 8'hFF;
        start   = 1'b1;

        @(posedge clk);
        #1;

        check(busy == 1'b1,
              "Master remains busy during extra start request");

        @(negedge clk);
        start = 1'b0;

        check_transfer(8'h69, 8'h96, 3,
                       "Busy-protection transfer 96 <-> 69");

        check(cs_assert_count == 1,
              "Start request while busy does not launch a second transfer");

        // ====================================================
        // TEST 5: clk_div_i = 0 protection
        //
        // Design treats zero as divider value one.
        // ====================================================
        $display("\n========== TEST 5: ZERO DIVIDER PROTECTION ==========");

        sclk_rise_count = 0;
        sclk_fall_count = 0;
        cs_assert_count = 0;

        start_transfer(8'h0F, 8'hF0, 16'd0,
                       "Zero-divider transfer 0F <-> F0");

        check_transfer(8'hF0, 8'h0F, 1,
                       "Zero-divider transfer 0F <-> F0");

        // ====================================================
        // Final result
        // ====================================================
        $display("\n========================================");

        if (failures == 0)
            $display("ALL SPI MASTER TESTS PASSED. Checks: %0d", checks);
        else
            $display("SPI MASTER TESTS FAILED. Failures: %0d / %0d",
                     failures, checks);

        $display("========================================\n");

        #50;
        $finish;
    end

endmodule

