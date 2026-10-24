# Core gap list: lab 5A vs SPECTRA

The starting point: every rule of `docs/PROTOCOL.md` section 1 and every core-related number of
the design, against what the lab 5A core (`rtl/lab5a`, plus two fixes: boot bubble, SRA sign) did.
Evidence column: how it was checked.

## 1. What the lab 5A core is (from reading the RTL and)

* 3 stages: IF/ID (`IF_ID.v`, decode + ID/EX register), EX (`execute.v`, ALU, branch, EX/WB
  register), MEM/WB (`wb.v`, store formatting, load alignment, squash counter).
* The register file is read in EX (from the registered rs1/rs2 selects) with a bypass from
  MEM/WB, so a result is usable by the very next instruction: no data stalls at all.
* Instruction memory and data memory are 4 KB synchronous BRAMs (`memory.v`): fetch uses
  `pc[11:2]`, data uses `addr[11:2]`, so every address wraps at 4 KB. A load reads in EX and
  its data arrives in MEM/WB; a store writes from MEM/WB; `data_mem` forwards a same-cycle
  store to a load byte by byte. There is no ready/handshake: `inst_mem_is_valid`,
  `dmem_read_valid`, `dmem_write_valid` are tied to 1.
* A taken branch, JAL or JALR resolves in EX; the next two instructions keep flowing but
  `wb_stall` (first/second) blocks their register write and `branch_stall` blocks their
  store, so they never take effect.
* `stall` input (tied 0) freezes every pipeline register one cycle later (`stall_read`).
* `exception` is a sticky flag for an illegal opcode or a misaligned fetch; the core keeps
  running and treats an illegal instruction as a no-op.
* Board top: 100 MHz divided to 1 Hz for the core, PC[15:0] on the LEDs, reset on pin J15
  (switch SW0).

## 2. Bugs found and fixed

| # | Bug | Fix | Evidence |
| --- | --- | --- | --- |
| B1 | The instruction at RESET executed twice after reset | `pipe.v` boot bubble (commit 629fb60) | `tb/lab5a/run_trace.py`: 0 differences |
| B2 | SRA/SRAI shifted in zeros (unsigned `?:` context) | `execute.v` `$unsigned($signed(a) >>> s)` (commit ccb7e2a) | same |

## 3. PROTOCOL.md section 1 (system rules)

| Rule | Lab 5A | Evidence / note |
| --- | --- | --- |
| Clock 50 MHz from the MMCM, board clock 100 MHz on E3 | No: 100 MHz divided to 1 Hz in `top_fpga.v` | E3 is already the clock pin |
| Reset = BTNC (N17), active high | Active high, but on J15 (= SW0, which SPECTRA uses as FWD) | baseline build keeps J15 |
| Reset releases core 0, and core 1 only when DUAL = 1 | One core | |
| 2 cores, both start at PC 0 | One core; `RESET` parameter = 0 | |
| ISA: RV32I + M only | RV32I **without AUIPC**; no M | every kit image uses AUIPC (17 in demo) |
| No FENCE/ECALL/EBREAK/CSR/compressed needed | Not decoded (flagged illegal) | build.py and run_all.py enforce it in firmware |
| Loads to x0 still access memory | Yes: the read is issued from `mem_to_reg`, independent of rd | t_lab5a `lw x0, 0(s0)` gives `ld` in the trace |
| Register file write-through (MEM/WB value read in the same cycle) | Yes in effect: the lab reads the register array in EX with a MEM/WB bypass | t_lab5a distance-1 chains match |
| Branches resolve in EX; 2 instructions squashed after taken branch/JAL/JALR | Yes (`wb_stall_first/second`, `branch_stall`) | t_lab5a poison counter = 0 |

## 4. Frozen numbers that touch the core

| Rule | Lab 5A |
| --- | --- |
| MUL on DSP, at most 3 cycles, all 4 MUL ops | None |
| Iterative DIV at most 34 cycles; spec results for /0 and INT_MIN / -1 | None |
| M-extension opcodes (opcode 0110011, funct7 0000001) | Not in `opcode.vh` |
| Decoder: every RV32IM encoding, illegal-instruction flag | RV32I without AUIPC; sticky `exception` flag |
| FWD switch: forwarding MEM/WB -> EX for rs1, rs2, store data; FWD = 0 = 1-cycle interlock on every distance-1 dependence | Always forwards; no interlock |
| Global freeze from md_busy, data port not ready, I-cache not ready; a bubble enters MEM/WB while EX holds | Only the external `stall` input (tied 0), one cycle late, no bubble insertion |
| Branch in EX during a memory stall redirects only once unfrozen | Not applicable (no memory stall exists) |
| MUL/DIV start only when not frozen | None |
| IF-A data port: req, we, addr, wdata, be -> rdata, ready; request held until ready; hit = ready in the 2nd cycle | Separate read port (EX) and write port (MEM/WB), fixed 1-cycle memory, no ready |
| Byte enables, load sign/zero extension | Yes (`wb.v` strobes and extension) |
| D-cache hit = 2 cycles in MEM/WB (1 stall); miss L + 4; dirty victim + (L + 4) | 1-cycle BRAM, no cache |
| Simulation commit trace from MEM/WB (`ifdef SIM`) | None (traced from outside with a shadow pipeline) |
| IMEM 16 KB true dual-port (port A core 0, port B core 1) | 4 KB single-port, wraps at 4 KB |
| DMEM 128 KB at 0x1000_0000; other data addresses = decode error | 4 KB, wraps at 4 KB, no decode |
| I-cache 2 KB 2-way per core; hit no stall; IC = 0 fetch costs L + 1 | Direct BRAM fetch, never stalls |
| MMIO at 0x2000_0000 through the arbiter | None (would wrap into DMEM) |
| Watchdog: no retired instruction for 100,000 cycles fails a system TB | the lab trace TB has a cycle watchdog |

## 5. Lab structure notes

* `pipe.v` `include`s `IF_ID.v`, `execute.v` and `wb.v`, so file lists name only `pipe.v`;
  SPECTRA's core splits them into separately compiled modules.
* `execute.v` and `top_fpga.v`, `tb_pipeline.v` use LF line endings, the other lab files CRLF;
  edits keep each file's style.
* The lab board build: LUT 2593, FF 1304, 1 RAMB36. `data_mem` became 1024
  LUTs of distributed RAM (its same-cycle byte-forwarding read prevents BRAM inference);
  `instr_mem` is the RAMB36; the register-file read multiplexers (about 1290 LUTs) are
  reported under `id_ex_reg`; WNS +5.612 ns covers only
  the 100 MHz divider, because the core clock is a divided register and unconstrained.
  SPECTRA's MMCM clock and BRAM modules replace both.

## 6. AUIPC

* The decoder also adds **AUIPC** (opcode 0010111: rd = pc + imm[31:12] << 12). Reason: the lab
  decoder lacks it and every kit firmware image needs it. The decoder test ("every RV32IM encoding
  decodes correctly") covers it.


## 7. Firmware-rule review, 16 Oct 2026

Checked on the gcc build (commit after spec-v1.0) by reading the sources and the 6 listings:

| Rule | Result | How checked |
| --- | --- | --- |
| `.data` / `.sdata` empty (a soft reset does not reload BRAM) | holds in all 6 images | `riscv-none-elf-objdump -h`: no .data/.sdata section; build.py refuses otherwise |
| No CSR, FENCE, ECALL, EBREAK, MRET, WFI | holds: 0 such instructions in all 6 listings | grep of the listings; run_all.py "only RV32IM instructions" PASS |
| "BARRIER is `lw zero`" | **does not hold as written**: boot.S loads BARRIER into `t3` on purpose, and C `barrier()` compiles to `lw a4, 12(...)` | listings |

Consequence: the hardware rule "loads to x0 still access memory" stays (lab 5A obeys it; the
RTL keeps it), but no current program relies on it. PROTOCOL.md v1.1 and interfaces.md
1.0.1 reworded accordingly. Signed off by Divyam on 16 Oct 2026.
