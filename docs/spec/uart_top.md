# uart_top (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/io/uart_top.v |
| Testbench | tb/tb_uart_top.v |
| Vectors | directed byte stream; the TB decodes the line itself |
| Interfaces | none (fed by result_streamer) |
| Removal parameter | none |

## Purpose
Transmit-only UART, 1,000,000 baud, 8N1, with a byte FIFO, on the Nexys A7 USB-UART (pin D4).

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `wr` | in | 1 | push `wr_data` into the FIFO |
| `wr_data` | in | 8 | |
| `full` | out | 1 | FIFO full (the writer must not push) |
| `busy` | out | 1 | FIFO not empty or a byte being sent |
| `tx` | out | 1 | serial line, idle high |

## Behaviour
1. Bit time exactly 50 `clk` cycles (50 MHz / 1 Mbaud). Frame: start bit 0, 8 data bits LSB
   first, stop bit 1: 500 cycles per byte (PROTOCOL.md section 5).
2. FIFO depth 512 bytes (one BRAM18); bytes leave back to back with no idle gap.

## Reset values
`tx` = 1, FIFO empty.

## Tests
Every bit lasts exactly 50 cycles; 256 bytes in a row decode correctly; `full` asserts at 512
and no byte is lost. PASS = all checks.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
