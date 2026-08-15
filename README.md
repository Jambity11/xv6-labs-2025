# xv6-labs-2025

本仓库为 MIT 6.1810 / xv6-labs-2025 课程实验的实现与实验报告整理，包含 xv6 内核源码修改、各实验测试结果以及实验报告材料。

实验网站：[xv6-labs-2025](https://pdos.csail.mit.edu/6.1810/2025/labs/)

## 项目简介

本项目基于 RISC-V 版本 xv6 操作系统，围绕用户程序、系统调用、页表、trap、copy-on-write、网络、锁、文件系统和 mmap 等主题完成一系列实验。实验目标不是单纯补全代码，而是通过修改一个小型但完整的教学操作系统，理解操作系统中进程、内存、文件系统、设备驱动和并发控制等机制的实际实现方式。

xv6 的代码规模相对真实生产内核小很多，但它保留了操作系统内核中最核心的路径：用户态程序通过系统调用进入内核，内核管理进程、页表、文件、磁盘、设备中断和锁。通过这些实验，可以把课堂中的抽象概念落到具体代码结构中，例如页表项权限、page fault、inode、buffer cache、spinlock、文件描述符和虚拟内存区域等。

## 已完成实验

| Lab | 主题 | 主要内容 | 状态 |
| --- | --- | --- | --- |
| Lab 0 | Environment Setup | xv6 环境配置、RISC-V 工具链、QEMU 运行 | 已完成 |
| Lab 1 | Utilities | `sleep`、`find`、用户态程序编写 | 已完成 |
| Lab 2 | System Calls | 新增系统调用、参数传递、内核/用户态接口 | 已完成 |
| Lab 3 | Page Tables | 用户页表检查、页表打印、superpages | 已完成 |
| Lab 4 | Traps | RISC-V assembly、backtrace、alarm | 已完成 |
| Lab 5 | Copy-on-Write | COW fork、引用计数、写时复制 page fault | 已完成 |
| Lab 6 | Networking | E1000 网卡驱动、UDP 接收 | 已完成 |
| Lab 7 | Locks | per-CPU memory allocator、read-write lock | 已完成 |
| Lab 8 | File System | large files、symbolic links | 已完成 |
| Lab 9 | mmap | memory-mapped files、lazy page fault、munmap | 已完成 |

## 仓库结构

```text
.
├── kernel/              # xv6 内核源码
├── user/                # xv6 用户态程序与测试程序
├── mkfs/                # 文件系统镜像构建工具
├── Makefile             # xv6 构建与测试入口
├── docs/                # 实验报告与截图资源       
├── README               # xv6 原始说明文件
└── README.md            # 本项目说明文件
```

## 环境要求

实验主要在 WSL / Linux 环境中完成，依赖如下工具：

- RISC-V 交叉编译工具链
- QEMU RISC-V 模拟器
- GNU Make
- Python 3

可通过以下命令检查主要工具：

```sh
riscv64-unknown-elf-gcc --version
qemu-system-riscv64 --version
make --version
python3 --version
```

根据本机安装方式不同，RISC-V 工具链命令也可能是 `riscv64-linux-gnu-gcc` 等其他前缀。

## 构建与运行

在仓库根目录下运行：

```sh
make clean
make qemu
```

进入 xv6 shell 后，可以运行对应实验的用户程序或测试程序，例如：

```sh
usertests -q
mmaptest
pgtbltest
kalloctest
nettest
```

退出 QEMU：

```text
Ctrl-a x
```

## 运行测试

xv6 labs 通过 `conf/lab.mk` 指定当前实验，例如：

```make
LAB=mmap
```

运行评分：

```sh
make grade
```

单独运行回归测试：

```sh
make qemu
```

进入 xv6 shell 后运行：

```sh
usertests -q
```

不同实验的完整评分通常需要切换到对应实验分支。

## 实验报告

实验报告与截图资源位于：

```text
docs/reports/
```

其中：

```text
docs/reports/labs/      # 各 Lab 报告正文
docs/reports/assets/    # 测试截图与实验材料
```

报告内容按 Lab 和任务点组织，重点记录实验目标、关键实现路径、调试问题、测试结果以及对 xv6 内核机制的理解。

## 学习与复盘

本仓库不仅保存实验代码，也用于后续复盘 xv6 的实现机制。后续整理重点包括：

- 从测试用例反推每个实验验证的内核行为；
- 梳理系统调用从用户态进入内核的完整路径；
- 理解 page table、trap、COW、mmap 等内存管理机制的联系；
- 对照实验报告补充每个关键修改背后的设计原因；
- 将“能跑通的代码”进一步整理为“能解释清楚的实现”。

## 参考资料

- [MIT 6.1810: Operating System Engineering](https://pdos.csail.mit.edu/6.1810/)
- [xv6 book](https://pdos.csail.mit.edu/6.1810/2025/xv6/book-riscv-rev5.pdf)
- [xv6-labs-2025](https://pdos.csail.mit.edu/6.1810/2025/labs/)
