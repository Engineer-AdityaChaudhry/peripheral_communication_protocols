`timescale 1ns / 1ps

module uart_register_tb;

    // --------------------------------------------------------
    // Clock, reset, and CPU-facing bus
    // --------------------------------------------------------
    logic       clk;
    logic       rst;
    logic       wr_i;
    logic       rd_i;
    logic [2:0] addr_i;
    logic [7:0] din_i;
    logic [7:0] dout_o;

    // --------------------------------------------------------
    // TX FIFO interface
    // --------------------------------------------------------
    logic       tx_fifo_push_o;
    logic [7:0] tx_fifo_din_o;
    logic       tx_fifo_empty_i;
    logic       tx_fifo_full_i;
    logic       tx_sreg_empty_i;

    // --------------------------------------------------------
    // RX FIFO interface
    // --------------------------------------------------------
    logic       rx_fifo_pop_o;
    logic [7:0] rx_fifo_dout_i;
    logic       rx_fifo_empty_i;
    logic       rx_fifo_threshold_hit_i;

    // --------------------------------------------------------
    // RX error-event inputs
    // --------------------------------------------------------
    logic rx_oe_i;
    logic rx_pe_i;
    logic rx_fe_i;
    logic rx_bi_i;

    // --------------------------------------------------------
    // Register-bank outputs
    // --------------------------------------------------------
    logic       tx_fifo_clear_o;
    logic       rx_fifo_clear_o;
    logic       fifo_enable_o;
    logic [4:0] rx_fifo_threshold_o;

    logic [7:0]  lcr_o;
    logic [7:0]  mcr_o;
    logic [3:0]  ier_o;
    logic [15:0] divisor_o;
    logic        baud16_tick_o;

    logic [7:0] lsr_o;
    logic [7:0] iir_o;
    logic       irq_o;

    // --------------------------------------------------------
    // Verification variables
    // --------------------------------------------------------
    integer checks;
    integer failures;
    integer measured_period;

    logic [7:0] read_data;

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------
    uart_register dut (
        .clk                     (clk),
        .rst                     (rst),

        .wr_i                    (wr_i),
        .rd_i                    (rd_i),
        .addr_i                  (addr_i),
        .din_i                   (din_i),
        .dout_o                  (dout_o),

        .tx_fifo_push_o          (tx_fifo_push_o),
        .tx_fifo_din_o           (tx_fifo_din_o),
        .tx_fifo_empty_i         (tx_fifo_empty_i),
        .tx_fifo_full_i          (tx_fifo_full_i),
        .tx_sreg_empty_i         (tx_sreg_empty_i),

        .rx_fifo_pop_o           (rx_fifo_pop_o),
        .rx_fifo_dout_i          (rx_fifo_dout_i),
        .rx_fifo_empty_i         (rx_fifo_empty_i),
        .rx_fifo_threshold_hit_i (rx_fifo_threshold_hit_i),

        .rx_oe_i                 (rx_oe_i),
        .rx_pe_i                 (rx_pe_i),
        .rx_fe_i                 (rx_fe_i),
        .rx_bi_i                 (rx_bi_i),

        .tx_fifo_clear_o         (tx_fifo_clear_o),
        .rx_fifo_clear_o         (rx_fifo_clear_o),
        .fifo_enable_o           (fifo_enable_o),
        .rx_fifo_threshold_o     (rx_fifo_threshold_o),

        .lcr_o                   (lcr_o),
        .mcr_o                   (mcr_o),
        .ier_o                   (ier_o),
        .divisor_o               (divisor_o),
        .baud16_tick_o           (baud16_tick_o),

        .lsr_o                   (lsr_o),
        .iir_o                   (iir_o),
        .irq_o                   (irq_o)
    );

    // --------------------------------------------------------
    // 100 MHz clock
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
    // Reset all DUT inputs
    // --------------------------------------------------------
    task automatic apply_reset;
        begin
            @(negedge clk);

            rst                     = 1'b1;
            wr_i                    = 1'b0;
            rd_i                    = 1'b0;
            addr_i                  = 3'h0;
            din_i                   = 8'h00;

            tx_fifo_empty_i         = 1'b1;
            tx_fifo_full_i          = 1'b0;
            tx_sreg_empty_i         = 1'b1;

            rx_fifo_dout_i          = 8'h00;
            rx_fifo_empty_i         = 1'b1;
            rx_fifo_threshold_hit_i = 1'b0;

            rx_oe_i                 = 1'b0;
            rx_pe_i                 = 1'b0;
            rx_fe_i                 = 1'b0;
            rx_bi_i                 = 1'b0;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            @(posedge clk);
            #1;
        end
    endtask

    // --------------------------------------------------------
    // One register write transaction
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
    // One register read transaction
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
    // Generate one-clock RX error events
    // --------------------------------------------------------
    task automatic pulse_rx_errors(
        input logic oe,
        input logic pe,
        input logic fe,
        input logic bi
    );
        begin
            @(negedge clk);

            rx_oe_i = oe;
            rx_pe_i = pe;
            rx_fe_i = fe;
            rx_bi_i = bi;

            @(posedge clk);
            #1;

            @(negedge clk);

            rx_oe_i = 1'b0;
            rx_pe_i = 1'b0;
            rx_fe_i = 1'b0;
            rx_bi_i = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // Measure baud16 tick period in system-clock cycles
    // --------------------------------------------------------
    task automatic measure_baud_period(
        output integer period
    );
        integer timeout;

        begin
            timeout = 0;

            while ((baud16_tick_o !== 1'b1) && (timeout < 30)) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end

            if (baud16_tick_o !== 1'b1) begin
                period = -1;
            end
            else begin
                period = 0;

                while (((baud16_tick_o !== 1'b1) || (period == 0)) &&
                       (period < 30)) begin
                    @(posedge clk);
                    #1;
                    period = period + 1;
                end

                if (baud16_tick_o !== 1'b1)
                    period = -1;
            end
        end
    endtask

    // --------------------------------------------------------
    // Global watchdog
    // --------------------------------------------------------
    initial begin
        #200_000;
        $fatal(1, "Global UART register testbench timeout");
    end

    // --------------------------------------------------------
    // Main verification sequence
    // --------------------------------------------------------
    initial begin
        checks   = 0;
        failures = 0;

        // ========================================================
        // TEST 1: Reset values
        // ========================================================
        $display("\n========== TEST 1: RESET ==========");
        apply_reset();

        check(lcr_o == 8'h03, "LCR resets to 8N1 with DLAB cleared");
        check(ier_o == 4'h0, "IER resets to zero");
        check(divisor_o == 16'h0001, "Divisor resets to one");
        check(lsr_o == 8'h60, "LSR resets with THRE and TEMT asserted");
        check(iir_o[0] == 1'b1, "IIR reports no interrupt pending after reset");
        check(irq_o == 1'b0, "IRQ is low after reset");
        check(fifo_enable_o == 1'b0, "FIFO mode disabled after reset");

        // ========================================================
        // TEST 2: THR write and TX FIFO full protection
        // ========================================================
        $display("\n========== TEST 2: THR / TX FIFO ==========");
        apply_reset();

        @(negedge clk);
        wr_i   = 1'b1;
        addr_i = 3'h0;
        din_i  = 8'hA5;

        #1;
        check(tx_fifo_push_o == 1'b1,
              "THR write generates TX FIFO push");
        check(tx_fifo_din_o == 8'hA5,
              "THR write forwards correct data to TX FIFO");

        @(posedge clk);
        @(negedge clk);
        wr_i = 1'b0;

        tx_fifo_full_i = 1'b1;

        @(negedge clk);
        wr_i   = 1'b1;
        addr_i = 3'h0;
        din_i  = 8'h5A;

        #1;
        check(tx_fifo_push_o == 1'b0,
              "THR write is blocked when TX FIFO is full");

        @(posedge clk);
        @(negedge clk);
        wr_i = 1'b0;

        // ========================================================
        // TEST 3: RBR read
        // ========================================================
        $display("\n========== TEST 3: RBR / RX FIFO ==========");
        apply_reset();

        rx_fifo_empty_i = 1'b0;
        rx_fifo_dout_i  = 8'h3C;

        @(negedge clk);
        rd_i   = 1'b1;
        addr_i = 3'h0;

        #1;
        check(rx_fifo_pop_o == 1'b1,
              "RBR read generates RX FIFO pop");
        check(dout_o == 8'h3C,
              "RBR read returns RX FIFO data");

        @(posedge clk);
        @(negedge clk);
        rd_i = 1'b0;

        // ========================================================
        // TEST 4: LCR, DLL, DLM, DLAB decode, baud timing
        // ========================================================
        $display("\n========== TEST 4: DLAB / DIVISOR ==========");
        apply_reset();

        // Enable DLAB while retaining 8N1 frame format.
        bus_write(3'h3, 8'h83);

        check(lcr_o == 8'h83, "LCR stores DLAB and 8N1 configuration");

        // DLL = 4
        bus_write(3'h0, 8'h04);

        // DLM = 0
        bus_write(3'h1, 8'h00);

        check(divisor_o == 16'h0004,
              "DLL and DLM form expected divisor value");

        bus_read(3'h0, read_data);
        check(read_data == 8'h04,
              "DLAB=1 address 0 reads DLL");

        bus_read(3'h1, read_data);
        check(read_data == 8'h00,
              "DLAB=1 address 1 reads DLM");

        measure_baud_period(measured_period);
        check(measured_period == 4,
              "baud16_tick period matches divisor of four");

        // Restore normal register access.
        bus_write(3'h3, 8'h03);

        check(lcr_o == 8'h03, "DLAB clears and normal 8N1 access returns");

        // ========================================================
        // TEST 5: FCR FIFO controls and RX trigger levels
        // ========================================================
        $display("\n========== TEST 5: FCR ==========");
        apply_reset();

        // FCR: enable FIFO, clear TX/RX FIFO, trigger = 14 bytes.
        bus_write(3'h2, 8'hC7);

        check(fifo_enable_o == 1'b1, "FCR enables FIFO mode");
        check(rx_fifo_threshold_o == 5'd14,
              "FCR trigger 11 selects threshold 14");
        check(tx_fifo_clear_o == 1'b1,
              "FCR TX clear generates one-cycle clear pulse");
        check(rx_fifo_clear_o == 1'b1,
              "FCR RX clear generates one-cycle clear pulse");

        @(posedge clk);
        #1;

        check(tx_fifo_clear_o == 1'b0,
              "TX FIFO clear pulse deasserts");
        check(rx_fifo_clear_o == 1'b0,
              "RX FIFO clear pulse deasserts");

        // Enable FIFO with RX threshold = 8.
        bus_write(3'h2, 8'h81);

        check(rx_fifo_threshold_o == 5'd8,
              "FCR trigger 10 selects threshold 8");

        // ========================================================
        // TEST 6: LSR dynamic status and sticky error bits
        // ========================================================
        $display("\n========== TEST 6: LSR ==========");
        apply_reset();

        rx_fifo_empty_i = 1'b0;
        tx_fifo_empty_i = 1'b1;
        tx_sreg_empty_i = 1'b0;

        #1;
        check(lsr_o[0] == 1'b1, "LSR DR asserts when RX FIFO has data");
        check(lsr_o[5] == 1'b1, "LSR THRE asserts when TX FIFO is empty");
        check(lsr_o[6] == 1'b0,
              "LSR TEMT is low while TX shift register is busy");

        tx_sreg_empty_i = 1'b1;

        #1;
        check(lsr_o[6] == 1'b1,
              "LSR TEMT asserts when TX FIFO and shift register are empty");

        // Isolate error-bit test.
        rx_fifo_empty_i = 1'b1;

        pulse_rx_errors(1'b1, 1'b1, 1'b1, 1'b1);

        check(lsr_o == 8'hFE,
              "LSR latches OE, PE, FE, BI, and RX FIFO error status");

        bus_read(3'h5, read_data);

        check(read_data == 8'hFE,
              "LSR read returns sticky error status");
        check(lsr_o == 8'h60,
              "LSR error bits clear after LSR read");

        // ========================================================
        // TEST 7: IER, IIR, IRQ, and interrupt priority
        // ========================================================
        $display("\n========== TEST 7: INTERRUPTS ==========");
        apply_reset();

        // Disable FIFO mode so RX interrupt uses Data Ready.
        bus_write(3'h2, 8'h00);

        rx_fifo_empty_i = 1'b0;
        tx_fifo_empty_i = 1'b0;

        // Enable received-data interrupt.
        bus_write(3'h1, 8'h01);

        check(ier_o == 4'h1, "IER stores receive-data interrupt enable");
        check(iir_o[3:0] == 4'b0100,
              "IIR reports received-data interrupt");
        check(irq_o == 1'b1,
              "IRQ asserts for enabled received-data interrupt");

        // Enable line-status plus receive-data interrupt.
        bus_write(3'h1, 8'h05);
        pulse_rx_errors(1'b0, 1'b1, 1'b0, 1'b0);

        check(iir_o[3:0] == 4'b0110,
              "Line-status interrupt has priority over received-data");

        // Reading LSR clears parity error; RX-data interrupt remains.
        bus_read(3'h5, read_data);

        check(iir_o[3:0] == 4'b0100,
              "RX-data interrupt remains after line-status clear");

        // Test THRE interrupt.
        rx_fifo_empty_i = 1'b1;
        tx_fifo_empty_i = 1'b1;

        bus_write(3'h1, 8'h02);

        check(iir_o[3:0] == 4'b0010,
              "IIR reports THRE interrupt");
        check(irq_o == 1'b1,
              "IRQ asserts for enabled THRE interrupt");

        tx_fifo_empty_i = 1'b0;

        #1;
        check(iir_o[0] == 1'b1,
              "IIR reports no pending interrupt after THRE clears");
        check(irq_o == 1'b0,
              "IRQ deasserts after THRE clears");

        // ========================================================
        // TEST 8: FIFO threshold-driven RX interrupt
        // ========================================================
        $display("\n========== TEST 8: RX THRESHOLD IRQ ==========");
        apply_reset();

        // FIFO enabled, threshold = 8.
        bus_write(3'h2, 8'h81);
        bus_write(3'h1, 8'h01);

        rx_fifo_empty_i         = 1'b0;
        rx_fifo_threshold_hit_i = 1'b0;

        #1;
        check(iir_o[0] == 1'b1,
              "RX interrupt waits for threshold when FIFO mode is enabled");

        rx_fifo_threshold_hit_i = 1'b1;

        #1;
        check(iir_o[3:0] == 4'b0100,
              "IIR reports RX interrupt after threshold hit");
        check(irq_o == 1'b1,
              "IRQ asserts after RX threshold hit");

        // ========================================================
        // TEST 9: MCR and scratch register
        // ========================================================
        $display("\n========== TEST 9: MCR / SCRATCH ==========");
        apply_reset();

        bus_write(3'h4, 8'hA5);
        bus_read(3'h4, read_data);

        check(mcr_o == 8'hA5, "MCR stores written value");
        check(read_data == 8'hA5, "MCR readback is correct");

        bus_write(3'h7, 8'h5A);
        bus_read(3'h7, read_data);

        check(read_data == 8'h5A,
              "Scratch register stores and returns data");

        // ========================================================
        // Final result
        // ========================================================
        $display("\n========================================");

        if (failures == 0)
            $display("ALL UART REGISTER TESTS PASSED. Checks: %0d", checks);
        else
            $display("UART REGISTER TESTS FAILED. Failures: %0d / %0d",
                     failures, checks);

        $display("========================================\n");

        #100;
        $finish;
    end

endmodule
