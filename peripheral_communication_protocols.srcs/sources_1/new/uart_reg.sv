`timescale 1ns / 1ps

// ============================================================
// 16550A-inspired UART Register Bank
//
// Register map:
//   0x0  DLAB=0: THR write / RBR read
//   0x0  DLAB=1: DLL
//   0x1  DLAB=0: IER
//   0x1  DLAB=1: DLM
//   0x2  Read: IIR, Write: FCR
//   0x3  LCR
//   0x4  MCR
//   0x5  LSR
//   0x6  MSR (returns 0 in this version)
//   0x7  Scratch register
//
// Notes:
// - FIFO clear outputs are one-clock pulses.
// - Add synchronous clear inputs to your FIFO modules later.
// - FIFOs remain physically active even when FCR[0] = 0.
//   FCR[0] currently affects threshold/interrupt behavior.
// ============================================================

module uart_register (
    input  logic       clk,
    input  logic       rst,

    // --------------------------------------------------------
    // Simple CPU/register-bus interface
    // --------------------------------------------------------
    input  logic       wr_i,
    input  logic       rd_i,
    input  logic [2:0] addr_i,
    input  logic [7:0] din_i,
    output logic [7:0] dout_o,

    // --------------------------------------------------------
    // TX FIFO interface
    // --------------------------------------------------------
    output logic       tx_fifo_push_o,
    output logic [7:0] tx_fifo_din_o,
    input  logic       tx_fifo_empty_i,
    input  logic       tx_fifo_full_i,
    input  logic       tx_sreg_empty_i,

    // --------------------------------------------------------
    // RX FIFO interface
    // --------------------------------------------------------
    output logic       rx_fifo_pop_o,
    input  logic [7:0] rx_fifo_dout_i,
    input  logic       rx_fifo_empty_i,
    input  logic       rx_fifo_threshold_hit_i,

    // --------------------------------------------------------
    // UART RX error-event inputs
    // These are one-clock pulses from uart_rx.sv.
    // --------------------------------------------------------
    input  logic       rx_oe_i,
    input  logic       rx_pe_i,
    input  logic       rx_fe_i,
    input  logic       rx_bi_i,

    // --------------------------------------------------------
    // FIFO control outputs
    // --------------------------------------------------------
    output logic       tx_fifo_clear_o,
    output logic       rx_fifo_clear_o,
    output logic       fifo_enable_o,
    output logic [4:0] rx_fifo_threshold_o,

    // --------------------------------------------------------
    // UART configuration outputs
    // --------------------------------------------------------
    output logic [7:0]  lcr_o,
    output logic [7:0]  mcr_o,
    output logic [3:0]  ier_o,
    output logic [15:0] divisor_o,
    output logic        baud16_tick_o,

    // --------------------------------------------------------
    // Status/interrupt outputs
    // --------------------------------------------------------
    output logic [7:0] lsr_o,
    output logic [7:0] iir_o,
    output logic       irq_o
);

    // --------------------------------------------------------
    // Address constants
    // --------------------------------------------------------
    localparam logic [2:0] ADDR_DATA = 3'h0;
    localparam logic [2:0] ADDR_IER  = 3'h1;
    localparam logic [2:0] ADDR_IIR_FCR = 3'h2;
    localparam logic [2:0] ADDR_LCR  = 3'h3;
    localparam logic [2:0] ADDR_MCR  = 3'h4;
    localparam logic [2:0] ADDR_LSR  = 3'h5;
    localparam logic [2:0] ADDR_MSR  = 3'h6;
    localparam logic [2:0] ADDR_SCR  = 3'h7;

    // --------------------------------------------------------
    // Internal registers
    // --------------------------------------------------------
    logic [7:0] lcr_reg;
    logic [7:0] mcr_reg;
    logic [7:0] scr_reg;

    logic [3:0] ier_reg;

    logic [7:0] dll_reg;
    logic [7:0] dlm_reg;

    // FCR fields
    logic       fcr_enable_reg;
    logic       fcr_dma_mode_reg;
    logic [1:0] fcr_rx_trigger_reg;

    // Sticky Line Status error bits
    logic lsr_oe_sticky;
    logic lsr_pe_sticky;
    logic lsr_fe_sticky;
    logic lsr_bi_sticky;
    logic lsr_rx_fifo_error_sticky;

    // Baud-rate counter
    logic [15:0] baud_count;
    logic [15:0] divisor_value;
    logic [15:0] divisor_effective;

    // Transaction decode signals
    logic write_thr;
    logic read_rbr;
    logic write_dll;
    logic write_dlm;
    logic write_ier;
    logic write_fcr;
    logic write_lcr;
    logic write_mcr;
    logic write_scr;
    logic read_lsr;
    logic write_divisor;
    logic write_fcr_clear_rx;

    // Interrupt signals
    logic line_status_irq_pending;
    logic rx_data_irq_pending;
    logic tx_empty_irq_pending;

    // --------------------------------------------------------
    // Decode bus accesses
    // --------------------------------------------------------
    always_comb begin
        write_thr = wr_i && (addr_i == ADDR_DATA) && !lcr_reg[7];
        read_rbr  = rd_i && (addr_i == ADDR_DATA) && !lcr_reg[7];

        write_dll = wr_i && (addr_i == ADDR_DATA) &&  lcr_reg[7];
        write_dlm = wr_i && (addr_i == ADDR_IER)  &&  lcr_reg[7];

        write_ier = wr_i && (addr_i == ADDR_IER) && !lcr_reg[7];
        write_fcr = wr_i && (addr_i == ADDR_IIR_FCR);
        write_lcr = wr_i && (addr_i == ADDR_LCR);
        write_mcr = wr_i && (addr_i == ADDR_MCR);
        write_scr = wr_i && (addr_i == ADDR_SCR);

        read_lsr = rd_i && (addr_i == ADDR_LSR);

        write_divisor     = write_dll || write_dlm;
        write_fcr_clear_rx = write_fcr && din_i[1];

        // CPU writes THR only when TX FIFO has room.
        tx_fifo_push_o = write_thr && !tx_fifo_full_i;
        tx_fifo_din_o  = din_i;

        // CPU reads RBR only when RX FIFO has data.
        rx_fifo_pop_o = read_rbr && !rx_fifo_empty_i;
    end

    // --------------------------------------------------------
    // LCR, IER, MCR, DLL, DLM, scratch-register storage
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            lcr_reg <= 8'h03; // Default: 8N1, DLAB = 0
            ier_reg <= 4'h0;
            mcr_reg <= 8'h00;
            scr_reg <= 8'h00;

            // Divisor = 1 prevents a divide-by-zero condition.
            dll_reg <= 8'h01;
            dlm_reg <= 8'h00;
        end
        else begin
            if (write_lcr)
                lcr_reg <= din_i;

            if (write_ier)
                ier_reg <= din_i[3:0];

            if (write_mcr)
                mcr_reg <= din_i;

            if (write_scr)
                scr_reg <= din_i;

            if (write_dll)
                dll_reg <= din_i;

            if (write_dlm)
                dlm_reg <= din_i;
        end
    end

    // --------------------------------------------------------
    // FCR storage and FIFO-clear pulses
    //
    // FCR[0]   FIFO enable
    // FCR[1]   Clear RX FIFO
    // FCR[2]   Clear TX FIFO
    // FCR[3]   DMA mode (stored but unused)
    // FCR[7:6] RX FIFO trigger level
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            fcr_enable_reg     <= 1'b0;
            fcr_dma_mode_reg   <= 1'b0;
            fcr_rx_trigger_reg <= 2'b00;

            tx_fifo_clear_o <= 1'b0;
            rx_fifo_clear_o <= 1'b0;
        end
        else begin
            // Default: clear signals pulse for one system-clock cycle.
            tx_fifo_clear_o <= 1'b0;
            rx_fifo_clear_o <= 1'b0;

            if (write_fcr) begin
                fcr_enable_reg     <= din_i[0];
                fcr_dma_mode_reg   <= din_i[3];
                fcr_rx_trigger_reg <= din_i[7:6];

                tx_fifo_clear_o <= din_i[2];
                rx_fifo_clear_o <= din_i[1];
            end
        end
    end

    // --------------------------------------------------------
    // RX FIFO threshold decoding
    //
    // FCR[7:6]:
    // 00 -> 1 byte
    // 01 -> 4 bytes
    // 10 -> 8 bytes
    // 11 -> 14 bytes
    // --------------------------------------------------------
    always_comb begin
        case (fcr_rx_trigger_reg)
            2'b00: rx_fifo_threshold_o = 5'd1;
            2'b01: rx_fifo_threshold_o = 5'd4;
            2'b10: rx_fifo_threshold_o = 5'd8;
            default: rx_fifo_threshold_o = 5'd14;
        endcase
    end

    // --------------------------------------------------------
    // Sticky Line Status errors
    //
    // Error bits clear when software reads LSR or clears RX FIFO.
    // A new error in the same clock cycle has priority and remains set.
    // --------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            lsr_oe_sticky            <= 1'b0;
            lsr_pe_sticky            <= 1'b0;
            lsr_fe_sticky            <= 1'b0;
            lsr_bi_sticky            <= 1'b0;
            lsr_rx_fifo_error_sticky <= 1'b0;
        end
        else begin
            if (read_lsr || write_fcr_clear_rx) begin
                lsr_oe_sticky            <= 1'b0;
                lsr_pe_sticky            <= 1'b0;
                lsr_fe_sticky            <= 1'b0;
                lsr_bi_sticky            <= 1'b0;
                lsr_rx_fifo_error_sticky <= 1'b0;
            end

            if (rx_oe_i)
                lsr_oe_sticky <= 1'b1;

            if (rx_pe_i)
                lsr_pe_sticky <= 1'b1;

            if (rx_fe_i)
                lsr_fe_sticky <= 1'b1;

            if (rx_bi_i)
                lsr_bi_sticky <= 1'b1;

            if (rx_pe_i || rx_fe_i || rx_bi_i)
                lsr_rx_fifo_error_sticky <= 1'b1;
        end
    end

    // --------------------------------------------------------
    // Baud generator
    //
    // baud16_tick_o pulses once every divisor clock cycles.
    //
    // UART baud rate = clk frequency / (16 * divisor)
    // --------------------------------------------------------
    always_comb begin
        divisor_value = {dlm_reg, dll_reg};

        if (divisor_value == 16'd0)
            divisor_effective = 16'd1;
        else
            divisor_effective = divisor_value;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            baud_count     <= 16'd0;
            baud16_tick_o  <= 1'b0;
        end
        else begin
            baud16_tick_o <= 1'b0;

            // Restart timing after software updates DLL or DLM.
            if (write_divisor) begin
                baud_count <= 16'd0;
            end
            else if (baud_count >= (divisor_effective - 1'b1)) begin
                baud_count    <= 16'd0;
                baud16_tick_o <= 1'b1;
            end
            else begin
                baud_count <= baud_count + 1'b1;
            end
        end
    end

    // --------------------------------------------------------
    // LSR, IIR, IRQ, and CPU read-data mux
    // --------------------------------------------------------
    always_comb begin
        // ---------------- LSR ----------------
        lsr_o = 8'h00;

        lsr_o[0] = !rx_fifo_empty_i;                 // DR
        lsr_o[1] = lsr_oe_sticky;                    // OE
        lsr_o[2] = lsr_pe_sticky;                    // PE
        lsr_o[3] = lsr_fe_sticky;                    // FE
        lsr_o[4] = lsr_bi_sticky;                    // BI
        lsr_o[5] = tx_fifo_empty_i;                  // THRE
        lsr_o[6] = tx_fifo_empty_i && tx_sreg_empty_i; // TEMT
        lsr_o[7] = lsr_rx_fifo_error_sticky;         // RXFIFOE

        // ---------- Basic interrupt sources ----------
        line_status_irq_pending =
            lsr_oe_sticky ||
            lsr_pe_sticky ||
            lsr_fe_sticky ||
            lsr_bi_sticky;

        // FIFO-enabled mode uses FIFO threshold.
        // Non-FIFO mode uses normal Data Ready behavior.
        if (fcr_enable_reg)
            rx_data_irq_pending = rx_fifo_threshold_hit_i;
        else
            rx_data_irq_pending = !rx_fifo_empty_i;

        tx_empty_irq_pending = tx_fifo_empty_i;

        // ---------------- IIR ----------------
        // IIR[0] = 1 -> no interrupt pending
        // IIR[0] = 0 -> interrupt pending
        //
        // Priority:
        // 1. Receiver line status
        // 2. Received data available
        // 3. THR empty
        iir_o = 8'h01;

        if (fcr_enable_reg)
            iir_o[7:6] = 2'b11;
        else
            iir_o[7:6] = 2'b00;

        if (ier_reg[2] && line_status_irq_pending)
            iir_o[3:0] = 4'b0110; // Receiver line status

        else if (ier_reg[0] && rx_data_irq_pending)
            iir_o[3:0] = 4'b0100; // Received data available

        else if (ier_reg[1] && tx_empty_irq_pending)
            iir_o[3:0] = 4'b0010; // THR empty

        irq_o = !iir_o[0];

        // ---------------- Outputs ----------------
        lcr_o      = lcr_reg;
        mcr_o      = mcr_reg;
        ier_o      = ier_reg;
        divisor_o  = divisor_value;
        fifo_enable_o = fcr_enable_reg;

        // ---------------- Read mux ----------------
        dout_o = 8'h00;

        if (rd_i) begin
            case (addr_i)
                ADDR_DATA:
                    dout_o = lcr_reg[7] ? dll_reg : rx_fifo_dout_i;

                ADDR_IER:
                    dout_o = lcr_reg[7] ? dlm_reg : {4'b0000, ier_reg};

                ADDR_IIR_FCR:
                    dout_o = iir_o;

                ADDR_LCR:
                    dout_o = lcr_reg;

                ADDR_MCR:
                    dout_o = mcr_reg;

                ADDR_LSR:
                    dout_o = lsr_o;

                ADDR_MSR:
                    dout_o = 8'h00; // Modem status not implemented yet

                ADDR_SCR:
                    dout_o = scr_reg;

                default:
                    dout_o = 8'h00;
            endcase
        end
    end

endmodule

