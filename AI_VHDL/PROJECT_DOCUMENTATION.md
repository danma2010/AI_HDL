# AI_VHDL Project Documentation

**Project:** 16-bit HDLC Controller FPGA Implementation  
**Language:** VHDL  
**Target Platform:** Xilinx FPGA (ISE Design Suite)  
**License:** MIT (Copyright Sharun John 2016)  
**Date Analyzed:** 2026-06-10

---

## Overview

This project implements an **HDLC (High-level Data Link Control) protocol controller** in VHDL for FPGA deployment. HDLC is a synchronous, bit-oriented Data Link Layer (OSI Layer 2) protocol that organizes data into frames with structured address, payload, and error-check fields.

### Key Features

| Feature | Details |
|---|---|
| Address Field | 16-bit |
| Data Payload | 8-bit per frame |
| Error Detection | 16-bit CRC (FCS) |
| Bit Stuffing | Transmit side: inserts 0 after 5 consecutive 1s |
| Bit Unstuffing | Receive side: removes inserted 0s |
| Frame Delimiting | Flag pattern 0x7E (01111110) |
| Abort Detection | 7+ consecutive 1s |

---

## Directory Structure

```
AI_VHDL/
├── AI_for_FPGA.docx                          # Project documentation (Word)
└── 16-bit-HDLC-using-VHDL/                  # Main source repository (MIT)
    ├── LICENSE
    ├── README.md
    └── HDLC Protocol FPGA Implementation/
        ├── Main/                             # Core Tx/Rx controllers
        │   ├── clkdiv.vhd                    # Clock divider
        │   ├── receive.vhd                   # HDLC receiver
        │   └── transmit.vhd                  # HDLC transmitter
        ├── Modules/                          # Reusable sub-components
        │   ├── Bit stuffing/
        │   │   └── BITSTFNG.vhd
        │   ├── Flag abort/
        │   │   ├── flagab.vhd
        │   │   └── tb_flagab.vhd
        │   ├── Shift reg/
        │   │   ├── shifreg.vhd
        │   │   └── tb_shifreg.vhd
        │   ├── Unstuffing/
        │   │   └── unstf.vhd
        │   ├── Zero Insert/
        │   │   └── zeroo.vhd
        │   ├── clk flag/
        │   │   ├── clkflag.vhd
        │   │   └── tb_clkflag.vhd
        │   ├── clock divider self/
        │   │   ├── clkdiv.vhd
        │   │   ├── clkdiv.bit                # Xilinx bitstream
        │   │   ├── clkdiv.ucf                # User Constraints File
        │   │   └── tb_clkdiv.vhd
        │   ├── flag gen/
        │   │   ├── flagen.vhd
        │   │   └── tb_flagen.vhd
        │   ├── piso/
        │   │   ├── piso.vhd
        │   │   ├── new piso/piso.vhd
        │   │   └── tb_piso.vhd
        │   └── sipo/
        │       ├── sipo.vhd
        │       └── tb_sipo.vhd
        └── Xilinx ISE - Component tests/     # Simulation screenshots (JPG)
```

---

## System Architecture

### High-Level Data Flow

```
TRANSMIT PATH
─────────────
Parallel Data (8-bit)
        │
        ▼
  [T_BUFFER]          Load parallel byte into buffer
        │
        ▼
  [T_SHIFT]           Parallel-to-serial conversion
        │
        ▼
  [CRC_GEN]           Compute and append 16-bit FCS
        │
        ▼
  [Z_STUFF]           Insert 0 after every 5 consecutive 1s
        │
        ▼
  [F_INSERT]          Wrap frame with 0x7E flag bytes
        │
        ▼
  Serial TxD ──────────────────────►  (transmission medium)


RECEIVE PATH
────────────
Serial RxD  ◄──────────────────────  (transmission medium)
        │
        ▼
  [F_DETECT]          Detect 0x7E flag, synchronize frame boundary
        │
        ▼
  [R_BUFFER]          Serial-to-parallel shift register
        │
        ▼
  [Z_UNSTUFF]         Remove stuffed 0 bits
        │
        ▼
  [R_SHIFT]           Extract 8-bit payload octets
        │
        ▼
  [CRC_CHK]           Verify FCS against received data
        │
        ▼
  Parallel Output (8-bit) + Status Flags
  (Abort, Octet_err, CRC_err)
```

---

## Module Reference

### Main Modules

---

#### `receive.vhd` — HDLC Receiver Controller

**Entity:** `HDLC_RECEIVE`

| Port | Direction | Width | Description |
|---|---|---|---|
| Reset | in | 1 | Synchronous reset |
| RxC | in | 1 | Receive clock |
| RxD | in | 1 | Serial data input |
| RxEnable | in | 1 | Enable receiver |
| RxOutputData_B0–B7 | out | 1 each | 8-bit parallel output |
| RxDataWrite_n | out | 1 | Data write strobe (active low) |
| RxStatusWrite_n | out | 1 | Status write strobe (active low) |

**Internal State Machines:**

| FSM | States | Function |
|---|---|---|
| F_DETECT | FD0–FD6, Flag, Idle | Detect 0x7E flag delimiter |
| Z_UNSTUFF | ZU0–ZU5, Unstuff | Remove stuffed bits; gate EnShift |
| A_DETECT | Sequential logic | Detect 7+ consecutive 1s (abort) |

**Internal Processes:**

| Process | Function |
|---|---|
| BIT_CNT | Count bits per octet; raise Octet_err on misalignment |
| CRC_CHK | Maintain FCS register; raise CRC_err on mismatch |
| R_BUFFER | 8-bit serial-in shift register |
| R_SHIFT | Latch parallel byte when EnShift valid |
| R_CONTROL | Generate DataValid, StatusValid; sample error flags |

**Error outputs (via RxOutputData status bits):**

- `Abort` — abort sequence detected
- `Octet_err` — frame not integer number of octets
- `CRC_err` — FCS check failed

---

#### `transmit.vhd` — HDLC Transmitter Controller

**Entity:** `HDLC_TRANSMIT`

| Port | Direction | Width | Description |
|---|---|---|---|
| Reset | in | 1 | Synchronous reset |
| TxC | in | 1 | Transmit clock |
| TxInputData_B0–B7 | in | 1 each | 8-bit parallel data input |
| TxStart | in | 1 | Begin frame transmission |
| TxAbort | in | 1 | Inject abort sequence |
| TxEmpty_n | in | 1 | More data available (active low) |
| TxEnable | in | 1 | Enable transmitter |
| TxD | out | 1 | Serial data output |
| TxRead_n | out | 1 | Read next byte strobe (active low) |

**Internal State Machines:**

| FSM | States | Function |
|---|---|---|
| F_INSERT | FI0–FI7, NF | Output 0x7E at frame boundaries; switch to NF for data |
| Z_STUFF | ZS0–ZS5, Stuff | Insert 0 bit after 5 consecutive 1s |

**Internal Processes:**

| Process | Function |
|---|---|
| CRC_GEN | Compute FCS during data bytes; append CRC after payload |
| A_INSERT | Latch TxAbort; inject 7 consecutive 1s abort sequence |
| T_CONTROL | Frame control: Start/Latch/Load/TS_CNT/CRC_CNT, read timing |

**Transmit Sequence:**

```
IDLE → [Flag 0x7E] → [Data Bytes + stuffing] → [CRC bytes + stuffing] → [Flag 0x7E] → IDLE
                                        ↑ abort can inject here
```

---

#### `clkdiv.vhd` (Main/) — System Clock Divider

**Entity:** `clkdiv`

| Generic | Default | Description |
|---|---|---|
| D | 10 | Counter bit width |

**Function:** Divides input clock frequency by 2^D. Output `clk_1hz` is the inverted MSB of a D-bit counter.

---

### Supporting Modules

---

#### `flagen.vhd` — HDLC Flag Generator

**Purpose:** Outputs the HDLC flag byte (01111110 = 0x7E) in serial form.  
**Architecture:** 8-state FSM (s0–s7)  
**Trigger:** Input signal `a`; outputs flag pattern on `z`.

---

#### `flagab.vhd` — Flag / Abort / Idle Detector

**Purpose:** Detects three special patterns from a serial bit stream.

| Output | Pattern Detected |
|---|---|
| `z` | Flag: `01111110` |
| `about` | Abort: 7+ consecutive `1`s |
| `idlout` | Idle: continuous `1`s |

**Architecture:** Three parallel 8-state FSMs running concurrently on same input.

---

#### `BITSTFNG.vhd` — Bit Stuffing Detector

**Purpose:** Detects when bit stuffing is required (5 consecutive 1s seen).  
**Architecture:** 5-state FSM (S1–S5)  
**Output:** `z='1'` when stuffed bit should be inserted after current position.

---

#### `unstf.vhd` — Bit Unstuffer

**Purpose:** Receives serial data and removes stuffed 0 bits.  
**Architecture:** 6-state FSM  
**Logic:** On transition S5→S6, if next bit is 0, it is dropped (destuffed). Output `det` indicates a stuffed bit was removed.

---

#### `zeroo.vhd` — Zero Inserter (Bit Stuffer)

**Purpose:** Inserts a `0` bit after every 5 consecutive `1`s.  
**Architecture:** 7-state FSM (s1–s7)  
**Logic:** States s1–s5 count consecutive 1s; s6 outputs `'0'` (the stuffed bit); s7 returns the original data bit.

---

#### `piso.vhd` — Parallel-In Serial-Out Shift Register

**Purpose:** Converts 8-bit parallel data to serial output.  
**Logic:** Index pointer `i` advances each clock; `sout <= x(i)`.  
**Note:** The main version has no explicit load control; an alternate implementation exists in `new piso/piso.vhd`.

---

#### `sipo.vhd` — Serial-In Parallel-Out Shift Register

**Purpose:** Accumulates serial bits into an 8-bit parallel word.  
**Logic:** `pout <= sin & pout(7 downto 1)` — shifts in from MSB end, output on `pout`.

---

#### `shifreg.vhd` — General Shift Register

**Purpose:** 8-bit serial shift register.  
**Logic:** `q <= sin & q(2 to 8)` — shifts in at position 1, output at `sout`.

---

#### `clkflag.vhd` — Clock + Flag Composite Module

**Purpose:** Structural module combining clock divider and flag generator.  
**Components Instantiated:**
- `clkdiv` → produces divided clock `cko`
- `flagen` → produces flag pattern output `y`

---

### Testbenches

| Testbench | Tests |
|---|---|
| `tb_flagab.vhd` | Flag, abort, and idle pattern detection |
| `tb_shifreg.vhd` | Shift register operation |
| `tb_clkflag.vhd` | Clock divider + flag generator |
| `tb_clkdiv.vhd` | Clock divider standalone |
| `tb_flagen.vhd` | Flag byte generation |
| `tb_piso.vhd` | Parallel-to-serial conversion |
| `tb_sipo.vhd` | Serial-to-parallel conversion |

Simulation waveform screenshots are stored in `Xilinx ISE - Component tests/`.

---

## CRC Implementation

The receiver and transmitter both implement a **16-bit CRC** (Frame Check Sequence, FCS).

- Polynomial: Defined in `work.hdlc_package` as `CRC_Polynomial` (package file not present in repo)
- FCS size: 16 bits (constant `FCS_size = 16`)
- Method: Linear feedback shift register (LFSR) XOR chain

**Transmitter:** CRC computed over address + data bytes, appended as two trailing bytes before the closing flag.

**Receiver:** CRC re-computed over received bytes (including received FCS). A known residue value indicates no errors.

---

## External Dependencies

| Library | Used For |
|---|---|
| `IEEE.STD_LOGIC_1164` | Standard logic types (`std_logic`, `std_logic_vector`) |
| `IEEE.STD_LOGIC_UNSIGNED` | Unsigned arithmetic on `std_logic_vector` |
| `IEEE.STD_LOGIC_ARITH` | Arithmetic operations |
| `work.hdlc_package` | `CRC_Polynomial`, `FCS_size` constants **(file not in repo)** |

---

## Known Gaps

| Item | Notes |
|---|---|
| `hdlc_package.vhd` | Referenced by `receive.vhd` and `transmit.vhd` but not present. Must define `CRC_Polynomial` (16-bit vector) and `FCS_size` (integer = 16). |
| Top-level integration entity | No single entity ties Tx and Rx together with shared clock and data bus. |
| Full Tx/Rx integration testbench | Testbenches exist per module but not for end-to-end loopback test. |
| PISO load control | Main `piso.vhd` lacks a load/enable signal; `new piso/piso.vhd` may address this. |

---

## Design Patterns & Conventions

1. **Synchronous FSMs** — All state machines clocked on rising edge of RxC/TxC.
2. **Active-low strobes** — `TxRead_n`, `RxDataWrite_n`, `RxStatusWrite_n` use active-low convention.
3. **Cascaded FSMs** — Distinct FSMs for flag detection, stuffing, and abort run in parallel, combined via control signals.
4. **Structural composition** — Modules instantiated explicitly (`clkflag.vhd` instantiates `clkdiv` and `flagen`).
5. **Shift registers as data path** — Core serial/parallel conversion built from shift register primitives.

---

## HDLC Frame Format

```
┌──────────┬────────────────┬──────────────┬──────────────────┬──────────┐
│  FLAG    │  ADDRESS       │  DATA        │  FCS (CRC-16)    │  FLAG    │
│  0x7E    │  16 bits       │  8 bits      │  16 bits         │  0x7E    │
│  (8 bit) │                │  (per frame) │                  │  (8 bit) │
└──────────┴────────────────┴──────────────┴──────────────────┴──────────┘
```

Bit stuffing is applied to the Address + Data + FCS fields (not to the flags themselves).

---

## Tool Chain

- **HDL Language:** VHDL (IEEE 1076)
- **Target Vendor:** Xilinx
- **IDE:** Xilinx ISE Design Suite
- **Constraints:** `.ucf` file (User Constraints File) for pin assignments
- **Bitstream:** `.bit` file present for `clkdiv` module
