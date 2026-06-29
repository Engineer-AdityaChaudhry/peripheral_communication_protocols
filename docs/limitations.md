# Scope and Limitations

This document states what is implemented and verified in the current repository, what is not currently implemented, and practical future extensions.

## UART

### Implemented and verified within this project

- `uart_16550_top` integrates `uart_register`, TX/RX `fifo_8x16` instances, `uart_tx`, and `uart_rx`.
- Simple CPU-facing register interface with `wr_i`, `rd_i`, `addr_i`, `din_i`, and `dout_o`.
- LCR-configured word length, parity, TX stop-bit timing, divisor latch access, and TX break control.
- Divisor-based 16x baud tick generation.
- TX/RX FIFOs with clear pulses and RX threshold support.
- Basic line-status and interrupt-related register behavior through `LSR`, `IER`, `IIR`, and `irq_o`.
- Self-checking TX, RX, register-level, and integrated loopback regressions.

### Not currently implemented

- 16550A compatibility beyond the implemented inspired subset.
- APB or AXI-Lite register bus.
- Modem-status behavior; `MSR` reads as `0x00`.
- 16550A interrupt behavior beyond the implemented line-status, RX-data, and TX-empty sources.
- Functional DMA mode behavior from FCR.
- 16550A-compatible FIFO disable behavior.
- Documented FPGA board-level UART validation.

### Future extension

- Add an APB or AXI-Lite wrapper.
- Tighten interrupt behavior against a defined software-visible specification.
- Add modem-status inputs and `MSR` behavior if needed.
- Add board-level bring-up notes and constraints after hardware testing.

## SPI

### Implemented and verified within this project

- Standard Mode 0 `spi_master` and `spi_slave` point-to-point full-duplex transfer.
- Active-low chip select, generated SCLK, MSB-first shifting, and `start`/`busy`/`done` control.
- Slave `miso_o` plus `miso_oe_o` output-enable for shared MISO integration.
- AD5628-oriented 32-bit SPI write master and behavioral DAC simulation model.
- Generic Mode 0 daisy-chain master/slave RTL and a three-slave daisy-chain testbench.
- Self-checking standard master/slave, AD5628, and daisy-chain regressions.

### Not currently implemented

- Memory-mapped SPI controller register wrapper.
- Physical AD5628 DAC or FPGA board validation.
- A documented preserved-results matrix for every CPOL/CPHA mode.
- AD5628 command modeling beyond the commands used by the testbench.
- A generic multi-chip-select SPI peripheral subsystem.

### Future extension

- Add APB or AXI-Lite control/status registers.
- Expand and preserve CPOL/CPHA regression evidence.
- Add board-level DAC testing if hardware is available.
- Add reusable wrappers for single-slave, multi-slave, and daisy-chain configurations.

## I2C

### Implemented and verified within this project

- Open-drain `scl`/`sda` behavior using `inout` wires and testbench pullups.
- 7-bit address plus R/W bit.
- START and STOP generation/detection.
- ACK/NACK handling.
- Single-byte write and single-byte read flows.
- Wrong-address NACK behavior.
- Baseline master-only and master/slave verification.
- Clock-stretching-aware master/slave path with slave-driven SCL stretching.

### Not currently implemented

- Repeated START.
- Multibyte transfers.
- Register-address read/write flow.
- Multi-master arbitration.
- 10-bit addressing.
- General call or SMBus-specific behavior.
- FPGA board-level I2C validation.

### Future extension

- Add repeated START sequencing.
- Add multibyte burst transfers and register-address transaction flows.
- Add arbitration and multi-master tests if multi-master support is required.
- Add board-level bring-up using real pullups and an external I2C device.
