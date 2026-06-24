module uarttx #(
    parameter integer CLK_FREQ  = 1000000,
    parameter integer BAUD_RATE = 9600
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       newd,       // Pulse high to request transmission
    input  wire [7:0] tx_data,    // Byte to transmit
    output reg        tx,         // UART TX serial output
    output reg        donetx      // Goes high for one baud-clock cycle after TX
);

    // Number of system-clock cycles per UART bit.
    localparam integer CLKS_PER_BIT      = CLK_FREQ / BAUD_RATE;
    localparam integer HALF_CLKS_PER_BIT = CLKS_PER_BIT / 2;

    // FSM state encoding: plain Verilog style.
    localparam [1:0] IDLE     = 2'b00;
    localparam [1:0] START    = 2'b01;
    localparam [1:0] TRANSFER = 2'b10;
    localparam [1:0] DONE     = 2'b11;

    reg [1:0] state;

    // Counter for generating the baud-rate clock.
    integer count;

    // Counts which data bit is currently being transmitted: 0 to 7.
    reg [2:0] bit_count;

    // Internal baud-rate clock.
    reg uclk;

    // Stores tx_data while it is being transmitted.
    reg [7:0] din;

    // ------------------------------------------------------------
    // Baud-rate clock generator.
    // uclk has one rising edge per UART bit period.
    // ------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            count <= 0;
            uclk  <= 1'b0;
        end
        else begin
            if (count == HALF_CLKS_PER_BIT - 1) begin
                count <= 0;
                uclk  <= ~uclk;
            end
            else begin
                count <= count + 1;
            end
        end
    end

    // ------------------------------------------------------------
    // UART transmitter FSM.
    //
    // UART frame:
    // Idle high -> Start bit low -> 8 data bits, LSB first -> Stop high
    // ------------------------------------------------------------
    always @(posedge uclk or posedge rst) begin
        if (rst) begin
            state     <= IDLE;
            tx        <= 1'b1;   // UART idle line is high
            donetx    <= 1'b0;
            bit_count <= 3'd0;
            din       <= 8'd0;
        end
        else begin
            case (state)

                // Wait for a transmit request.
                IDLE: begin
                    tx        <= 1'b1;
                    donetx    <= 1'b0;
                    bit_count <= 3'd0;

                    if (newd) begin
                        din   <= tx_data;  // Store byte before transmission
                        state <= START;
                    end
                    else begin
                        state <= IDLE;
                    end
                end

                // Drive the UART start bit low for one bit period.
                START: begin
                    tx     <= 1'b0;
                    donetx <= 1'b0;
                    state  <= TRANSFER;
                end

                // Send data bits LSB first: din[0], din[1], ... din[7].
                TRANSFER: begin
                    tx     <= din[bit_count];
                    donetx <= 1'b0;

                    if (bit_count == 3'd7) begin
                        bit_count <= 3'd0;
                        state     <= DONE;
                    end
                    else begin
                        bit_count <= bit_count + 1'b1;
                        state     <= TRANSFER;
                    end
                end

                // Send stop bit high and indicate completion.
                DONE: begin
                    tx     <= 1'b1;  // Stop bit
                    donetx <= 1'b1;
                    state  <= IDLE;
                end

                // Recovery for any invalid/unknown state.
                default: begin
                    state     <= IDLE;
                    tx        <= 1'b1;
                    donetx    <= 1'b0;
                    bit_count <= 3'd0;
                end

            endcase
        end
    end

endmodule