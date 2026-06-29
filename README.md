# Peripheral Communication Protocols — SystemVerilog RTL and Verification

This repository contains synthesizable RTL and self-checking SystemVerilog verification for UART, SPI, and I2C peripheral communication blocks. The project is organized as an AMD Vivado project with RTL in `peripheral_communication_protocols.srcs/sources_1/new`, testbenches in `peripheral_communication_protocols.srcs/sim_1/new`, and XSim simulation artifacts under `peripheral_communication_protocols.sim/sim_1/behav/xsim`.

## Protocol Summary

| Protocol | Implemented Design | Key Features | Verification Status | Detailed Documentation Link |
|---|---|---|---|---|
| UART | `uart_16550_top`, a 16550A-inspired UART peripheral | Programmable LCR framing, baud-divisor registers, TX/RX FIFOs, register-level configuration/status, loopback testing, and basic interrupt-related registers (`IER`, `IIR`, `LSR`, `irq_o`) | Self-checking TX, RX, register-level, and integrated loopback regressions | [docs/uart.md](docs/uart.md) |
| SPI | Standard Mode 0 master/slave, AD5628 DAC-oriented SPI write path, and multi-device daisy-chain RTL | Full-duplex point-to-point transfer, active-low chip select, SCLK divider generation, slave MISO output-enable, 32-bit DAC write framing, and serial daisy-chain shifting | Self-checking standard master/slave, AD5628 model, and daisy-chain regressions | [docs/spi.md](docs/spi.md) |
| I2C | One-byte I2C master/slave RTL plus clock-stretch-aware master/slave variants | Open-drain SCL/SDA, 7-bit addressing, START/STOP, ACK/NACK, single-byte read/write transfers, and slave clock-stretching verification | Self-checking master-only, master/slave, and clock-stretching regressions | [docs/i2c.md](docs/i2c.md) |

## Architecture Overview

```text
Testbench / Stimulus
        |
        v
RTL Peripheral <----> Behavioral Model / Partner Device
        |
        v
Self-checking scoreboard, assertions, pass/fail checks
```

## Verification Summary

The counts below are self-checking simulation results from the named regressions. They are listed per regression and are not combined across unrelated tests.

| Regression | Testbench | Self-Checking Result |
|---|---|---:|
| UART TX regression | `uart_tx_tb` | 204 checks passed |
| UART RX regression | `uart_rx_tb` | 43 checks passed |
| UART register-level regression | `uart_register_tb` | 47 checks passed |
| UART integrated loopback regression | `uart_16550_top_tb` | 46 checks passed |
| Standard SPI master/slave regression | `spi_master_slave_tb` | 94 checks passed |
| AD5628 SPI DAC regression | `ad5628_spi_master_slave_tb` | 59 checks passed |
| SPI daisy-chain regression | `spi_daisy_chain_tb` | 31 checks passed |
| I2C master-only baseline regression | `i2c_master_tb` | 18 checks passed |
| I2C master/slave regression | `i2c_tb` | 35 checks passed |
| I2C clock-stretching regression | `i2c_cs_tb` | 42 checks passed |

## Tools and Workflow

- SystemVerilog RTL and self-checking testbenches
- AMD Vivado / XSim project files and generated simulation scripts
- Waveform debugging through XSim waveform databases (`.wdb`)
- Pass/fail checks and scoreboard-style counters in testbenches
- Git/GitHub-friendly Markdown documentation

## Current Scope and Next Steps

Current RTL focuses on protocol-level peripheral behavior and simulation-driven verification. Realistic future extensions include:

- APB or AXI-Lite register integration
- Reusable memory-mapped peripheral wrappers
- More complete UART interrupt behavior
- Expanded SPI mode verification
- I2C repeated START, multibyte transfers, and arbitration
- FPGA board-level bring-up
