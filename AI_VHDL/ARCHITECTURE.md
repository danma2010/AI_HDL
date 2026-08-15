# HDLC Controller — Architecture & Reproduction Design Document

## 1. Purpose

This document reverse-engineers the VHDL sources in this repository into a
architecture specification precise enough to **reproduce the design from
scratch** (new project, same behavior) or to **complete/rebuild the existing
one** in Xilinx ISE. It also records the gaps found in the current tree that
must be resolved before the design will actually compile and simulate.

Protocol target: HDLC (ISO/IEC 13239), Layer‑2 framing with bit‑oriented
synchronous transmission, zero‑bit insertion/deletion (bit stuffing), 16‑bit
address field, 8‑bit data field granularity, 16‑bit FCS (CRC‑CCITT), flag
delimiter `0x7E` (`01111110`), and abort‑on‑seven‑ones detection.

---

## 2. Repository inventory (as found)

The repository contains **two generations** of the same design:

```
HDLC Protocol FPGA Implementation/
├── Main/                          <- Generation 2: integrated FSM controllers (the "real" design)
│   ├── transmit.vhd                  entity HDLC_TRANSMIT
│   ├── receive.vhd                   entity HDLC_RECEIVE
│   └── clkdiv.vhd                    entity clkdiv (baud/clock divider utility)
│
├── Modules/                       <- Generation 1: discrete proof-of-concept building blocks
│   ├── sipo/                         serial-in parallel-out shift register
│   ├── piso/ (+ "new piso"/)         parallel-in serial-out shift register (two variants)
│   ├── Shift reg/                    generic 8-bit serial shift register
│   ├── flag gen/                     0x7E flag pattern generator FSM
│   ├── Flag abort/                   flag/abort/idle triple-FSM detector
│   ├── clk flag/                     clkdiv + flagen composition
│   ├── clock divider self/           clkdiv + testbench + UCF + bitstream
│   ├── Bit stuffing/                 5-state zero-insertion-after-5-ones FSM
│   ├── Unstuffing/                   zero-deletion (destuff) FSM
│   └── Zero Insert/                  alternate zero-insertion FSM (7-state, w/ lookahead)
│   (each has a matching tb_*.vhd testbench, ISE-generated)
│
└── Xilinx ISE - Component tests/  <- ISim waveform screenshots (bitgen, bitremov, crcgen,
                                       crcdet, flaggen, pin-locking) documenting Gen-1 module tests
```

`Modules/` is exploratory: each FSM there implements **one** HDLC primitive in
isolation (flag detection, stuffing, unstuffing, shift registers) and was
verified independently via its testbench and ISE simulation (screenshots in
`Xilinx ISE - Component tests/`). `Main/` is the synthesis of that
exploration into two cohesive, single-entity controllers
(`HDLC_TRANSMIT`, `HDLC_RECEIVE`) that internally re-implement the same
FSM concepts as tightly-coupled sub-processes rather than separate
components. **`Main/` is the design that should be treated as canonical**
when reproducing the controller; `Modules/` should be treated as reference
material / unit-level building blocks, not as instantiated sub-components of
`Main` (nothing in `Main` instantiates anything from `Modules`).

---

## 3. Target system architecture

```
                 ┌─────────────────────────────────────────────────────┐
                 │                     hdlc_package                     │  <-- MISSING, must author (§6.1)
                 │  constant FCS_size : integer := 16;                  │
                 │  constant CRC_Polynomial : std_logic_vector(...)     │
                 └─────────────────────────────────────────────────────┘
                                   ▲ used by ▲
        ┌──────────────────────────┴───┐   ┌─┴──────────────────────────┐
        │        HDLC_TRANSMIT         │   │        HDLC_RECEIVE        │
Host -->│ TxInputData_B0..B7 (byte bus)│   │ RxOutputData_B0..B7 (byte)│--> Host
Host -->│ TxRead_n / TxEmpty_n (FIFO)  │   │ RxDataWrite_n / RxStatusWrite_n │--> Host
Host -->│ TxStart / TxAbort / TxEnable │   │ RxEnable                   │<-- Host
        │ TxC (serial clock, in)       │   │ RxC (serial clock, in)     │
        │ TxD (serial data, out) ------│---│----> line ----> RxD (serial data, in)
        └───────────────────────────────┘   └─────────────────────────────┘

        ┌───────────────────────────────┐
        │            clkdiv             │   generic D; free-running counter,
        │ clk_in --> [D-bit counter] -->│   clk_1hz <= not q(D-1)  (toggles every 2^(D-1) cycles)
        │ reset,  clk_1hz (out)         │   Not wired to TxC/RxC in Main today (§6.2).
        └───────────────────────────────┘
```

There is currently **no top-level entity** wiring `HDLC_TRANSMIT`,
`HDLC_RECEIVE` and `clkdiv` together, and no FIFO/memory model behind the
`TxInputData_*` / `RxOutputData_*` byte buses. Both are needed for a working
system and are specified in §6.

### 3.1 Host-side interface contract (both directions use an 8250/16550-style handshake)

**Transmit side** (`HDLC_TRANSMIT`):
| Signal | Dir | Meaning |
|---|---|---|
| `TxInputData_B0..B7` | in | Byte to transmit, presented by host/FIFO on the bus |
| `TxRead_n` | out | Active-low strobe: HDLC_TRANSMIT is consuming the current byte, host should advance FIFO |
| `TxEmpty_n` | in | Active-high: FIFO has more data (i.e. NOT empty) |
| `TxStart` | in | Pulse to begin a new frame |
| `TxAbort` | in | Pulse to abort the frame in progress (flushes with abort sequence) |
| `TxEnable` | in | Master clock-enable for the whole block |
| `TxC` / `Reset` | in | Bit clock / synchronous-ish reset |
| `TxD` | out | Serial output bitstream |

**Receive side** (`HDLC_RECEIVE`):
| Signal | Dir | Meaning |
|---|---|---|
| `RxD` / `RxC` / `Reset` | in | Serial input bitstream / bit clock / reset |
| `RxOutputData_B0..B7` | out | Decoded byte (data byte, or status byte when `RxStatusWrite_n` pulses) |
| `RxDataWrite_n` | out | Active-low strobe: a valid data byte is present on the output bus |
| `RxStatusWrite_n` | out | Active-low strobe: a status byte is present (`{5'b11111, Abort, Octet_err, CRC_err}`) |
| `RxEnable` | in | Master clock-enable |

---

## 4. `HDLC_TRANSMIT` internal architecture (`Main/transmit.vhd`)

Five cooperating sub-blocks, all clocked on `TxC`, gated by `TxEnable`:

### 4.1 `F_INSERT` — flag insertion sequencer
9-state FSM (`FI0..FI7, NF`) that free-runs through 8 states to shift out one
`01111110` flag octet per 8 `TxC` cycles while idle, then latches into `NF`
(non-flag) for the duration of the frame body (address+data+FCS) once
`NonFlagFields='1'`, returning to `FI0` when the frame body ends.
`TxD` is driven `'0'` at `FI0`/`FI7` (flag framing bits), `'1'` at the other
flag states, and `ZS_Out or Aborting` while in `NF` (i.e. the stuffed frame
body, or a continuous abort pattern of 1s).

### 4.2 `Z_STUFF` — zero-bit stuffing
7-state FSM (`ZS0..ZS5, Stuff`) counting consecutive `1` bits on `ZS_In`
(the outgoing bit stream, taken from `T_SHIFT(0)` normally, or from the CRC
shift register's top bit while `EnCrcGen='1'`). After 5 consecutive `1`s
(`ZS5`) it forces one `Stuff` cycle that inserts a `0` (`ZS_Out='1'` during
`ZS1..ZS5`, forcing `TxD<=1` is wrong — actually `ZS_Out` gates the stuffed
bit onto `TxD`; the shift/CRC registers are held (not clocked) during `ZS5`
so the stuffed `0` doesn't consume a data bit). Resets synchronously via
`RstZS` (held while in flag states, i.e. between frames).

### 4.3 `T_BUFFER` / `T_SHIFT` — byte load and bit shift
`T_BUFFER` latches `TxInputData_int` (byte assembled from `TxInputData_B0..B7`)
on `Latch`. `T_SHIFT` is an 8-bit shift-right register that reloads from
`T_BUFFER` on `Load` and otherwise shifts out `TxD`'s next bit LSB-first,
each `TxC` cycle except while stalled at `ZS5`.

### 4.4 `CRC_GEN` — CRC-16 generator
Standard LFSR CRC computed over the address+data bytes as they are
shifted out (`ZS_In`/`T_SHIFT(0)`), using `CRC_Polynomial` from
`hdlc_package`; `FCS` is preset to all-`1`s (`RstZS='1'`) at the start of
each frame body, then serialized out MSB-first once `EnCrcGen='1'`
(replacing `ZS_In` with the complemented top FCS bit) as the trailing 16
bits of the frame, i.e. transmitted CRC = inverted FCS register content.

### 4.5 `A_INSERT` — abort injection
Latches `TxAbort` (`AbortLatch`→`Abort`) and asserts `Aborting` for the
remainder of the current frame body once triggered, which forces `TxD` to a
continuous `1`-stream (7+ ones = HDLC abort sequence) via `ZS_Out or
Aborting` in §4.1 and forces `EnCrcGen<='0'`.

### 4.6 `T_CONTROL` — frame-level control/handshake FSM
Coordinates `TxStart`→`StartLatch`→`Start`→`StartAck` handshake with the
host FIFO (`TxEmpty_n`), drives `Read_n`/`TxRead_n` pulses to fetch each
byte at the right point in the 8-cycle flag/byte cadence (`TS_CNT`, a 3-bit
byte-bit counter), tracks `NonFlagFields` (frame body active), `NotLastByte`
/`NotLastByteD` (FIFO-empty lookahead, 1 byte pipelined), `Load` (when to
reload `T_SHIFT`), `CRC_CNT` (counts the 2 (16-bit) or 4 (32-bit, per
`FCS_size` generic-like constant) CRC bytes appended after data), and
`EnCrcGen` (switches the bit source from data to CRC for the trailing
bytes).

---

## 5. `HDLC_RECEIVE` internal architecture (`Main/receive.vhd`)

Mirrors the transmit side, clocked on `RxC`:

### 5.1 `F_DETECT` — flag/idle detector
9-state FSM (`FD0..FD6, Flag, Idle`) that recognizes six consecutive `1`s
followed by a `0` as a flag (`Flag` state) and seven consecutive `1`s as
line-idle (`Idle` state, HDLC "mark idle"). Drives `FDT` (flag-detected
latch) and `OD_CNT` (4-bit counter used to require **two** consecutive
flags before `OctetDetected` goes high — i.e. byte alignment starts only
after the second flag of a pair, giving the destuffer/CRC a clean octet
boundary) and `RstStatus` (one-cycle-early CRC-init pulse).

### 5.2 `Z_UNSTUFF` — zero-bit destuffing
Same 7-state topology as `Z_STUFF` (`ZU0..ZU5, Unstuff`) but running over
incoming bits (`R_BUFFER(0)`); at `ZU5` a `0` bit is recognized as a stuffed
bit and consumed without being shifted into `R_SHIFT` (`EnShift='0'` for
that cycle). Runs only while `OctetDetected='1'`.

### 5.3 `A_DETECT` — abort detection
Sets `Abort='1'` if the FSM is at `FD6` with `RxD='1'` while a frame is
already in progress (`OctetDetected='1'`); cleared when a `Flag` is next
seen. Feeds the status byte and gates `RxDataWrite_n`.

### 5.4 `BIT_CNT` — byte boundary counter
3-bit counter of shifted-in bits (`EnShift`), used to pulse `DataValid`
every 8th valid bit and to compute `Octet_err` (non-multiple-of-8 bits
received when a flag/abort ends the frame — frame is not octet-aligned).

### 5.5 `CRC_CHK` — CRC-16 checker
Same LFSR structure as the transmitter's `CRC_GEN`, continuously fed by
`R_BUFFER(0)`, reset by `RstStatus`; compared each cycle against the fixed
CRC "good" remainder computed by the `CRC_Remainder` function (a
compile-time constant equal to the CRC of an all-zero message with the
polynomial's standard non-zero preset — the receiver-side check value)
to produce `CRC_err`.

### 5.6 `R_BUFFER` / `R_SHIFT` — serial-in shift registers
`R_BUFFER` is a raw SIPO of `RxD` (used by `Z_UNSTUFF`/`A_DETECT`/`CRC_CHK`
to look at the last 8 raw line bits). `R_SHIFT` is the destuffed data
register (only clocked when `EnShift='1'`), presented to the host as
`RxOutputData_int` when a full byte (`BIT_CNT="111"`) is ready
(`DataValid`).

### 5.7 `R_CONTROL` / `R_DATA` — host handoff
On `DataValid`, `RxOutputData_int <= R_SHIFT` and `RxDataWrite_n` pulses.
At end-of-frame (`OctetDetectedD` falling, tracked through a 7-stage
`StatusValid` shift chain to align with the CRC/abort/octet-error signals
which are computed with a few cycles of latency), a status byte
`"11111" & Abort & Octet_err & CRC_err` is presented instead and
`RxStatusWrite_n` pulses. The `*_sample` registers (`Abort_sample`,
`Octet_err_sample`, `CRC_err_sample`, tagged "HD 230410" in the source)
capture these three flags at the correct pipeline stage (`StatusValid(0)`)
so the eventual status byte reflects the frame that just ended rather than
whatever the live (still-changing) `Abort`/`Octet_err`/`CRC_err` signals
happen to be 7 cycles later.

---

## 6. Gaps to close before this reproduces / compiles

These are concrete, load-bearing gaps in the current tree — not style
opinions:

### 6.1 `hdlc_package` does not exist in the repository (blocking)
Both `Main/transmit.vhd` and `Main/receive.vhd` do `use
work.hdlc_package.all;` and reference `FCS_size` and `CRC_Polynomial` from
it. **This package is absent from the repo**, so neither file compiles as-is.
To reproduce, author `hdlc_package.vhd`:

```vhdl
library IEEE;
use IEEE.std_logic_1164.all;

package hdlc_package is
  constant FCS_size : integer := 16;  -- 16-bit FCS per README; use 32 for CRC-32
  -- CRC-CCITT (x^16 + x^12 + x^5 + 1), the standard HDLC FCS polynomial.
  -- Bit i corresponds to the x^i tap feeding back into FCS(i).
  constant CRC_Polynomial : std_logic_vector(FCS_size-1 downto 0) :=
    "0001000000100001"; -- bits 12 and 5 set (bit 16/x^16 implicit, bit 0/x^0 implicit)
end package hdlc_package;
```
Confirm the exact polynomial/bit convention against the intended CRC
standard before use (CRC‑CCITT/X.25 is the HDLC-standard FCS and is the
correct default for a "16-bit CRC" HDLC controller per this repo's README).

### 6.2 No top-level integration entity (blocking for a working system)
Nothing instantiates `HDLC_TRANSMIT` + `HDLC_RECEIVE` + `clkdiv` together,
and nothing provides the FIFO/memory that `TxInputData_*`/`TxRead_n`/
`TxEmpty_n` and `RxOutputData_*`/`RxDataWrite_n` are designed to interface
with. `clkdiv` exists in two identical copies (`Main/clkdiv.vhd` and
`Modules/clock divider self/clkdiv.vhd`) but is wired into neither
`HDLC_TRANSMIT` nor `HDLC_RECEIVE` — both take `TxC`/`RxC` directly as
external clock inputs. A `hdlc_top.vhd` is needed (see §7).

### 6.3 Testbench/entity port mismatches in `Modules/`
`tb_clkdiv.vhd` declares a component `clkdiv` with ports
`clk, reset, ckout` — but `clkdiv.vhd`'s actual entity ports are `clk_in,
reset, clk_1hz` (and it has a `generic (D : natural := 10)` the testbench
doesn't set). This testbench will not bind/elaborate against the current
entity. Likely an earlier interface revision left un-synced. Similar
staleness should be assumed/checked for the other `tb_*.vhd` files in
`Modules/` before relying on them.

### 6.4 Two un-related `Zero Insert` implementations
`Modules/Bit stuffing/BITSTFNG.vhd` (5-state) and `Modules/Zero
Insert/zeroo.vhd` (7-state, with an extra lookahead/replay state `s7`) both
claim to do zero-insertion but are structurally different attempts; neither
is instantiated by `Main`. Treat `Main`'s inline `Z_STUFF` process as
authoritative.

### 6.5 Board-specific artifacts
`Modules/clock divider self/clkdiv.ucf` locks pins (`p122`, `p6`, `p2`) for
a specific package/board; `.bit` bitstream files are committed binaries tied
to that synthesis. These are not portable and should be regenerated for
whatever target device the reproduction targets, not reused.

---

## 7. Reproduction plan

To rebuild this design cleanly in a new Xilinx ISE (or Vivado/ghdl, if
migrating) project:

1. **Author `hdlc_package.vhd`** per §6.1 and add it to the library first
   (compile order: package → transmit/receive → top).
2. **Compile `Main/transmit.vhd` and `Main/receive.vhd`** against it.
   Fix any residual analysis errors (none expected beyond the package
   dependency based on this review, aside from typical ISE-vs-modern-VHDL
   strictness around the `RstStatus <= '1' when ... else` mixed
   comparisons using `B"0111"` literal — verify tool compatibility).
3. **Write `hdlc_top.vhd`**: instantiate `HDLC_TRANSMIT`, `HDLC_RECEIVE`,
   and (optionally) two `clkdiv` instances if TxC/RxC are to be derived
   on-chip from a system clock rather than supplied externally. Add a
   minimal host-side model: an 8-byte-deep synchronous FIFO (or dual-port
   RAM + counters) behind `TxInputData_*`/`TxRead_n`/`TxEmpty_n`, and a
   register/FIFO capturing `RxOutputData_*` on `RxDataWrite_n`/
   `RxStatusWrite_n`.
4. **Loop TxD → RxD** (directly, or through a UCF-defined external pin pair)
   for a self-test configuration, and drive `TxC`/`RxC` from the same
   source clock so bit timing lines up.
5. **Write one system-level testbench** (`tb_hdlc_top.vhd`) that:
   - Applies reset, enables both blocks, loads a known byte sequence into
     the TX FIFO, pulses `TxStart`, and captures `TxD`.
   - Feeds `TxD` into `RxD` and confirms the received bytes on
     `RxOutputData_*` (gated by `RxDataWrite_n`) match the transmitted
     payload, and that the trailing status byte
     (`RxStatusWrite_n`) reports `Abort=0, Octet_err=0, CRC_err=0`.
   - Adds negative cases: inject a bit error mid-frame → expect
     `CRC_err='1'`; pulse `TxAbort` mid-frame → expect `Abort='1'` on the
     receiver and no data-valid for the truncated frame.
   - Optionally re-purpose the individual `Modules/tb_*.vhd` testbenches
     (after fixing port mismatches per §6.3) as focused unit tests for
     flag detection, stuffing/destuffing and CRC in isolation — useful for
     debugging `Main` failures at the sub-block level, mirroring how the
     original author validated the Gen‑1 modules (per the ISE Component
     Tests screenshots) before integrating into Gen‑2.
6. **Regenerate constraints** (`.ucf`/`.xdc`) for the actual target
   device/pins; do not reuse the committed `clkdiv.ucf` pin locations
   unless targeting the identical board.
7. **Synthesize, implement, and generate a bitstream**; verify in hardware
   or via post-place-and-route timing simulation that `TxC`/`RxC` timing
   closes at the intended bit rate.

---

## 8. Signal/naming glossary (for quick cross-reference while reading the source)

| Prefix/term | Meaning |
|---|---|
| `T_*` | Transmit-side internal signal (buffer/shift/control) |
| `R_*` | Receive-side internal signal |
| `FI_State` / `F_State` | Flag insertion / flag detection FSM state |
| `ZS_State` / `Z_State` | Zero-stuff / zero-unstuff FSM state |
| `FCS` | Frame Check Sequence shift register (live CRC accumulator) |
| `NonFlagFields` | High for the entire address+data+FCS body of a frame (i.e. "not currently sending/receiving a flag") |
| `_n` suffix | Active-low signal (`TxRead_n`, `RxDataWrite_n`, `RxStatusWrite_n`) |
| `Aborting` / `Abort` | TX: latched intent to abort and force a `1`-fill. RX: detected 7+ ones mid-frame |
| `OctetDetected` | RX: byte-alignment has locked on (two flags seen back-to-back) |

---

## 9. Summary

The design is a byte-interface HDLC framer/deframer split into two
peer entities (`HDLC_TRANSMIT`, `HDLC_RECEIVE`), each built from small
communicating FSMs for flag handling, bit stuffing/destuffing, CRC-16
generation/checking, and abort handling — a fairly direct, understandable
decomposition that matches the `Modules/` prototypes it evolved from. The
logic itself looks complete and self-consistent. What is missing for a
build-from-scratch reproduction is entirely at the integration layer: the
shared constants package, a top-level wiring entity, a host-side FIFO
model, and a system-level testbench — all specified concretely in §6–§7
above.
