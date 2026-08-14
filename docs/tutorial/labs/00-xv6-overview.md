# xv6 代码地图：初始代码是什么、C 项目如何统筹、做 labs 前要会什么

> 文档定位：这是**动手改代码之前**的前置学习笔记，不是某个 Lab 的实验报告，
> 所以不套用报告的"四小节"格式。它的任务是解决三个问题——
> ① 这个仓库里最初的代码都是些啥；② 这么大的 C 项目是怎么有序组织起来的；
> ③ 我之后改代码（做 labs）前，需要先弄懂哪些知识点。
>
> 读法建议：**别一口气读完**。第一部分和第二部分先读，看懂"开机"这条主线；
> 第三部分（系统调用）是做 lab2 及以后所有 lab 都绕不开的，可以放到做 lab2 前精读；
> 第四、五、六部分当**地图和速查表**，动手时翻回来对照即可。

---

## 第一部分　整体地图：这个仓库里到底有什么

先不钻进任何一行代码，只建立一张"哪里有什么"的全局图。

### 1.1 三个目录 + 两个文件的职责

```text
xv6-labs-2025/
├── kernel/    # 内核本体：特权态运行，管理 CPU、内存、进程、文件、设备
├── user/      # 用户程序：非特权态运行，如 sh、ls、echo，以及测试程序
├── mkfs/      # 工具：mkfs.c，用来把用户程序打包成磁盘镜像 fs.img
├── Makefile   # 总指挥：决定编译哪些文件、怎么链接、怎么跑 QEMU
└── kernel.ld  # 链接脚本：决定内核最终被摆在内存的哪个地址
```

**类比**：把整个 xv6 想成一家"酒店"。

- `kernel/` 是**后台**——前台看不到，但水、电、安保、房态管理都在这里。
- `user/` 是**前台/客房**——客人（用户程序）只在这里活动。
- `mkfs/` 是**开业前的布草**——把前台要用的东西打包好。
- `Makefile` 是**施工总指挥**——负责把后台和前台都盖起来。
- `kernel.ld` 是**规划图纸**——规定每栋楼盖在哪个门牌号。

**关键认知**：`kernel/` 和 `user/` 是**两个世界**。内核代码跑在特权态（supervisor/machine mode），
能碰所有硬件；用户程序跑在非特权态（user mode），想干任何"大事"（读文件、开进程、写屏幕）
都只能通过**系统调用**求内核帮忙。这条"求助通道"就是第三部分要精读的主线。

### 1.2 三个目录里分别有什么

- `kernel/`（33 个文件）里能看到熟悉的 `.c` 源码，但注意后缀不止一种：
  - `.c` —— C 代码主体（`main.c`、`proc.c`、`vm.c`、`fs.c`……）
  - `.h` —— 头文件（`defs.h`、`types.h`、`param.h`、`memlayout.h`……）
  - `.S` —— 汇编（`entry.S`、`swtch.S`、`trampoline.S`、`kernelvec.S`，这些 C 写不了）
  - `.ld` —— 链接脚本（`kernel.ld`）
- `user/`（26 个文件）里是**普通 C 程序**：`sh.c`（shell）、`ls.c`、`echo.c`、`cat.c`……
  以及它们共用的"迷你库" `ulib.c`、`printf.c`、`umalloc.c`，和一句关键文件 `usys.pl`（稍后讲）。
- `mkfs/` 只有一个 `mkfs.c`，负责生成 `fs.img` 磁盘镜像。

**自检问题 1**：`echo` 是你平时敲的命令，它在 xv6 里其实是 `user/echo.c` 编译出的一个**用户程序**，
跑在非特权态。那 `printf` 输出文字时，最终是靠谁来把字符真正写到屏幕的？（答案见第三部分，先带着问题往下读。）

---

## 第二部分　主线一：开机 boot（精读）——`main.c` 是整个内核的目录

理解一个大型代码项目，最高效的入口往往不是挨个读文件，而是**顺着"它启动时干了什么"走一遍**。
xv6 的开机流程非常短，短到可以逐行看完，而它恰好把整个内核的"部门结构"依次点了一遍名。

### 2.1 从哪里开始：`kernel.ld` 决定了第一条指令的地址

链接脚本 `kernel/kernel.ld` 是整个故事的起点，因为它回答了"内核第一行代码应该摆在哪"：

```ld
OUTPUT_ARCH( "riscv" )
ENTRY( _entry )            # 入口符号是 _entry

SECTIONS
{
  . = 0x80000000;          # 从物理地址 0x80000000 开始摆

  .text : {
    kernel/entry.o(_entry) # 第一条指令必须是 entry.S 的 _entry
    *(.text .text.*)       # 其余所有 .c/.S 的代码段跟在后头
    ...
  }
  ...
  PROVIDE(end = .);        # 记录内核的"末尾"地址，供内存分配器用
}
```

两个要点：

1. `ENTRY(_entry)` + `kernel/entry.o(_entry)`：**开机第一条执行的代码是 `kernel/entry.S` 里的 `_entry`**。
2. `. = 0x80000000`：QEMU 把内核加载到物理地址 `0x80000000` 并从这里开始执行（这个约定写在 `kernel/memlayout.h` 第 39 行的 `KERNBASE`）。

### 2.2 `entry.S` → `start.c`：从机器态降到超级态

RISC-V 有三级权限：M（machine，最高）、S（supervisor）、U（user，最低）。
CPU 一上电在 M 态，但 xv6 内核主体跑在 S 态。所以要"降一级"：

1. `kernel/entry.S` 的 `_entry`：只做一件事——给每个 CPU 搭一个初始栈，然后跳到 `start()`。
   （栈空间来自 `start.c` 第 11 行的 `char stack0[4096 * NCPU]`。）
2. `kernel/start.c` 的 `start()`（第 15 行起）：配置一堆 M 态寄存器，最后用一句
   `asm volatile("mret")`（第 48 行）**切换到 S 态并跳到 `main()`**。
   中间那几行（第 18–33 行）在干的事概括成一句话：把中断、异常都"下放"给 S 态处理，让 S 态能访问全部内存。

**这一步你不需要逐行懂**，记住结论就行：`_entry` → `start()` → `main()`，前两段是"开机引桥"，
真正的大戏从 `main()` 开始。

### 2.3 `main.c`：按顺序初始化每个子系统

`kernel/main.c` 的 `main()`（第 10–45 行）是**理解整个内核结构的最佳入口**，因为它按依赖顺序
把每个子系统"启动"了一遍。把它读成一份**部门点名表**：

```c
void main()
{
  if(cpuid() == 0){            // 只有 0 号 CPU 做全局初始化
    consoleinit();             // 1. 控制台（键盘/屏幕输入输出）
    printfinit();              // 2. 打印函数（依赖控制台）
    kinit();                   // 3. 物理内存分配器（之后才能分配页面）
    kvminit();                 // 4. 内核页表（内存虚拟化的地图）
    kvminithart();             // 5. 打开分页（之后"虚拟地址"才生效）
    procinit();                // 6. 进程表（登记进程的地方）
    trapinit();                // 7. 陷阱/中断的入口登记
    trapinithart();            // 8. 安装内核态的中断处理入口
    plicinit();                // 9. 中断控制器（外设中断的总闸）
    plicinithart();            // 10. 让本 CPU 接收外设中断
    binit();                   // 11. 磁盘块缓存（buffer cache）
    iinit();                   // 12. inode 表（文件的"户口本"）
    fileinit();                // 13. 文件表（每个进程打开的文件）
    virtio_disk_init();        // 14. 硬盘驱动（真能读写磁盘了）
    userinit();                // 15. 创建第一个用户进程
    started = 1;               // 通知其他 CPU：都就绪了
  } else { ... }               // 其他 CPU 等 0 号就绪后再补几个 per-CPU 初始化

  scheduler();                 // 16. 调度器：从此永远在进程间来回切换
}
```

**把它和目录对应起来，就是你以后改代码的导航**：

| 序号 | main.c 里的调用 | 负责什么 | 定义在哪个文件 | 你会在哪个 lab 碰到 |
| --- | --- | --- | --- | --- |
| 1–2 | `consoleinit` / `printfinit` | 终端、打印 | `console.c` / `printf.c` | （工具，各 lab 都会用） |
| 3 | `kinit` | 物理内存分配 | `kalloc.c` | lab7（per-CPU 分配器） |
| 4–5 | `kvminit` / `kvminithart` | 内核页表、开分页 | `vm.c` | lab3、lab5（COW）、lab9（mmap） |
| 6 | `procinit` | 进程表 | `proc.c` | lab2、lab5、lab7 |
| 7–8 | `trapinit` / `trapinithart` | 中断/异常入口 | `trap.c` + `trampoline.S` | lab4、lab6、lab9 |
| 9–10 | `plicinit` / `plicinithart` | 中断控制器 | `plic.c` | lab6（网络）、lab4 |
| 11 | `binit` | 磁盘块缓存 | `bio.c` | lab8（文件系统） |
| 12 | `iinit` | inode 表 | `fs.c` | lab8 |
| 13 | `fileinit` | 文件表 | `file.c` | lab8 |
| 14 | `virtio_disk_init` | 硬盘驱动 | `virtio_disk.c` | lab8 |
| 15 | `userinit` | 第一个进程 | `proc.c` | lab2、lab5 |
| 16 | `scheduler` | 进程调度 | `proc.c` | lab7 |

> 这就是"有序组织"的第一层含义：**启动顺序 = 依赖顺序**。分配器（3）必须先于页表（4）先于进程（6），
> 进程（6）必须先于磁盘（11–14）——因为第一个进程 `userinit` 要从磁盘读程序进来跑。
> 顺序一乱，系统就会在"要用某个东西时发现它还没初始化"。

### 2.4 为什么看懂 `main.c` 就等于拿到了整个内核的目录

因为 `main()` 的每一个 `xxxinit()` 都是一扇门：想知道"文件系统怎么工作"，
就顺着 `iinit()` 进 `fs.c`；想知道"进程怎么创建"，就顺着 `procinit`/`userinit` 进 `proc.c`。
**以后你接到一个 lab 任务，第一步永远是：先判断它属于哪个部门，再从 `main.c` 找到那扇门走进去。**

**自检问题 2**：`userinit()` 在 `main.c` 第 31 行被调用，但它具体实现在 `proc.c`。C 编译器怎么知道
`main.c` 里可以调用一个定义在别处的函数？（答案在第四部分"defs.h 是目录页"。）

---

## 第三部分　主线二：一次系统调用（精读）——labs 的命脉

用户程序跑在非特权态，干不了大事。那 `echo hello` 想打印、`ls` 想读目录，怎么办？
答案就是**系统调用**：用户程序举手，内核代为办事。这条"求助通道"是 lab2 的核心，
也是 lab4（trap）、lab5（COW）、lab9（mmap）反复要走的路。精读它，等于握住整个内核的主动脉。

### 3.1 用户态那半边：`user.h` → `usys.pl` → `ecall`

以 `write` 为例。用户在程序里写 `write(1, "hi", 2)`，但它**不是**一个普通函数调用，而是一段跳板：

1. **声明**：`user/user.h` 第 10 行 `int write(int, const void*, int);` —— 告诉用户程序"有 write 这么个东西可用"。
2. **生成跳板**：`user/usys.pl` 是一个 Perl 脚本，`Makefile` 第 104–105 行用它在编译时**自动生成** `user/usys.S`。
   脚本的 `entry("write")`（第 29 行）会展开成三段汇编（见 `usys.pl` 第 19–21 行）：
   ```asm
   write:
     li a7, SYS_write   # 把系统调用编号放进寄存器 a7
     ecall              # 主动触发一次 trap，落入内核
     ret
   ```
   这里 `SYS_write` 的值 16，来自 `kernel/syscall.h` 第 17 行。
3. **触发**：`ecall` 是一条 RISC-V 指令，作用就是"从用户态硬切换到内核态"。

**为什么要这么绕？** 因为用户态和内核态之间**不能直接函数调用**——两者权限不同、地址空间不同。
所以约定：`a7` 放"要办哪件事的编号"，`a0~a5` 放参数，然后 `ecall` 一键切进内核。

### 3.2 硬件与 trampoline：进入内核的"空中换轨"

`ecall` 之后，CPU 跳到内核提前装好的入口 `uservec`（在 `kernel/trampoline.S` 第 21 行）。
它做的事可以概括成一句话：**在用户页表和内核页表之间"空中换轨"，同时把用户现场保存下来**。

- `trampoline.S` 第 37–73 行：把用户的所有寄存器（ra、sp、a0~a7、s0~s11……）存进一块叫
  **trapframe** 的内存（它的布局见 `kernel/proc.h` 第 43–80 行的 `struct trapframe`，每个寄存器对应一个固定偏移）。
- 第 75–98 行：装上内核栈、内核页表，然后 `jalr t0` 跳进 `usertrap()`。
- 为什么叫 trampoline（蹦床）：这段代码被映射在**用户和内核同一个虚拟地址** `TRAMPOLINE`
  （`kernel/memlayout.h` 第 44 行），这样切换页表时它自己不会"失联"。

**类比**：trampoline 是火车在两条铁轨（用户页表 / 内核页表）之间换轨的**转辙器**——车在换轨的瞬间，
必须保证轮子始终压着铁轨。

### 3.3 内核那半边：`usertrap` → `syscall` 分发表

进入内核后，`kernel/trap.c` 的 `usertrap()`（第 37 行起）接手：

1. **识别是系统调用**：第 54 行 `if(r_scause() == 8)` —— 读 `scause` 寄存器判断 trap 原因，`8` 就代表"来自用户态的 ecall"。
2. **准备返回值地址**：第 62 行 `p->trapframe->epc += 4` —— 让用户返回时跳过这条 `ecall`，从下一条指令继续。
3. **分发**：第 68 行调用 `syscall()`，跳到 `kernel/syscall.c`。
4. `syscall()`（`syscall.c` 第 131 行起）读 `p->trapframe->a7`（第 137 行）拿到编号，
   然后查一张**函数指针表**（第 107–129 行的 `syscalls[]`），按编号调用对应的 `sys_xxx()`，把返回值写回 `a0`：

  这个方括号是 C 的函数指针数组语法，指定初始化
  

   ```c
   static uint64 (*syscalls[])(void) = {
     [SYS_fork]    sys_fork,
     [SYS_exit]    sys_exit,
     ...
     [SYS_write]   sys_write,   // 编号 16 → 调用 sys_write()
     ...
   };

   num = p->trapframe->a7;                       // 取编号
   p->trapframe->a0 = syscalls[num]();           // 查表并调用
   ```

5. 真正的实现 `sys_write` 在 `kernel/sysfile.c`（文件类系统调用都在这），进程类在 `kernel/sysproc.c`。
   注意：`sys_write` 是**内核侧**的实现，和用户侧的 `write` 跳板是两回事——中间隔着分发表解耦。

### 3.4 返回用户态

办完事，`usertrap()` 调用 `prepare_return()`（`trap.c` 第 99 行起）把返回现场准备好，最终回到
`trampoline.S` 的 `userret`（第 100 行），恢复寄存器、切回用户页表，`sret`（第 149 行）跳回用户程序。

### 3.5 一张图串起来

```text
用户程序: write(1,"hi",2)
   │
   ▼
user/usys.S（由 usys.pl 生成）:  li a7, SYS_write ; ecall   ← 用户态
═══════════════════════════════════════════════════════   ← ecall 跨越权限
   ▼                                                        （内核态）
trampoline.S uservec: 保存寄存器到 trapframe → 换内核页表 → 跳 usertrap
   ▼
trap.c usertrap():  scause==8 → epc+=4 → syscall()
   ▼
syscall.c syscall():  num = a7 → syscalls[num]()  ← 函数指针分发表
   ▼
sysfile.c sys_write() / sysproc.c sys_fork() …      ← 真正的实现
   ▼
（原路返回）usertrap → prepare_return → trampoline.S userret → sret → 用户程序
```

**自检问题 3**：`usys.pl` 生成的跳板只做 `li a7, SYS_write; ecall; ret` 三件事，它**没有**真正实现 write。
那真正的实现藏在哪？两段代码是靠什么"对上号"的？（提示：`syscall.h` 的编号 + `syscall.c` 的表。）

**自检问题 4**：假如 lab2 让你新增一个系统调用 `trace`，根据这条主线，你猜需要动哪几个文件？
（先自己列，再去对照第六部分的"加系统调用 5 步"，看漏了哪个。）

---

## 第四部分　C 大项目是怎么"统筹"的（你最好奇的部分）

你问：这么大的项目，C 语言是怎么做到有序组织、把各部件统筹好的？
答案不是某个"魔法"，而是**几个朴素的工程技巧叠加**。xv6 把这几个技巧用得极其干净，特别适合学。

### 4.1 技巧一：`defs.h` 是"目录页"（接口总表）

C 有个麻烦：函数必须**先声明后使用**。如果 `main.c` 要调用 `proc.c` 里的 `userinit()`，
要么在 `main.c` 里手写声明，要么……把**所有跨文件的函数声明集中到一个头文件**里。
xv6 选了后者，这个文件就是 `kernel/defs.h`。

看 `defs.h` 的结构：开头先声明几个**结构体**（第 1–10 行，`struct buf;` 等，这叫"前向声明"，
告诉编译器"有这个名字，但长啥样先别管"），然后用 `// bio.c`、`// console.c`、`// proc.c`……
这样的注释，**按源文件分组**列出所有对外函数。例如：

```c
// proc.c
int             cpuid(void);
void            userinit(void);
struct proc*    myproc();
...
// vm.c
void            kvminit(void);
pte_t *         walk(pagetable_t, uint64, int);
...
```

**效果**：任何一个 `.c` 文件，只要 `#include "defs.h"`，就能调用**整个内核所有模块**提供的函数。
`defs.h` 就是内核的"目录页"——想知道内核有哪些能力，翻这一页就全看见了。

**类比**：defs.h 像图书馆的**总书目卡片**。每本书（每个 .c）的具体内容分散在不同书架，
但所有书的名字都在一张卡片上登记，找书先查卡片。

### 4.2 技巧二：头文件各司其职（分工明确）

xv6 没把东西全塞进一个头文件，而是分了几个职责清晰的：

| 头文件 | 只管什么 | 典型内容 |
| --- | --- | --- |
| `types.h` | 类型定义 | `uint`、`uint64`、`pde_t`（第 1–10 行） |
| `param.h` | 可调参数/上限 | `NPROC 64`、`NOFILE 16`、`FSSIZE 2000`（第 1–14 行） |
| `memlayout.h` | 地址布局 | `KERNBASE`、`TRAMPOLINE`、`UART0` 等地址常量（第 21–59 行） |
| `riscv.h` | 硬件寄存器操作 | `r_scause()`、`w_satp()` 等内联汇编宏 |
| `defs.h` | 跨文件函数接口 | 所有模块的函数声明 |
| `syscall.h` | 系统调用编号 | `SYS_fork 1` … `SYS_close 21` |
| `proc.h` / `fs.h` / `file.h` 等 | 各自的**结构体**定义 | `struct proc`、`struct inode`、`struct file` |

**经验法则**（通用工程实践）：`.h` 放"给别人看的接口和结构定义"，`.c` 放"内部实现"。
一个模块 = 一个 `.h`（声明）+ 一个 `.c`（实现），别人只用 include 你的 `.h`，看不到也改不了你的内部。

### 4.3 技巧三：`Makefile` 是总指挥

`Makefile` 统筹了"编译哪些、按什么顺序、最后怎么拼"三件事：

- **编译哪些**：第 4–31 行的 `OBJS` 列表逐个点名内核要编译的 `.o`；第 125–144 行的 `UPROGS`
  点名要打包进磁盘镜像的用户程序。
- **怎么链接内核**：第 86–89 行，用 `ld -T kernel/kernel.ld` 把 `OBJS` 按 `kernel.ld` 的图纸拼成一个 `kernel/kernel` 可执行文件。
- **怎么产出磁盘镜像**：第 146–147 行，`mkfs/mkfs fs.img README $(UPROGS)` 把用户程序打进 `fs.img`。
- **怎么跑**：第 169–175 行的 `QEMUOPTS` 定义 QEMU 的参数，`make qemu` 就把内核 + 磁盘镜像一起交给 QEMU。

**你只需要记住一条命令链路**：`make qemu` = 编译内核 + 编译用户程序 + 做磁盘镜像 + 启动 QEMU。

### 4.4 技巧四：链接脚本决定"谁住哪个地址"

`kernel.ld`（第四部分已见）本质是一张**内存平面图**：把 `.text`（代码）、`.rodata`（只读常量）、
`.data`（已初始化全局变量）、`.bss`（未初始化全局变量）按顺序排布，并强制第一条指令在 `0x80000000`。
它还在第 44 行 `PROVIDE(end = .)` 标记内核末尾——`kalloc.c` 就从 `end` 开始往后分配空闲内存。
**这回答了"为什么内核知道自己从哪开始、空闲内存从哪开始"**：都是链接脚本在编译时定死的。

### 4.5 技巧五：不依赖 C 标准库（freestanding 环境）

你平时写的 C 程序依赖 `stdio.h`、`malloc`、`printf`，那是"宿主"环境提供的。
但**内核是第一个跑起来的程序，没有操作系统在它下面**，所以 `Makefile` 第 65–72 行用了一堆
`-ffreestanding -nostdlib -fno-builtin-xxx` 关掉标准库和编译器内置函数，改由 xv6 **自带**一套迷你库：
`kernel/string.c`（memset/memmove/strlen……）、`kernel/printf.c`（自己的 printf）、`kernel/kalloc.c`（自己的 malloc，即 `kalloc`）。
同理，`user/` 也有 `ulib.c`、`umalloc.c`、`printf.c` 给用户程序用。
**这解释了为什么代码里到处都是"手写基础函数"**——不是炫技，是别无选择。

### 4.6 技巧六："注册表"模式解耦（最重要的思想）

第三部分那个 `syscalls[]` 函数指针表，是 xv6 里最漂亮的设计之一：

```c
static uint64 (*syscalls[])(void) = {
  [SYS_write]   sys_write,
  ...
};
```

- **编号**（`syscall.h`）和**实现**（`sysfile.c`/`sysproc.c`）被这张表隔开，互不知道对方。
- 加一个系统调用 = 在 `syscall.h` 加个编号 + 在表里加一行 + 写个 `sys_xxx()`，**不用改动 `syscall()` 主函数本身**。
- 用户侧的 `usys.pl` 也只认编号，不认实现。

这叫"注册表 / 分发表"模式：**把"不变的框架"和"会变的功能"用一张表隔开**。以后你在 lab 里会反复遇到
类似模式（设备驱动分派、中断处理、文件类型操作），一看就懂，因为它们都是"查表调函数"。

### 4.7 小结：这些技巧拼起来的效果

xv6 用 7 个朴素技巧，把一万多行 C 组织得井井有条：**接口集中**（defs.h）、**职责分层**（头文件分工）、
**构建自动化**（Makefile）、**地址规划**（kernel.ld）、**自给自足**（freestanding + 迷你库）、
**框架与功能解耦**（注册表模式）。它们都不是 xv6 独有的，而是**所有大中型 C 项目通用的组织方法**。
你学的不只是 xv6，而是一套"怎么用 C 写大项目"的方法论。

---

## 第五部分　做 labs 前要会的前置知识点（对照清单）

按"通用基础 + 各 lab 对照"来列。**通用基础是拦路虎，先补它**；各 lab 的知识点等动手前再针对性补。

### 5.1 通用基础（不补这些，后面处处卡壳）

- **C 语言硬功夫**：指针、结构体、**函数指针**（看懂 `syscalls[]` 表的前提）、数组、`typedef`、`static`、`extern`。
  这些贯穿全部 lab。
- **头文件与多文件编译**：`#include` 的两种写法（`""` vs `<>`）、为什么分 `.h`/`.c`、`Makefile` 大致在干嘛。
- **RISC-V 汇编"能看懂就行"**：寄存器 `a0~a7`（参数/返回值）、`sp`、`ecall`/`sret` 这两条指令、`csr` 寄存器的概念。
  不需要会写，但 lab4 会直接考汇编阅读。
- **调试基本功**：会看编译报错、会用 `make qemu-gdb` 打断点、`kernel.asm` 是什么（`Makefile` 第 88 行生成的汇编对照）。
- **工具链**：会跑 `make qemu`、知道 `Ctrl-a x` 退出、知道 `make grade` 评分。

### 5.2 各 lab 对照表

| Lab | 主题 | 前置知识点 | 会改动的主要文件 |
| --- | --- | --- | --- |
| lab1 Utilities | 用户程序 | 进程 fork/exec、管道 `|`、C 字符串处理 | `user/` 下新建程序 + `Makefile` 的 `UPROGS` |
| lab2 System Calls | 新增系统调用 | 第三部分整条主线 + `struct proc` + copyin/copyout | `syscall.h`、`syscall.c`、`sysproc.c`、`usys.pl`、`user.h`、`defs.h` |
| lab3 Page Tables | 页表 | 页表三级结构、`walk()`、`vm.c`、`memlayout.h`、`vmprint` | `vm.c`、`proc.c`、`defs.h` |
| lab4 Traps | 中断/返回 | `trampoline.S`、`trapframe` 布局、栈帧（backtrace）、定时器 | `trap.c`、`proc.c`、`riscv.h` |
| lab5 Copy-on-Write | COW fork | `uvmcopy`、页表项权限位、引用计数、缺页异常 | `vm.c`、`kalloc.c`、`trap.c`、`riscv.h` |
| lab6 Networking | 网卡驱动 | 内存映射 IO、E1000 寄存器、`mbuf` 队列、中断 | 新增 `e1000.c`、`net.c`、`kernel.ld` 内存映射 |
| lab7 Locks | 并发 | `spinlock`、`acquire/release`、per-CPU、`push_off/pop_off` | `kalloc.c`、`bio.c`、`spinlock.h` |
| lab8 File System | 文件系统 | `inode`、`dinode`、`bmap`、目录项、路径解析 `namei` | `fs.c`、`fs.h`、`file.c`、`sysfile.c`、`mkfs.c` |
| lab9 mmap | 内存映射文件 | 懒分配缺页、`VMA` 概念、`lab5` 的缺页处理经验 | `sysfile.c`、`proc.c`、`trap.c`、`vm.c` |

> 用法：**别提前背整张表**。接到某个 lab 时，回来看它那一行，缺什么补什么。

---

## 第六部分　改代码的通用套路（速查）

### 6.1 新增一个系统调用：5 步（以 lab2 为例）

1. `kernel/syscall.h`：加编号 `#define SYS_trace 22`。
2. `kernel/syscall.c`：加 `extern uint64 sys_trace(void);`，并在 `syscalls[]` 表里加 `[SYS_trace] sys_trace`。
3. 实现 `sys_trace`：放 `sysproc.c`（进程相关）或 `sysfile.c`（文件相关）。
4. `user/usys.pl`：加 `entry("trace");`（重新 make 时自动生成跳板）。
5. `user/user.h`：加 `int trace(int);` 给用户程序用。
   （另有全局接口变动时，同步 `kernel/defs.h`。）

**检验你的理解**：这 5 步恰好是第三部分主线的"顺藤摸瓜"——编号（syscall.h）→ 分发表（syscall.c）→
实现（sysproc/sysfile）→ 用户跳板（usys.pl）→ 用户声明（user.h）。少了任何一环，链路就断。

### 6.2 定位陌生子系统的三步法

接到 lab 任务后，不要漫无目的地读文件，按这个顺序：

1. **先归部门**：这个任务属于进程/内存/文件/设备/并发中的哪一类？对应 `main.c` 里哪个 `init`？
2. **看目录页**：翻 `defs.h` 找到该模块对外提供了哪些函数，锁定相关函数名。
3. **进实现**：grep 函数名进对应 `.c`，从那个函数开始读。

例如 lab3 要看页表：`main.c` → `kvminit`（vm.c）→ `defs.h` 里 `// vm.c` 一栏 → `walk`、`mappages`、`uvmcopy` → 读 `vm.c`。

---

## 自检问题（确认你真的懂了）

1. `echo` 打印文字，最终靠谁把字符真正写到屏幕？（提示：`sys_write` → `console.c`/`uart.c`）
2. `main.c` 能调用 `proc.c` 的 `userinit()`，靠什么机制？
3. `usys.pl` 的跳板（`li a7; ecall; ret`）和 `sysfile.c` 的 `sys_write` 靠什么对上号？
4. 新增系统调用 `trace` 要动哪几个文件？漏了会怎样？
5. `kernel.ld` 的 `PROVIDE(end = .)` 给谁用？为什么内核知道空闲内存从哪开始？
6. 为什么要用 `-ffreestanding -nostdlib`？`kalloc` 和标准库 `malloc` 是什么关系？
7. 一句话说清 trampoline 为什么必须映射在用户和内核**同一个地址**。

（答案都可以从本文正文里找到；答不上来的，回到对应小节重读，别跳过。）

---

## 下一步建议

- **现在**：只做两件事——① 跑一次 `make qemu`，在 shell 里敲 `ls`、`echo hi`，感受用户程序的世界；
  ② 打开 `kernel/main.c`，对着 2.3 那张表把每个 `init` 点进去瞄一眼，建立"部门地图"。
- **做 lab2 前**：精读第三部分，然后照 6.1 亲手加一个 `trace`，跑通一次完整链路。
- **做 lab3 前**：回来看 5.2 表里 lab3 那一行，补页表知识。
- 每做完一个 lab，回头看本文第六部分，把"套路"和刚做的 lab 对应上——套路用多了，就内化成你自己的了。
