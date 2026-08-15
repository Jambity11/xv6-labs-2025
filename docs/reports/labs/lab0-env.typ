#import "../templates/lab-report.typ": part

= Lab0: Environment Setup

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/riscv")[https://github.com/Jambity11/xv6-labs-2025/tree/riscv]

xv6 是给 RISC-V 指令集写的教学操作系统，而我们手头的电脑是 x86 架构、跑着 Windows。摆在面前的第一个问题很直接：怎么让一个「给别的 CPU 写的操作系统」在我们这台机器上编译、运行、还能调试？

这个问题是所有后续实验的前提——没有一个能随时 `make qemu` 跑起来的环境，后面谈内核、页表、锁都是空话。所以 Lab0 本身不写内核代码，它的全部意义就是搭好这条「从源码到运行」的通道。

初步想法是分层搭积木。Windows 提供最底层的宿主；在它上面装 WSL 2 和一个 Ubuntu 发行版，得到一套完整的 Linux 编译环境；再装 RISC-V 交叉工具链，把 C 源码编译成 RISC-V 指令；最后用 QEMU 模拟一台 RISC-V 机器，让 xv6 跑在这台「软件造出来的机器」上。每一层只干自己该干的事。

#part("前置知识")

*交叉编译。*我们电脑的 CPU 是 x86，编译出来的程序默认只能在 x86 上跑。要得到能在 RISC-V 上跑的程序，得用「交叉编译器」——编译器本身运行在 x86 上，但生成的机器码是 RISC-V 的。所以用 `gcc-riscv64-linux-gnu` 编出来的可执行文件，Windows 或 WSL 自己反而不能直接执行。

*QEMU：用软件模拟硬件。*QEMU 是一个模拟器，能用软件模拟出整套 RISC-V CPU 和外围设备。xv6 就运行在 QEMU 模拟出的这台「虚拟 RISC-V 机器」上。这也是为什么你在 xv6 里敲的命令，实际是发给 QEMU 里那个 xv6 内核，而不是发给 Windows。

*一次 make qemu 做了什么。*xv6 的 Makefile 会先编译内核、编译 `user/` 下的用户程序，再把它们打包进 `fs.img`（一个文件系统镜像），最后启动 QEMU 加载运行。所以你在 xv6 shell 里看到的每个命令，其实都是被编译进 `fs.img` 的用户程序。

配置过程本身不复杂：启用 WSL 2、装 Ubuntu 24.04，然后安装工具链。

#figure(
  image("../assets/env/wsl.png", width: 85%),
  caption: [配置 WSL 2 与 Ubuntu 24.04],
)

```bash
sudo apt update
sudo apt install git build-essential gdb-multiarch qemu-system-misc \
  gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu
```

装好后克隆实验仓库，用独立分支保存不同 Lab 的源码（`util`、`syscall`、`pgtbl` 等），`riscv` 作为基线。这样每次实验只需切换到对应分支，就能编译运行同一套工程，也方便用 `git diff` 对比改动。最后在源码分支执行 `make qemu`，终端出现 xv6 的 `$` 提示符，说明处理器模拟、内核启动、用户态 shell 都正常了。

配置过程里我遇到一个版本问题：最初装的 Ubuntu 22.04 软件源里 QEMU 是 6.2，而 xv6-labs-2025 要求不低于 7.2，Makefile 的版本检查过不去。自己编译新版 QEMU 会引入一堆构建依赖，不如直接换 Ubuntu 24.04——它的软件源能直接装到满足要求的 QEMU。换发行版重装工具链后，`make qemu` 和 `make grade` 就都正常了。

这个实验最重要的是帮我建立了一个清晰的心智模型：xv6 并不是一个运行在 WSL 内核里的普通 Linux 程序。WSL 只是提供编译环境，QEMU 负责模拟硬件，xv6 才是跑在那台模拟硬件上的目标操作系统。这个「层与层」的认知，是后面所有实验的出发点。
