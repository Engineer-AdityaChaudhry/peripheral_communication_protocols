`timescale 1ns / 1ps

module i2c_cs_tb;

    localparam logic [6:0]  SLAVE_ADDR      = 7'h50;
    localparam logic [6:0]  WRONG_ADDR      = 7'h51;
    localparam logic [15:0] SCL_HALF_PERIOD = 16'd20;

    logic clk;
    logic rst;

    logic        start;
    logic [6:0]  addr_i;
    logic        rw_i;
    logic [7:0]  tx_data_i;
    logic [15:0] scl_half_period_i;

    logic stretch_enable;

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
    logic       slave_stretch_active;

    integer checks;
    integer failures;

    integer start_count;
    integer stop_count;
    integer write_valid_count;
    integer stretch_low_samples;

    integer starts_before;
    integer stops_before;
    integer writes_before;

    // I2C requires pull-up resistors on both open-drain lines.
    pullup(scl);
    pullup(sda);

    i2c_cs_master u_master (
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

    i2c_cs_slave #(
        .SLAVE_ADDR(SLAVE_ADDR)
    ) u_slave (
        .clk              (clk),
        .rst              (rst),

        .stretch_enable_i (stretch_enable),

        .scl              (scl),
        .sda              (sda),

        .data_reg_o       (slave_data_reg),
        .write_valid_o    (slave_write_valid),
        .selected_o       (slave_selected),
        .read_nack_o      (slave_read_nack),
        .stretch_active_o (slave_stretch_active)
    );

    // 100 MHz system clock.
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Monitor protocol START and STOP conditions.
    always @(negedge sda) begin
        if (!rst && (scl === 1'b1))
            start_count = start_count + 1;
    end

    always @(posedge sda) begin
        if (!rst && (scl === 1'b1))
            stop_count = stop_count + 1;
    end

    always @(posedge slave_write_valid) begin
        if (!rst)
            write_valid_count = write_valid_count + 1;
    end

    // Count time where the slave actively holds SCL low.
    always @(posedge clk) begin
        if (rst)
            stretch_low_samples = 0;
        else if (slave_stretch_active && (scl === 1'b0))
            stretch_low_samples = stretch_low_samples + 1;
    end

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

    task automatic wait_for_done(
        input string transaction_name
    );
        integer timeout;
        logic done_seen;

        begin
            timeout   = 0;
            done_seen = 1'b0;

            while (!done_seen && (timeout < 30000)) begin
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

    task automatic wait_for_stretch_start;
        integer timeout;
        logic stretch_seen;

        begin
            timeout      = 0;
            stretch_seen = 1'b0;

            while (!stretch_seen && (timeout < 30000)) begin
                @(posedge clk);
                #1;

                if (slave_stretch_active)
                    stretch_seen = 1'b1;

                timeout = timeout + 1;
            end

            check(stretch_seen,
                  "Slave enters clock-stretch state");
        end
    endtask

    initial begin
        checks              = 0;
        failures            = 0;

        start_count         = 0;
        stop_count          = 0;
        write_valid_count   = 0;
        stretch_low_samples = 0;

        rst                 = 1'b1;
        start               = 1'b0;
        addr_i              = 7'h00;
        rw_i                = 1'b0;
        tx_data_i           = 8'h00;
        scl_half_period_i   = SCL_HALF_PERIOD;
        stretch_enable      = 1'b0;

        repeat (5) @(posedge clk);

        @(negedge clk);
        rst = 1'b0;

        repeat (5) @(posedge clk);
        #1;

        $display("\n========== TEST 1: RESET / IDLE BUS ==========");

        check(scl === 1'b1, "SCL is high while idle");
        check(sda === 1'b1, "SDA is high while idle");
        check(master_busy === 1'b0, "Master busy resets low");
        check(master_ack_error === 1'b0, "Master ACK error resets low");
        check(slave_data_reg === 8'h00, "Slave data register resets to 00");
        check(slave_stretch_active === 1'b0,
              "Slave stretch flag resets low");

        // ====================================================
        // TEST 2: Normal write, no clock stretching.
        // ====================================================
        $display("\n========== TEST 2: NORMAL WRITE ==========");

        starts_before = start_count;
        stops_before  = stop_count;
        writes_before = write_valid_count;

        stretch_enable = 1'b0;
        launch_transaction(SLAVE_ADDR, 1'b0, 8'hA5);

        @(posedge clk);
        #1;
        check(master_busy === 1'b1,
              "Normal write makes master busy");

        wait_for_done("Normal write");

        check(master_ack_error === 1'b0,
              "Normal write receives ACKs");

        check(slave_data_reg === 8'hA5,
              "Normal write stores A5");

        check(write_valid_count == (writes_before + 1),
              "Normal write creates one slave write-valid event");

        check(start_count == (starts_before + 1),
              "Normal write creates one START");

        check(stop_count == (stops_before + 1),
              "Normal write creates one STOP");

        // ====================================================
        // TEST 3: Stretched write.
        // Slave holds SCL low after address reception.
        // ====================================================
        $display("\n========== TEST 3: CLOCK-STRETCHED WRITE ==========");

        starts_before       = start_count;
        stops_before        = stop_count;
        writes_before       = write_valid_count;
        stretch_low_samples = 0;

        stretch_enable = 1'b1;
        launch_transaction(SLAVE_ADDR, 1'b0, 8'h3C);

        wait_for_stretch_start();

        check(slave_stretch_active === 1'b1,
              "Slave reports active clock stretch");

        check(scl === 1'b0,
              "Slave holds shared SCL low during stretch");

        repeat (120) @(posedge clk);

        check(master_busy === 1'b1,
              "Master remains busy while SCL is stretched");

        check(slave_stretch_active === 1'b1,
              "Slave remains in stretch state while request is high");

        check(stretch_low_samples >= 100,
              "SCL stays low for an extended stretch interval");

        @(negedge clk);
        stretch_enable = 1'b0;

        wait_for_done("Clock-stretched write");

        check(master_ack_error === 1'b0,
              "Clock-stretched write still receives ACKs");

        check(slave_data_reg === 8'h3C,
              "Clock-stretched write stores 3C");

        check(write_valid_count == (writes_before + 1),
              "Clock-stretched write creates one write-valid event");

        check(start_count == (starts_before + 1),
              "Clock-stretched write creates one START");

        check(stop_count == (stops_before + 1),
              "Clock-stretched write creates one STOP");

        check(scl === 1'b1,
              "SCL returns high after stretched transaction");

        check(sda === 1'b1,
              "SDA returns high after stretched transaction");

        // ====================================================
        // TEST 4: Read back data written during stretched write.
        // ====================================================
        $display("\n========== TEST 4: READ AFTER STRETCHED WRITE ==========");

        starts_before = start_count;
        stops_before  = stop_count;

        launch_transaction(SLAVE_ADDR, 1'b1, 8'h00);

        wait_for_done("Read after stretched write");

        check(master_ack_error === 1'b0,
              "Read request receives address ACK");

        check(master_rx_data === 8'h3C,
              "Master reads back stored byte 3C");

        check(slave_read_nack === 1'b1,
              "Slave detects master's final read NACK");

        check(start_count == (starts_before + 1),
              "Read creates one START");

        check(stop_count == (stops_before + 1),
              "Read creates one STOP");

        // ====================================================
        // TEST 5: Wrong address must receive NACK.
        // ====================================================
        $display("\n========== TEST 5: WRONG ADDRESS ==========");

        starts_before = start_count;
        stops_before  = stop_count;
        writes_before = write_valid_count;

        launch_transaction(WRONG_ADDR, 1'b0, 8'h55);

        wait_for_done("Wrong-address write");

        check(master_ack_error === 1'b1,
              "Master reports NACK for wrong address");

        check(slave_data_reg === 8'h3C,
              "Wrong-address write does not modify slave data");

        check(write_valid_count == writes_before,
              "Wrong-address write creates no slave write event");

        check(start_count == (starts_before + 1),
              "Wrong-address transaction creates one START");

        check(stop_count == (stops_before + 1),
              "Wrong-address transaction creates one STOP");

        check(master_busy === 1'b0,
              "Master clears busy after final STOP");

        check(scl === 1'b1,
              "SCL is high at final idle");

        check(sda === 1'b1,
              "SDA is high at final idle");

        $display("\n========================================");

        if (failures == 0)
            $display("ALL I2C CLOCK-STRETCHING TESTS PASSED. Checks: %0d",
                     checks);
        else
            $display("I2C CLOCK-STRETCHING TESTS FAILED. Failures: %0d / %0d",
                     failures, checks);

        $display("========================================\n");

        #100;
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "Global timeout: i2c_cs_tb did not finish.");
    end

endmodule

