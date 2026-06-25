`timescale 1ns / 1ps

module ad5628_spi_master (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [31:0] frame_i,
    input  logic [15:0] clk_div_i,

    output logic        sync_n_o,
    output logic        sclk_o,
    output logic        mosi_o,
    output logic        busy_o,
    output logic        done_o
);

    typedef enum logic [1:0] {
        IDLE,
        TRANSFER,
        FINISH
    } state_t;

    state_t state;

    logic [31:0] tx_shift;
    logic [15:0] clk_div_latched;
    logic [15:0] div_count;
    logic [5:0]  edge_count;

    logic start_d;
    logic start_pulse;

    assign start_pulse = start && !start_d;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= IDLE;
            sync_n_o        <= 1'b1;
            sclk_o          <= 1'b0;
            mosi_o          <= 1'b0;
            busy_o          <= 1'b0;
            done_o          <= 1'b0;
            tx_shift        <= 32'h0000_0000;
            clk_div_latched <= 16'd1;
            div_count       <= 16'd0;
            edge_count      <= 6'd0;
            start_d         <= 1'b0;
        end else begin
            start_d <= start;
            done_o  <= 1'b0;

            case (state)
                IDLE: begin
                    sync_n_o   <= 1'b1;
                    sclk_o     <= 1'b0;
                    mosi_o     <= 1'b0;
                    busy_o     <= 1'b0;
                    div_count  <= 16'd0;
                    edge_count <= 6'd0;

                    if (start_pulse) begin
                        tx_shift <= frame_i;

                        if (clk_div_i == 16'd0)
                            clk_div_latched <= 16'd1;
                        else
                            clk_div_latched <= clk_div_i;

                        sync_n_o <= 1'b0;
                        sclk_o   <= 1'b0;
                        mosi_o   <= 1'b0;
                        busy_o   <= 1'b1;
                        state    <= TRANSFER;
                    end
                end

                TRANSFER: begin
                    if (div_count == (clk_div_latched - 16'd1)) begin
                        div_count <= 16'd0;

                        if (sclk_o == 1'b0) begin
                            sclk_o   <= 1'b1;
                            mosi_o   <= tx_shift[31];
                            tx_shift <= {tx_shift[30:0], 1'b0};
                        end else begin
                            sclk_o <= 1'b0;
                        end

                        if (edge_count == 6'd63) begin
                            edge_count <= 6'd0;
                            state      <= FINISH;
                        end else begin
                            edge_count <= edge_count + 1'b1;
                        end
                    end else begin
                        div_count <= div_count + 1'b1;
                    end
                end

                FINISH: begin
                    sync_n_o <= 1'b1;
                    sclk_o   <= 1'b0;
                    mosi_o   <= 1'b0;
                    busy_o   <= 1'b0;
                    done_o   <= 1'b1;
                    state    <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule


