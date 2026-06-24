`timescale 1ns / 1ps

// ============================================================
// 8-bit wide, 16-entry synchronous circular FIFO
//
// Intended uses:
//   - TX FIFO: stores bytes written by CPU before UART TX sends them
//   - RX FIFO: stores bytes received by UART RX before CPU reads them
//
// Capacity:
//   - Width = 8 bits  = one byte per entry
//   - Depth = 16      = can store up to 16 bytes
// ============================================================

module fifo_8x16 (

    // ---------------- Clock and control ----------------
    input  logic       clk,
    input  logic       rst,       // Active-high asynchronous reset
    input  logic       en,        // FIFO enable; 0 = ignore push/pop requests

    // ---------------- Write / push interface ----------------
    input  logic       push_in,   // Request to write din into FIFO
    input  logic [7:0] din,       // Byte to be written

    // ---------------- Read / pop interface ----------------
    input  logic       pop_in,    // Request to remove oldest byte
    output logic [7:0] dout,      // Oldest FIFO byte; valid when empty = 0

    // ---------------- Status outputs ----------------
    output logic       empty,     // 1 when FIFO has zero bytes
    output logic       full,      // 1 when FIFO has 16 bytes
    output logic [4:0] count,     // Number of stored bytes: 0 to 16

    // ---------------- Error outputs ----------------
    output logic       overrun,   // One-clock pulse: push attempted when full
    output logic       underrun,  // One-clock pulse: pop attempted when empty

    // ---------------- Threshold output ----------------
    input  logic [4:0] threshold,         // Valid values: 1 to 16; 0 disables trigger
    output logic       threshold_trigger  // 1 when count >= threshold
);

    // --------------------------------------------------------
    // FIFO memory:
    // 16 entries, each entry stores one 8-bit byte.
    //
    // mem[0] through mem[15]
    // --------------------------------------------------------
    logic [7:0] mem [0:15];

    // --------------------------------------------------------
    // Circular pointers:
    //
    // wr_ptr = location where the next pushed byte is stored
    // rd_ptr = location containing the next byte to be popped
    //
    // Four bits can represent addresses 0 through 15.
    // Pointer wrap-around happens automatically after address 15.
    // --------------------------------------------------------
    logic [3:0] wr_ptr;
    logic [3:0] rd_ptr;

    // Internal accepted transactions.
    logic do_push;
    logic do_pop;

    // --------------------------------------------------------
    // Status flags based on occupancy count.
    //
    // count needs 5 bits because it must represent 0 to 16.
    // Four bits would only represent 0 to 15.
    // --------------------------------------------------------
    assign empty = (count == 5'd0);
    assign full  = (count == 5'd16);

    // --------------------------------------------------------
    // A pop is accepted only when:
    //   1. FIFO is enabled
    //   2. pop_in is requested
    //   3. FIFO is not empty
    // --------------------------------------------------------
    assign do_pop = en && pop_in && !empty;

    // --------------------------------------------------------
    // A push is accepted only when:
    //   1. FIFO is enabled
    //   2. push_in is requested
    //   3. FIFO is not full
    //
    // Exception:
    // A write is allowed when full if a valid pop happens during
    // the same clock cycle. One byte leaves and one enters, so
    // the FIFO remains full.
    // --------------------------------------------------------
    assign do_push = en && push_in && (!full || do_pop);

    // --------------------------------------------------------
    // FIFO output:
    //
    // dout always shows the oldest stored byte.
    // When FIFO is empty, dout is forced to 0 because no valid
    // byte is available. Always check empty before using dout.
    // --------------------------------------------------------
    assign dout = empty ? 8'h00 : mem[rd_ptr];

    // --------------------------------------------------------
    // Threshold output:
    //
    // Usually useful for RX FIFO interrupt generation.
    //
    // Example:
    // threshold = 4
    // count >= 4 -> threshold_trigger = 1
    //
    // threshold = 0 disables this output.
    // --------------------------------------------------------
    assign threshold_trigger =
        en && (threshold != 5'd0) && (count >= threshold);

    // ============================================================
    // Main sequential FIFO logic
    // ============================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            // Reset pointers and occupancy.
            wr_ptr   <= 4'd0;
            rd_ptr   <= 4'd0;
            count    <= 5'd0;

            // Clear one-cycle error flags.
            overrun  <= 1'b0;
            underrun <= 1'b0;

            // Memory does not need resetting.
            // Since count = 0, empty = 1 and old memory data is ignored.
        end
        else begin
            // Default: error flags are one-clock pulses.
            overrun  <= 1'b0;
            underrun <= 1'b0;

            // ----------------------------------------------------
            // Overrun:
            // CPU/device tried to push when FIFO was full and
            // there was no valid simultaneous pop.
            // ----------------------------------------------------
            if (en && push_in && full && !do_pop) begin
                overrun <= 1'b1;
            end

            // ----------------------------------------------------
            // Underrun:
            // CPU/device tried to pop when FIFO was empty.
            // ----------------------------------------------------
            if (en && pop_in && empty) begin
                underrun <= 1'b1;
            end

            // ----------------------------------------------------
            // Push operation:
            // Store din at wr_ptr, then advance write pointer.
            // ----------------------------------------------------
            if (do_push) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + 4'd1;
            end

            // ----------------------------------------------------
            // Pop operation:
            // The consumer uses dout, then rd_ptr advances so the
            // next stored byte becomes the new oldest byte.
            // ----------------------------------------------------
            if (do_pop) begin
                rd_ptr <= rd_ptr + 4'd1;
            end

            // ----------------------------------------------------
            // Update FIFO occupancy count.
            //
            // push only:      count increases
            // pop only:       count decreases
            // push + pop:     count unchanged
            // neither:        count unchanged
            // ----------------------------------------------------
            case ({do_push, do_pop})
                2'b10: count <= count + 5'd1;
                2'b01: count <= count - 5'd1;
                default: count <= count;
            endcase
        end
    end

endmodule