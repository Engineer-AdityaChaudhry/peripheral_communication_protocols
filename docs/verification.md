# Verification Methodology

## Philosophy

The project uses self-checking SystemVerilog testbenches. Each regression drives protocol-level stimulus, observes DUT outputs and partner-device behavior, and reports pass/fail checks through testbench counters.

A "check" means one explicit testbench condition evaluated by the local helper task or equivalent scoreboard-style logic. A passing regression reports zero failures and a final check count.

## Testbench Coverage Themes

The regressions focus on:

- Reset and idle-state behavior
- Nominal protocol transfers
- Framing and timing-sensitive behavior
- Data integrity through transmit/receive paths
- Error-path behavior such as NACK, framing error, parity error, overrun, or wrong address
- Busy/done handshakes and single-cycle completion pulses
- FIFO ordering, FIFO clear behavior, and threshold-driven status where present

## Behavioral Partner Models

Several testbenches connect the DUT to another RTL block or a behavioral model:

- UART integrated loopback connects `tx_o` back into `rx_i`.
- Standard SPI connects `spi_master` to `spi_slave`.
- AD5628 SPI uses `ad5628_spi_slave_model` to model DAC frame reception and command effects in simulation.
- SPI daisy-chain verification connects multiple daisy-chain slave instances in series.
- I2C master-only verification uses a lightweight ACK responder.
- I2C master/slave and clock-stretching tests connect the real master/slave RTL on shared open-drain `scl`/`sda` wires with pullups.

## Waveform Debugging

The Vivado/XSim project contains generated simulation artifacts and waveform databases under:

```text
peripheral_communication_protocols.sim/sim_1/behav/xsim
```

The generated TCL files add visible design signals to the waveform view when objects are available, and `.wdb` files are present for several simulations. These artifacts support waveform inspection in Vivado/XSim.

## Consolidated Regression Table

These are self-checking simulation results from the named regressions. Counts are intentionally not summed across unrelated tests.

| Area | Regression | Testbench Module | Result |
|---|---|---|---:|
| UART | TX regression | `uart_tx_tb` | 204 checks passed |
| UART | RX regression | `uart_rx_tb` | 43 checks passed |
| UART | Register-level regression | `uart_register_tb` | 47 checks passed |
| UART | Integrated loopback regression | `uart_16550_top_tb` | 46 checks passed |
| SPI | Standard master/slave regression | `spi_master_slave_tb` | 94 checks passed |
| SPI | AD5628 DAC regression | `ad5628_spi_master_slave_tb` | 59 checks passed |
| SPI | Daisy-chain regression | `spi_daisy_chain_tb` | 31 checks passed |
| I2C | Master-only baseline regression | `i2c_master_tb` | 18 checks passed |
| I2C | Master/slave regression | `i2c_tb` | 35 checks passed |
| I2C | Clock-stretching regression | `i2c_cs_tb` | 42 checks passed |

The preserved `simulate.log` in the XSim directory currently shows the `i2c_cs_tb` clock-stretching regression passing with 42 checks. Other self-checking regressions are present as testbench sources with their own final pass/fail summaries, but no single repository-level regression script was found.

## Running Available XSim Scripts

The repository contains generated XSim shell scripts for the currently selected simulation, `i2c_cs_tb`, in:

```text
peripheral_communication_protocols.sim/sim_1/behav/xsim
```

Run them from that directory:

```bash
cd peripheral_communication_protocols.sim/sim_1/behav/xsim
./compile.sh
./elaborate.sh
./simulate.sh
```

The scripts contain these Vivado/XSim commands:

```bash
xvlog --incr --relax -L uvm -prj i2c_cs_tb_vlog.prj
xelab --incr --debug typical --relax --mt 8 -L xil_defaultlib -L uvm -L unisims_ver -L unimacro_ver -L secureip --snapshot i2c_cs_tb_behav xil_defaultlib.i2c_cs_tb xil_defaultlib.glbl -log elaborate.log
xsim i2c_cs_tb_behav -key {Behavioral:sim_1:Functional:i2c_cs_tb} -tclbatch i2c_cs_tb.tcl -log simulate.log
```

The generated project file `peripheral_communication_protocols.xpr` lists the additional simulation testbenches under the `sim_1` file set, but this repository does not include a checked-in Makefile or script that runs every listed regression automatically.
