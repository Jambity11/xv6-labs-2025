#import "../templates/lab-report.typ": part

= Lab3: Page Table

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/pgtbl")[https://github.com/Jambity11/xv6-labs-2025/tree/pgtbl]

我们知道程序里看到的「地址」和内存条上真实的位置，根本不是一回事。把两者一一对应起来的那张表，就是本实验的主角——页表。

本实验围绕 RISC-V 的 Sv39 页表展开，四个任务按下面的顺序层层递进：先看懂一个已经存在的进程页表长什么样，再给它加一块用户与内核共享的只读页来加速 `getpid()`，然后写一个能打印整棵页表树的函数，最后让 xv6 支持 2MB 的 superpage。概括起来就是：读页表、改页表、打印页表、让叶子页表项出现在新的层级。

#part("前置知识")

要弄明白上面那个「同一地址却互不干扰」的问题，得先知道处理器到底是怎么把程序地址翻译成物理地址的。下面几个概念在四个任务里都会反复出现，这里先把它们讲清楚。

*虚拟地址与物理地址。*CPU 执行的每条读写指令给出的都是虚拟地址（用户态尤其如此），内存条上真实的存储位置则是物理地址，两者之间需要一次翻译，页表就是记录「哪个虚拟页对应哪个物理页」的表。引入这层间接至少有三个好处：隔离——进程 A 和进程 B 的虚拟地址即便相同，也能映射到不同的物理页，互不可见；虚拟地址空间可以连续，物理页却可以散布在内存各处；以及，翻译的同时还能顺带做权限检查（能不能读、写、执行，用户态能不能碰）。

*Sv39 的地址结构。*RISC-V 的 Sv39 方案使用 39 位虚拟地址，切成四段：高位的三个 9 位（共 27 位）是三级页表的索引，最低 12 位是页内偏移（一页 4KB，即 `2^12` 字节）。翻译时，`satp` 寄存器指向根页表（第 2 级），用虚拟地址的最高 9 位在它的 512 个表项里选一个；选中的表项指向下一级（第 1 级）页表，再用中间 9 位选一个；如此降到第 0 级，最后选中的表项给出物理页号，拼上低 12 位偏移就是物理地址。一张页表正好占一页、放 512 个 8 字节表项，这就是「9 位索引、512 项」这个数字的由来。

*页表项 PTE 的组成。*每个 PTE 是 64 位：高 44 位是物理页号（PPN），低 10 位是标志。标志里最关键的是 `PTE_V`（有效）、`PTE_R`/`PTE_W`/`PTE_X`（读/写/执行）、`PTE_U`（用户态可访问）。RISC-V 有个细节值得注意：`PTE_W` 为 1 表示可写，此时 `PTE_R` 一般也必须为 1；当 `PTE_W=0`、`PTE_R=1` 时表示「可读可执行」，代码页就是这么设置的。所以 RISC-V 里没有「只写」或「只执行」的页，这一点和 x86 不同。另一个约定更重要：一个 PTE 如果只有 `PTE_V` 而没有 R/W/X 中的任何一个，它指向的是下一级页表（分支节点）；如果带了 R/W/X，它才是最终映射到物理页的叶子节点。这个约定是后面 `vmprint` 和 superpage 两个任务共同的判断依据。

*TLB 与刷新。*页表翻译每走一步都要读内存，非常慢，所以 CPU 里有个叫 TLB 的缓存，把最近用过的「虚拟页 → 物理页」翻译存起来。改了页表之后必须用 `sfence_vma` 刷掉旧缓存，否则 CPU 可能继续用旧的映射或旧权限。

*去哪查更详细。*上面这些概念的权威出处有两处：《xv6: a simple, Unix-like teaching operating system》第 3 章「Page tables」讲 xv6 具体怎么用页表；《The RISC-V Instruction Set Manual, Volume II: Privileged Architecture》里的「Sv39」一节是硬件行为的权威定义。查资料时这几个关键词很有效：「Sv39 页表结构」「RISC-V PTE flags」「satp register」「xv6 walk 函数」。我写代码时最常翻开的是 `kernel/riscv.h`（PTE 宏和地址拆分宏）和 `kernel/vm.c`（`walk`、`mappages`、`uvmalloc` 这些翻译与映射函数），这两个文件读懂了，页表实验就成了一半。

== Inspect a user-process page table (easy)

第一个任务先不急着改代码，而是回答一个更基本的问题：xv6 里一个真实存在的进程页表，到底长什么样？每一项里装的是什么？与其看手册上的示意图，不如让 xv6 把自己的一张页表原样打印出来看。运行 `pgtbltest`，它会通过 `pgpte()` 把用户地址空间里前 10 个页、以及 `MAXVA` 附近最后 10 个页的页表项打印出来。

#figure(
  image("../assets/pgtbl/pgtbltest.png", width: 92%),
  caption: [pgtbltest 输出的用户进程页表项],
)

输出每一行有四个字段：`va`（虚拟地址）、`pte`（完整的 64 位表项）、`pa`（物理页地址）、`perm`（权限）。这里最容易被误解的一点是：`pte` 不是物理地址，它里面高 44 位才是物理页号，低 10 位是权限，必须分别用 `PTE2PA` 和 `PTE_FLAGS` 两个宏去拆。拆开之后能看到清晰的规律：代码页是 `PTE_R | PTE_X | PTE_U`（可读可执行、用户可访问，但不可写），数据页是 `PTE_R | PTE_W | PTE_U`（可读可写，但不可执行）。

输出里最有意思的是地址空间顶部的两个特殊映射：`TRAMPOLINE` 和 `TRAPFRAME`。它们明明出现在用户进程的页表里，却没有 `PTE_U` 位。我第一次看的时候也困惑：「都在用户页表里了，用户态为什么不能访问？」其实这正是页表权限和「出现在页表中」之间的区别：映射存在只代表内核需要借道这个页表访问这些页，不代表用户态被授权。`TRAMPOLINE` 存的是用户态切到内核态的那段跳板代码，`TRAPFRAME` 存的是进内核时保存的寄存器现场，两者都摘掉了 `PTE_U`，用户程序就碰不到。

这个任务最终的结论一句话：一个 PTE 等于「物理页号 + 权限位」，二者必须分开看。这句话会贯穿后面所有任务——共享页只加 `PTE_U | PTE_R` 不加 `PTE_W`，打印页表靠 R/W/X 位判断叶子，superpage 让叶子出现在第 1 级。

== Speed up system calls (easy)

弄明白页表长什么样之后，第二个任务开始拿它做点实事。先想一个问题：`getpid()` 这种系统调用，pid 在进程存活期间根本不会变，为什么每次都要兴师动众地 `ecall` 进内核跑一趟？有没有办法让用户程序不进内核、直接拿到这个值？xv6 的答案是：在内核和用户之间共享一页内存，内核在创建进程时把 pid 写进去，用户态直接读这一页，一次 `ecall` 都不用。

```text
普通 getpid(): 用户态 -> ecall -> usertrap() -> sys_getpid() -> 返回用户态
ugetpid():     用户态 -> 直接读 USYSCALL 页里的 pid
```

实现上有四个关键点，每个都对应一个「为什么」。

一是固定地址。所有进程都把这块共享页映射到同一个虚拟地址 `USYSCALL`（定义在 `kernel/memlayout.h`）。这样用户代码不用知道物理页在哪，读这个常量地址即可；不同进程的这个地址各自映射到自己的物理页，互不干扰。

二是权限。这个映射只设 `PTE_R | PTE_U`，故意不加 `PTE_W`：加 `PTE_U` 是让用户态能读，不加 `PTE_W` 是防止用户程序改写 pid。页表在这里充当了一个「只读接口」，把「内核维护、用户只读」这条约定硬件化了。这是本任务我最想记住的一点：*权限位不只是防崩溃的，它是在表达一份数据契约。*

三是生命周期要配对。`allocproc()` 分配物理页并写入 pid，`proc_pagetable()` 建立映射；退出时 `proc_freepagetable()` 负责删映射，`freeproc()` 负责释放物理页。为什么要拆成两处？因为「解除映射」和「归还物理内存」是两件事，如果两处都释放，同一页会被释放两次。这种「谁建立、谁拆除」的对应，是 xv6 内存管理里反复出现的纪律。

四是用户态读取。`user/ulib.c` 里的 `ugetpid()` 把 `USYSCALL` 强转成 `struct usyscall *` 再读字段，不产生任何系统调用，所以它不需要在 `syscall.h` 里分配编号——这个函数压根不进内核。

这个任务让我第一次意识到，页表不只是「翻译地址」的表格，它本身就是一个可以拿来设计的工具：共享只读内存、用户态零开销地读内核数据，靠的都是页表权限和映射安排。

#part("代码解读")

这个任务的内核侧改动集中在「地址定义、进程结构、创建、映射、释放」五处，用户侧只加了一个读取函数。先把六段代码集中贴出来，下面再统一逐段解释。

`kernel/memlayout.h` 里的地址定义：

```c
#define TRAMPOLINE (MAXVA - PGSIZE)
#define TRAPFRAME  (TRAMPOLINE - PGSIZE)
#define USYSCALL   (TRAPFRAME - PGSIZE)
```

`kernel/proc.h` 里 `struct proc` 新增的字段：

```c
struct usyscall *usyscall;
```

`kernel/proc.c` 的 `allocproc()` 里，分配共享页并写入 pid：

```c
// Allocate a usyscall page.
if((p->usyscall = (struct usyscall *)kalloc()) == 0){
  freeproc(p);
  release(&p->lock);
  return 0;
}
memset(p->usyscall, 0, PGSIZE);
p->usyscall->pid = p->pid;
```

`kernel/proc.c` 的 `proc_pagetable()` 里，建立只读映射：

```c
// map the usyscall page below the trapframe page.
// user code may read it, but must not write it.
if(mappages(pagetable, USYSCALL, PGSIZE,
            (uint64)(p->usyscall), PTE_R | PTE_U) < 0){
  uvmunmap(pagetable, TRAPFRAME, 1, 0);
  uvmunmap(pagetable, TRAMPOLINE, 1, 0);
  uvmfree(pagetable, 0);
  return 0;
}
```

`kernel/proc.c` 的 `freeproc()` 里，释放共享页：

```c
if(p->usyscall)
  kfree((void*)p->usyscall);
p->usyscall = 0;
```

`user/ulib.c` 里的用户态读取函数：

```c
ugetpid(void)
{
  struct usyscall *u = (struct usyscall *)USYSCALL;
  return u->pid;
}
```

下面逐段解释这些代码在做什么、为什么这么写。

*地址定义。*`USYSCALL` 被安排在地址空间顶部的 `TRAPFRAME` 下方。为什么放这里？用户的 text/data/heap 都从低地址往上长，把这块共享页放到和 `TRAMPOLINE`、`TRAPFRAME` 一样的高地址区，就不会和用户程序自己的内存打架。固定这个地址后，所有进程用同一个常量就能找到各自的共享页。

*进程结构里存指针。*`struct usyscall *usyscall` 保存的是「这个进程的共享页在内核视角下的地址」。注意这是内核地址，用户态的 `ugetpid()` 用的是 `USYSCALL` 这个虚拟地址，两者靠页表映射对应起来。

*创建进程时分配并写入。*`allocproc()` 里 `kalloc()` 分配一页物理内存，`memset` 清零，然后把刚分配的 `p->pid` 写进这一页。注意顺序：`allocproc()` 在前面已经给进程分配了 pid（`p->pid = allocpid()`），这里把 pid 落进共享页。这样内核创建进程的那一刻，共享页里就已经有了正确的 pid。

*建立映射。*`proc_pagetable()` 里把用户虚拟地址 `USYSCALL` 映射到物理页 `p->usyscall`，权限是 `PTE_R | PTE_U`：`PTE_U` 让用户态能访问，`PTE_R` 允许读，而*故意不加 `PTE_W`*。这一行注释写得很清楚——"user code may read it, but must not write it"——页表权限在这里表达的是一份数据契约：pid 由内核维护、用户只能读。如果用户硬要写这个地址，硬件会当场触发写保护异常，因为 PTE 里根本没有写权限。

*释放。*进程退出时 `freeproc()` 只负责 `kfree` 释放物理页。解除映射这件事由 `proc_freepagetable()` 里 `uvmunmap` 完成。为什么要拆成两处？因为「解除映射」和「归还物理内存」是两件事：如果两处都去 `kfree`，这一页会被释放两次，空闲链表就坏了。

*用户态读取。*`ugetpid()` 就两行：把 `USYSCALL` 这个常量地址强转成 `struct usyscall *`，读它的 `pid` 字段。全程没有任何 `ecall`，不产生系统调用。这就是「零开销拿 pid」的全部秘密——它读的只是普通内存，只不过这页内存是内核预先映射好的。

#part("自测与解答")

*问：共享页权限为什么是 `PTE_R | PTE_U` 而不是 `PTE_R | PTE_W | PTE_U`？*

*答：*`PTE_U` 让用户态能访问，`PTE_R` 允许读；不加 `PTE_W` 是为了防止用户程序直接改写 pid。如果加上写权限，恶意或出错的用户代码就能把 pid 改成任意值，破坏内核维护的数据。用页表权限把「内核写、用户只读」这条约定硬件化，是这个任务最核心的设计。

*问：不同进程都用同一个 `USYSCALL` 地址，为什么读到的 pid 互不干扰？*

*答：*虚拟地址相同不代表物理地址相同。每个进程有自己独立的页表，`USYSCALL` 在每个进程页表里映射到各自的物理页——`allocproc()` 给每个进程都 `kalloc()` 了一页，写的是各自的 pid。地址是「假坐标」，页表才是「真对应」。

*问：释放时为什么解除映射（`proc_freepagetable`）和释放物理页（`freeproc`）要分开？*

*答：*解除映射只是把页表项清掉，物理页还在内存里；释放物理页才是把页还给分配器。两者必须成对但各司其职，如果两处都释放，同一页会被 `kfree` 两次，空闲链表会被破坏。这个「谁建立、谁拆除」的对应关系，是 xv6 内存管理里反复出现的纪律。

== Print a page table (easy)

前两个任务里，页表要么是看、要么是加一块映射。现在换一个角度：如果我想把整棵页表的结构完整打印出来，让自己一眼看清虚拟地址是怎么一级一级翻译到物理页的，该怎么做？这看起来只是个打印函数，但里面藏着一个必须先想清楚的问题——怎么区分一个页表项指向的是「下一级页表」，还是「最终物理页」？

答案就是前置知识里说的那个约定：只有 `PTE_V`、没有 R/W/X 的是分支节点；带 R/W/X 的是叶子节点。写成代码就是检查 `(pte & (PTE_R | PTE_W | PTE_X)) == 0`。这个判断一旦漏掉，就会把普通数据页里的字节也当成 PTE 继续往下解析，打印出一堆乱码甚至内核崩溃——因为一个数据页的内容根本不是表项。

打印用递归：从第 2 级开始，扫描当前页表的 512 个表项，跳过 `PTE_V` 为 0 的；对有效项打印「虚拟地址前缀、pte、pa」，如果是分支节点，就把它指向的物理页当作下一级页表递归下去，深度加一、缩进多两个点。所以缩进直接反映层级，打印出来就是一棵树。

```text
level 2 顶层页表
  -> level 1 中间页表
       -> level 0 底层页表
            -> 4KB 物理页
```

这个任务真正的价值是为最后一个任务做铺垫：它逼你把「叶子在哪一级」这件事想清楚。`vmprint` 里写的是「叶子在第 0 级」，而 superpage 要打破的恰恰是这个假设。

#part("代码解读")

先建立两个 C 层面的前提，否则下面的代码会看不懂。第一，`pagetable_t` 在 `kernel/riscv.h` 里定义为 `typedef uint64 *pagetable_t;`，所以**一张页表在 C 里就是 512 个 8 字节整数的数组**，`pagetable[i]` 就是第 `i` 个页表项（PTE）。第二，xv6 内核在 RISC-V 上是直接映射的——内核虚拟地址等于物理地址，所以代码敢写 `(pagetable_t)pa`，把一个物理地址直接当指针用。

`kernel/vm.c` 里的完整实现：

```c
static void
vmprintwalk(pagetable_t pagetable, int level, uint64 va)
{
  for(int i = 0; i < 512; i++){
    pte_t pte = pagetable[i];

    if((pte & PTE_V) == 0)
      continue;

    uint64 childva = va | ((uint64)i << PXSHIFT(level));
    uint64 pa = PTE2PA(pte);

    for(int j = 0; j < 3 - level; j++)
      printf(" ..");

    printf("%p: pte %p pa %p\n", (void*)childva, (void*)pte, (void*)pa);

    if(level > 0 && (pte & (PTE_R | PTE_W | PTE_X)) == 0){
      vmprintwalk((pagetable_t)pa, level - 1, childva);
    }
  }
}

void
vmprint(pagetable_t pagetable)
{
  printf("page table %p\n", pagetable);
  vmprintwalk(pagetable, 2, 0);
}
```

下面逐段解释。

*入口 `vmprint`。*打印表头，然后调用 `vmprintwalk(pagetable, 2, 0)`。`level = 2` 表示从顶层页表开始（Sv39 三级编号 2、1、0，从高到低），`va = 0` 表示虚拟地址从 0 开始拼。这两个参数决定了后面每一层递归的起点。

*循环与跳过无效项。*`for(int i = 0; i < 512; i++)`——为什么是 512？一页 4096 字节，一个 PTE 8 字节，正好 512 项。`if((pte & PTE_V) == 0) continue;` 里 `PTE_V` 是第 0 位（`1L << 0`），这一位为 0 表示这个表项根本没有映射，直接跳过。

*算虚拟地址 `childva`——全函数最精妙的一行。*这一行是 `uint64 childva = va | ((uint64)i << PXSHIFT(level));`。先看 `PXSHIFT(level)`，定义在 `kernel/riscv.h`：`#define PXSHIFT(level) (PGSHIFT + (9 * (level)))`。Sv39 的 39 位虚拟地址切成「3 个 9 位索引 + 12 位页内偏移」：level 2 索引在 bit 30–38（`PXSHIFT(2) = 12 + 18 = 30`），level 1 在 bit 21–29，level 0 在 bit 12–20。而 `i` 正好是 0–511 的 9 位数，`i << PXSHIFT(level)` 就是把「这一层第 `i` 项」的索引左移到它在虚拟地址里该在的位置。`va | ...` 则把上一层已经拼好的地址前缀和这一层的索引合并起来。这样一层层嵌下去，打印出的 `childva` 就是「这个 PTE 负责的那段虚拟地址的起点」，能直接和真实地址对上。

*从 PTE 拆物理地址。*`uint64 pa = PTE2PA(pte);`，对应宏 `#define PTE2PA(pte) (((pte) >> 10) << 12)`。一个 64 位 PTE 的低 10 位是权限标志、高 44 位是物理页号（PPN）。`>> 10` 丢掉低 10 位标志，`<< 12` 把 PPN 左移成按 4KB 对齐的物理地址（一个物理页的地址低 12 位全是 0）。打印时 `pte` 和 `pa` 是分开打的——`pte` 是原始 64 位（含标志），`pa` 是拆出来的纯地址，这正是「pte 不等于物理地址，得拆开看」的代码体现。

*缩进。*`for(int j = 0; j < 3 - level; j++) printf(" ..");`——level 2 打 1 组 `..`，level 1 打 2 组，level 0 打 3 组。越深缩进越多，输出天然是一棵树。

*判断分支还是叶子。*递归条件是 `if(level > 0 && (pte & (PTE_R | PTE_W | PTE_X)) == 0)`，分两部分，各回答一个问题。`(pte & (PTE_R | PTE_W | PTE_X)) == 0` 回答「这是分支还是叶子」：RISC-V 约定带 R/W/X 任一位的 PTE 是叶子（直接映射到最终物理页），只有 `PTE_V`、没有任何 R/W/X 的才是分支（指向下一级页表），所以把三个位合成掩码去 `&`，结果是 0 就说明「没有读写执行权限 → 不是数据页 → 是下一级页表」，才递归进去。漏掉这个判断的后果很严重：会把普通数据页里的字节也当成 PTE 解析，打印出一堆乱码甚至内核崩溃。`level > 0` 回答「还有没有下一级」：第 0 级是最底层，下面没有第 -1 级页表了，这是防御。递归时 `(pagetable_t)pa` 把下一级页表的物理地址当指针（回到开头的直接映射），`level - 1` 降一级，`childva` 作为新的地址前缀传下去。

#part("自测与解答")

*问：`PTE2PA` 为什么是 `>> 10` 再 `<< 12`，而不是直接 `pte & ~0x3FF`？*

*答：*两者对「PPN 落在 bit 10–53」这个前提都成立，结果也都是把低 10 位标志清零。但 `>> 10 << 12` 额外做了一件事：把中间保留位也一起清掉、只把真正的 PPN 对齐到物理地址。如果将来 Sv39 的 PPN 位宽扩展，`>> 10 << 12` 的写法更稳；直接 `& ~0x3FF` 会把保留位原样留在结果里，一旦这些位有值，物理地址就错了。

*问：怎么判断一个 PTE 是「指向下一级页表」还是「指向最终物理页」？*

*答：*看 R/W/X 位。带 R/W/X 任一位的是叶子（最终物理页），只有 `PTE_V`、没有任何 R/W/X 的是分支（下一级页表）。代码里就是 `(pte & (PTE_R | PTE_W | PTE_X)) == 0` 判断分支。

*问：递归条件里的 `level > 0` 是多余的还是必要的？*

*答：*必要的。`level == 0` 时已经是最底层，下面没有下一级页表。虽然正常映射里第 0 级的 PTE 都该是叶子，但万一出现一个无 R/W/X 的第 0 级项，`level > 0` 能拦住它、不递归到 `level = -1`，避免越界。

== Use superpages (moderate)/(hard)

前三个任务里有一个隐含的共同点：翻译的终点（叶子 PTE）永远在第 0 级，一个叶子对应一个 4KB 页。顺着想下去会自然冒出一个问题：为什么叶子非得在第 0 级？能不能让一次翻译覆盖更大的范围，比如让第 1 级就出现叶子、一个表项直接管 2MB？这就是 superpage 要回答的问题。

为什么值得做？映射 2MB 用普通方式要 512 个 4KB 页加上 512 个第 0 级叶子 PTE；用 superpage 只要 1 个第 1 级叶子 PTE 加上 1 块 2MB 连续物理内存。表项少了，TLB 的覆盖范围也大了（一个 TLB 项就能覆盖 2MB）。代价是：分配、翻译、fork 复制、释放，全都要「认得」这种大页。

```text
普通方式：512 个 4KB 物理页 + 512 个 level-0 叶子 PTE
superpage：1 个 2MB 连续物理块 + 1 个 level-1 叶子 PTE
```

我把这个任务拆成四条线来想，每一条都对应一个「原来的假设被打破」的地方。

分配线（`kernel/kalloc.c`）。新增 `superalloc()` 和 `superfree()`，管理 2MB 对齐的连续物理块；初始化时从物理内存里划出一部分给 superpage 专用链表，保证它和 4KB 普通页链表不重叠。

翻译线（`kernel/vm.c`）。`walk()` 原本默认叶子只在第 0 级，现在遇到第 1 级的叶子要停下来，不能再把它当指针往下走；`walkaddr()` 算物理地址时，superpage 要保留 21 位页内偏移（`2MB = 2^21` 字节），普通页只保留 12 位。这个 21 位和 12 位的差别，就是「大页」在地址计算上最核心的体现。

映射线。`uvmalloc()` 在 `sbrk()` 扩内存时，如果当前虚拟地址按 2MB 对齐、剩余空间至少 2MB，就优先走 superpage；首尾不足 2MB 或没对齐的部分，退回普通 4KB 页。所以一个进程的地址空间是「大页管中间、小页管边角」的混合形态。

复制与释放线。`uvmcopy()` 在 fork 时要按映射类型分别处理：普通页按 4KB 复制，superpage 就分配新的 2MB 块、整块复制、建立相同映射。释放时最麻烦的是「只释放大页尾巴上的一个 4KB」：不能直接 free 整个 2MB，否则前面的内容也没了。做法是 `demote_superpage()`——把那个第 1 级叶子「降级」成 512 个第 0 级的 4KB PTE（内容不动），再按原来的小页逻辑释放目标那一页。降级这个动作把「大页」重新翻译回「小页」，让原有释放代码不用大改。

*核心知识点：叶子可以不在第 0 级。*superpage 表面上只是「把常量从 4KB 换成 2MB」，实际上它动摇的是一个更根本的假设：翻译的深度是可变的。一旦叶子可以出现在第 1 级，所有「默认叶子在第 0 级」的代码——`walk`、`walkaddr`、`uvmcopy`、`uvmfree`——都要重新审视。这也是这个任务被标成 hard 的原因：它的改动是分布式的，牵一发动全身。

我在这个任务里踩的坑，基本都来自这种「分布式改动」：`issuperpage()` 在定义之前被调用，编译器报 implicit declaration；`uvmcopy()` 里留了没用到的变量，被 `-Werror` 拦住；`superpg_fork` 报 `sbrk failed`，是因为 superpage 空闲链表没预留够 2MB 对齐的块。这些坑本身没多少「知识含量」，但它们反复提醒我：改内存管理不能只盯着一个函数，要把分配、翻译、复制、释放四条线一起走查一遍。

#part("代码解读")

superpage 的全部代码可以按四条线来读：分配（`kalloc.c`）、翻译与建映射（`vm.c` 的 `walksuper`/`supermappage`/`walkaddr`）、增长（`uvmalloc`）、复制与释放（`uvmcopy`/`demote_superpage`）。先把所有代码集中贴出来，下面再统一逐段解释。

*分配线 `kernel/kalloc.c`。*`kmem` 旁边新增一个管理 2MB 块的 `supermem`：

```c
struct {
  struct spinlock lock;
  struct run *freelist;
} kmem;

struct {
  struct spinlock lock;
  struct run *freelist;
} supermem;
```

`kinit()` 把物理内存切成「普通页区 + superpage 区 + 普通页区」三段：

```c
initlock(&kmem.lock, "kmem");
initlock(&supermem.lock, "supermem");

uint64 super_start = SUPERPGROUNDUP((uint64)end);
uint64 super_end = super_start + NSUPERPAGE * SUPERPGSIZE;

if(super_end > PHYSTOP)
  panic("kinit: not enough memory for superpages");

freerange(end, (void*)super_start);          // 前面这段给普通 4KB 页
for(uint64 p = super_start; p + SUPERPGSIZE <= super_end; p += SUPERPGSIZE)
  superfree((void*)p);                        // 中间这段给 superpage
freerange((void*)super_end, (void*)PHYSTOP);  // 后面这段再给普通 4KB 页
```

*翻译线 `kernel/vm.c`。*「只走两级」的 `walksuper`：

```c
static pte_t *
walksuper(pagetable_t pagetable, uint64 va, int alloc)
{
  if(va >= MAXVA)
    panic("walksuper");

  pte_t *pte = &pagetable[PX(2, va)];
  if(*pte & PTE_V){
    if(PTE_LEAF(*pte))
      return 0;
    pagetable = (pagetable_t)PTE2PA(*pte);
  } else {
    if(!alloc || (pagetable = (pagetable_t)kalloc()) == 0)
      return 0;
    memset(pagetable, 0, PGSIZE);
    *pte = PA2PTE(pagetable) | PTE_V;
  }

  return &pagetable[PX(1, va)];
}
```

判断是否 superpage 的 `issuperpage`：

```c
static int
issuperpage(pagetable_t pagetable, uint64 va)
{
  pte_t *pte = walksuper(pagetable, va, 0);
  return pte && (*pte & PTE_V) && PTE_LEAF(*pte);
}
```

建立 superpage 映射的 `supermappage`：

```c
static int
supermappage(pagetable_t pagetable, uint64 va, uint64 pa, int perm)
{
  if((va % SUPERPGSIZE) != 0)
    panic("supermappage: va not aligned");
  if((pa % SUPERPGSIZE) != 0)
    panic("supermappage: pa not aligned");

  pte_t *pte = walksuper(pagetable, va, 1);
  if(pte == 0)
    return -1;
  if(*pte & PTE_V)
    panic("supermappage: remap");

  *pte = PA2PTE(pa) | perm | PTE_V;
  return 0;
}
```

认得第 1 级叶子的 `walkaddr`：

```c
uint64
walkaddr(pagetable_t pagetable, uint64 va)
{
  if(va >= MAXVA)
    return 0;

  for(int level = 2; level >= 0; level--){
    pte_t *pte = &pagetable[PX(level, va)];

    if((*pte & PTE_V) == 0)
      return 0;

    if(PTE_LEAF(*pte)){
      if((*pte & PTE_U) == 0)
        return 0;

      uint64 pa = PTE2PA(*pte);
      if(level == 1)
        return pa + (va & (SUPERPGSIZE - 1));
      return pa + (va & (PGSIZE - 1));
    }

    pagetable = (pagetable_t)PTE2PA(*pte);
  }

  return 0;
}
```

*映射线 `uvmalloc`。*

```c
for(a = oldsz; a < newsz; a += sz){
  if((a % SUPERPGSIZE) == 0 && a + SUPERPGSIZE <= newsz){
    sz = SUPERPGSIZE;
    mem = superalloc();
    if(mem == 0){
      uvmdealloc(pagetable, a, oldsz);
      return 0;
    }
    memset(mem, 0, SUPERPGSIZE);
    if(supermappage(pagetable, a, (uint64)mem, PTE_R | PTE_U | xperm) != 0){
      superfree(mem);
      uvmdealloc(pagetable, a, oldsz);
      return 0;
    }
  } else {
    sz = PGSIZE;
    mem = kalloc();
    if(mem == 0){
      uvmdealloc(pagetable, a, oldsz);
      return 0;
    }
    memset(mem, 0, PGSIZE);
    if(mappages(pagetable, a, PGSIZE, (uint64)mem, PTE_R | PTE_U | xperm) != 0){
      kfree(mem);
      uvmdealloc(pagetable, a, oldsz);
      return 0;
    }
  }
}
```

*复制线 `uvmcopy`。*

```c
if((i % SUPERPGSIZE) == 0 && issuperpage(old, i)){
  szinc = SUPERPGSIZE;

  if((mem = superalloc()) == 0)
    goto err;

  memmove(mem, (char*)pa, SUPERPGSIZE);

  if(supermappage(new, i, (uint64)mem, flags) != 0){
    superfree(mem);
    goto err;
  }
} else {
  szinc = PGSIZE;

  if((mem = kalloc()) == 0)
    goto err;

  memmove(mem, (char*)pa, PGSIZE);

  if(mappages(new, i, PGSIZE, (uint64)mem, flags) != 0){
    kfree(mem);
    goto err;
  }
}
```

*释放线 `demote_superpage`。*

```c
static int
demote_superpage(pagetable_t pagetable, uint64 va)
{
  pte_t *spte = walksuper(pagetable, va, 0);
  if(spte == 0 || (*spte & PTE_V) == 0 || !PTE_LEAF(*spte))
    return -1;

  uint64 pa = PTE2PA(*spte);
  uint flags = PTE_FLAGS(*spte);

  pagetable_t l0 = (pagetable_t)kalloc();
  if(l0 == 0)
    return -1;
  memset(l0, 0, PGSIZE);

  for(int i = 0; i < 512; i++)
    l0[i] = PA2PTE(pa + i * PGSIZE) | flags;

  *spte = PA2PTE(l0) | PTE_V;
  return 0;
}
```

下面逐段解释。

*分配线。*`supermem` 的结构和 `kmem` 完全一样：一把锁加一条空闲链表，只是块大小从 4KB 变成 2MB。`kinit()` 里 `super_start` 用 `SUPERPGROUNDUP(end)` 向上取整到 2MB 对齐，保证 superpage 区起点对齐；`NSUPERPAGE` 决定预留多少个 2MB 块；`freerange` 把前、后两段交给普通 4KB 链表，中间对齐的一段用 `superfree` 交给 superpage 链表。这样 superpage 区独占中间一块、和普通页不重叠。为什么不能直接 `kalloc` 512 次来凑一个 superpage？因为 superpage 要求物理地址 2MB 对齐且连续 2MB，`kalloc` 每次只给一个 4KB 页，既不保证对齐也不保证连续——所以必须有一个专门的分配器。

*翻译线：`walksuper`。*普通 `walk` 要一直走到第 0 级，而 `walksuper` 在拿到第 1 级页表后就直接返回 `&pagetable[PX(1, va)]`——第 1 级的那个 PTE。注意中间的关键判断：如果第 2 级 PTE 是叶子（`PTE_LEAF(*pte)`），返回 0，意思是「这里已经有一层更粗的映射，不能再往下找第 1 级了」，这是对页表结构的保护。`PTE_LEAF` 宏定义在 `riscv.h`：`#define PTE_LEAF(pte) (((pte) & PTE_R) | ((pte) & PTE_W) | ((pte) & PTE_X))`，非零就说明是叶子。

*`issuperpage` 与 `supermappage`。*`issuperpage` 靠 `walksuper` 拿到第 1 级 PTE，检查它有效且是叶子，是就说明这个 2MB 区域是 superpage 映射。`supermappage` 先检查虚拟地址和物理地址都按 2MB 对齐（大页的前提），再用 `walksuper(pagetable, va, 1)` 拿到第 1 级 PTE（`alloc=1` 表示第 1 级页表不存在就现建），最后 `*pte = PA2PTE(pa) | perm | PTE_V` 把这个 PTE 写成一个**第 1 级叶子**——`perm` 里带 R/W/X，所以它是叶子；它直接指向 2MB 的物理块。普通 4KB 映射的叶子在第 0 级，superpage 的叶子在第 1 级，这就是二者本质的区别。

*翻译的另一半：`walkaddr`。*关键在 `if(level == 1) return pa + (va & (SUPERPGSIZE - 1));`——遇到第 1 级的叶子，页内偏移要保留 21 位（2MB = 2^21），而第 0 级叶子只保留 12 位。这个「21 位还是 12 位」的分支，就是「大页」在地址计算上最核心的体现：叶子在哪一级，偏移的位数就由那一级覆盖的大小决定。

*映射线：`uvmalloc`。*判断条件是 `(a % SUPERPGSIZE) == 0 && a + SUPERPGSIZE <= newsz`——当前地址 2MB 对齐、且剩余空间足够放下一个完整 2MB，两个都满足才走大页。所以一个进程的地址空间是「大页管中间、小页管边角」的混合形态：开头和结尾不满 2MB 的部分用小页，中间整块整块的用大页。

*复制与释放线。*`uvmcopy()` 遇到 superpage 就 `superalloc` 新的 2MB、`memmove` 整块复制、`supermappage` 建立相同映射；普通页仍按 4KB 走。释放时最麻烦的是「只释放大页尾巴上的一个 4KB」：不能直接 free 整个 2MB，否则前面的内容也没了。解法是 `demote_superpage`——先确认第 1 级 PTE 确实是个叶子，取出原 superpage 的物理地址 `pa` 和权限 `flags`，分配一张新的第 0 级页表 `l0`，把 512 个项分别指向 `pa + i * PGSIZE`（即这块 2MB 物理内存里的 512 个 4KB 页），权限沿用原来的 `flags`，最后把第 1 级 PTE 从「叶子」改成「指向 l0 的分支」。注意：**物理内容完全没动**，变的只是页表结构——原来一个第 1 级叶子直接管 2MB，现在换成「第 1 级分支 + 512 个第 0 级叶子」。降级之后，`uvmunmap` 就能用原来的小页逻辑去释放目标那个 4KB 了；`uvmunmap` 里的处理是：释放范围完整覆盖一个 2MB 且对齐，就直接 `superfree` 整块，否则先 `demote_superpage` 再按小页释放。

#part("自测与解答")

*问：为什么 superpage 需要专门的 `superalloc`/`superfree`，而不能 `kalloc` 512 次拼出来？*

*答：*superpage 要求物理地址 2MB 对齐、且连续 2MB。`kalloc` 每次只从 4KB 链表取一页，既不保证 512 个页连续，也不保证起始地址 2MB 对齐。所以必须单独维护一个「2MB 对齐连续块」的空闲链表，`kinit` 里把一块对齐的内存区切好放进去。

*问：`demote_superpage` 明明「内容不动」，为什么就能把大页拆成小页？*

*答：*因为拆的只是页表结构。原来第 1 级叶子直接指向一块 2MB 物理内存；降级后，第 1 级指向一张新的第 0 级页表，这张页表里的 512 个 PTE 分别指向那块 2MB 物理内存里的 512 个 4KB 页（`pa + i * PGSIZE`）。物理内存没挪动，只是多了一层索引，所以「内容不动」也能拆。

*问：`walkaddr` 里 `level == 1` 时保留 21 位偏移、`level == 0` 时保留 12 位，为什么位数不同？*

*答：*页内偏移的位数由「这一级叶子覆盖多大」决定：第 1 级叶子映射 2MB（2 的 21 次方），偏移就是 21 位；第 0 级叶子映射 4KB（2 的 12 次方），偏移就是 12 位。偏移位数必须和映射大小匹配，否则算出的物理地址会错位。

*问：`uvmalloc` 里用 superpage 的条件为什么是「对齐」和「足够大」两个？*

*答：*一是 `a % SUPERPGSIZE == 0`（虚拟地址 2MB 对齐），二是 `a + SUPERPGSIZE <= newsz`（剩余空间足够放下完整 2MB）。两个都要满足才能建立 2MB 映射；末尾那一段不满 2MB 或没对齐，只能退回 4KB 小页。这就是「大页管中间、小页管边角」的由来。

== 实验结果

完成本 Lab 后，在 `pgtbl` 分支运行：

```text
$ make grade
```

最终 `pgtbltest`、`answers-pgtbl.txt`、`usertests` 和 time 均通过，得分 41/41。

#figure(
  image("../assets/pgtbl/grade.png", width: 92%),
  caption: [Page Table Lab 的 make grade 测试结果],
)

四个任务合起来，把页表从「被动翻译地址的表」变成了「可以主动设计的工具」：权限位用来表达只读契约，共享页用来省掉系统调用，三级结构可以被打印、也可以被大页改写层级。测试通过说明页面权限、共享页生命周期、页表打印、superpage 映射、fork 复制与部分释放都符合要求。
