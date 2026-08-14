# xv6 labs learning roadmap

这份路线的目标不是再拿一遍 grade，而是把已经完成的 xv6-labs-2025 反过来拆开，变成自己能解释、能定位源码、能复现关键修改的知识。

后续所有笔记和报告都遵守一个原则：旧 Typst 报告、AI 对话和通过的代码都只能作为证据，不能直接当成理解。每个任务都要能用自己的话回答：

1. 题目真正要 xv6 多出什么行为？
2. 这个行为发生在 xv6 的哪条执行路径上？
3. 为什么要改这些文件，而不是别的文件？
4. 测试到底在验证什么？
5. 如果从空白分支重新做，我会怎样定位入口？

## Materials

- xv6 book: `docs/book-riscv-rev5.pdf`
- Official labs index: `docs/official-labs/index.md`
- Source map: `docs/notes/00-xv6-map.md`
- Old Typst report: `docs/reports_old/`
- Code branches: `util`, `syscall`, `pgtbl`, `traps`, `cow`, `net`, `lock`, `fs`, `mmap`

## Study method

每个 lab 按同一套流程复盘。

0. Explain it in plain words

   每个任务先用人话说清楚它到底在干什么。不要一上来写“实现某系统调用”“修改某 PTE”“维护某字段”。先写类似这样的句子：

   - `sandbox`：给进程做沙盒，限制它能调用哪些内核服务。
   - `USYSCALL`：内核提前把 pid 写在用户能读但不能改的小纸条上，省掉每次 `getpid()` 都进内核。
   - `backtrace`：程序出问题时，沿着函数调用留下的脚印往回找。
   - `alarm`：给用户程序设闹钟，时间到了先跳去 handler，结束后回到被打断的位置。

   只有这句话讲顺了，后面才进入寄存器、页表、trapframe、锁、inode 等术语。

1. Read the assignment

   只提取任务要求、测试命令、需要观察的行为。不要先看答案。

2. Read the tests

   优先找 `user/*test.c`、`test-xv6.py`、Makefile 中的目标。测试通常比题面更具体：它会暴露参数格式、边界条件、失败信息和评分期望。

3. Trace the original path

   在未修改或基线分支里找到 xv6 原本的执行路径。例如 syscall 任务要先追 `user/usys.pl -> ecall -> usertrap() -> syscall() -> sys_*()`；文件系统任务要先追 `sys_open() -> namei() -> inode -> readi()/writei()`。

4. Compare the diff

   用对应 lab 分支和 `riscv` 基线比较，只看这个任务相关文件。每个改动都要写出一句“为什么它必须在这里”。

5. Explain from memory

   合上旧报告，用自己的话写一版短解释。写不顺的地方才回头查书、查源码、查旧报告。

6. Write the Markdown report

   报告只写已经能解释的内容。不要为了显得完整而堆概念。

## Report structure

新的 Markdown 报告建议放在 `docs/markdown-report/`。每个任务使用固定结构：

```markdown
## Task name

### Plain words

先用生活化但准确的话说这个任务是在做什么。

### Concrete example

用一个具体命令、一次函数调用、一个地址、一个文件名或一次中断走一遍。

### What this task asks xv6 to do

再把人话翻译成 xv6 要实现的行为。

### How xv6 worked before the change

写原始执行路径和原始限制。

### How I found the files to change

解释定位过程，而不是只列文件名。

### Implementation idea

写核心数据结构、控制流、关键判断，可以用小流程图或伪代码。

### Details that can go wrong

写权限位、生命周期、锁、引用计数、边界条件等真正危险的点。

### What the tests prove

说明测试覆盖了哪些行为，哪些行为只是自己推断或手动验证过。
```

## Reading plan

不要把 xv6 book 当成需要一次性读完的教材。每个 lab 带着问题读对应章节。

| Stage | Lab | Main question | Book focus | Main code |
| --- | --- | --- | --- | --- |
| 0 | Environment | xv6 如何被构建、启动、运行在 QEMU 里？ | Chapter 1 的运行环境和第一个进程 | `Makefile`, `kernel/entry.S`, `kernel/main.c`, `user/init.c` |
| 1 | Utilities | 用户程序如何接收参数、调用系统调用、组合进程？ | Chapter 1: operating system interfaces | `user/*.c`, `user/user.h`, `user/usys.pl`, `Makefile` |
| 2 | System Calls | 用户态如何进入内核，内核如何分发 syscall？ | System call, trap, process state | `kernel/syscall.c`, `kernel/syscall.h`, `kernel/sysproc.c`, `kernel/proc.h`, `user/usys.pl` |
| 3 | Page Tables | 虚拟地址如何翻译成物理地址，权限位如何生效？ | Page tables | `kernel/vm.c`, `kernel/riscv.h`, `kernel/memlayout.h`, `kernel/proc.c` |
| 4 | Traps | syscall、异常、中断为什么能走统一入口？ | Traps and system calls | `kernel/trap.c`, `kernel/trampoline.S`, `kernel/kernelvec.S`, `kernel/proc.h` |
| 5 | Copy-on-Write | fork 为什么可以延迟复制物理页？ | Virtual memory and page faults | `kernel/vm.c`, `kernel/kalloc.c`, `kernel/trap.c`, `kernel/riscv.h` |
| 6 | Networking | 网卡如何用 descriptor ring 和内存交换数据包？ | Device drivers and interrupts | `kernel/e1000.c`, `kernel/net.c`, `kernel/trap.c`, `kernel/plic.c` |
| 7 | Locks | 正确的锁为什么还可能性能很差？ | Locking | `kernel/spinlock.c`, `kernel/kalloc.c`, `kernel/bio.c`, `kernel/proc.c` |
| 8 | File System | 文件名、inode、磁盘块、日志如何连起来？ | File system | `kernel/fs.c`, `kernel/file.c`, `kernel/sysfile.c`, `kernel/log.c`, `kernel/fs.h` |
| 9 | mmap | 文件映射如何把 VM、trap、file system 串起来？ | Virtual memory plus file system | `kernel/sysfile.c`, `kernel/proc.h`, `kernel/trap.c`, `kernel/vm.c`, `kernel/file.c` |

## How to locate files

遇到一个任务，先判断它属于哪种行为。

| If the task says... | First place to inspect | Then inspect | Usual reason |
| --- | --- | --- | --- |
| Add a user command | `user/<cmd>.c`, `Makefile` | existing commands such as `user/ls.c`, `user/wc.c` | 用户程序必须被编译并写入 `fs.img` |
| Add a syscall | `user/user.h`, `user/usys.pl`, `kernel/syscall.h`, `kernel/syscall.c` | `kernel/sysproc.c` or `kernel/sysfile.c` | 用户态 stub、syscall number、内核分发表必须对齐 |
| Store per-process state | `kernel/proc.h` | `allocproc()`, `freeproc()`, `kfork()`, `exec()` | 状态要跟着进程生命周期走 |
| Handle a page fault | `kernel/trap.c` | `kernel/vm.c`, `kernel/riscv.h`, `kernel/kalloc.c` | trap 入口决定异常原因，VM 代码负责页表和物理页 |
| Change address mapping | `kernel/vm.c` | `kernel/memlayout.h`, `kernel/proc.c` | 页表创建、映射、解除映射都集中在这里 |
| Change file behavior | `kernel/sysfile.c` | `kernel/file.c`, `kernel/fs.c`, `kernel/fs.h` | syscall 层处理参数，file/inode 层处理对象和磁盘布局 |
| Change disk block layout | `kernel/fs.h`, `kernel/fs.c` | `mkfs/mkfs.c` | on-disk 格式和镜像生成必须一致 |
| Reduce lock contention | code that owns the shared data | `kernel/spinlock.c`, tests such as `kalloctest`, `bcachetest` | 先找共享数据，再判断锁粒度 |
| Change device behavior | device driver file | interrupt path in `kernel/trap.c`, `kernel/plic.c` | 设备通常通过寄存器、DMA buffer、中断和内核交换信息 |

## Lab-by-lab goals

### Lab 1: Utilities

Focus: user programs, arguments, file descriptors, `fork()`, `exec()`, `wait()`, pipes, directory traversal.

You should be able to explain:

- why a new `user/*.c` file is not enough and `Makefile` also matters;
- how `argv` arrives in a user program;
- why `fork()` plus `exec()` is the usual xv6 way to start another command;
- why recursive directory traversal must skip `.` and `..`.

### Lab 2: System Calls

Focus: syscall path, trapframe registers, syscall table, process-owned policy state.

You should be able to explain:

- where the syscall number is stored;
- how arguments move from user registers to kernel code;
- why `syscall()` is the common enforcement point for sandboxing;
- why sandbox policy survives `exec()` only if it lives in `struct proc`.

### Lab 3: Page Tables

Focus: Sv39 page table, PTE flags, user/kernel permissions, shared read-only page, recursive page-table printing, superpages.

You should be able to explain:

- the difference between a PTE value, its physical address part, and its flag bits;
- how xv6 maps special pages such as trampoline, trapframe, and `USYSCALL`;
- why a page can be user-readable but not user-writable;
- how a non-leaf PTE differs from a leaf PTE.

### Lab 4: Traps

Focus: RISC-V registers, stack frames, backtrace, alarm delivery and return.

You should be able to explain:

- why entering the kernel requires saving user registers;
- why `sepc`, `scause`, and `stval` are enough to diagnose many exceptions;
- why backtrace depends on frame pointers;
- why alarm handlers must save and restore the interrupted trapframe.

### Lab 5: Copy-on-Write

Focus: lazy physical-page copying, reference counting, write faults.

You should be able to explain:

- why normal `fork()` is expensive;
- why COW clears `PTE_W` and marks pages specially;
- how a write page fault turns one shared read-only mapping into a private writable page;
- why physical pages need reference counts and lock protection.

### Lab 6: Networking

Focus: E1000 descriptor rings, DMA, packet buffers, interrupt-driven receive path.

You should be able to explain:

- how TX and RX rings describe buffers to the NIC;
- why the driver must update ownership/status fields carefully;
- how a received packet travels from hardware into xv6 network code;
- why memory-ordering and descriptor format details matter.

### Lab 7: Locks

Focus: contention, per-CPU allocator, read-write lock, lock statistics.

You should be able to explain:

- why passing tests is not enough if lock contention is high;
- how splitting a global freelist into per-CPU freelists reduces contention;
- when stealing from another CPU is necessary;
- why a read-write lock needs a policy for waiting writers.

### Lab 8: File System

Focus: inode block mapping, large files, symbolic links.

You should be able to explain:

- how `bmap()` translates a file logical block number into a disk block number;
- why adding double-indirect blocks changes both constants and traversal logic;
- why symbolic links are resolved in `open()`;
- how to prevent infinite symlink loops.

### Lab 9: mmap

Focus: VMA metadata, lazy page fault loading, dirty write-back, unmap.

You should be able to explain:

- why `mmap()` records a mapping instead of immediately reading every page;
- why VMA state belongs to `struct proc`;
- how a page fault finds the VMA and loads data from the mapped file;
- when `munmap()` must write modified pages back.

## Working agreement

For each lab, the order should be:

1. write the plain-words version first;
2. walk one concrete execution example;
3. build a short learning note in `docs/notes/`;
4. verify the explanation against source and old report;
5. ask and answer a few understanding checks;
6. write Markdown report content only after the explanation is stable;
7. later migrate the Markdown into Typst for layout.

The first concrete next step is `docs/notes/01-util.md`: start from the smallest user programs and practice the file-location method before moving into kernel internals.
