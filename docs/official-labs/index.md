# Official xv6-labs-2025 index

This file is a local study index for the official xv6-labs-2025 assignments. Keep it short: link to the official page, record the task names, and connect each lab to the local source/report material.

Official course root:

- <https://pdos.csail.mit.edu/6.1810/2025/>
- <https://pdos.csail.mit.edu/6.1810/2025/labs/>

## Local references

| Material | Local path |
| --- | --- |
| xv6 book | `docs/book-riscv-rev5.pdf` |
| old Typst report | `docs/reports_old/` |
| learning roadmap | `docs/learning-roadmap.md` |
| source map | `docs/notes/00-xv6-map.md` |

## Labs

| Lab | Topic | Official page | Local old report | Code branch |
| --- | --- | --- | --- | --- |
| 0 | Environment setup | course setup pages | `docs/reports_old/labs/lab0-env.typ` | `riscv` / local environment |
| 1 | Utilities | <https://pdos.csail.mit.edu/6.1810/2025/labs/util.html> | `docs/reports_old/labs/lab1-util.typ` | `util` |
| 2 | System calls | <https://pdos.csail.mit.edu/6.1810/2025/labs/syscall.html> | `docs/reports_old/labs/lab2-syscall.typ` | `syscall` |
| 3 | Page tables | <https://pdos.csail.mit.edu/6.1810/2025/labs/pgtbl.html> | `docs/reports_old/labs/lab3-pgtbl.typ` | `pgtbl` |
| 4 | Traps | <https://pdos.csail.mit.edu/6.1810/2025/labs/traps.html> | `docs/reports_old/labs/lab4-traps.typ` | `traps` |
| 5 | Copy-on-write fork | <https://pdos.csail.mit.edu/6.1810/2025/labs/cow.html> | `docs/reports_old/labs/lab5-cow.typ` | `cow` |
| 6 | Networking | <https://pdos.csail.mit.edu/6.1810/2025/labs/net.html> | `docs/reports_old/labs/lab6-net.typ` | `net` |
| 7 | Locks | <https://pdos.csail.mit.edu/6.1810/2025/labs/lock.html> | `docs/reports_old/labs/lab7-lock.typ` | `lock` |
| 8 | File system | <https://pdos.csail.mit.edu/6.1810/2025/labs/fs.html> | `docs/reports_old/labs/lab8-fs.typ` | `fs` |
| 9 | mmap | <https://pdos.csail.mit.edu/6.1810/2025/labs/mmap.html> | `docs/reports_old/labs/lab9-mmap.typ` | `mmap` |

## Task checklist from the local report

Use this checklist to keep the official task, old report, and code branch aligned. If the official page differs from the old report, prefer the official page and record the difference in the lab note.

### Lab 1: Utilities

- Boot xv6
- `sleep`
- `sixfive`
- `memdump`
- `find`
- `find -exec`

### Lab 2: System calls

- GDB and system calls
- Sandbox a command
- Sandbox with allowed pathnames
- Attack xv6

### Lab 3: Page tables

- Inspect a user-process page table
- Speed up system calls
- Print a page table
- Use superpages

### Lab 4: Traps

- RISC-V assembly
- Backtrace
- Alarm

### Lab 5: Copy-on-write

- Copy-on-write fork

### Lab 6: Networking

- NIC transmit/receive driver work
- UDP receive path

### Lab 7: Locks

- Memory allocator
- Read-write lock

### Lab 8: File system

- Large files
- Symbolic links

### Lab 9: mmap

- Memory-mapped files

## How to use this index

For each lab:

1. Open the official page and write down the requested behavior.
2. Open the local old report only to see what was previously claimed.
3. Compare the lab branch against `riscv`.
4. Write a new note in `docs/notes/NN-lab-name.md`.
5. Convert only understood notes into the new Markdown report.
