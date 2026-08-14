# xv6 source map

这份地图只回答一个问题：遇到某类实验任务时，应该先去哪里看源码。它不是完整源码注释。

## Big picture

```text
user command
  -> user library / syscall stub
  -> ecall
  -> trampoline and trap handling
  -> syscall dispatcher or device/exception handler
  -> process, vm, file system, lock, or driver code
  -> return through trapframe
```

xv6 的源码很小，但路径比较清楚：用户态程序通过系统调用或异常进入内核，内核围绕进程、页表、文件、磁盘、设备和锁做管理。

## Top-level directories

| Path | Role | When to inspect |
| --- | --- | --- |
| `kernel/` | 内核源码 | syscall、页表、trap、进程、锁、文件系统、设备驱动相关任务 |
| `user/` | 用户程序、用户库、测试程序 | 新增命令、测试入口、用户态 syscall 声明 |
| `mkfs/` | 构建 xv6 文件系统镜像 | 文件系统格式、需要把用户程序放进 `fs.img` 时 |
| `Makefile` | 编译、运行、打包用户程序 | 新增用户程序、运行 QEMU、运行 grade |
| `test-xv6.py` | 评分脚本入口之一 | 想确认测试检查什么行为时 |
| `docs/` | 学习材料和报告 | 不影响 xv6 运行，只放笔记、报告、截图 |

## User side

| File | Role | Typical labs |
| --- | --- | --- |
| `user/*.c` | xv6 用户程序和测试程序 | util, syscall, pgtbl, traps, mmap |
| `user/user.h` | 用户态可见的函数声明、结构声明 | 新增 syscall、新增用户库函数 |
| `user/usys.pl` | 生成 syscall 汇编 stub | syscall 类任务 |
| `user/ulib.c` | 用户态辅助函数 | pgtbl 的 `ugetpid()` 等 |
| `user/printf.c` | 用户态 printf | 调试输出、理解用户程序支持能力 |
| `user/sh.c` | xv6 shell | 命令如何被解析、fork/exec/wait 如何组合 |
| `user/usertests.c` | 大量回归测试 | 修改内核后判断是否破坏原有行为 |

New user command checklist:

1. create or inspect `user/<name>.c`;
2. include `kernel/types.h`, `kernel/stat.h`, `user/user.h` as needed;
3. add `$U/_<name>` to `UPROGS` in `Makefile`;
4. build `fs.img`;
5. run the command inside xv6 shell, not host shell.

## Syscall path

```text
user code calls function
  -> generated stub from user/usys.pl
  -> syscall number placed in a7
  -> ecall
  -> trampoline.S
  -> usertrap() in kernel/trap.c
  -> syscall() in kernel/syscall.c
  -> sys_* implementation
  -> return value written to trapframe->a0
```

| File | Role | What to look for |
| --- | --- | --- |
| `user/user.h` | user-visible declaration | syscall prototype |
| `user/usys.pl` | stub generator | `entry("name")` |
| `kernel/syscall.h` | syscall numbers | `SYS_name` |
| `kernel/syscall.c` | dispatcher | `syscalls[]`, name table, common policy checks |
| `kernel/sysproc.c` | process-related syscall implementations | process, memory-size, timing, lab-specific syscalls |
| `kernel/sysfile.c` | file-related syscall implementations | open, read, write, link, mmap-like file operations |
| `kernel/trap.c` | reaches `syscall()` from user trap | why syscall enters kernel at all |
| `kernel/proc.h` | process state | per-process fields used by syscalls |

新增 syscall 时，最常见错误是只写了 `sys_*`，但忘了用户态声明、stub、number、dispatch table 中的一处。

## Process and scheduling

| File | Role | What to look for |
| --- | --- | --- |
| `kernel/proc.h` | `struct proc`, `struct trapframe`, CPU state | per-process metadata, saved registers |
| `kernel/proc.c` | process allocation, fork, exec interaction, wait, scheduler | state lifecycle |
| `kernel/swtch.S` | context switch assembly | kernel thread register switching |
| `kernel/entry.S` | first kernel entry after boot | very early startup |
| `kernel/main.c` | kernel initialization order | which subsystem starts when |
| `kernel/exec.c` | replace process address space with program image | why `exec()` keeps `struct proc` but replaces user memory |

Rule of thumb: if a state must survive `exec()` or be inherited by `fork()`, inspect `struct proc`, `allocproc()`, `freeproc()`, `kfork()`, and `exec()`.

## Trap and interrupt path

| File | Role | What to look for |
| --- | --- | --- |
| `kernel/trap.c` | user traps, kernel traps, device interrupts | syscall, page fault, timer interrupt |
| `kernel/trampoline.S` | transition between user and kernel page tables | saving/restoring user registers |
| `kernel/kernelvec.S` | kernel-mode trap vector | traps while already in kernel |
| `kernel/riscv.h` | CSR helpers and PTE flag macros | `scause`, `sepc`, `stval`, `satp`, interrupt control |
| `kernel/plic.c` | platform interrupt controller | external device interrupt dispatch |

Use this path for alarm, backtrace context, page faults, device interrupts, and anything involving `scause`.

Important RISC-V registers:

| Register | Meaning |
| --- | --- |
| `a7` | syscall number before `ecall` |
| `a0` | first argument and return value |
| `sepc` | saved user PC at trap time |
| `scause` | trap reason |
| `stval` | extra trap value, often faulting virtual address |
| `satp` | active page table |

## Virtual memory

| File | Role | What to look for |
| --- | --- | --- |
| `kernel/vm.c` | page-table walk, mapping, unmapping, copying | `walk()`, `mappages()`, `uvmunmap()`, `uvmcopy()` |
| `kernel/riscv.h` | PTE flags and address macros | `PTE_V`, `PTE_R`, `PTE_W`, `PTE_X`, `PTE_U`, `PTE2PA` |
| `kernel/memlayout.h` | virtual and physical memory layout constants | `TRAMPOLINE`, `TRAPFRAME`, device addresses |
| `kernel/kalloc.c` | physical page allocator | page allocation, free list, COW refcount |
| `kernel/proc.c` | per-process page-table creation/destruction | special user mappings, process address space lifecycle |

Page-table checklist:

1. Is the PTE valid?
2. Is it a leaf PTE or a pointer to the next level?
3. Which physical page does it point to?
4. Which permissions are set?
5. Who owns the physical page lifecycle?
6. Should unmapping also free the physical page?

## File system

| File | Role | What to look for |
| --- | --- | --- |
| `kernel/sysfile.c` | file syscalls and argument handling | `sys_open()`, `sys_read()`, `sys_write()`, `sys_link()` |
| `kernel/file.c` | open file table | file reference counts, file read/write dispatch |
| `kernel/file.h` | `struct file` and related definitions | file object fields |
| `kernel/fs.c` | inode and block mapping logic | `bmap()`, `readi()`, `writei()`, `namei()` |
| `kernel/fs.h` | on-disk filesystem layout | inode format, constants such as direct/indirect counts |
| `kernel/log.c` | filesystem transaction log | crash-safe grouped writes |
| `kernel/bio.c` | buffer cache | disk block cache and locking |
| `kernel/virtio_disk.c` | disk driver | physical disk request path |
| `mkfs/mkfs.c` | create filesystem image | must match on-disk constants in `fs.h` |

File-system rule: if you change on-disk layout constants, check both kernel file-system code and `mkfs`.

## Locks and concurrency

| File | Role | What to look for |
| --- | --- | --- |
| `kernel/spinlock.c` | spinlock acquire/release | interrupt disabling, ownership tracking |
| `kernel/spinlock.h` | spinlock data structure | lock metadata |
| `kernel/sleeplock.c` | sleep lock implementation | locks held across blocking disk operations |
| `kernel/sleeplock.h` | sleep lock data structure | inode and buffer locking |
| `kernel/proc.c` | sleep/wakeup and process locks | blocking coordination |
| `kernel/kalloc.c` | allocator lock contention | per-CPU allocator lab |
| `kernel/bio.c` | buffer cache lock contention | bcache-related lock work |

Lock-debugging checklist:

1. What data is protected?
2. Which code reads or writes it?
3. Can the holder sleep?
4. Can an interrupt handler touch the same data?
5. Is the problem correctness or contention?

## Devices and networking

| File | Role | What to look for |
| --- | --- | --- |
| `kernel/uart.c` | console device | basic character I/O and interrupts |
| `kernel/virtio_disk.c` | disk device | descriptor-based disk I/O |
| `kernel/plic.c` | interrupt controller | claim and complete external interrupts |
| `kernel/trap.c` | interrupt dispatch | route device interrupts |
| `kernel/e1000.c` | E1000 NIC driver, when present on net branch | TX/RX descriptor rings |
| `kernel/net.c` | xv6 network stack, when present on net branch | packet processing |

Driver code often has three layers: memory buffers owned by the kernel, descriptors shared with hardware, and interrupt or polling code that moves ownership forward.

## Common source-location patterns

### Adding a command

Start at user program examples, then Makefile.

```text
user/<cmd>.c
  -> Makefile UPROGS
  -> run inside xv6 shell
```

### Adding a syscall

Start from user declaration and follow the dispatcher.

```text
user/user.h
user/usys.pl
kernel/syscall.h
kernel/syscall.c
kernel/sysproc.c or kernel/sysfile.c
```

### Adding per-process behavior

Start from `struct proc` and check lifecycle.

```text
kernel/proc.h
kernel/proc.c: allocproc/freeproc/kfork
kernel/exec.c if exec changes behavior
```

### Handling page faults

Start from the trap cause.

```text
kernel/trap.c
kernel/riscv.h
kernel/vm.c
kernel/kalloc.c
```

### Changing a file's block layout

Start from on-disk constants.

```text
kernel/fs.h
kernel/fs.c
mkfs/mkfs.c
```

## What not to do

- Do not start by reading every file linearly.
- Do not start from the old report prose.
- Do not memorize file lists without a reason for each file.
- Do not say "because the answer changed this file"; say what responsibility that file owns.
- Do not trust passing grade as proof that you can explain the mechanism.

## First-pass self check

Before writing a report section, answer these without looking:

1. What user-visible behavior changed?
2. What original xv6 path did I extend?
3. Which data structure stores the new state?
4. Who initializes that state?
5. Who copies or inherits that state?
6. Who frees or invalidates that state?
7. What lock or permission bit prevents unsafe access?
8. Which test would fail if this part were missing?
