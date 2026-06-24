`timescale 1ns / 1ps

// ============================================================
// Self-checking testbench for fifo_8x16
//
// Instantiates two FIFOs:
//   1. TX FIFO: CPU writes bytes, UART transmitter pops bytes
//   2. RX FIFO: UART receiver pushes bytes, CPU reads bytes
//
// Test coverage:
//   - Reset behavior
//   - Normal TX FIFO write/read order
//   - Normal RX FIFO write/read order
//   - RX threshold trigger
//   - TX FIFO full and overrun
//   - RX FIFO empty and underrun
//   - Simultaneous push + pop
//   - FIFO enable behavior
// ============================================================

module fifo_8x16_tb;

    // --------------------------------------------------------
    // Common clock and reset
    // --------------------------------------------------------
    logic clk;
    logic rst;

    // ========================================================
    // TX FIFO signals
    // ========================================================
    logic       tx_en;
    logic       tx_push_in;
    logic       tx_pop_in;
    logic [7:0] tx_din;
    logic [4:0] tx_threshold;

    logic [7:0] tx_dout;
    logic       tx_empty;
    logic       tx_full;
    logic       tx_overrun;
    logic       tx_underrun;
    logic       tx_threshold_trigger;
    logic [4:0] tx_count;

    // ========================================================
    // RX FIFO signals
    // ========================================================
    logic       rx_en;
    logic       rx_push_in;
    logic       rx_pop_in;
    logic [7:0] rx_din;
    logic [4:0] rx_threshold;

    logic [7:0] rx_dout;
    logic       rx_empty;
    logic       rx_full;
    logic       rx_overrun;
    logic       rx_underrun;
    logic       rx_threshold_trigger;
    logic [4:0] rx_count;

    // --------------------------------------------------------
    // Scoreboards:
    // These queues act as the expected/golden FIFO behavior.
    //
    // Every accepted push adds an item.
    // Every accepted pop removes the oldest item.
    // --------------------------------------------------------
    byte unsigned tx_model[$];
    byte unsigned rx_model[$];

    integer tests_run;
    integer tests_failed;
    integer i;

    // ========================================================
    // DUT 1: TX FIFO
    //
    // In the real UART:
    // push_in = CPU writes a byte to transmit register/FIFO
    // pop_in  = UART TX logic requests the next byte
    // ========================================================
    fifo_8x16 tx_fifo (
        .clk               (clk),
        .rst               (rst),
        .en                (tx_en),
        .push_in           (tx_push_in),
        .pop_in            (tx_pop_in),
        .din               (tx_din),
        .dout              (tx_dout),
        .empty             (tx_empty),
        .full              (tx_full),
        .count             (tx_count),
        .overrun           (tx_overrun),
        .underrun          (tx_underrun),
        .threshold         (tx_threshold),
        .threshold_trigger (tx_threshold_trigger)
    );

    // ========================================================
    // DUT 2: RX FIFO
    //
    // In the real UART:
    // push_in = UART RX logic receives a completed byte
    // pop_in  = CPU reads a received byte
    // ========================================================
    fifo_8x16 rx_fifo (
        .clk               (clk),
        .rst               (rst),
        .en                (rx_en),
        .push_in           (rx_push_in),
        .pop_in            (rx_pop_in),
        .din               (rx_din),
        .dout              (rx_dout),
        .empty             (rx_empty),
        .full              (rx_full),
        .count             (rx_count),
        .overrun           (rx_overrun),
        .underrun          (rx_underrun),
        .threshold         (rx_threshold),
        .threshold_trigger (rx_threshold_trigger)
    );

    // --------------------------------------------------------
    // Clock generator: 100 MHz clock, period = 10 ns
    // --------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ========================================================
    // PASS / FAIL helper tasks
    // ========================================================

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            tests_run++;

            if (condition === 1'b1) begin
                $display("PASS [%0d] %s", tests_run, message);
            end
            else begin
                tests_failed++;
                $display("FAIL [%0d] %s | time = %0t",
                         tests_run, message, $time);
            end
        end
    endtask

    task automatic check_byte(
        input logic [7:0] actual,
        input logic [7:0] expected,
        input string message
    );
        begin
            tests_run++;

            if (actual === expected) begin
                $display("PASS [%0d] %s | data = 0x%02h",
                         tests_run, message, actual);
            end
            else begin
                tests_failed++;
                $display("FAIL [%0d] %s | expected = 0x%02h, got = 0x%02h",
                         tests_run, message, expected, actual);
            end
        end
    endtask

    // ========================================================
    // Reset both FIFO instances
    // ========================================================
    task automatic apply_reset;
        begin
            rst          = 1'b1;

            tx_en        = 1'b1;
            tx_push_in   = 1'b0;
            tx_pop_in    = 1'b0;
            tx_din       = 8'h00;
            tx_threshold = 5'd0;

            rx_en        = 1'b1;
            rx_push_in   = 1'b0;
            rx_pop_in    = 1'b0;
            rx_din       = 8'h00;
            rx_threshold = 5'd0;

            tx_model.delete();
            rx_model.delete();

            repeat (2) @(posedge clk);

            @(negedge clk);
            rst = 1'b0;

            @(posedge clk);
            #1;
        end
    endtask

    // ========================================================
    // TX FIFO helper tasks
    // ========================================================

    // CPU writes one byte into TX FIFO.
    task automatic tx_push(input logic [7:0] data);
        begin
            @(negedge clk);
            tx_din     = data;
            tx_push_in = 1'b1;
            tx_pop_in  = 1'b0;

            @(posedge clk);
            #1;

            tx_push_in = 1'b0;

            // Update expected model after a valid push.
            tx_model.push_back(data);

            check(tx_count == tx_model.size(),
                  "TX FIFO count correct after push");
        end
    endtask

    // UART transmitter reads/removes one byte from TX FIFO.
    task automatic tx_pop_and_check(input logic [7:0] expected_data);
        begin
            // Before pop, dout must show the oldest stored byte.
            @(negedge clk);
            check_byte(tx_dout, expected_data,
                       "TX FIFO provides correct oldest byte");

            tx_pop_in  = 1'b1;
            tx_push_in = 1'b0;

            @(posedge clk);
            #1;

            tx_pop_in = 1'b0;

            // Remove expected oldest byte from scoreboard.
            tx_model.pop_front();

            check(tx_count == tx_model.size(),
                  "TX FIFO count correct after pop");
        end
    endtask

    // ========================================================
    // RX FIFO helper tasks
    // ========================================================

    // UART receiver places one received byte into RX FIFO.
    task automatic rx_push(input logic [7:0] data);
        begin
            @(negedge clk);
            rx_din     = data;
            rx_push_in = 1'b1;
            rx_pop_in  = 1'b0;

            @(posedge clk);
            #1;

            rx_push_in = 1'b0;

            // Update expected model after valid push.
            rx_model.push_back(data);

            check(rx_count == rx_model.size(),
                  "RX FIFO count correct after push");
        end
    endtask

    // CPU reads/removes one byte from RX FIFO.
    task automatic rx_pop_and_check(input logic [7:0] expected_data);
        begin
            // Before pop, dout must show oldest received byte.
            @(negedge clk);
            check_byte(rx_dout, expected_data,
                       "RX FIFO provides correct oldest byte");

            rx_pop_in  = 1'b1;
            rx_push_in = 1'b0;

            @(posedge clk);
            #1;

            rx_pop_in = 1'b0;

            // Remove expected oldest byte from scoreboard.
            rx_model.pop_front();

            check(rx_count == rx_model.size(),
                  "RX FIFO count correct after pop");
        end
    endtask

    // ========================================================
    // Main test sequence
    // ========================================================
    initial begin
        tests_run    = 0;
        tests_failed = 0;

        // ----------------------------------------------------
        // TEST 1: Reset
        // ----------------------------------------------------
        $display("\n========== TEST 1: RESET ==========");
        apply_reset();

        check(tx_empty == 1'b1, "TX FIFO is empty after reset");
        check(tx_full  == 1'b0, "TX FIFO is not full after reset");
        check(tx_count == 5'd0, "TX FIFO count is zero after reset");

        check(rx_empty == 1'b1, "RX FIFO is empty after reset");
        check(rx_full  == 1'b0, "RX FIFO is not full after reset");
        check(rx_count == 5'd0, "RX FIFO count is zero after reset");

        // ----------------------------------------------------
        // TEST 2: TX FIFO normal behavior
        //
        // Simulates CPU writing "HELLO", then UART TX consuming it.
        // ----------------------------------------------------
        $display("\n========== TEST 2: TX FIFO NORMAL ORDER ==========");
        apply_reset();

        tx_push(8'h48); // H
        tx_push(8'h45); // E
        tx_push(8'h4C); // L
        tx_push(8'h4C); // L
        tx_push(8'h4F); // O

        check(tx_count == 5'd5, "TX FIFO stores five bytes");

        tx_pop_and_check(8'h48); // H
        tx_pop_and_check(8'h45); // E
        tx_pop_and_check(8'h4C); // L
        tx_pop_and_check(8'h4C); // L
        tx_pop_and_check(8'h4F); // O

        check(tx_empty == 1'b1, "TX FIFO empty after all bytes are sent");

        // ----------------------------------------------------
        // TEST 3: RX FIFO normal behavior and threshold
        //
        // Simulates UART RX receiving four bytes before CPU reads.
        // ----------------------------------------------------
        $display("\n========== TEST 3: RX FIFO + THRESHOLD ==========");
        apply_reset();

        rx_threshold = 5'd4;

        rx_push(8'h17);
        rx_push(8'hC0);
        rx_push(8'h55);

        check(rx_threshold_trigger == 1'b0,
              "RX threshold remains low below four bytes");

        rx_push(8'hAA);

        check(rx_count == 5'd4, "RX FIFO count reaches four");
        check(rx_threshold_trigger == 1'b1,
              "RX threshold asserts at four bytes");

        rx_pop_and_check(8'h17);

        check(rx_threshold_trigger == 1'b0,
              "RX threshold clears when count drops below four");

        rx_pop_and_check(8'hC0);
        rx_pop_and_check(8'h55);
        rx_pop_and_check(8'hAA);

        check(rx_empty == 1'b1, "RX FIFO empty after CPU reads all data");

        // ----------------------------------------------------
        // TEST 4: TX FIFO full condition and overrun
        // ----------------------------------------------------
        $display("\n========== TEST 4: TX FIFO FULL + OVERRUN ==========");
        apply_reset();

        for (i = 0; i < 16; i++) begin
            tx_push(i[7:0]);
        end

        check(tx_full  == 1'b1, "TX FIFO full after sixteen pushes");
        check(tx_count == 5'd16, "TX FIFO count equals sixteen");
        check_byte(tx_dout, 8'h00,
                   "TX FIFO retains first byte at output");

        // Invalid push while FIFO is full.
        @(negedge clk);
        tx_din     = 8'hA5;
        tx_push_in = 1'b1;

        @(posedge clk);
        #1;

        check(tx_overrun == 1'b1,
              "TX overrun asserts on push to full FIFO");
        check(tx_count == 5'd16,
              "TX FIFO count unchanged after invalid push");

        tx_push_in = 1'b0;

        @(posedge clk);
        #1;

        check(tx_overrun == 1'b0,
              "TX overrun clears after one clock cycle");

        // Confirm all 16 values leave in the same order.
        for (i = 0; i < 16; i++) begin
            tx_pop_and_check(i[7:0]);
        end

        check(tx_empty == 1'b1, "TX FIFO empty after sixteen pops");

        // ----------------------------------------------------
        // TEST 5: RX FIFO empty condition and underrun
        // ----------------------------------------------------
        $display("\n========== TEST 5: RX FIFO EMPTY + UNDERRUN ==========");
        apply_reset();

        @(negedge clk);
        rx_pop_in = 1'b1;

        @(posedge clk);
        #1;

        check(rx_underrun == 1'b1,
              "RX underrun asserts on pop from empty FIFO");
        check(rx_count == 5'd0,
              "RX FIFO count remains zero after invalid pop");

        rx_pop_in = 1'b0;

        @(posedge clk);
        #1;

        check(rx_underrun == 1'b0,
              "RX underrun clears after one clock cycle");

        // ----------------------------------------------------
        // TEST 6: Simultaneous push and pop on TX FIFO
        //
        // FIFO initially contains 11, 22.
        // A pop removes 11 while push adds AA.
        // Final FIFO order must be 22, AA.
        // ----------------------------------------------------
        $display("\n========== TEST 6: SIMULTANEOUS PUSH + POP ==========");
        apply_reset();

        tx_push(8'h11);
        tx_push(8'h22);

        @(negedge clk);

        check_byte(tx_dout, 8'h11,
                   "TX FIFO oldest byte correct before simultaneous transfer");

        tx_din     = 8'hAA;
        tx_push_in = 1'b1;
        tx_pop_in  = 1'b1;

        @(posedge clk);
        #1;

        tx_push_in = 1'b0;
        tx_pop_in  = 1'b0;

        // Update scoreboard: remove 11, append AA.
        tx_model.pop_front();
        tx_model.push_back(8'hAA);

        check(tx_count == 5'd2,
              "TX count unchanged after simultaneous push and pop");
        check_byte(tx_dout, 8'h22,
                   "TX FIFO next oldest byte is correct");

        tx_pop_and_check(8'h22);
        tx_pop_and_check(8'hAA);

        // ----------------------------------------------------
        // TEST 7: RX FIFO disabled
        // ----------------------------------------------------
        $display("\n========== TEST 7: RX FIFO ENABLE ==========");
        apply_reset();

        rx_en = 1'b0;

        @(negedge clk);
        rx_din     = 8'h5A;
        rx_push_in = 1'b1;

        @(posedge clk);
        #1;

        rx_push_in = 1'b0;

        check(rx_count == 5'd0,
              "Disabled RX FIFO ignores push request");
        check(rx_empty == 1'b1,
              "Disabled RX FIFO remains empty");

        rx_en = 1'b1;

        // ----------------------------------------------------
        // Final result
        // ----------------------------------------------------
        $display("\n========================================");

        if (tests_failed == 0) begin
            $display("ALL FIFO TESTS PASSED. Total checks: %0d", tests_run);
        end
        else begin
            $display("FIFO TESTS FAILED. Failed: %0d out of %0d",
                     tests_failed, tests_run);
        end

        $display("========================================\n");

        #20;
        $finish;
    end

endmodule