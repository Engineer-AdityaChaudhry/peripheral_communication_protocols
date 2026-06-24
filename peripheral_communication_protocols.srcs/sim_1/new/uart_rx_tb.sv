`timescale 1ns / 1ps

module uart_rx_tb;

    logic clk;
    logic rst;
    logic baud16_tick;
    logic rx;

    logic [7:0] lcr;
    logic       rx_fifo_full;

    logic [7:0] rx_fifo_din;
    logic       rx_fifo_push;
    logic       parity_error;
    logic       framing_error;
    logic       break_interrupt;
    logic       overrun;

    integer checks;
    integer failures;

    integer push_count;
    integer parity_error_count;
    integer framing_error_count;
    integer break_interrupt_count;
    integer overrun_count;

    logic [7:0] last_rx_data;

    // Faster simulation: baud16_tick generated every clock period.
    localparam integer TICK_DIV = 1;

    uart_rx dut (
        .clk             (clk),
        .rst             (rst),
        .baud16_tick     (baud16_tick),
        .rx              (rx),

        .rx_fifo_full    (rx_fifo_full),
        .rx_fifo_din     (rx_fifo_din),
        .rx_fifo_push    (rx_fifo_push),

        .lcr             (lcr),

        .parity_error    (parity_error),
        .framing_error   (framing_error),
        .break_interrupt (break_interrupt),
        .overrun         (overrun)
    );

    // ------------------------------------------------------------
    // 100 MHz system clock
    // ------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ------------------------------------------------------------
    // One-clock-cycle baud16 tick
    // ------------------------------------------------------------
    initial begin
        baud16_tick = 1'b0;

        forever begin
            repeat (TICK_DIV) @(negedge clk);
            baud16_tick = 1'b1;

            @(negedge clk);
            baud16_tick = 1'b0;
        end
    end

    // ------------------------------------------------------------
    // Monitor one-cycle DUT outputs
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            push_count            = 0;
            parity_error_count    = 0;
            framing_error_count   = 0;
            break_interrupt_count = 0;
            overrun_count         = 0;
            last_rx_data          = 8'h00;
        end
        else begin
            if (rx_fifo_push) begin
                push_count   = push_count + 1;
                last_rx_data = rx_fifo_din;
            end

            if (parity_error)
                parity_error_count = parity_error_count + 1;

            if (framing_error)
                framing_error_count = framing_error_count + 1;

            if (break_interrupt)
                break_interrupt_count = break_interrupt_count + 1;

            if (overrun)
                overrun_count = overrun_count + 1;
        end
    end

    // ------------------------------------------------------------
    // PASS / FAIL helpers
    // ------------------------------------------------------------
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
                $display("FAIL [%0d] %s | time = %0t",
                         checks, message, $time);
            end
        end
    endtask

    task automatic check_delta(
        input integer before_value,
        input integer after_value,
        input integer expected_delta,
        input string message
    );
        begin
            check(
                (after_value - before_value) == expected_delta,
                $sformatf("%s | expected delta=%0d, actual delta=%0d",
                          message,
                          expected_delta,
                          after_value - before_value)
            );
        end
    endtask

    // ------------------------------------------------------------
    // Timing and serial-driver helpers
    // ------------------------------------------------------------
    task automatic wait_baud_ticks(
        input integer number_of_ticks
    );
        integer seen;

        begin
            seen = 0;

            while (seen < number_of_ticks) begin
                @(posedge clk);

                if (baud16_tick) begin
                    #1;
                    seen = seen + 1;
                end
            end
        end
    endtask

    task automatic drive_symbol(
        input logic value,
        input integer symbol_ticks
    );
        begin
            @(negedge clk);
            #1;
            rx = value;

            wait_baud_ticks(symbol_ticks);
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);

            rst          = 1'b1;
            rx           = 1'b1;
            lcr          = 8'h03;
            rx_fifo_full = 1'b0;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            repeat (4) @(posedge clk);
            #1;
        end
    endtask

    function automatic integer data_bits_from_wls(
        input logic [1:0] wls
    );
        case (wls)
            2'b00:  data_bits_from_wls = 5;
            2'b01:  data_bits_from_wls = 6;
            2'b10:  data_bits_from_wls = 7;
            default: data_bits_from_wls = 8;
        endcase
    endfunction

    function automatic integer stop_ticks_from_lcr(
        input logic       stb,
        input logic [1:0] wls
    );
        if (!stb)
            stop_ticks_from_lcr = 16;
        else if (wls == 2'b00)
            stop_ticks_from_lcr = 24;
        else
            stop_ticks_from_lcr = 32;
    endfunction

    function automatic logic expected_parity(
        input logic [7:0] data,
        input logic [7:0] format_lcr
    );
        logic data_xor;

        begin
            case (format_lcr[1:0])
                2'b00:  data_xor = ^data[4:0];
                2'b01:  data_xor = ^data[5:0];
                2'b10:  data_xor = ^data[6:0];
                default: data_xor = ^data[7:0];
            endcase

            // Stick parity:
            // SP=1, EPS=0 -> mark parity -> force 1
            // SP=1, EPS=1 -> space parity -> force 0
            if (format_lcr[5])
                expected_parity = format_lcr[4] ? 1'b0 : 1'b1;

            // Normal parity
            else if (format_lcr[4])
                expected_parity = data_xor;   // even parity
            else
                expected_parity = ~data_xor;  // odd parity
        end
    endfunction

    // ------------------------------------------------------------
    // Send one UART frame into DUT RX pin.
    //
    // bad_parity = 1 sends the opposite parity bit.
    // bad_stop   = 1 holds the first stop bit low.
    // ------------------------------------------------------------
    task automatic send_uart_frame(
        input logic [7:0] data,
        input logic [7:0] format_lcr,
        input logic       bad_parity,
        input logic       bad_stop
    );
        integer i;
        integer data_bits;
        integer stop_ticks;
        logic parity_bit;

        begin
            data_bits  = data_bits_from_wls(format_lcr[1:0]);
            stop_ticks = stop_ticks_from_lcr(
                             format_lcr[2],
                             format_lcr[1:0]
                         );

            // Start bit
            drive_symbol(1'b0, 16);

            // Data bits: LSB first
            for (i = 0; i < data_bits; i = i + 1)
                drive_symbol(data[i], 16);

            // Optional parity bit
            if (format_lcr[3]) begin
                parity_bit = expected_parity(data, format_lcr);

                if (bad_parity)
                    parity_bit = ~parity_bit;

                drive_symbol(parity_bit, 16);
            end

            // Stop period
            drive_symbol(bad_stop ? 1'b0 : 1'b1, stop_ticks);

            // Idle after frame
            drive_symbol(1'b1, 8);
        end
    endtask

    task automatic wait_for_receiver_to_finish;
        begin
            // Allows DUT synchronizer and final output pulses
            // to reach the monitor.
            wait_baud_ticks(32);
        end
    endtask

    // ------------------------------------------------------------
    // Global simulation watchdog
    // ------------------------------------------------------------
    initial begin
        #300_000;
        $fatal(1, "Global testbench timeout");
    end

    // ------------------------------------------------------------
    // Main self-checking tests
    // ------------------------------------------------------------
    initial begin
        integer push_before;
        integer pe_before;
        integer fe_before;
        integer bi_before;
        integer ov_before;

        checks   = 0;
        failures = 0;
        rst      = 1'b0;
        rx       = 1'b1;
        lcr      = 8'h03;
        rx_fifo_full = 1'b0;

        // ========================================================
        // TEST 1: Reset
        // ========================================================
        $display("\n========== TEST 1: RESET ==========");
        apply_reset();

        check(rx_fifo_push === 1'b0, "RX FIFO push is low after reset");
        check(parity_error === 1'b0, "Parity error is low after reset");
        check(framing_error === 1'b0, "Framing error is low after reset");
        check(break_interrupt === 1'b0, "Break interrupt is low after reset");
        check(overrun === 1'b0, "Overrun is low after reset");

        // ========================================================
        // TEST 2: Valid 8N1
        // ========================================================
        $display("\n========== TEST 2: VALID 8N1 ==========");
        apply_reset();

        lcr = 8'h03;

        push_before = push_count;
        pe_before   = parity_error_count;
        fe_before   = framing_error_count;
        bi_before   = break_interrupt_count;
        ov_before   = overrun_count;

        send_uart_frame(8'hA5, 8'h03, 1'b0, 1'b0);
        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 1, "8N1 pushes one received byte");
        check(last_rx_data == 8'hA5, "8N1 received data equals 0xA5");
        check_delta(pe_before, parity_error_count, 0, "8N1 has no parity error");
        check_delta(fe_before, framing_error_count, 0, "8N1 has no framing error");
        check_delta(bi_before, break_interrupt_count, 0, "8N1 has no break interrupt");
        check_delta(ov_before, overrun_count, 0, "8N1 has no overrun");

        // ========================================================
        // TEST 3: Valid 8E1
        // ========================================================
        $display("\n========== TEST 3: VALID 8E1 ==========");
        apply_reset();

        lcr = 8'h1B; // 8-bit, parity enable, even parity, 1 stop

        push_before = push_count;
        pe_before   = parity_error_count;
        fe_before   = framing_error_count;

        send_uart_frame(8'h13, 8'h1B, 1'b0, 1'b0);
        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 1, "8E1 pushes one received byte");
        check(last_rx_data == 8'h13, "8E1 received data equals 0x13");
        check_delta(pe_before, parity_error_count, 0, "8E1 parity is valid");
        check_delta(fe_before, framing_error_count, 0, "8E1 has no framing error");

        // ========================================================
        // TEST 4: Valid 8O1
        // ========================================================
        $display("\n========== TEST 4: VALID 8O1 ==========");
        apply_reset();

        lcr = 8'h0B; // 8-bit, parity enable, odd parity, 1 stop

        push_before = push_count;
        pe_before   = parity_error_count;

        send_uart_frame(8'h13, 8'h0B, 1'b0, 1'b0);
        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 1, "8O1 pushes one received byte");
        check(last_rx_data == 8'h13, "8O1 received data equals 0x13");
        check_delta(pe_before, parity_error_count, 0, "8O1 parity is valid");

        // ========================================================
        // TEST 5: Valid 5N1.5
        // ========================================================
        $display("\n========== TEST 5: VALID 5N1.5 ==========");
        apply_reset();

        lcr = 8'h04; // 5-bit, no parity, 1.5 stop bits

        push_before = push_count;
        fe_before   = framing_error_count;

        send_uart_frame(8'h15, 8'h04, 1'b0, 1'b0);
        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 1, "5N1.5 pushes one received byte");
        check(last_rx_data == 8'h15, "5N1.5 received lower five bits correctly");
        check_delta(fe_before, framing_error_count, 0, "5N1.5 has no framing error");

        // ========================================================
        // TEST 6: Parity error
        // ========================================================
        $display("\n========== TEST 6: PARITY ERROR ==========");
        apply_reset();

        lcr = 8'h1B; // 8E1

        push_before = push_count;
        pe_before   = parity_error_count;
        fe_before   = framing_error_count;

        send_uart_frame(8'h13, 8'h1B, 1'b1, 1'b0);
        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 1,
                    "Parity-error frame still pushes received byte");
        check(last_rx_data == 8'h13,
              "Parity-error frame retains received data");
        check_delta(pe_before, parity_error_count, 1,
                    "Invalid parity causes parity-error pulse");
        check_delta(fe_before, framing_error_count, 0,
                    "Parity-error frame has valid stop bit");

        // ========================================================
        // TEST 7: Framing error
        // ========================================================
        $display("\n========== TEST 7: FRAMING ERROR ==========");
        apply_reset();

        lcr = 8'h03; // 8N1

        push_before = push_count;
        pe_before   = parity_error_count;
        fe_before   = framing_error_count;
        bi_before   = break_interrupt_count;

        send_uart_frame(8'h55, 8'h03, 1'b0, 1'b1);
        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 1,
                    "Framing-error frame still pushes received byte");
        check(last_rx_data == 8'h55,
              "Framing-error frame retains received data");
        check_delta(pe_before, parity_error_count, 0,
                    "Framing-error frame has no parity error");
        check_delta(fe_before, framing_error_count, 1,
                    "Low stop bit causes framing-error pulse");
        check_delta(bi_before, break_interrupt_count, 0,
                    "Nonzero framing-error frame is not a break");

        // ========================================================
        // TEST 8: False start-bit glitch
        // ========================================================
        $display("\n========== TEST 8: FALSE START GLITCH ==========");
        apply_reset();

        push_before = push_count;
        pe_before   = parity_error_count;
        fe_before   = framing_error_count;

        // Low for fewer than 8 ticks, then return high.
        drive_symbol(1'b0, 4);
        drive_symbol(1'b1, 40);

        check_delta(push_before, push_count, 0,
                    "Short low glitch does not push data");
        check_delta(pe_before, parity_error_count, 0,
                    "Short low glitch has no parity error");
        check_delta(fe_before, framing_error_count, 0,
                    "Short low glitch has no framing error");

        // ========================================================
        // TEST 9: RX FIFO full -> overrun
        // ========================================================
        $display("\n========== TEST 9: RX FIFO OVERRUN ==========");
        apply_reset();

        lcr          = 8'h03;
        rx_fifo_full = 1'b1;

        push_before = push_count;
        ov_before   = overrun_count;

        send_uart_frame(8'h3C, 8'h03, 1'b0, 1'b0);
        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 0,
                    "Full RX FIFO blocks push");
        check_delta(ov_before, overrun_count, 1,
                    "Full RX FIFO causes overrun pulse");

        rx_fifo_full = 1'b0;

        // ========================================================
        // TEST 10: Break condition
        // ========================================================
        $display("\n========== TEST 10: BREAK CONDITION ==========");
        apply_reset();

        lcr = 8'h03;

        push_before = push_count;
        fe_before   = framing_error_count;
        bi_before   = break_interrupt_count;

        // All-zero data and a low stop sample indicates break.
        send_uart_frame(8'h00, 8'h03, 1'b0, 1'b1);
        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 1,
                    "Break frame pushes received data");
        check(last_rx_data == 8'h00,
              "Break frame received data is zero");
        check_delta(fe_before, framing_error_count, 1,
                    "Break condition causes framing error");
        check_delta(bi_before, break_interrupt_count, 1,
                    "Break condition causes break interrupt");

        // ========================================================
        // TEST 11: LCR latching during an active frame
        // ========================================================
        $display("\n========== TEST 11: LCR LATCHING ==========");
        apply_reset();

        // Start as 8E1. Change LCR mid-frame to 5N1.5.
        // Current receive frame must remain 8E1.
        lcr = 8'h1B;

        push_before = push_count;
        pe_before   = parity_error_count;
        fe_before   = framing_error_count;

        fork
            begin
                send_uart_frame(8'h13, 8'h1B, 1'b0, 1'b0);
            end

            begin
                // Change after start bit is already confirmed.
                wait_baud_ticks(20);
                lcr = 8'h04;
            end
        join

        wait_for_receiver_to_finish();

        check_delta(push_before, push_count, 1,
                    "Latched-LCR frame pushes one byte");
        check(last_rx_data == 8'h13,
              "Latched-LCR frame keeps original 8-bit data");
        check_delta(pe_before, parity_error_count, 0,
                    "Latched-LCR frame keeps original parity mode");
        check_delta(fe_before, framing_error_count, 0,
                    "Latched-LCR frame keeps original stop format");

        // ========================================================
        // Final result
        // ========================================================
        $display("\n========================================");

        if (failures == 0)
            $display("ALL UART RX TESTS PASSED. Checks: %0d", checks);
        else
            $display("UART RX TESTS FAILED. Failures: %0d / %0d",
                     failures, checks);

        $display("========================================\n");

        #100;
        $finish;
    end

endmodule