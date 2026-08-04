#import "../templates/lab-report.typ": part

= Lab3: Page Table

对应源码分支：#link("https://github.com/JambitX11/xv6-labs-2025/tree/pgtbl")[https://github.com/JambitX11/xv6-labs-2025/tree/pgtbl]

本实验研究 RISC-V Sv39 页表。用户程序使用的是虚拟地址，内存条上的实际位置则由物理地址表示。页表位于二者之间，既负责地址翻译，也通过权限位决定某个页面能否被用户读取、写入或执行。

```text
用户程序给出虚拟地址
  -> Sv39 页表逐级查找 PTE
  -> PTE 给出物理页和访问权限
  -> 处理器访问实际物理内存
```

== Inspect a user-process page table (easy)

#part("实验目的")

本任务运行 `pgtbltest`，观察当前用户进程低地址和最高地址附近的页表项，并解释输出中的虚拟地址、页表项、物理地址和权限。目标是先看懂 xv6 已有页表，再进行后续修改。

#part("实验步骤")

在 xv6 shell 中运行 `pgtbltest`。测试程序通过 `pgpte()` 查询前 10 个用户页面以及 `MAXVA` 之前的最后 10 个页面，因此输出同时覆盖普通程序区域和地址空间顶部的特殊映射。

#figure(
  image("../assets/pgtbl/pgtbltest.png", width: 92%),
  caption: [pgtbltest 输出中的用户进程页表项],
)

每行输出可以按以下方式理解：

```text
va    用户程序使用的虚拟地址
pte   页表项的完整 64 位数值
pa    从 pte 中取出的物理页地址
perm  pte 低位保存的权限标志
```

`PTE_V` 表示映射有效，`PTE_R`、`PTE_W` 和 `PTE_X` 分别表示可读、可写和可执行，`PTE_U` 表示用户态可以访问。代码页通常可读、可执行但不可写；数据页通常可读、可写但不可执行。若 `pte` 和 `perm` 都为 0，该虚拟页没有映射，访问时会产生缺页异常。

地址空间顶部的 `TRAPFRAME` 保存用户寄存器，`TRAMPOLINE` 保存用户态与内核态切换时执行的代码。它们出现在进程页表中，但没有 `PTE_U`，所以用户程序不能直接读写这些页面。

本任务最终修改 `answers-pgtbl.txt`，记录各页的逻辑用途和权限解释；`user/pgtbltest.c` 用于生成观察结果。

#part("实验中遇到的问题和解决方法")

分析时容易把 `pte` 直接当成物理地址。实际上一条 PTE 同时包含物理页号和低位标志，需要分别使用 `PTE2PA` 与 `PTE_FLAGS` 提取。另一个误区是认为相邻虚拟页必然对应相邻物理页。虚拟地址可以连续，但物理页由分配器独立选择，因此应逐项查看映射。

#part("实验心得")

页表项同时完成地址翻译和权限检查。用户程序看到的是连续虚拟空间，内核可以把它映射到分散的物理页，并对每一页设置不同权限。地址空间顶部的特殊页也说明，页面出现在用户页表中不等于用户态一定有权访问。

== Speed up system calls (easy)

#part("实验目的")

本任务使用一页用户与内核共享的只读内存加速 `getpid()`。普通 `getpid()` 需要执行 `ecall`、进入内核、查找当前进程再返回；而 pid 在进程运行期间基本不变，可以由内核预先写入共享页，用户函数 `ugetpid()` 直接读取。

```text
普通 getpid():
用户态 -> ecall -> usertrap() -> sys_getpid() -> 返回用户态

ugetpid():
用户态 -> 读取 USYSCALL 页面中的 pid
```

#part("实验步骤")

首先在 `kernel/memlayout.h` 中定义固定虚拟地址 `USYSCALL`，位置安排在 `TRAPFRAME` 下方，并定义只保存 pid 的 `struct usyscall`。固定地址使所有进程都能用同一个地址找到各自的共享页，但不同进程的该地址会映射到不同物理页。

`kernel/proc.h` 在进程结构中记录共享页的内核指针。`kernel/proc.c` 的 `allocproc()` 为新进程分配物理页并写入 pid；`proc_pagetable()` 将该页映射到用户虚拟地址 `USYSCALL`。权限只设置 `PTE_R | PTE_U`：`PTE_U` 允许用户访问，`PTE_R` 允许读取，没有 `PTE_W` 可以防止用户伪造 pid。

进程退出时，`proc_freepagetable()` 删除 `USYSCALL` 映射，`freeproc()` 再释放实际物理页。解除映射和释放物理内存由两个位置分别完成，避免同一页被释放两次。

最后在 `user/ulib.c` 中实现 `ugetpid()`，把固定地址解释为 `struct usyscall *` 并读取 pid。由于它只是普通内存读取，不需要新增系统调用号，也不执行 `ecall`。`user/user.h` 提供用户态声明。

#part("实验中遇到的问题和解决方法")

共享页必须设置 `PTE_U`，否则用户态读取会发生异常；同时不能设置 `PTE_W`，否则用户程序能够修改内核提供的数据。页面清理也需要明确责任：页表销毁函数只解除映射，`freeproc()` 才释放物理页。若两处都要求释放物理页，会产生重复释放。

#part("实验心得")

共享页适合保存由内核维护、用户频繁读取且不需要每次重新计算的数据。页表权限保证用户可以读到 pid，却不能修改它。这个优化减少了特权级切换，但仍保留内核对数据内容和页面生命周期的控制。

== Print a page table (easy)

#part("实验目的")

本任务实现 `vmprint()`，按照 Sv39 的三级结构打印页表。页表原本只是内存中的多层数组，递归打印后可以直接看到哪些 PTE 指向下一级页表，哪些 PTE 已经是最终页面映射。

#part("实验步骤")

Sv39 把虚拟地址分成三级索引，每级索引选择一张页表中的一个 PTE。可以将它理解为三级目录：

```text
level 2 顶层页表
  -> level 1 中间页表
       -> level 0 底层页表
            -> 4KB 物理页
```

有效 PTE 有两种用途。若只设置 `PTE_V` 而没有读、写、执行权限，它保存的是下一级页表地址；若包含 `PTE_R`、`PTE_W` 或 `PTE_X`，它就是叶子 PTE，已经给出最终物理页面。

`kernel/vm.c` 中新增 `vmprint()` 和递归辅助函数。函数从 level 2 开始扫描当前页表的 512 个 PTE，跳过无效项，打印该项对应的虚拟地址前缀、PTE 和物理地址。遇到非叶子项时，把它指向的物理页当作下一张页表继续递归；遇到叶子项时只打印，不再向下。

每深入一级，输出前增加一组 `..`，因此缩进直接反映页表深度。`kernel/defs.h` 增加函数声明，系统调用 `kpgtbl()` 则调用 `vmprint()` 打印指定页表。

#part("实验中遇到的问题和解决方法")

如果把所有有效 PTE 都当成下一级页表，程序会把普通数据页中的字节继续解释为 PTE，导致错误输出或内核异常。因此递归前必须检查读、写、执行位，确认当前项是非叶子项。测试还要求固定的缩进与地址格式，物理地址可以随运行变化，但虚拟地址和层级结构必须一致。

#part("实验心得")

打印结果把三级页表的查找过程显示成一棵树。非叶子 PTE 负责继续查找，叶子 PTE 才完成地址翻译。这个区别也是 superpage 的基础，因为叶子项并不一定只能出现在 level 0。

== Use superpages (moderate)/(hard)

#part("实验目的")

本任务让 xv6 在合适的用户内存区域使用 2MB superpage。普通页为 4KB，映射 2MB 内存需要 512 个普通页和 512 个底层 PTE；superpage 使用一个 level-1 叶子 PTE 就能覆盖同样区域。

```text
普通方式：512 个 4KB 物理页 + 512 个 level-0 叶子 PTE
superpage：1 个 2MB 连续物理块 + 1 个 level-1 叶子 PTE
```

这样可以减少页表项数量，并提高 TLB 对大块连续内存的覆盖范围。代价是分配、复制和释放都必须认识这种更大的页面。

#part("实验步骤")

第一部分修改 `kernel/kalloc.c`。普通 `kalloc()` 继续管理 4KB 页，新增 `superalloc()` 与 `superfree()` 管理 2MB 对齐的连续物理块。初始化时将一部分物理内存放入 superpage 专用空闲链表，并确保这些地址不会同时进入普通页链表。

第二部分修改 `kernel/vm.c` 的映射与地址翻译。新增的 level-1 页表遍历函数在中间层找到目标 PTE，映射函数检查虚拟地址和物理地址是否都按 2MB 对齐，然后直接设置一个带读写权限的 level-1 叶子项。

`uvmalloc()` 负责用户调用 `sbrk()` 后的内存增长。当当前虚拟地址按 2MB 对齐、剩余增长空间至少为 2MB 时，它优先调用 `superalloc()`；首尾不足 2MB 或未对齐的部分仍使用普通 4KB 页。

```text
sbrk() 扩展用户内存
  -> 当前地址是否按 2MB 对齐
  -> 剩余空间是否至少为 2MB
  -> 都满足：分配并映射 superpage
  -> 否则：继续分配普通 4KB 页
```

由于 level-1 现在也可能出现叶子项，原先默认叶子只在 level 0 的代码都需要调整。`walk()` 遇到中间层叶子时应停止下降；`walkaddr()` 计算物理地址时，要为 superpage 保留 21 位页内偏移，而普通页只保留 12 位偏移。

第三部分处理进程复制。`kernel/vm.c` 的 `uvmcopy()` 在 `fork()` 时检查父进程当前映射类型。普通页仍按 4KB 分配和复制；遇到 level-1 superpage 时，子进程分配新的 2MB 物理块，复制整块内容，并建立相同大小的映射。父子进程由此拥有内容相同但相互独立的物理内存。

第四部分处理释放。若要解除完整的 2MB 映射，可以清除 level-1 PTE 并调用 `superfree()`。若只释放其中最后 4KB，不能直接释放整个 superpage。实现通过 `demote_superpage()` 新建一张 level-0 页表，把原来的 2MB 映射改写为 512 个普通 4KB PTE，再按原有逻辑释放目标小页。

```text
部分释放 2MB superpage
  -> 保留原 2MB 物理内容
  -> 建立 512 个 4KB PTE
  -> 用 level-0 页表替换原 level-1 叶子
  -> 只解除要求释放的 4KB 映射
```

`kernel/memlayout.h` 与 `kernel/riscv.h` 补充 superpage 大小、对齐和叶子判断相关定义，`kernel/defs.h` 增加分配及释放函数声明。主要行为集中在 `kernel/kalloc.c` 和 `kernel/vm.c`。

#part("实验中遇到的问题和解决方法")

第一次编译时，`issuperpage()` 在 `walksuper()` 定义之前调用它，编译器产生 implicit declaration 和 conflicting types 错误；`uvmcopy()` 中还保留了未使用的 `pte` 变量。将辅助函数声明移到调用之前，并删除未使用变量后，`kernel/vm.o` 可以正常编译。

随后 `superpg_fork` 报告 `sbrk failed`。该测试一次申请多个 2MB 页面，如果 superpage 空闲链表没有正确初始化，或预留的连续块数量不足，`superalloc()` 会过早返回空。重新划分普通页区域与 superpage 区域，并预留足够的 2MB 对齐块后，内存增长成功。

`superpg_free` 还要求只释放 superpage 尾部的 4KB，同时保留前面内容。直接清除 level-1 PTE 会让整个 2MB 映射消失，因此最终加入降级过程，把大页拆成普通页映射后再部分释放。

#part("实验心得")

Superpage 并不是简单地把常量从 4KB 改为 2MB。叶子 PTE 所在层级发生变化后，物理分配、虚拟地址翻译、`fork()` 复制和内存释放都必须同步调整。部分释放尤其说明，大页提高了映射效率，但处理小粒度操作时需要先恢复为普通页结构。

== 实验结果

完成本 Lab 后，在 `pgtbl` 分支运行：

```text
$ make grade
```

最终 `pgtbltest`、`answers-pgtbl.txt`、`usertests` 和 time 均通过，得分为 41/41。

#figure(
  image("../assets/pgtbl/grade.png", width: 92%),
  caption: [Page Table Lab 的 make grade 测试结果],
)

本实验先读取现有页表，再增加共享只读页和页表打印，最后扩展到 2MB superpage。测试结果表明，页面权限、共享页生命周期、三级页表打印、superpage 映射、`fork()` 复制及部分释放均符合要求。
