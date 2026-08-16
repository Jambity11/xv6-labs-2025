# Lab 1 Utilities 学习笔记

这是第一份真正的复盘笔记。它的目的不是把 Lab1 的答案再背一遍，而是先练会一个更基础的问题：一个用户态 C 程序，怎样变成 xv6 shell 里可以运行的命令。

官网页面：

- <https://pdos.csail.mit.edu/6.1810/2025/labs/util.html>

本地参考：

- 旧报告：`docs/reports_old/labs/lab1-util.typ`
- 代码分支：`origin/util`
- 基线分支：`origin/riscv`

## 先抓住一句话

Lab1 的一句话版本：

> 你写的 `user/*.c` 不是自动出现在 xv6 里的；它要先被交叉编译成 RISC-V 用户程序，再被 `mkfs` 放进 `fs.img`，最后才能被 xv6 shell 执行。

所以这个 lab 先别急着想“算法怎么写”，先看懂这条路径：

```text
你写 user/sleep.c
  -> Makefile 的 UPROGS 里登记 $U/_sleep
  -> make 用 RISC-V 工具链编译出 user/_sleep
  -> mkfs 把 _sleep 写进 fs.img
  -> QEMU 启动 xv6
  -> xv6 shell 运行 sleep
```

只要这个路径没通，代码写得再对，xv6 shell 里也找不到命令。

## 这个 Lab 真正在学什么

这个 Lab 不是主要考困难算法，而是在教 xv6 的用户态一侧：

1. 一个 `user/` 里的 C 文件怎样成为 xv6 里的命令。
2. 命令行参数怎样进入 `argc` 和 `argv`。
3. 用户程序怎样调用已有系统调用，例如 `pause`、`open`、`read`、`fstat`、`fork`、`exec`、`wait`。
4. 文件描述符怎样把文件、管道、控制台、设备统一成同一种读写接口。
5. 目录为什么可以被当作包含 `struct dirent` 记录的文件来读。

最重要的执行路径：

```text
host shell runs make
  -> cross-compile user/*.c into RISC-V binaries
  -> mkfs writes selected binaries into fs.img
  -> QEMU boots xv6
  -> xv6 shell runs commands from fs.img
```

如果一个命令没有列在 `UPROGS` 里，它可以有源码，但不会出现在 xv6 文件系统里。

## Files changed by the util branch

From `origin/riscv...origin/util`, the branch touches:

```text
.gitignore
Makefile
conf/lab.mk
grade-lab-util
gradelib.py
kernel/param.h
kernel/riscv.h
user/find.c
user/findtest.sh
user/memdump.c
user/sixfive.c
user/sixfive.txt
user/sleep.c
```

For learning the implemented tasks, separate these into two groups.

Course/lab infrastructure:

- `conf/lab.mk`: selects `LAB=util`.
- `grade-lab-util`, `gradelib.py`: grading infrastructure.
- large Makefile changes: shared course framework for multiple labs.
- `.gitignore`: local generated-file hygiene.
- `kernel/param.h`, `kernel/riscv.h`: branch-level upstream/course changes; inspect only if a task or compile error points there.

Task implementation:

- `user/sleep.c`: new user command.
- `user/sixfive.c`: new user command that scans text files.
- `user/memdump.c`: new user command that interprets memory bytes using a format string.
- `user/find.c`: new user command that traverses directories and optionally runs another command.
- `Makefile`: registers user commands in `UPROGS` and lab-specific extra files in `UEXTRA`.
- `user/findtest.sh`, `user/sixfive.txt`: test input material copied into `fs.img`.

## How to know which files to inspect

The assignment asks for user commands, not new kernel behavior. So the first guess should be `user/*.c` and `Makefile`, not `kernel/`.

The path is:

```text
write user command
  -> add it to Makefile UPROGS
  -> mkfs puts _command into fs.img
  -> xv6 shell finds and execs it
  -> command calls existing syscalls
```

No new syscall is needed in this lab because xv6 already provides the kernel services used by these programs:

- sleeping: `pause()`;
- files: `open()`, `read()`, `close()`, `fstat()`;
- process control: `fork()`, `exec()`, `wait()`;
- output: `printf()`, `fprintf()`.

## Task: sleep

### Behavior

`sleep ticks` waits for a given number of timer ticks and exits.

### Source-location reasoning

This is a new shell command. Therefore:

1. `user/sleep.c` owns argument parsing and the syscall call.
2. `Makefile` must include `$U/_sleep` in `UPROGS`.
3. No kernel file is required because xv6 already has a sleep-like syscall named `pause` in this branch.

### Implementation path

```text
xv6 shell: sleep 10
  -> argv[0] = "sleep", argv[1] = "10"
  -> atoi(argv[1]) gives 10
  -> pause(10)
  -> exit(0)
```

### Things to understand

- `argv` values are strings. The command must convert `"10"` into integer `10`.
- Missing arguments must be rejected before reading `argv[1]`.
- This program runs inside xv6, so it uses xv6's user library, not the host C library.

### Understanding check

Answer without reading the old report:

1. Why does `sleep.c` include `user/user.h`?
2. What happens if `$U/_sleep` is removed from `UPROGS` but `user/sleep.c` still exists?
3. Why does this task not require editing `kernel/sysproc.c`?

## Task: sixfive

### Behavior

`sixfive file...` scans each input file and prints complete decimal integers divisible by 5 or 6.

The subtle part is "complete integer". A digit inside a word should not be treated as a standalone number.

### Source-location reasoning

This task is a user-level file scanner. Therefore:

1. `user/sixfive.c` owns parsing.
2. `Makefile` registers `$U/_sixfive`.
3. `user/sixfive.txt` is test data copied into the file system image.
4. The kernel already has `open()` and `read()`, so no kernel change is needed.

### Implementation idea

The implementation uses a small state machine:

```text
SEP_STATE
  after a separator; a digit can start a valid number

NUMBER_STATE
  currently reading a valid decimal integer

INVALID_STATE
  inside a non-number token; ignore digits until a separator appears
```

On a separator:

- if currently in `NUMBER_STATE`, finish the number and print it if divisible by 5 or 6;
- reset to `SEP_STATE`.

On a digit:

- from `SEP_STATE`, start a number;
- from `NUMBER_STATE`, append the digit;
- from `INVALID_STATE`, ignore it.

On any other character:

- move to `INVALID_STATE`;
- discard any partial number.

### Things to understand

- Reading one character at a time makes token boundaries explicit.
- End of file acts like a separator; otherwise the last number would be missed.
- The divisor test is not the main difficulty. Correct token recognition is.

### Understanding check

1. Why should `xv6` not make the program print `6`?
2. What state should the scanner enter after reading `12a`?
3. Why is EOF handled after the read loop?

## Task: memdump

### Behavior

`memdump` interprets bytes according to a format string and prints values of different sizes or pointer interpretations.

### Source-location reasoning

This is pure user-level memory interpretation:

1. `user/memdump.c` owns all behavior.
2. `Makefile` registers `$U/_memdump`, but only when `LAB=util`.
3. No kernel file is needed because the program only reads its own address space and optionally standard input.

### Implementation idea

The format string determines how many bytes to read and how to interpret them:

| Format | Meaning | Pointer advance |
| --- | --- | --- |
| `i` | `int` | `sizeof(int)` |
| `p` | 64-bit pointer-sized value | `sizeof(uint64)` |
| `h` | `short` | `sizeof(short)` |
| `c` | one character | `1` |
| `s` | pointer to string | `sizeof(char *)` |
| `S` | inline null-terminated string | `strlen(data) + 1` |

### Things to understand

- This task exposes C's raw memory model: the same bytes can be interpreted differently depending on type.
- `s` and `S` are different. `s` treats the bytes as a pointer to a string; `S` treats the current bytes as the string itself.
- Casts such as `(int *)data` do not copy bytes; they reinterpret the address.

### Understanding check

1. Why does `i` advance by 4 bytes but `c` advances by 1 byte?
2. Why does `s` read a `char *` from memory instead of printing `data` directly?
3. Why is this task useful before studying page tables and virtual memory?

## Task: find

### Behavior

`find path name` recursively walks a directory tree and prints paths whose last component equals `name`.

`find path name -exec cmd args...` runs another command for each matching path.

### Source-location reasoning

This task combines file-system interfaces and process interfaces, but still from user space:

1. `user/find.c` owns traversal and optional execution.
2. `Makefile` registers `$U/_find`.
3. `user/findtest.sh` is copied into `fs.img` as test material.
4. No kernel file is needed because existing syscalls already expose directories, file metadata, and process creation.

### Implementation path

```text
open(path)
  -> fstat(fd)
  -> if last component matches target, print or exec
  -> if type is directory:
       read dirent records
       skip empty entries
       skip "." and ".."
       append child name to path
       recursively find(child)
  -> close(fd)
```

For `-exec`:

```text
matching path found
  -> build argv = command arguments + matched path + null
  -> fork()
  -> child execs command
  -> parent waits
```

### Things to understand

- Directories are read with `read(fd, &de, sizeof(de))`; each record is a `struct dirent`.
- `de.name` has fixed length `DIRSIZ`, so code must ensure the copied name is null-terminated.
- Recursion must skip `.` and `..`; otherwise it can loop forever.
- `exec()` does not return on success. If it returns, that means it failed.
- `wait(0)` prevents the parent from racing ahead and leaving children unreaped.

### Understanding check

1. Why does `find` call `fstat()` after `open()`?
2. Why compare the last path component rather than the whole path?
3. Why must `args[cmd_argc + 1]` be set to `0` before calling `exec()`?
4. Why is `fork()` needed before `exec()` in `-exec` mode?

## What this lab should teach before moving on

After this lab, you should be comfortable saying:

- A user command is just a RISC-V user program placed in `fs.img`.
- `Makefile` decides which commands are available in xv6.
- `user/user.h` exposes user-level function declarations.
- Existing syscalls are enough for many programs; not every new feature needs kernel changes.
- `fork()` creates a process, while `exec()` replaces the current process image.
- File descriptors are the user-visible handles for files, directories, console, and pipes.

## Draft report direction

When writing the Markdown report for this lab, avoid saying only "I implemented sleep/sixfive/memdump/find." Instead, organize it around the path:

```text
source file
  -> Makefile registration
  -> fs.img
  -> xv6 shell
  -> existing syscall interface
```

The strongest section will be "How I knew which files to change": because all requested behaviors are user commands, the initial search starts in `user/` and `Makefile`; kernel code only becomes relevant if the requested behavior requires a service that no existing syscall provides.
