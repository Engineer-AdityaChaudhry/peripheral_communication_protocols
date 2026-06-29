# UART RTL and Verification

## Overview

UART is an asynchronous serial protocol: the transmitter and receiver do not share a clock line. Instead, both sides agree on a baud rate and frame format, and the receiver samples the serial `rx` line relative to the detected start bit.

This project contains a `16550A`-inspired UART path centered on `uart_16550_top`.

**16550A-inspired implementation; not presented as fully 16550A compliant.**

## Implemented Architecture

```text
uart_16550_top
  |
  +-- uart_register
  |     - simple CPU-facing register interface
  |     - LCR/IER/IIR/FCR/MCR/LSR/scratch/divisor handling
  |     - baud16_tick generation
  |
  +-- fifo_8x16 (TX FIFO)
  +-- uart_tx
  |
  +-- uart_rx
  +-- fifo_8x16 (RX FIFO)
```

The top-level port interface is a simple register bus:

- `wr_i`, `rd_i`, `addr_i[2:0]`, `din_i[7:0]`, `dout_o[7:0]`
- UART pins `rx_i` and `tx_o`
- Interrupt output `irq_o`

## Framing and Baud Generation

The UART TX/RX path uses a `baud16_tick` enable at 16x the target baud rate. `uart_register` generates this tick from the 16-bit divisor formed by `DLM:DLL`; a zero divisor is treated as one to avoid divide-by-zero behavior.

The Line Control Register (`LCR`) drives the frame format:

| LCR Field | Implemented Behavior |
|---|---|
| `LCR[1:0]` | Word length select: 5, 6, 7, or 8 data bits |
| `LCR[2]` | TX stop-bit selection: 1 stop bit, 1.5 stop bits for 5-bit words, or 2 stop bits |
| `LCR[3]` | Parity enable |
| `LCR[4]` | Even parity select when parity is enabled |
| `LCR[5]` | Stick parity support |
| `LCR[6]` | TX break control |
| `LCR[7]` | Divisor latch access bit (`DLAB`) |

Transmit frames include start bit, configured data bits LSB-first, optional parity, and stop timing from `LCR[2]`. Receive logic synchronizes the asynchronous `rx` input, confirms a start bit at its midpoint, samples data bits, checks optional parity, validates the first stop bit, and reports parity, framing, break, and overrun events.

## Register and FIFO Behavior

`uart_register` implements a 3-bit address map inspired by the 16550A register layout:

| Address | `DLAB=0` Access | `DLAB=1` Access |
|---:|---|---|
| `0x0` | THR write / RBR read | DLL |
| `0x1` | IER | DLM |
| `0x2` | IIR read / FCR write | IIR read / FCR write |
| `0x3` | LCR | LCR |
| `0x4` | MCR | MCR |
| `0x5` | LSR | LSR |
| `0x6` | MSR returns `0x00` | MSR returns `0x00` |
| `0x7` | Scratch register | Scratch register |

The TX and RX FIFOs use `fifo_8x16`, an 8-bit wide, 16-entry synchronous circular FIFO. FIFO clear commands from FCR are one-clock pulses. `FCR[7:6]` selects RX trigger levels of 1, 4, 8, or 14 bytes.

Important implementation detail: the physical FIFOs remain active even when `FCR[0]` is zero. In this RTL, `FCR[0]` affects threshold/interrupt behavior, not whether bytes are stored in the FIFO.

Interrupt-related behavior is implemented through `IER`, `IIR`, `LSR`, sticky RX error bits, RX data threshold/data-ready detection, TX-empty detection, and `irq_o`. The implemented interrupt priority is receiver line status, received data available, then THR empty.

## Verification Strategy

UART verification is split into focused self-checking regressions:

| Regression | Testbench Module | Covered Areas | Result |
|---|---|---|---:|
| TX regression | `uart_tx_tb` | Reset, 8N1, parity formats, stop-bit formats, back-to-back bytes, LCR latching, break control | 204 checks passed |
| RX regression | `uart_rx_tb` | Valid frames, parity/framing errors, false-start rejection, FIFO overrun, break condition, LCR latching | 43 checks passed |
| Register-level regression | `uart_register_tb` | THR/RBR, DLAB/DLL/DLM, FCR controls, LSR sticky errors, IER/IIR/IRQ, RX threshold IRQ, MCR/scratch | 47 checks passed |
| Integrated loopback regression | `uart_16550_top_tb` | Register configuration, 8N1/8E1 loopback, FIFO ordering, RX FIFO clear, final TX status | 46 checks passed |

## Current Limitations

- The UART is 16550A-inspired, not intended to provide 16550A-compatible behavior beyond the implemented subset.
- The CPU interface is a simple local register bus, not APB or AXI-Lite.
- `MSR` returns `0x00`; modem-status behavior is not implemented.
- FCR DMA mode is stored but unused.
- FIFO enable does not disable physical FIFO storage.
- RX validates the first stop bit and does not implement extended stop-bit duration checking.
- Interrupt behavior is useful for simulation and register-level testing, but is not a comprehensive 16550A interrupt model.
- No FPGA board-level UART bring-up is documented in this repository.
