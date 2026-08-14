# Lab3: Page Table

- 源码分支：`pgtbl`
- 基线分支：`riscv`
- 仓库：<https://github.com/JambitX11/xv6-labs-2025/tree/pgtbl>

> 说明：本文是骨架。带 `> ✍️` 的是写给自己看的提示，写正文时删掉即可。
> 每一小节不要照抄代码，而是用自己的话回答提示里的问题。

## 实验概述

> ✍️ 用 3~5 句话讲：这个 Lab 整体在学什么？四个任务是什么关系（从"读页表"到"改页表"再到"支持大页"）？
> 关键词：Sv39 三级页表、PTE = 物理页号 + 权限位、虚拟地址到物理地址的翻译。

---

## Inspect a user-process page table (easy)

### 实验目的

> ✍️ 这个任务不写代码，那它到底要你学会什么？（提示：学会"读"一条 PTE，把它拆成 pa 和 perm。）

### 实验步骤

> ✍️ 运行 `pgtbltest`，贴 `../assets/pgtbl/pgtbltest.png` 截图，然后讲清楚：
> 1. 输出里每一列 `va / pte / pa / perm` 分别是什么？
> 2. 为什么 `perm 0x5b` 的代码页"可读可执行但不可写"？`0x5b` 对应哪些位？
> 3. 顶部 `TRAPFRAME`(perm 0xc7) 和 `TRAMPOLINE`(perm 0x4b) 明明在页表里，为什么没有 `PTE_U`？
> 4. `pte=0, perm=0` 的行代表什么？用户访问它会怎样？

### 实验中遇到的问题和解决方法

> ✍️ 比如：一开始是不是把 `pte` 直接当成了物理地址？怎么纠正的？

### 实验心得

> ✍️ 一句话留下印象最深的理解（提示：PTE 是"地址 + 权限"的混合体，不是纯地址）。

---

## Speed up system calls (easy)

### 实验目的

> ✍️ 普通 `getpid()` 为什么慢？"共享只读页"的优化思路是什么？（提示：省掉一次 ecall。）

### 实验步骤

> ✍️ 按"生命周期四步"讲清楚，每步对应哪个函数、哪行代码：
> 1. 分配物理页 + 写 pid（`allocproc`，`kalloc`）
> 2. 建映射（`proc_pagetable`，`mappages(..., PTE_R | PTE_U)`）
> 3. 解映射（`proc_freepagetable`，`uvmunmap(..., 0)`）
> 4. 释放物理页（`freeproc`，`kfree`）
>
> 必须回答：
> - 为什么权限是 `PTE_R | PTE_U`，而不能有 `PTE_W`？
> - 为什么解映射和释放要分成两步、`do_free` 为什么传 0？
> - `ugetpid()` 为什么不需要新增系统调用号？
> - 不同进程用同一个 `USYSCALL` 地址，为什么能读到各自的 pid？

### 实验中遇到的问题和解决方法

> ✍️ 如果一开始漏了 `PTE_U` 会怎样？如果 `mappages` 失败，清理顺序要注意什么？

### 实验心得

> ✍️ 一句话（提示："共享靠映射，只读靠权限位"，页面生命周期由内核控制）。

---

## Print a page table (easy)

### 实验目的

> ✍️ 为什么要把页表打印成树？（提示：让三级查找过程"可见"。）

### 实验步骤

> ✍️ 讲清楚 `vmprint` 的递归逻辑：
> 1. 如何用 `PXSHIFT(level)` 拼出每一行的虚拟地址前缀？
> 2. 怎样判断一个 PTE 是"叶子"还是"指向下一级页表"？（提示：看 R/W/X 位）
> 3. 缩进 `" .."` 的个数怎么对应层级？
> 4. 贴一张 `print_kpgtbl` 的输出，指着一行讲它代表什么。

### 实验中遇到的问题和解决方法

> ✍️ 比如：如果把所有有效 PTE 都递归下去，会发生什么？（把数据页当页表解释）

### 实验心得

> ✍️ 一句话（提示：叶子 PTE 才完成地址翻译，非叶子 PTE 负责继续往下找——这是后面 superpage 的基础）。

---

## Use superpages (moderate/hard)

### 实验目的

> ✍️ 普通页 4KB，映射 2MB 需要 512 个 PTE；superpage 怎么用 1 个 PTE 做到？为什么能省页表、提升 TLB 覆盖？

### 实验步骤

> ✍️ 分四块讲，每块说明"为什么叶子可能出现在 level 1"这个变化逼着代码怎么改：
> 1. **分配器**（`kalloc.c`）：`superalloc`/`superfree` 为什么要有独立空闲链表？为什么 2MB 块必须 2MB 对齐？`kinit` 里怎么切分内存？
> 2. **映射与翻译**（`vm.c`）：`walksuper`/`supermappage` 干什么；`walkaddr` 为什么普通页偏移 12 位、superpage 偏移 21 位；`uvmalloc` 什么条件下才用 superpage。
> 3. **fork 复制**（`uvmcopy`）：遇到 superpage 时为什么不能按 4KB 复制？
> 4. **释放与 demote**（`uvmunmap`/`demote_superpage`）：完整释放和部分释放分别怎么处理？为什么"只释放最后 4KB"必须先 demote？

### 实验中遇到的问题和解决方法

> ✍️ 你真实踩过的坑，比如：`issuperpage` 在 `walksuper` 定义前调用导致的 implicit declaration；
> superpage 空闲链表没初始化好导致 `superpg_fork` 里 `sbrk failed`；部分释放没 demote 导致整块丢失。

### 实验心得

> ✍️ 一句话（提示：superpage 不是把 PGSIZE 改大，而是"叶子 PTE 所在层级变了"，于是分配/翻译/复制/释放全都要跟着改）。

---

## 实验结果

> ✍️ 贴 `../assets/pgtbl/grade.png`，说明 `make grade` 的得分，以及各测试用例分别验证了什么。
