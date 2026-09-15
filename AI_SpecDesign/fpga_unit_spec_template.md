# FPGA Functional Unit Specification

> **How to use this template.** Fill every `<placeholder>` and delete the _italic guidance notes_ before handing the document to an AI generator. This spec is the single source of truth: the AI must implement **only** what is written here and must **not** infer unstated behaviour. Anything genuinely undecided goes in §14 (Open Questions), not left implicit. Keep tables complete — an empty interface row is treated as an error, not a "don't care".

---

## 0. Document Control

| Field | Value |
|---|---|
| Unit name | `<canonical_module_name>` |
| Document ID / version | `<DOC-ID> / v<0.1>` |
| Author | `<name>` |
| Date | `<YYYY-MM-DD>` |
| Status | `Draft / In Review / Approved` |
| Reviewers | `<names>` |

**Revision history**

| Version | Date | Author | Change summary |
|---|---|---|---|
| 0.1 | `<YYYY-MM-DD>` | `<name>` | Initial draft |

---

## 1. Purpose & Scope

_One paragraph: what this unit does and why it exists in the larger system._

- **Purpose:** `<what problem the unit solves>`
- **In scope:** `<functions this unit must implement>`
- **Out of scope:** `<explicitly excluded functions — see also §10>`
- **Parent system / context:** `<where this block sits; upstream and downstream blocks>`

---

## 2. Functional Overview

_A concise, implementation-independent description of behaviour. A block diagram reference belongs here._

- **Summary:** `<2–5 sentences describing observable behaviour>`
- **Block diagram:** `<link or embedded figure: inputs → processing → outputs>`
- **Key data flow:** `<describe the main path data takes through the unit>`

---

## 3. Target Technology & Toolchain

_These constraints directly shape the generated RTL. Be specific._

| Item | Value |
|---|---|
| HDL language | `VHDL-2008 / SystemVerilog / <other>` |
| Target device family | `<e.g. AMD Artix-7, Versal Gen 2, Altera Agilex>` |
| Specific part (if fixed) | `<e.g. xcvc1902-...>` |
| Synthesis tool & version | `<e.g. Vivado 2024.x, non-project/Tcl mode>` |
| Simulation tool | `<e.g. Questa One, GHDL>` |
| Verification methodology | `<e.g. UVM / cocotb / directed testbench>` |
| Primary clock frequency (target) | `<MHz>` |
| Vendor IP allowed? | `Yes / No — if yes, which: <list>` |

---

## 4. Interface Specification

### 4.1 Parameters / Generics

| Name | Type | Default | Range / legal values | Description |
|---|---|---|---|---|
| `<DATA_WIDTH>` | `integer` | `<16>` | `<8..64>` | `<meaning>` |
| `<...>` | | | | |

### 4.2 Port List

_List every port. Direction is from the unit's perspective. Group by function (clock/reset, control, data, status)._

| Port | Dir | Width | Clock domain | Active level / polarity | Description |
|---|---|---|---|---|---|
| `<clk>` | in | 1 | — | rising edge | `<primary clock>` |
| `<rst_n>` | in | 1 | `<clk>` | active-low, sync | `<reset>` |
| `<s_valid>` | in | 1 | `<clk>` | active-high | `<input handshake>` |
| `<s_data>` | in | `<DATA_WIDTH>` | `<clk>` | — | `<input payload>` |
| `<m_valid>` | out | 1 | `<clk>` | active-high | `<output handshake>` |
| `<m_data>` | out | `<DATA_WIDTH>` | `<clk>` | — | `<output payload>` |
| `<...>` | | | | | |

### 4.3 Clocking & Reset

- **Clock(s):** `<name, frequency, source>`
- **Clock domain crossings:** `<none / describe each CDC and required synchroniser style>`
- **Reset scheme:** `<synchronous/asynchronous, active level, assertion source, minimum assertion duration>`
- **Reset behaviour:** `<state of all outputs during and immediately after reset>`

### 4.4 Interface Protocol(s)

_For each bus/handshake, state the exact protocol and any deviations from the standard._

- **Protocol:** `<AXI4-Stream / AXI4-Lite / custom valid-ready / ...>`
- **Handshake rules:** `<e.g. data stable while valid=1 and ready=0; no backpressure assumed>`
- **Byte/bit ordering:** `<endianness, MSB/LSB-first>`
- **Reference:** `<link to protocol spec if standard>`

---

## 5. Register Map (if applicable)

_Delete this section if the unit has no software-visible registers._

| Offset | Name | Access | Reset value | Bit field | Description |
|---|---|---|---|---|---|
| `0x00` | `<CTRL>` | RW | `0x0` | `[0] enable` | `<meaning>` |
| `0x04` | `<STATUS>` | RO | `0x0` | `[0] busy` | `<meaning>` |
| `<...>` | | | | | |

---

## 6. Functional Requirements

_Number each requirement so it can be traced to a verification item in §12._

### 6.1 Behavioural Requirements

| ID | Requirement |
|---|---|
| FR-1 | `<precise, testable statement — e.g. "When s_valid & s_ready, the unit latches s_data on the next rising clk edge.">` |
| FR-2 | `<...>` |

### 6.2 Algorithm / Data Path / Equations

_Give exact math and fixed-point formats. Ambiguity here is the most common source of wrong RTL._

- **Operation(s):** `<equations, transfer function, or pseudocode>`
- **Numeric format:** `<signed/unsigned, integer/fixed-point Qm.n, saturation vs. wrap, rounding mode>`
- **Overflow/underflow handling:** `<saturate / wrap / flag>`

### 6.3 State Machine(s)

_For each FSM: list states, the reset state, transition conditions, and outputs per state (Moore/Mealy)._

- **FSM name:** `<...>` (type: `Moore / Mealy`)
- **States:** `<IDLE, LOAD, RUN, DONE, ERROR>`
- **Reset state:** `<IDLE>`
- **Transition table / diagram:** `<table or figure>`

### 6.4 Data Formats

- **Input format:** `<layout, valid ranges, alignment>`
- **Output format:** `<layout, valid ranges, alignment>`

### 6.5 Latency & Throughput

- **Latency:** `<cycles from input to corresponding output>`
- **Throughput:** `<samples/clock; initiation interval if pipelined>`
- **Pipelining:** `<required depth / free to choose>`

---

## 7. Timing & Performance Requirements

- **Fmax target:** `<MHz>`
- **Critical paths / constraints of note:** `<...>`
- **Required constraint files:** `<XDC/SDC notes, false paths, multicycle paths>`

---

## 8. Resource & Physical Constraints

| Resource | Budget / limit |
|---|---|
| LUTs | `<max>` |
| FFs | `<max>` |
| BRAM / URAM | `<max>` |
| DSP | `<max>` |
| Power | `<budget, if applicable>` |

- **Preferred implementation style:** `<e.g. use DSP48 for multiplies; infer BRAM for buffer; no latches>`

---

## 9. Error Handling & Edge Cases

_Enumerate every abnormal condition and the required response. AI generators are weakest here — be exhaustive._

| Condition | Required behaviour |
|---|---|
| `<invalid input / protocol violation>` | `<assert error flag, drop sample, ...>` |
| `<reset mid-operation>` | `<...>` |
| `<back-to-back transactions>` | `<...>` |
| `<boundary values (0, max, all-ones)>` | `<...>` |

---

## 10. Assumptions, Dependencies & Exclusions

- **Assumptions:** `<what the unit may rely on being true — e.g. input is always aligned>`
- **External dependencies:** `<other blocks, IP, packages, clock sources>`
- **Explicit exclusions:** `<what this unit must NOT do>`

---

## 11. Coding & Style Requirements (directives to the AI generator)

_These are binding instructions for how the RTL is written, not just what it does._

- Implement **only** the behaviour specified above. If any requirement is ambiguous or missing, **stop and list the question in §14** rather than assuming.
- Language / standard: `<VHDL-2008 / SystemVerilog-2017>`; synthesizable subset only.
- Naming conventions: `<e.g. signals lower_snake_case, generics UPPER_SNAKE_CASE, active-low suffix _n>`.
- No inferred latches; all registers reset per §4.3; fully synchronous to the stated clock(s).
- One entity/module per file; file name matches unit name.
- Comment each process/always block and each FSM state with its intent.
- Include a header block (unit name, version, author, date, spec reference).
- Provide a matching `<language>` package/parameter file for shared types/constants if applicable.

---

## 12. Verification & Acceptance Criteria

_Each item should trace back to a requirement ID from §6. This defines "done"._

| V-ID | Traces to | Check | Pass criterion |
|---|---|---|---|
| V-1 | FR-1 | `<directed test / assertion>` | `<expected result>` |
| V-2 | FR-2 | `<...>` | `<...>` |

- **Coverage target:** `<functional/code coverage goal, if any>`
- **Testbench expectations:** `<self-checking / reference model / UVM env>`
- **Definition of done:** synthesizes clean at `<Fmax>`, meets §8 budgets, all V-IDs pass.

---

## 13. Deliverables

- [ ] RTL source file(s) — `<language>`
- [ ] Package/constants file (if applicable)
- [ ] Constraint file(s) — `<XDC/SDC>`
- [ ] Testbench / verification environment
- [ ] Build/run script — `<e.g. Vivado non-project Tcl>`
- [ ] Brief implementation notes / README

---

## 14. Open Questions & References

**Open questions** _(the AI must populate anything it cannot resolve from this spec):_

| # | Question | Blocking? | Owner | Resolution |
|---|---|---|---|---|
| Q1 | `<...>` | Yes/No | `<name>` | `<...>` |

**References**

- `<links to protocol specs, algorithms, parent-system docs, related units>`
