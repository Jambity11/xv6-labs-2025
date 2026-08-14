#import "../templates/lab-report.typ": part

= Lab0: Environment Setup

对应源码分支：#link("https://github.com/JambitX11/xv6-labs-2025/tree/riscv")[https://github.com/JambitX11/xv6-labs-2025/tree/riscv]

课程实验网站：https://pdos.csail.mit.edu/6.828/2025/

本实验完成 xv6-labs-2025 所需开发环境的配置。整个运行环境由多层组成：Windows 提供宿主系统，WSL 中的 Ubuntu 提供 Linux 编译环境，RISC-V 交叉工具链负责生成目标程序，QEMU 模拟 RISC-V 计算机，最后由 QEMU 启动 xv6。

```text
Windows
  -> WSL 2 与 Ubuntu 24.04
  -> RISC-V GCC、GDB、Make
  -> QEMU 模拟 RISC-V 硬件
  -> xv6 内核与 xv6 shell
```

#part("实验目的")

本实验的目标是建立一套可以编译、运行、调试和测试 xv6 的环境，并确认 Git 分支能够正常与 GitHub 同步。完成环境配置后，后续实验只需要切换到相应源码分支，即可在 WSL 中编译并运行同一套 xv6 工程。

#part("实验步骤")

首先在 Windows 中启用 WSL 2，并安装 Ubuntu 24.04。xv6 的源码虽然保存在 Windows 可以访问的仓库中，但实际编译命令在 Ubuntu 终端内执行，因此可以使用课程提供的 Linux 工具链和 Makefile。

#figure(
  image("../assets/env/wsl.png", width: 85%),
  caption: [配置 WSL 2 与 Ubuntu 24.04],
)

随后安装 Git、Make、GDB、QEMU 和 RISC-V 交叉编译工具链。这里的“交叉编译”表示编译器运行在 x86-64 的 WSL 环境中，但生成的是 RISC-V 指令，生成的程序不能由 Windows 或 WSL 直接执行，需要交给 QEMU 中的 RISC-V 虚拟机运行。

```bash
sudo apt update
sudo apt install git build-essential gdb-multiarch qemu-system-misc \
  gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu
```

安装完成后克隆实验仓库，并使用独立分支保存不同 Lab 的源码。`util`、`syscall`、`pgtbl`、`traps` 等分支保存相应实验实现，`report` 分支只保存 Typst 报告。这样可以在不混入报告文件的情况下比较各实验分支与 `riscv` 基线的代码差异。

最后在源码分支执行 `make qemu`。Makefile 会编译内核和用户程序、生成文件系统镜像，然后启动 QEMU。终端出现 xv6 的 `$` 提示符后，说明处理器模拟、内核启动和用户态 shell 均已正常工作。执行 `make grade` 则可运行课程提供的自动测试。

#part("实验中遇到的问题和解决方法")

最初使用的 WSL 发行版是 Ubuntu 22.04，其软件源提供的 QEMU 版本为 6.2，而 xv6-labs-2025 要求 QEMU 版本不低于 7.2。执行构建命令时，Makefile 的版本检查因此无法通过。

一种处理方法是自行编译新版 QEMU，但这会额外引入构建依赖和维护工作。本实验最终改用 Ubuntu 24.04，其软件源能够直接安装满足要求的 QEMU。重新安装 RISC-V GCC、GDB 和 QEMU 后，`make qemu` 与 `make grade` 均可正常运行。

#part("实验心得")

完成配置后，我明确了 xv6 并不是运行在 WSL 内核中的普通 Linux 程序。WSL 负责提供编译环境，QEMU 负责模拟硬件，xv6 才是运行在该硬件上的目标操作系统。后续在 xv6 shell 中执行的命令，也都是被编译进 `fs.img` 的 xv6 用户程序。
