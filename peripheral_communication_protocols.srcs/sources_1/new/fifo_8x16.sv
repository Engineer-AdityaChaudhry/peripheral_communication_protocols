`timescale 1ns / 1ps

// ============================================================
// 8-bit wide, 16-entry synchronous circular FIFO
// ============================================================

module fifo_8x16 (
    input  logic       clk,
    input  logic       rst,
    input  logic       clear_i,   // Synchronous FIFO clear from FCR
    input  logic       en,

    input  logic       push_in,
    input  logic [7:0] din,

    input  logic       pop_in,
    output logic [7:0] dout,

    output logic       empty,
    output logic       full,
    output logic [4:0] count,

    output logic       overrun,
    output logic       underrun,

    input  logic [4:0] threshold,
    output logic       threshold_trigger
);

    logic [7:0] mem [0:15];

    logic [3:0] wr_ptr;
    logic [3:0] rd_ptr;

    logic do_push;
    logic do_pop;

    assign empty = (count == 5'd0);
    assign full  = (count == 5'd16);

    // A valid pop requires stored data.
    assign do_pop = en && pop_in && !empty;

    // When FIFO is full, allow a push only if a valid pop happens
    // in the same clock cycle.
    assign do_push = en && push_in && (!full || do_pop);

    // Oldest valid byte.
    assign dout = empty ? 8'h00 : mem[rd_ptr];

    // Usually used by RX FIFO interrupt logic.
    assign threshold_trigger =
        en && (threshold != 5'd0) && (count >= threshold);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr   <= 4'd0;
            rd_ptr   <= 4'd0;
            count    <= 5'd0;
            overrun  <= 1'b0;
            underrun <= 1'b0;
        end
        else if (clear_i) begin
            // FCR clear command: synchronous clear.
            wr_ptr   <= 4'd0;
            rd_ptr   <= 4'd0;
            count    <= 5'd0;
            overrun  <= 1'b0;
            underrun <= 1'b0;
        end
        else begin
            // Error flags are one-clock pulses.
            overrun  <= 1'b0;
            underrun <= 1'b0;

            if (en && push_in && full && !do_pop)
                overrun <= 1'b1;

            if (en && pop_in && empty)
                underrun <= 1'b1;

            if (do_push) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + 4'd1;
            end

            if (do_pop) begin
                rd_ptr <= rd_ptr + 4'd1;
            end

            case ({do_push, do_pop})
                2'b10: count <= count + 5'd1;
                2'b01: count <= count - 5'd1;
                default: count <= count;
            endcase
        end
    end

endmodule