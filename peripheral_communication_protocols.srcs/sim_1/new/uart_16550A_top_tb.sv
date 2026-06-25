`timescale 1ns / 1ps

module uart_16550_top_tb;

    // --------------------------------------------------------
    // DUT bus and UART signals
    // --------------------------------------------------------
    logic       clk;
    logic       rst;

    logic       wr_i;
    logic       rd_i;
    logic [2:0] addr_i;
    logic [7:0] din_i;
    logic [7:0] dout_o;

    logic tx_o;
    wire  rx_i;
    logic irq_o;

    // --------------------------------------------------------
    // Testbench variables
    // --------------------------------------------------------
    integer checks;
    integer failures;

    logic [7:0] read_data;
    logic [7:0] lsr_data;
    logic [7:0] iir_data;

    // UART loopback connection.
    assign rx_i = tx_o;

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------
    uart_16550_top dut (
        .clk    (clk),
        .rst    (rst),

        .wr_i   (wr_i),
        .rd_i   (rd_i),
        .addr_i (addr_i),
        .din_i  (din_i),
        .dout_o (dout_o),

        .rx_i   (rx_i),
        .tx_o   (tx_o),

        .irq_o  (irq_o)
    );

    // --------------------------------------------------------
    // 100 MHz system clock
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
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

            rst    = 1'b1;
            wr_i   = 1'b0;
            rd_i   = 1'b0;
            addr_i = 3'h0;
            din_i  = 8'h00;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            repeat (2) @(posedge clk);
            #1;
        end
    endtask

    // --------------------------------------------------------
    // CPU register write
    // --------------------------------------------------------
    task automatic bus_write(
        input logic [2:0] addr,
        input logic [7:0] data
    );
        begin
            @(negedge clk);

            wr_i   = 1'b1;
            rd_i   = 1'b0;
            addr_i = addr;
            din_i  = data;

            @(posedge clk);
            #1;

            @(negedge clk);

            wr_i  = 1'b0;
            din_i = 8'h00;
        end
    endtask

    // --------------------------------------------------------
    // CPU register read
    // --------------------------------------------------------
    task automatic bus_read(
        input  logic [2:0] addr,
        output logic [7:0] data
    );
        begin
            @(negedge clk);

            wr_i   = 1'b0;
            rd_i   = 1'b1;
            addr_i = addr;

            #1;
            data = dout_o;

            @(posedge clk);
            #1;

            @(negedge clk);
            rd_i = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // Wait for enabled RX interrupt.
    // --------------------------------------------------------
    task automatic wait_for_rx_irq(
        input string test_name
    );
        integer timeout;

        begin
            timeout = 0;

            while ((irq_o !== 1'b1) && (timeout < 25000)) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end

            check(
                irq_o === 1'b1,
                $sformatf("%s generated an RX interrupt", test_name)
            );
        end
    endtask

    // --------------------------------------------------------
    // Wait until the entire TX path becomes idle.
    // --------------------------------------------------------
    task automatic wait_for_tx_idle;
        integer timeout;

        begin
            timeout = 0;

            while (
                !((dut.tx_fifo_empty == 1'b1) &&
                  (dut.tx_sreg_empty == 1'b1)) &&
                (timeout < 25000)
            ) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end

            check(
                (dut.tx_fifo_empty == 1'b1) &&
                (dut.tx_sreg_empty == 1'b1),
                "TX FIFO and transmit shift register become empty"
            );
        end
    endtask

    // --------------------------------------------------------
    // Send one byte through full UART loopback and verify it.
    // --------------------------------------------------------
    task automatic send_and_check(
        input logic [7:0] expected_data,
        input string test_name
    );
        logic [7:0] received_data;
        logic [7:0] local_lsr;
        logic [7:0] local_iir;

        begin
            // Write THR at address 0 when DLAB = 0.
            bus_write(3'h0, expected_data);

            wait_for_rx_irq(test_name);

            // Read IIR.
            bus_read(3'h2, local_iir);

            check(
                local_iir[3:0] == 4'b0100,
                $sformatf("%s reports RX-data interrupt in IIR", test_name)
            );

            // Read LSR and confirm data is available.
            bus_read(3'h5, local_lsr);

            check(
                local_lsr[0] == 1'b1,
                $sformatf("%s sets LSR Data Ready", test_name)
            );

            // Read RBR at address 0.
            bus_read(3'h0, received_data);

            check(
                received_data == expected_data,
                $sformatf("%s loopback received 0x%02h correctly",
                          test_name, expected_data)
            );

            repeat (2) @(posedge clk);
            #1;

            check(
                irq_o == 1'b0,
                $sformatf("%s RX interrupt clears after RBR read", test_name)
            );
        end
    endtask

    // --------------------------------------------------------
    // Global watchdog
    // --------------------------------------------------------
    initial begin
        #500_000;
        $fatal(1, "Global timeout: UART top-level testbench did not finish.");
    end

    // --------------------------------------------------------
    // Main test sequence
    // --------------------------------------------------------
    initial begin
        checks   = 0;
        failures = 0;

        // ====================================================
        // TEST 1: Reset behavior
        // ====================================================
        $display("\n========== TEST 1: RESET ==========");
        apply_reset();

        bus_read(3'h5, lsr_data);

        check(tx_o == 1'b1, "TX idles high after reset");
        check(lsr_data == 8'h60,
              "LSR reset value shows THRE and TEMT asserted");
        check(irq_o == 1'b0, "IRQ is low after reset");

        // ====================================================
        // TEST 2: Program divisor and UART configuration
        //
        // Divisor = 4:
        // baud16_tick every four system clocks.
        //
        // LCR = 0x03:
        // 8 data bits, no parity, one stop bit, DLAB = 0.
        // ====================================================
        $display("\n========== TEST 2: UART CONFIGURATION ==========");

        // LCR = 8N1 + DLAB = 1
        bus_write(3'h3, 8'h83);

        // DLL = 4
        bus_write(3'h0, 8'h04);

        // DLM = 0
        bus_write(3'h1, 8'h00);

        // Return to normal register map, 8N1.
        bus_write(3'h3, 8'h03);

        // FCR: enable FIFO, RX threshold = 1 byte.
        bus_write(3'h2, 8'h01);

        // IER: enable received-data interrupt.
        bus_write(3'h1, 8'h01);

        bus_read(3'h3, read_data);
        check(read_data == 8'h03, "LCR is configured for 8N1");

        // ====================================================
        // TEST 3: 8N1 UART loopback
        // ====================================================
        $display("\n========== TEST 3: 8N1 LOOPBACK ==========");

        send_and_check(8'h55, "8N1 byte 0x55");
        send_and_check(8'hA5, "8N1 byte 0xA5");
        send_and_check(8'h00, "8N1 byte 0x00");
        send_and_check(8'hFF, "8N1 byte 0xFF");

        // ====================================================
        // TEST 4: 8E1 UART loopback
        //
        // LCR = 0x1B:
        // 8 data bits, even parity, one stop bit.
        // ====================================================
        $display("\n========== TEST 4: 8E1 LOOPBACK ==========");

        bus_write(3'h3, 8'h1B);

        send_and_check(8'h13, "8E1 byte 0x13");
        send_and_check(8'hA6, "8E1 byte 0xA6");

        bus_read(3'h5, lsr_data);

        check(
            lsr_data[4:1] == 4'b0000,
            "8E1 loopback completes without RX error flags"
        );

        // Restore 8N1.
        bus_write(3'h3, 8'h03);

        // ====================================================
        // TEST 5: Back-to-back TX FIFO ordering
        // ====================================================
        $display("\n========== TEST 5: BACK-TO-BACK FIFO ==========");

        // Write two bytes before reading either received byte.
        bus_write(3'h0, 8'h3C);
        bus_write(3'h0, 8'hC3);

        wait_for_rx_irq("Back-to-back first byte");

        bus_read(3'h0, read_data);

        check(
            read_data == 8'h3C,
            "First queued byte arrives first through loopback"
        );

        wait_for_rx_irq("Back-to-back second byte");

        bus_read(3'h0, read_data);

        check(
            read_data == 8'hC3,
            "Second queued byte arrives second through loopback"
        );

        // ====================================================
        // TEST 6: RX FIFO clear via FCR[1]
        // ====================================================
        $display("\n========== TEST 6: FCR RX FIFO CLEAR ==========");

        // Send one byte and deliberately leave it in RX FIFO.
        bus_write(3'h0, 8'h5A);
        wait_for_rx_irq("RX FIFO clear setup byte");

        bus_read(3'h5, lsr_data);

        check(
            lsr_data[0] == 1'b1,
            "RX FIFO contains data before FCR clear"
        );

        // FCR = FIFO enable + RX FIFO clear.
        bus_write(3'h2, 8'h03);

        repeat (3) @(posedge clk);
        #1;

        bus_read(3'h5, lsr_data);

        check(
            lsr_data[0] == 1'b0,
            "FCR RX clear removes pending received byte"
        );

        check(
            irq_o == 1'b0,
            "IRQ deasserts after RX FIFO clear"
        );

        // ====================================================
        // TEST 7: Final transmitter status
        // ====================================================
        $display("\n========== TEST 7: FINAL TX STATUS ==========");

        wait_for_tx_idle();

        bus_read(3'h5, lsr_data);

        check(
            lsr_data[5] == 1'b1,
            "LSR THRE is high when TX FIFO is empty"
        );

        check(
            lsr_data[6] == 1'b1,
            "LSR TEMT is high when TX FIFO and shift register are empty"
        );

        // ====================================================
        // Results
        // ====================================================
        $display("\n========================================");

        if (failures == 0)
            $display("ALL UART TOP-LEVEL TESTS PASSED. Checks: %0d", checks);
        else
            $display(
                "UART TOP-LEVEL TESTS FAILED. Failures: %0d / %0d",
                failures,
                checks
            );

        $display("========================================\n");

        #100;
        $finish;
    end

endmodule