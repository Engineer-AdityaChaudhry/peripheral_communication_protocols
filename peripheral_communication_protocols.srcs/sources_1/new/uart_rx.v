module uartrx #(
    parameter integer CLK_FREQ  = 1000000,
    parameter integer BAUD_RATE = 9600
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,            // UART serial input
    output reg        done,          // High for one clock after valid byte received
    output reg [7:0]  rxdata,
    output reg        framing_error // High if stop bit is not logic 1
);

    // Number of system-clock cycles in one UART bit period.
    localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    // FSM states.
    localparam [1:0] IDLE       = 2'b00;
    localparam [1:0] START_BIT  = 2'b01;
    localparam [1:0] DATA_BITS  = 2'b10;
    localparam [1:0] STOP_BIT   = 2'b11;

    reg [1:0] state;

    // Counts clock cycles within one UART bit period.
    integer clk_count;

    // Counts received data bits: 0 through 7.
    reg [2:0] bit_count;

    // ------------------------------------------------------------
    // UART Receiver FSM
    //
    // UART frame:
    // Idle high -> Start bit low -> 8 data bits LSB first -> Stop bit high
    // ------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= IDLE;
            clk_count     <= 0;
            bit_count     <= 3'd0;
            rxdata        <= 8'd0;
            done          <= 1'b0;
            framing_error <= 1'b0;
        end
        else begin
            // Default: done is asserted for only one system-clock cycle.
            done <= 1'b0;

            case (state)

                // Wait until a low level appears on RX.
                IDLE: begin
                    clk_count     <= 0;
                    bit_count     <= 3'd0;
                    framing_error <= 1'b0;

                    if (rx == 1'b0)
                        state <= START_BIT;
                end

                // Wait half a bit period, then confirm RX is still low.
                // This rejects short glitches on the RX line.
                START_BIT: begin
                    if (clk_count == (CLKS_PER_BIT / 2) - 1) begin
                        clk_count <= 0;

                        if (rx == 1'b0)
                            state <= DATA_BITS;
                        else
                            state <= IDLE; // False start bit / noise
                    end
                    else begin
                        clk_count <= clk_count + 1;
                    end
                end

                // Sample each data bit in the middle of its bit period.
                // UART sends data LSB first.
                DATA_BITS: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 0;

                        // Store current serial bit in bit_count position.
                        rxdata[bit_count] <= rx;

                        if (bit_count == 3'd7) begin
                            bit_count <= 3'd0;
                            state     <= STOP_BIT;
                        end
                        else begin
                            bit_count <= bit_count + 1'b1;
                        end
                    end
                    else begin
                        clk_count <= clk_count + 1;
                    end
                end

                // Verify stop bit after one full bit period.
                STOP_BIT: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 0;

                        if (rx == 1'b1) begin
                            done          <= 1'b1;
                            framing_error <= 1'b0;
                        end
                        else begin
                            framing_error <= 1'b1;
                        end

                        state <= IDLE;
                    end
                    else begin
                        clk_count <= clk_count + 1;
                    end
                end

                default: begin
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule