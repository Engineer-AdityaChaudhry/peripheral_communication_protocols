# SPI RTL and Verification

## Overview

SPI is a synchronous serial protocol using a clock (`SCLK`), master-out/slave-in (`MOSI`), master-in/slave-out (`MISO`), and chip select (`CS_n`). Because the master provides `SCLK`, both sides shift data relative to shared clock edges.

This repository separates three SPI use cases:

- Standard point-to-point SPI master/slave communication
- AD5628 DAC-oriented SPI write framing
- Multi-device SPI daisy-chain behavior

## Standard Point-to-Point SPI

The standard point-to-point implementation uses:

- `spi_master`
- `spi_slave`
- `spi_master_slave_tb`

`spi_master` implements Mode 0 timing:

- `CPOL = 0`, so `SCLK` idles low
- `CPHA = 0`, so incoming `MISO` is sampled on rising edges and outgoing `MOSI` changes on falling edges
- MSB-first transfer
- Parameterized `DATA_WIDTH`, defaulting to 8 bits
- Active-low `cs_n`
- Runtime `clk_div_i` SCLK half-period divider
- `start`, `busy`, and one-cycle `done` handshake

`spi_slave` also implements Mode 0. It synchronizes `sclk_i`, `cs_n_i`, and `mosi_i` into the local `clk` domain, captures received data, and drives `miso_o` only while selected. The separate `miso_oe_o` signal supports safe integration onto a shared tri-state MISO wire.

SPI is full duplex: every clock edge sequence shifts one bit from master to slave on `MOSI` while also shifting one bit from slave to master on `MISO`. A single frame therefore exchanges both transmit and receive data.

## CPOL/CPHA Scope

The repository also contains configurable SPI RTL:

- `spi_cpha_master`
- `spi_cpha_slave`
- `spi_cpha_master_slave_tb`

These modules are written to support Modes 0 through 3. The headline verification matrix below only claims the requested preserved regression categories: standard master/slave, AD5628 DAC write path, and daisy chain. Do not treat the summary table as proof that every CPOL/CPHA mode has preserved log evidence in the current repository artifacts.

## SPI Daisy Chain

The daisy-chain implementation uses:

- `spi_daisy_chain_master`
- `spi_daisy_chain_slave`
- `spi_daisy_chain_tb`

In a daisy chain, multiple devices are connected serially:

```text
Master MOSI -> Slave 0 SDI -> Slave 0 SDO -> Slave 1 SDI -> ... -> Master MISO
```

All devices share `SCLK` and `CS_n`. Data shifts through each device, so a complete chain transfer takes `NUM_SLAVES * DATA_WIDTH` serial bits. With the default testbench configuration, one shared transaction shifts a three-slave chain.

The daisy-chain RTL uses fixed initial Mode 0 timing: `SCLK` idles low, rising edges sample, and falling edges launch the next bit.

## AD5628 DAC-Oriented SPI Path

The AD5628-oriented path uses:

- `ad5628_spi_master`
- `ad5628_spi_slave_model`
- `ad5628_spi_master_slave_tb`

`ad5628_spi_master` is a dedicated write-only SPI frame generator. It accepts a 32-bit `frame_i`, shifts it MSB-first, drives `sync_n_o`, `sclk_o`, and `mosi_o`, and reports `busy_o`/`done_o`.

`ad5628_spi_slave_model` is a behavioral simulation model, not synthesizable production RTL. It models a subset of DAC command behavior used by the testbench:

- Internal reference register command
- Write-and-update DAC channel command
- DAC channel outputs visible to the testbench
- Frame validity, command execution, and unsupported-command flags

No physical AD5628 board verification is documented in this repository.

## Test Matrix

| Regression | Testbench Module | Result |
|---|---|---:|
| Standard master/slave | `spi_master_slave_tb` | 94 checks passed |
| AD5628 DAC write path | `ad5628_spi_master_slave_tb` | 59 checks passed |
| Daisy chain | `spi_daisy_chain_tb` | 31 checks passed |

## Current Limitations

- The standard `spi_master`/`spi_slave` path is Mode 0.
- Configurable CPOL/CPHA RTL and a testbench are present, but the top-level verification summary does not claim preserved results for every mode.
- The AD5628 path is simulation-oriented and write-only; no physical DAC or FPGA board result is documented.
- The AD5628 model covers only the commands used by the project testbench.
- There is no memory-mapped software register wrapper around the SPI blocks.
