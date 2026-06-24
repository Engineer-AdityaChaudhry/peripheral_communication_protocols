`timescale 1ns / 1ps

module uart_tx_tb;

    logic clk;
    logic rst;
    logic baud16_tick;

    logic [7:0] lcr;

    logic [7:0] tx_fifo_dout;
    logic       tx_fifo_empty;
    logic       tx_fifo_pop;

    logic tx;
    logic sreg_empty;

    // Testbench-only fixed 16-byte FIFO model.
    // A fixed array is more deterministic in Vivado XSim than a queue.
    logic [7:0] fifo_model [0:15];
    integer fifo_head;
    integer fifo_tail;
    integer fifo_count;

    integer checks;
    integer failures;
    integer pop_count;

    localparam integer TICK_DIV = 1;

    uart_tx dut (
        .clk           (clk),
        .rst           (rst),
        .baud16_tick   (baud16_tick),

        .tx_fifo_empty (tx_fifo_empty),
        .tx_fifo_dout  (tx_fifo_dout),
        .tx_fifo_pop   (tx_fifo_pop),

        .lcr           (lcr),

        .tx            (tx),
        .sreg_empty    (sreg_empty)
    );

    // --------------------------------------------------------
    // System clock: 100 MHz
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // --------------------------------------------------------
    // Mock 16x baud tick: one clock-wide enable pulse.
    // --------------------------------------------------------
    initial begin
        baud16_tick = 1'b0;

        forever begin
            repeat (TICK_DIV) @(negedge clk);
            baud16_tick = 1'b1;

            @(negedge clk);
            baud16_tick = 1'b0;
        end
    end

    // --------------------------------------------------------
    // Behavioral FIFO model
    // --------------------------------------------------------
    always_comb begin
        tx_fifo_empty = (fifo_count == 0);

        if (fifo_count == 0)
            tx_fifo_dout = 8'h00;
        else
            tx_fifo_dout = fifo_model[fifo_head];
    end

    always @(posedge clk) begin
        if (rst) begin
            fifo_head = 0;
            fifo_tail = 0;
            fifo_count = 0;
            pop_count = 0;
        end
        else if (tx_fifo_pop) begin
            if (fifo_count == 0) begin
                failures = failures + 1;
                $display("FAIL: TX attempted FIFO pop while FIFO was empty");
            end
            else begin
                if (fifo_head == 15)
                    fifo_head = 0;
                else
                    fifo_head = fifo_head + 1;

                fifo_count = fifo_count - 1;
                pop_count = pop_count + 1;
            end
        end
    end

    // --------------------------------------------------------
    // PASS / FAIL helpers
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
                $display("FAIL [%0d] %s  | time = %0t",
                         checks, message, $time);
            end
        end
    endtask

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

    // Wait for the start bit, but fail cleanly instead of hanging forever.
    task automatic wait_for_tx_start(
        input string frame_name
    );
        integer timeout_cycles;

        begin
            timeout_cycles = 0;

            while ((tx !== 1'b0) && (timeout_cycles < 1000)) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end

            if (tx !== 1'b0) begin
                failures = failures + 1;
                $display(
                    "FAIL: %s never started. empty=%b dout=%02h pop=%b time=%0t",
                    frame_name, tx_fifo_empty, tx_fifo_dout, tx_fifo_pop, $time
                );
                $fatal(1, "Timeout waiting for UART start bit");
            end

            #1;
        end
    endtask

    task automatic enqueue_tx_byte(
        input logic [7:0] data
    );
        begin
            if (fifo_count == 16) begin
                failures = failures + 1;
                $display("FAIL: Testbench FIFO model overflow");
            end
            else begin
                fifo_model[fifo_tail] = data;

                if (fifo_tail == 15)
                    fifo_tail = 0;
                else
                    fifo_tail = fifo_tail + 1;

                fifo_count = fifo_count + 1;
            end
        end
    endtask

    task automatic apply_reset;
        begin
            // Change reset away from a clock edge to avoid testbench races.
            @(negedge clk);
            rst = 1'b1;
            lcr = 8'h03; // Default 8N1.

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            repeat (2) @(posedge clk);
            #1;
        end
    endtask

    function automatic integer data_bits_from_wls(
        input logic [1:0] wls
    );
        case (wls)
            2'b00: data_bits_from_wls = 5;
            2'b01: data_bits_from_wls = 6;
            2'b10: data_bits_from_wls = 7;
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
                2'b00: data_xor = ^data[4:0];
                2'b01: data_xor = ^data[5:0];
                2'b10: data_xor = ^data[6:0];
                default: data_xor = ^data[7:0];
            endcase

            // Stick parity
            if (format_lcr[5])
                expected_parity = format_lcr[4] ? 1'b0 : 1'b1;

            // Even parity
            else if (format_lcr[4])
                expected_parity = data_xor;

            // Odd parity
            else
                expected_parity = ~data_xor;
        end
    endfunction

    task automatic expect_symbol(
        input logic expected_value,
        input integer symbol_ticks,
        input string label
    );
        begin
            check(
                tx === expected_value,
                $sformatf("%s correct at symbol start", label)
            );

            wait_baud_ticks(symbol_ticks / 2);

            check(
                tx === expected_value,
                $sformatf("%s correct at symbol midpoint", label)
            );

            wait_baud_ticks(symbol_ticks - (symbol_ticks / 2));
        end
    endtask

    task automatic check_frame(
        input logic [7:0] expected_data,
        input logic [7:0] expected_lcr,
        input logic       wait_for_start,
        input logic       next_frame_follows,
        input string      frame_name
    );
        integer i;
        integer data_bits;
        integer stop_ticks;
        logic parity_value;

        begin
            data_bits    = data_bits_from_wls(expected_lcr[1:0]);
            stop_ticks   = stop_ticks_from_lcr(
                               expected_lcr[2],
                               expected_lcr[1:0]
                           );
            parity_value = expected_parity(expected_data, expected_lcr);

            if (wait_for_start) begin
                wait_for_tx_start(frame_name);
            end

            expect_symbol(
                1'b0,
                16,
                $sformatf("%s start bit", frame_name)
            );

            for (i = 0; i < data_bits; i = i + 1) begin
                expect_symbol(
                    expected_data[i],
                    16,
                    $sformatf("%s data bit %0d", frame_name, i)
                );
            end

            if (expected_lcr[3]) begin
                expect_symbol(
                    parity_value,
                    16,
                    $sformatf("%s parity bit", frame_name)
                );
            end

            expect_symbol(
                1'b1,
                stop_ticks,
                $sformatf("%s stop bit(s)", frame_name)
            );

            if (next_frame_follows) begin
                check(
                    tx === 1'b0,
                    $sformatf("%s immediately starts next frame", frame_name)
                );
            end
            else begin
                check(
                    tx === 1'b1,
                    $sformatf("%s returns TX line to idle high", frame_name)
                );

                check(
                    sreg_empty === 1'b1,
                    $sformatf("%s leaves transmitter empty", frame_name)
                );
            end
        end
    endtask

    // Whole-testbench watchdog: stops accidental infinite simulations.
    initial begin
        #200_000; // 200 us with `timescale 1ns/1ps
        $fatal(1, "Global UART TX testbench timeout");
    end

    // --------------------------------------------------------
    // Test sequence
    // --------------------------------------------------------
    initial begin
        checks     = 0;
        failures   = 0;
        pop_count  = 0;
        fifo_head  = 0;
        fifo_tail  = 0;
        fifo_count = 0;
        rst        = 1'b0;
        lcr        = 8'h03;

        // ----------------------------------------------------
        // TEST 1: Reset
        // ----------------------------------------------------
        $display("\n========== TEST 1: RESET ==========");
        apply_reset();

        check(tx === 1'b1, "TX is idle high after reset");
        check(sreg_empty === 1'b1, "Shift register is empty after reset");
        check(tx_fifo_pop === 1'b0, "No FIFO pop after reset");

        // ----------------------------------------------------
        // TEST 2: 8N1
        // ----------------------------------------------------
        $display("\n========== TEST 2: 8N1 ==========");
        apply_reset();

        lcr = 8'h03; // 8 data, no parity, 1 stop.
        enqueue_tx_byte(8'hA5);

        check_frame(8'hA5, 8'h03, 1'b1, 1'b0, "8N1 0xA5");
        check(pop_count == 1, "8N1 causes exactly one FIFO pop");

        // ----------------------------------------------------
        // TEST 3: 8E1
        // 0x13 has three ones, so even parity bit must be 1.
        // ----------------------------------------------------
        $display("\n========== TEST 3: 8E1 ==========");
        apply_reset();

        lcr = 8'h1B; // 8 data, even parity, 1 stop.
        enqueue_tx_byte(8'h13);

        check_frame(8'h13, 8'h1B, 1'b1, 1'b0, "8E1 0x13");

        // ----------------------------------------------------
        // TEST 4: 8O1
        // 0x13 has three ones, so odd parity bit must be 0.
        // ----------------------------------------------------
        $display("\n========== TEST 4: 8O1 ==========");
        apply_reset();

        lcr = 8'h0B; // 8 data, odd parity, 1 stop.
        enqueue_tx_byte(8'h13);

        check_frame(8'h13, 8'h0B, 1'b1, 1'b0, "8O1 0x13");

        // ----------------------------------------------------
        // TEST 5: 8N2
        // ----------------------------------------------------
        $display("\n========== TEST 5: 8N2 ==========");
        apply_reset();

        lcr = 8'h07; // 8 data, no parity, 2 stops.
        enqueue_tx_byte(8'h5A);

        check_frame(8'h5A, 8'h07, 1'b1, 1'b0, "8N2 0x5A");

        // ----------------------------------------------------
        // TEST 6: 5N1.5
        // ----------------------------------------------------
        $display("\n========== TEST 6: 5N1.5 ==========");
        apply_reset();

        lcr = 8'h04; // 5 data, no parity, 1.5 stops.
        enqueue_tx_byte(8'h15);

        check_frame(8'h15, 8'h04, 1'b1, 1'b0, "5N1.5 0x15");

        // ----------------------------------------------------
        // TEST 7: Stick / mark parity
        // ----------------------------------------------------
        $display("\n========== TEST 7: MARK PARITY ==========");
        apply_reset();

        lcr = 8'h2B; // 8 data, parity, SP=1, EPS=0 => parity forced high.
        enqueue_tx_byte(8'h00);

        check_frame(8'h00, 8'h2B, 1'b1, 1'b0, "8M1 0x00");

        // ----------------------------------------------------
        // TEST 8: Two back-to-back FIFO bytes
        // ----------------------------------------------------
        $display("\n========== TEST 8: BACK-TO-BACK ==========");
        apply_reset();

        lcr = 8'h03;

        enqueue_tx_byte(8'h55);
        enqueue_tx_byte(8'hAA);

        check_frame(8'h55, 8'h03, 1'b1, 1'b1, "Back-to-back byte 1");
        check_frame(8'hAA, 8'h03, 1'b0, 1'b0, "Back-to-back byte 2");

        check(pop_count == 2, "Two queued bytes cause exactly two FIFO pops");

        // ----------------------------------------------------
        // TEST 9: LCR is latched per transmitted frame
        // Change LCR from 8N1 to 8N2 during frame transmission.
        // Current frame must remain 8N1.
        // ----------------------------------------------------
        $display("\n========== TEST 9: LCR LATCHING ==========");
        apply_reset();

        lcr = 8'h03;
        enqueue_tx_byte(8'hC3);

        fork
            begin
                wait_for_tx_start("LCR-latching stimulus");
                wait_baud_ticks(4);
                lcr = 8'h07; // Try to change active frame to 8N2.
            end

            begin
                check_frame(
                    8'hC3,
                    8'h03,
                    1'b1,
                    1'b0,
                    "Latched 8N1 frame"
                );
            end
        join

        // ----------------------------------------------------
        // TEST 10: Break control
        // ----------------------------------------------------
        $display("\n========== TEST 10: BREAK CONTROL ==========");
        apply_reset();

        lcr = 8'h43; // 8N1 + LCR[6] break control.
        #1;
        check(tx === 1'b0, "Break control forces TX low");

        lcr = 8'h03;
        #1;
        check(tx === 1'b1, "TX returns high when break is cleared");

        // ----------------------------------------------------
        // Final result
        // ----------------------------------------------------
        $display("\n========================================");

        if (failures == 0)
            $display("ALL UART TX TESTS PASSED. Checks: %0d", checks);
        else
            $display("UART TX TESTS FAILED. Failures: %0d / %0d",
                     failures, checks);

        $display("========================================\n");

        #100;
        $finish;
    end

endmodule