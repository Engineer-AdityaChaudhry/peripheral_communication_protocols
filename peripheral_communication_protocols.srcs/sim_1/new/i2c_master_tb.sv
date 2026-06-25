`timescale 1ns / 1ps

module i2c_master_tb;

    localparam int unsigned CLK_PERIOD = 10;

    // 100 MHz system clock / (2 * 4) = 12.5 MHz SCL.
    // Kept fast so simulation finishes quickly.
    localparam logic [15:0] SCL_HALF_PERIOD = 16'd4;

    localparam logic [6:0] TEST_ADDR = 7'h50;
    localparam logic [7:0] TEST_DATA = 8'hA5;

    logic clk;
    logic rst;

    logic        start;
    logic [6:0]  addr_i;
    logic        rw_i;
    logic [7:0]  tx_data_i;
    logic [15:0] scl_half_period_i;

    tri scl;
    tri sda;

    logic [7:0] rx_data;
    logic       busy;
    logic       done;
    logic       ack_error;

    // Lightweight behavioral ACK responder.
    logic       ack_drive_low;
    logic [7:0] observed_address;
    logic [7:0] observed_data;

    integer checks;
    integer failures;

    integer start_count;
    integer stop_count;
    integer scl_rise_count;
    logic   bus_active;

    // Pull-up resistors required by the open-drain bus.
    pullup(scl);
    pullup(sda);

    // Testbench responder can only pull SDA low for ACK.
    assign sda = ack_drive_low ? 1'b0 : 1'bz;

    i2c_master u_dut (
        .clk               (clk),
        .rst               (rst),

        .start             (start),
        .addr_i            (addr_i),
        .rw_i              (rw_i),
        .tx_data_i         (tx_data_i),
        .scl_half_period_i (scl_half_period_i),

        .scl               (scl),
        .sda               (sda),

        .rx_data_o         (rx_data),
        .busy_o            (busy),
        .done_o            (done),
        .ack_error_o       (ack_error)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --------------------------------------------------------
    // Observe START and STOP conditions.
    // --------------------------------------------------------
    always @(negedge sda) begin
        if (!rst && (scl === 1'b1)) begin
            start_count = start_count + 1;
            bus_active  = 1'b1;
        end
    end

    always @(posedge sda) begin
        if (!rst && (scl === 1'b1)) begin
            stop_count = stop_count + 1;
            bus_active = 1'b0;
        end
    end

    // Includes the 18 protocol clocks plus one SCL rise used
    // to create the STOP condition.
    always @(posedge scl) begin
        if (bus_active)
            scl_rise_count = scl_rise_count + 1;
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

    task automatic wait_for_start;
        logic found;

        begin
            found = 1'b0;

            while (!found) begin
                @(negedge sda);

                if (scl === 1'b1)
                    found = 1'b1;
            end
        end
    endtask

    task automatic receive_byte_and_ack(
        output logic [7:0] byte_o
    );
        integer i;

        begin
            byte_o = 8'h00;

            // Capture eight bits on SCL rising edges.
            for (i = 7; i >= 0; i = i - 1) begin
                @(posedge scl);
                #1;
                byte_o[i] = sda;
            end

            // ACK is driven during the ninth SCL clock.
            @(negedge scl);
            ack_drive_low = 1'b1;

            @(posedge scl);
            @(negedge scl);

            ack_drive_low = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // Minimal behavioral responder for this master-only test.
    // It acknowledges the address byte and write-data byte.
    // --------------------------------------------------------
    initial begin
        ack_drive_low = 1'b0;

        wait_for_start();

        receive_byte_and_ack(observed_address);
        receive_byte_and_ack(observed_data);
    end

    initial begin
        checks          = 0;
        failures        = 0;
        start_count     = 0;
        stop_count      = 0;
        scl_rise_count  = 0;
        bus_active      = 1'b0;

        rst               = 1'b1;
        start             = 1'b0;
        addr_i            = 7'h00;
        rw_i              = 1'b0;
        tx_data_i         = 8'h00;
        scl_half_period_i = SCL_HALF_PERIOD;

        repeat (4) @(posedge clk);

        @(negedge clk);
        rst = 1'b0;

        repeat (3) @(posedge clk);
        #1;

        $display("\n========== TEST 1: RESET ==========");

        check(scl === 1'b1, "SCL is released high in idle");
        check(sda === 1'b1, "SDA is released high in idle");
        check(busy === 1'b0, "Master busy resets low");
        check(done === 1'b0, "Master done resets low");
        check(ack_error === 1'b0, "ACK error resets low");

        $display("\n========== TEST 2: ONE-BYTE I2C WRITE ==========");

        start_count    = 0;
        stop_count     = 0;
        scl_rise_count = 0;

        @(negedge clk);
        addr_i    = TEST_ADDR;
        rw_i      = 1'b0;
        tx_data_i = TEST_DATA;
        start     = 1'b1;

        @(posedge clk);
        #1;

        check(busy === 1'b1, "Master accepts write request");
        check(scl === 1'b1, "SCL remains high before START");

        @(negedge clk);
        start = 1'b0;

        begin : wait_for_done
            integer timeout;
            logic done_seen;

            timeout   = 0;
            done_seen = 1'b0;

            while (!done_seen && (timeout < 5000)) begin
                @(posedge clk);
                #1;

                if (done)
                    done_seen = 1'b1;

                timeout = timeout + 1;
            end

            check(done_seen === 1'b1,
                  "Master completes transaction and pulses done");
        end

        check(start_count == 1,
              "Master generates exactly one START condition");

        check(stop_count == 1,
              "Master generates exactly one STOP condition");

        check(observed_address == {TEST_ADDR, 1'b0},
              "Master sends 7-bit address followed by write bit");

        check(observed_data == TEST_DATA,
              "Master sends expected write data byte");

        check(ack_error === 1'b0,
              "Master detects ACK after address and data bytes");

        check(scl_rise_count == 19,
              "Bus shows 18 transfer clocks plus STOP SCL rise");

        check(scl === 1'b1,
              "SCL returns high after STOP");

        check(sda === 1'b1,
              "SDA returns high after STOP");

        check(busy === 1'b0,
              "Master clears busy after STOP");

        @(posedge clk);
        #1;

        check(done === 1'b0,
              "Done is a one-clock pulse");

        $display("\n========================================");

        if (failures == 0)
            $display("ALL I2C MASTER TESTS PASSED. Checks: %0d",
                     checks);
        else
            $display("I2C MASTER TESTS FAILED. Failures: %0d / %0d",
                     failures, checks);

        $display("========================================\n");

        #100;
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "Global timeout: I2C master testbench did not finish.");
    end

endmodule

