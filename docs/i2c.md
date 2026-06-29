# I2C RTL and Verification

## Overview

I2C is a two-wire shared serial bus using serial clock (`SCL`) and serial data (`SDA`). Both lines are open-drain: devices only drive a logic 0, and logic 1 is produced by releasing the line so the pull-up brings it high.

The repository includes two related I2C RTL paths:

- `i2c_master` and `i2c_slave` for baseline one-byte read/write transfers without clock stretching
- `i2c_cs_master` and `i2c_cs_slave` for clock-stretching-aware transfers

## Open-Drain Bus Behavior

The RTL models open-drain behavior with `inout` bus wires:

- Drive low: assign `0`
- Release high: assign `z`
- Testbenches instantiate `pullup(scl)` and `pullup(sda)`

This matches the core I2C rule that no device actively drives a logic 1 onto the shared bus.

## Transfer Format

The implemented transfers use 7-bit addressing and single-byte data movement.

Write sequence:

```text
START -> {7-bit address, W=0} -> ACK
      -> 8-bit data           -> ACK -> STOP
```

Read sequence:

```text
START -> {7-bit address, R=1} -> ACK
      -> receive 8-bit data  -> master NACK -> STOP
```

`START` is SDA falling while SCL is high. `STOP` is SDA rising while SCL is high. ACK is a low SDA level during the ninth clock; NACK is a released/high SDA level during that ACK slot.

The slave address is parameterized in the slave modules, with the testbenches using `7'h50`.

## Clock Stretching

The baseline `i2c_master` advances using the configured `scl_half_period_i` and does not include clock-stretch waiting.

The clock-stretching path uses `i2c_cs_master` and `i2c_cs_slave`. Whenever the master releases SCL for a high phase, it waits until the actual shared `scl` bus is high. This is required because a slave may hold SCL low to delay the transfer.

`i2c_cs_slave` includes `stretch_enable_i` for test/demo control. In the clock-stretching testbench, the slave holds SCL low after receiving the address byte and before completing its ACK phase. The master remains busy until SCL is released and the transfer can continue.

## Verification Stages

| Verification Stage | Testbench Module | Result |
|---|---|---:|
| Master-only baseline | `i2c_master_tb` | 18 checks passed |
| Master/slave transfers | `i2c_tb` | 35 checks passed |
| Clock stretching | `i2c_cs_tb` | 42 checks passed |

The clock-stretching regression includes normal write behavior, stretched write behavior, readback after a stretched write, wrong-address NACK handling, and final idle-bus checks.

## Current Scope

Implemented and verified scope:

- Single-byte writes
- Single-byte reads
- 7-bit address plus R/W bit
- START and STOP generation/detection
- ACK/NACK behavior
- Wrong-address NACK handling
- Slave clock stretching in the `i2c_cs_*` path

Not claimed in the current implementation:

- Repeated START
- Multi-master arbitration
- Multibyte transfers
- Register-address read/write flow
- 10-bit addressing
- SMBus-specific behavior
- FPGA board-level I2C bring-up
