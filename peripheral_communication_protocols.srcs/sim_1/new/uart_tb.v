`timescale 1ns / 1ps

module uart_tb;

    // ------------------------------------------------------------
    // UART parameters
    // ------------------------------------------------------------
    parameter CLK_FREQ  = 1000000;  // 1 MHz
    parameter BAUD_RATE = 9600;

    // 1 MHz clock = 1 us period = 1000 ns
    localparam CLK_HALF_PERIOD = 500;

    // Approximate UART bit time for waiting in testbench
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam BIT_PERIOD   = CLKS_PER_BIT * 1000; // ns

    // ------------------------------------------------------------
    // Testbench signals
    // ------------------------------------------------------------
    reg clk;
    reg rst;

    reg [7:0] dintx;
    reg       newd;

    wire tx;
    wire [7:0] doutrx;
    wire donetx;
    wire donerx;

    // TX is directly connected to RX for loopback verification
    wire rx;
    assign rx = tx;

    integer errors;

    // ------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------
    uart_top #(
        .clk_freq (CLK_FREQ),
        .baud_rate(BAUD_RATE)
    ) dut (
        .clk     (clk),
        .rst     (rst),
        .rx      (rx),
        .dintx   (dintx),
        .newd    (newd),
        .tx      (tx),
        .doutrx  (doutrx),
        .donetx  (donetx),
        .donerx  (donerx)
    );

    // ------------------------------------------------------------
    // 1 MHz clock generator
    // ------------------------------------------------------------
    always #CLK_HALF_PERIOD clk = ~clk;

    // ------------------------------------------------------------
    // Send one byte and verify loopback reception
    // ------------------------------------------------------------
    task send_byte;
        input [7:0] expected_data;
        begin
            // Wait until previous transmission is complete
            wait(donetx == 1'b0);

            dintx = expected_data;
            newd  = 1'b1;

            // Keep newd high long enough for transmitter to detect it
            #(2 * BIT_PERIOD);

            newd = 1'b0;

            // Wait for receiver completion
            @(posedge donerx);

            #1000; // Small delay for waveform clarity

            if (doutrx == expected_data) begin
                $display("PASS: Sent %h, received %h at time %0t",
                         expected_data, doutrx, $time);
            end
            else begin
                $display("ERROR: Sent %h, received %h at time %0t",
                         expected_data, doutrx, $time);
                errors = errors + 1;
            end

            // Gap between bytes
            #(2 * BIT_PERIOD);
        end
    endtask

    // ------------------------------------------------------------
    // Main test sequence
    // ------------------------------------------------------------
    initial begin
        clk    = 1'b0;
        rst    = 1'b1;
        dintx  = 8'h00;
        newd   = 1'b0;
        errors = 0;

        // Hold reset for several UART bit periods
        #(5 * BIT_PERIOD);
        rst = 1'b0;

        // Give DUT time to settle after reset
        #(2 * BIT_PERIOD);

        // Test data patterns
        send_byte(8'h55); // 01010101
        send_byte(8'hAA); // 10101010
        send_byte(8'h00);
        send_byte(8'hFF);
        send_byte(8'h41); // ASCII 'A'
        send_byte(8'h48); // ASCII 'H'
        send_byte(8'h69); // ASCII 'i'

        if (errors == 0) begin
            $display("====================================");
            $display("UART LOOPBACK TEST PASSED");
            $display("====================================");
        end
        else begin
            $display("====================================");
            $display("UART LOOPBACK TEST FAILED: %0d errors", errors);
            $display("====================================");
        end

        #(5 * BIT_PERIOD);
        $finish;
    end

    // ------------------------------------------------------------
    // Timeout protection
    // ------------------------------------------------------------
    initial begin
        #20000000; // 20 ms
        $display("ERROR: Simulation timeout");
        $finish;
    end

endmodule