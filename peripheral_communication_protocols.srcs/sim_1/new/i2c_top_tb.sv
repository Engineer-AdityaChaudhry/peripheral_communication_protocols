`timescale 1ns / 1ps

module i2c_tb;

    localparam logic [6:0]  SLAVE_ADDR      = 7'h50;
    localparam logic [6:0]  WRONG_ADDR      = 7'h51;
    localparam logic [15:0] SCL_HALF_PERIOD = 16'd16;

    logic clk;
    logic rst;

    logic        start;
    logic [6:0]  addr_i;
    logic        rw_i;
    logic [7:0]  tx_data_i;
    logic [15:0] scl_half_period_i;

    tri scl;
    tri sda;

    logic [7:0] master_rx_data;
    logic       master_busy;
    logic       master_done;
    logic       master_ack_error;

    logic [7:0] slave_data_reg;
    logic       slave_write_valid;
    logic       slave_selected;
    logic       slave_read_nack;

    integer checks;
    integer failures;

    integer start_count;
    integer stop_count;
    integer write_valid_count;

    // --------------------------------------------------------
    // I2C pull-up resistors.
    // Master and slave only pull lines low; these pullups make
    // released lines read as logic 1.
    // --------------------------------------------------------
    pullup(scl);
    pullup(sda);

    // --------------------------------------------------------
    // DUT: I2C Master
    // --------------------------------------------------------
    i2c_master u_master (
        .clk               (clk),
        .rst               (rst),

        .start             (start),
        .addr_i            (addr_i),
        .rw_i              (rw_i),
        .tx_data_i         (tx_data_i),
        .scl_half_period_i (scl_half_period_i),

        .scl               (scl),
        .sda               (sda),

        .rx_data_o         (master_rx_data),
        .busy_o            (master_busy),
        .done_o            (master_done),
        .ack_error_o       (master_ack_error)
    );

    // --------------------------------------------------------
    // DUT: I2C Slave
    // --------------------------------------------------------
    i2c_slave #(
        .SLAVE_ADDR(SLAVE_ADDR)
    ) u_slave (
        .clk           (clk),
        .rst           (rst),

        .scl           (scl),
        .sda           (sda),

        .data_reg_o    (slave_data_reg),
        .write_valid_o (slave_write_valid),
        .selected_o    (slave_selected),
        .read_nack_o   (slave_read_nack)
    );

    // --------------------------------------------------------
    // 100 MHz system clock
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // I2C START/STOP monitors
    // --------------------------------------------------------
    always @(negedge sda) begin
        if (!rst && (scl === 1'b1))
            start_count = start_count + 1;
    end

    always @(posedge sda) begin
        if (!rst && (scl === 1'b1))
            stop_count = stop_count + 1;
    end

    // Count completed slave writes.
    always @(posedge slave_write_valid) begin
        if (!rst)
            write_valid_count = write_valid_count + 1;
    end

    // --------------------------------------------------------
    // Self-checking utility
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
    // Send a one-cycle master start request.
    // --------------------------------------------------------
    task automatic launch_transaction(
        input logic [6:0] address,
        input logic       read_not_write,
        input logic [7:0] write_data
    );
        begin
            @(negedge clk);
            addr_i    = address;
            rw_i      = read_not_write;
            tx_data_i = write_data;
            start     = 1'b1;

            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // Wait for a master completion pulse.
    // --------------------------------------------------------
    task automatic wait_for_done(
        input string transaction_name
    );
        integer timeout;
        logic done_seen;

        begin
            timeout   = 0;
            done_seen = 1'b0;

            while (!done_seen && (timeout < 10000)) begin
                @(posedge clk);
                #1;

                if (master_done)
                    done_seen = 1'b1;

                timeout = timeout + 1;
            end

            check(done_seen,
                  {transaction_name, ": master completes transaction"});
        end
    endtask

    // --------------------------------------------------------
    // Main test sequence
    // --------------------------------------------------------
    initial begin
        integer starts_before;
        integer stops_before;
        integer writes_before;

        checks            = 0;
        failures          = 0;
        start_count       = 0;
        stop_count        = 0;
        write_valid_count = 0;

        rst               = 1'b1;
        start             = 1'b0;
        addr_i            = 7'h00;
        rw_i              = 1'b0;
        tx_data_i         = 8'h00;
        scl_half_period_i = SCL_HALF_PERIOD;

        repeat (5) @(posedge clk);

        @(negedge clk);
        rst = 1'b0;

        repeat (5) @(posedge clk);
        #1;

        $display("\n========== TEST 1: RESET / IDLE BUS ==========");

        check(scl === 1'b1, "SCL is high while bus is idle");
        check(sda === 1'b1, "SDA is high while bus is idle");
        check(master_busy === 1'b0, "Master busy is low after reset");
        check(master_done === 1'b0, "Master done is low after reset");
        check(master_ack_error === 1'b0, "Master ACK error is low after reset");
        check(slave_data_reg === 8'h00, "Slave data register resets to 00");

        // ====================================================
        // TEST 2: Successful write
        // START -> A0 -> ACK -> A5 -> ACK -> STOP
        // ====================================================
        $display("\n========== TEST 2: WRITE TO VALID SLAVE ==========");

        starts_before = start_count;
        stops_before  = stop_count;
        writes_before = write_valid_count;

        launch_transaction(SLAVE_ADDR, 1'b0, 8'hA5);

        @(posedge clk);
        #1;
        check(master_busy === 1'b1,
              "Write request makes master busy");

        wait_for_done("Valid write");

        check(master_ack_error === 1'b0,
              "Valid slave address and data receive ACKs");

        check(slave_data_reg === 8'hA5,
              "Slave stores written byte A5");

        check(write_valid_count == (writes_before + 1),
              "Slave produces one write-valid event");

        check(start_count == (starts_before + 1),
              "Write produces exactly one START");

        check(stop_count == (stops_before + 1),
              "Write produces exactly one STOP");

        check(scl === 1'b1,
              "SCL returns high after write STOP");

        check(sda === 1'b1,
              "SDA returns high after write STOP");

        check(master_busy === 1'b0,
              "Master clears busy after write");

        // ====================================================
        // TEST 3: Successful read
        // START -> A1 -> ACK -> slave sends A5
        //       -> master NACK -> STOP
        // ====================================================
        $display("\n========== TEST 3: READ FROM VALID SLAVE ==========");

        starts_before = start_count;
        stops_before  = stop_count;

        launch_transaction(SLAVE_ADDR, 1'b1, 8'h00);

        @(posedge clk);
        #1;
        check(master_busy === 1'b1,
              "Read request makes master busy");

        wait_for_done("Valid read");

        check(master_ack_error === 1'b0,
              "Slave ACKs valid read address");

        check(master_rx_data === 8'hA5,
              "Master receives stored slave byte A5");

        check(slave_data_reg === 8'hA5,
              "Read transaction preserves slave data register");

        check(slave_read_nack === 1'b1,
              "Slave detects master's final read NACK");

        check(start_count == (starts_before + 1),
              "Read produces exactly one START");

        check(stop_count == (stops_before + 1),
              "Read produces exactly one STOP");

        check(scl === 1'b1,
              "SCL returns high after read STOP");

        check(sda === 1'b1,
              "SDA returns high after read STOP");

        // ====================================================
        // TEST 4: Wrong address
        // Slave must not ACK and must not overwrite A5.
        // ====================================================
        $display("\n========== TEST 4: WRONG SLAVE ADDRESS ==========");

        starts_before = start_count;
        stops_before  = stop_count;
        writes_before = write_valid_count;

        launch_transaction(WRONG_ADDR, 1'b0, 8'h3C);

        wait_for_done("Invalid-address write");

        check(master_ack_error === 1'b1,
              "Master reports NACK for wrong slave address");

        check(slave_data_reg === 8'hA5,
              "Wrong-address transaction does not modify slave data");

        check(write_valid_count == writes_before,
              "Wrong-address transaction creates no slave write event");

        check(start_count == (starts_before + 1),
              "Wrong-address transfer still has one START");

        check(stop_count == (stops_before + 1),
              "Wrong-address transfer still ends with one STOP");

        check(master_busy === 1'b0,
              "Master clears busy after NACK and STOP");

        check(scl === 1'b1,
              "SCL is high after wrong-address STOP");

        check(sda === 1'b1,
              "SDA is high after wrong-address STOP");

        $display("\n========================================");

        if (failures == 0)
            $display("ALL I2C MASTER-SLAVE TESTS PASSED. Checks: %0d",
                     checks);
        else
            $display("I2C MASTER-SLAVE TESTS FAILED. Failures: %0d / %0d",
                     failures, checks);

        $display("========================================\n");

        #100;
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "Global timeout: i2c_tb did not finish.");
    end

endmodule

