# Lab 3 Page Tables 学习笔记

官网页面：

- <https://pdos.csail.mit.edu/6.1810/2025/labs/pgtbl.html>

本地参考：

- 旧报告：`docs/reports_old/labs/lab3-pgtbl.typ`
- 代码分支：`origin/pgtbl`
- 基线分支：`origin/riscv`

## 这个 Lab 真正在学什么

Lab3 的核心是把“虚拟地址到物理地址”这件事从抽象概念落到 xv6 代码：

```text
虚拟地址 va
  -> Sv39 三级页表
  -> 找到 PTE
  -> PTE 给出物理页地址和权限位
  -> 处理器访问物理内存
```

你需要把 PTE 拆成两部分理解：

```text
PTE = 物理页号 + 权限/状态标志
```

常见标志：

- `PTE_V`：这项有效。
- `PTE_R`：可读。
- `PTE_W`：可写。
- `PTE_X`：可执行。
- `PTE_U`：用户态可访问。

如果一个有效 PTE 只有 `PTE_V`，没有 R/W/X，它通常不是最终映射，而是指向下一层页表。只要出现 R/W/X 中任意一个，它就是叶子 PTE，表示已经找到最终物理页。

## 可见分支改动怎么分类

`origin/riscv...origin/pgtbl` 中，和任务理解直接相关的主要文件：

```text
answers-pgtbl.txt
kernel/defs.h
kernel/kalloc.c
kernel/memlayout.h
kernel/proc.c
kernel/proc.h
kernel/riscv.h
kernel/syscall.c
kernel/syscall.h
kernel/sysproc.c
kernel/vm.c
user/pgtbltest.c
user/ulib.c
user/user.h
user/usys.pl
user/usertests.c
```

其中：

- `user/pgtbltest.c`：测试入口，也告诉你题目关心什么。
- `answers-pgtbl.txt`：解释页表观察结果。
- `kernel/memlayout.h`：新增 `USYSCALL` 虚拟地址和 `struct usyscall`。
- `kernel/proc.h` / `kernel/proc.c`：给每个进程分配、映射、释放 `USYSCALL` 页。
- `user/ulib.c`：实现 `ugetpid()`，直接读共享页。
- `kernel/syscall.*` / `kernel/sysproc.c` / `user/usys.pl` / `user/user.h`：新增 `pgpte()`、`kpgtbl()` 这类测试/观察用 syscall。
- `kernel/vm.c`：页表打印、superpage 映射、地址翻译、复制、释放。
- `kernel/kalloc.c`：新增 2MB superpage 的分配器。
- `kernel/riscv.h`：新增 superpage 大小、对齐、叶子 PTE 判断等宏。

## 任务一：Inspect a user-process page table

### 先用人话说

这个任务就是在看：

> 用户程序手里拿着的“虚拟地址”，最后到底指向哪块真实内存。

用户程序平时看到的地址，比如 `0x0`、`0x1000`，并不一定是真实内存条上的地址。它更像一个“房间号”或者“抽象编号”。真正住在哪个物理房间，要查页表。

页表项 PTE 就像地址簿里的一条记录：

```text
这个虚拟页 -> 对应哪个物理页
这个页能不能读
这个页能不能写
这个页能不能执行
用户态能不能访问
```

所以 `pgtbltest` 打印页表，不是为了炫一堆十六进制数，而是让你学会读这张地址簿。

### 要理解的行为

`pgtbltest` 打印当前进程低地址和高地址附近的 PTE。输出里通常有：

```text
va    虚拟地址
pte   页表项完整数值
pa    PTE 中取出的物理页地址
perm  PTE 低位权限标志
```

这一步不是优化，也不是新机制，而是先学会读页表。

### 先抓住一句话

这一任务就是在练一件事：

> 给你一个虚拟地址 `va`，你要能沿着页表找到对应 PTE，并把这个 PTE 拆成“物理地址部分”和“权限标志部分”。

不要把 `pte` 当成纯地址。PTE 是一张小纸条，上面同时写着：

```text
这页映射到哪个物理页
这页能不能读、写、执行、被用户态访问
```

### 真实执行路径

以 `pgpte((void *)va)` 为例：

```text
用户程序 pgtbltest 调用 pgpte(va)
  -> pgpte 是测试用系统调用
  -> 用户态 stub 把 SYS_pgpte 放进 a7，把 va 放进 a0
  -> ecall 进入内核
  -> syscall() 分发到 sys_pgpte()
  -> sys_pgpte() 取出参数 va
  -> pgpte(p->pagetable, va)
  -> walk() 沿当前进程页表查找 PTE
  -> 返回 PTE 数值给用户程序
  -> pgtbltest 打印 va / pte / pa / perm
```

所以它不是直接“偷看硬件”，而是通过一个测试用 syscall 让内核帮用户程序查询自己的页表。

### 怎么知道要看哪些文件

题目要查询 PTE，所以看：

```text
user/pgtbltest.c
kernel/sysproc.c    sys_pgpte()
kernel/vm.c         pgpte() / walk()
kernel/riscv.h      PTE2PA / PTE_FLAGS / PTE_U 等宏
```

如果只是回答页表内容，还要写：

```text
answers-pgtbl.txt
```

### 关键理解

不能把 `pte` 直接等同于物理地址。正确拆法是：

```text
PTE2PA(pte)     取出物理页地址
PTE_FLAGS(pte)  取出权限标志
```

地址空间顶部的特殊映射尤其重要：

- `TRAMPOLINE`：用户态和内核态切换时执行的代码。
- `TRAPFRAME`：保存用户寄存器现场。
- `USYSCALL`：本 lab 新增的用户可读共享页。

这些页可以出现在用户进程页表中，但是否能被用户态访问取决于有没有 `PTE_U`。

### 自检问题

1. 为什么 `pte=0` 和 `perm=0` 表示没有映射？
2. 为什么 `TRAPFRAME` 在用户页表中，却不能让用户随便读写？
3. 相邻虚拟页一定对应相邻物理页吗？

## 任务二：Speed up system calls

### 先用人话说

这个任务是在说：`getpid()` 这件事太小了，每次都进内核有点浪费。

普通 `getpid()` 像这样：

```text
用户：我的 pid 是多少？
内核：我查一下，是 7。
```

如果用户程序频繁问 pid，每次都要 `ecall` 进内核。这个任务的想法是：

> 内核提前把 pid 写在一张用户能看、但不能改的小纸条上。用户以后直接看纸条，不用每次敲内核的门。

这张小纸条就是 `USYSCALL` 页。它被映射进用户页表，权限是“用户可读、不可写”。

### 要实现的行为

普通 `getpid()` 要进内核：

```text
用户态 getpid()
  -> ecall
  -> sys_getpid()
  -> 返回 pid
```

本任务新增 `ugetpid()`，让用户程序直接从只读共享页读 pid：

```text
用户态 ugetpid()
  -> 读取 USYSCALL 页里的 pid
```

### 先抓住一句话

这个任务的本质是：

> 把一个由内核维护、用户经常读取、内容很小的数据，提前映射到用户页表里，让用户直接读内存，省掉一次 `ecall`。

这里的数据就是 pid。

### 真实执行路径

普通 `getpid()`：

```text
用户程序 getpid()
  -> a7 = SYS_getpid
  -> ecall 进入内核
  -> sys_getpid() 读取 myproc()->pid
  -> pid 写回 a0
  -> 回到用户态
```

`ugetpid()`：

```text
用户程序 ugetpid()
  -> 直接访问固定虚拟地址 USYSCALL
  -> 把这页解释成 struct usyscall
  -> 读取 u->pid
  -> 没有 ecall，没有进入内核
```

内核提前做的准备是：

```text
allocproc()
  -> 分配一页 p->usyscall
  -> 写入 p->usyscall->pid

proc_pagetable()
  -> 把 p->usyscall 映射到用户虚拟地址 USYSCALL
  -> 权限设置为 PTE_R | PTE_U
```

权限的意思很直接：用户能读，不能写。

### 怎么知道要改哪些文件

要给每个进程一页共享数据，所以状态属于进程：

```text
kernel/proc.h
kernel/proc.c
```

要在用户地址空间固定位置放这页，所以看内存布局：

```text
kernel/memlayout.h
kernel/vm.c
```

要写用户态函数，所以看：

```text
user/ulib.c
user/user.h
```

### 实现主线

在 `kernel/memlayout.h` 定义：

```text
USYSCALL = TRAPFRAME - PGSIZE
struct usyscall { int pid; }
```

在进程创建时：

```text
allocproc()
  -> kalloc() 分配一页
  -> 清零
  -> 写入 p->pid
```

在页表创建时：

```text
proc_pagetable()
  -> mappages(pagetable, USYSCALL, PGSIZE, p->usyscall, PTE_R | PTE_U)
```

权限只能是用户可读，不能用户可写：

```text
PTE_R | PTE_U
```

用户态 `ugetpid()`：

```text
struct usyscall *u = (struct usyscall *)USYSCALL;
return u->pid;
```

### 容易错的点

- 忘记 `PTE_U`：用户态无法访问，会 fault。
- 错加 `PTE_W`：用户程序可以伪造 pid。
- 释放时重复 free：`proc_freepagetable()` 只解除映射，`freeproc()` 释放实际物理页。
- 以为所有进程共用同一物理页：不是。虚拟地址一样，但每个进程映射到自己的物理页。

### 自检问题

1. `USYSCALL` 为什么要放在固定虚拟地址？
2. 为什么 `ugetpid()` 不需要新增 syscall？
3. 为什么不同进程可以用同一个 `USYSCALL` 虚拟地址但读到不同 pid？

## 任务三：Print a page table

### 先用人话说

页表不是一张简单表，而是多层目录。你可以把 Sv39 页表想成三级文件夹：

```text
第一级目录
  -> 第二级目录
       -> 第三级目录
            -> 具体物理页
```

`vmprint()` 的作用就是把这棵目录树打印出来，让你看到地址翻译不是“查一次表”就结束，而是一级一级往下找。

所以这个任务不是为了新增用户功能，而是为了让你能看见 xv6 进程页表内部长什么样。

### 要实现的行为

`vmprint()` 把三级页表打印成树状结构，让你看到哪些 PTE 是中间页表，哪些 PTE 是最终映射。

```text
level 2
  -> level 1
       -> level 0
            -> physical page
```

### 先抓住一句话

`vmprint()` 的本质是：

> 把原本藏在内存里的三级页表，用缩进打印成一棵树。

这不是为了新增 OS 功能，而是为了让你能观察页表结构。

### 真实执行路径

```text
用户程序 pgtbltest 调用 kpgtbl()
  -> kpgtbl 是测试用系统调用
  -> ecall 进入内核
  -> syscall() 分发到 sys_kpgtbl()
  -> sys_kpgtbl() 找到当前进程 p->pagetable
  -> vmprint(p->pagetable)
  -> 从 level 2 开始扫描 512 个 PTE
  -> 遇到无效项：跳过
  -> 遇到非叶子项：打印后递归下一层
  -> 遇到叶子项：打印最终映射，不再递归
```

看输出时，缩进越深，说明页表层级越低。

### 怎么知道要改哪些文件

页表遍历在：

```text
kernel/vm.c
```

函数要被别的文件调用，需要声明：

```text
kernel/defs.h
```

测试程序通过 syscall 触发打印，所以还会涉及：

```text
kernel/sysproc.c
kernel/syscall.c
kernel/syscall.h
user/user.h
user/usys.pl
```

### 实现主线

递归扫描每张页表的 512 个 PTE：

```text
for i in 0..511:
    pte = pagetable[i]
    if pte 无效:
        continue
    打印 va 前缀、pte、pa
    if pte 不是叶子:
        递归打印下一层页表
```

判断叶子 PTE 的关键是：

```text
PTE_R | PTE_W | PTE_X
```

只有 `PTE_V` 而没有 R/W/X 的项，才是“指向下一层页表”。

### 容易错的点

- 把所有有效 PTE 都递归下去，会把普通数据页当成页表解释。
- 虚拟地址前缀不是实际访问地址，而是由各级索引拼出来的范围前缀。
- 输出格式对测试很重要，理解时不用死背，但实现时要对齐要求。

### 自检问题

1. 为什么非叶子 PTE 通常只有 `PTE_V`？
2. 为什么叶子 PTE 不一定只出现在 level 0？
3. `vmprint()` 为什么可以帮助理解 superpage？

## 任务四：Use superpages

### 先用人话说

普通页是小标签：每 4KB 内存贴一张标签。2MB 内存就要贴 512 张标签。

superpage 是大标签：一张标签直接管 2MB。

```text
普通页：
  512 个 4KB 页面
  512 个 PTE

superpage：
  1 个 2MB 页面
  1 个 PTE
```

这件事的好处是页表更小，TLB 也更容易覆盖大块连续内存。难点是：以前 xv6 默认“最终标签”都在页表最底层，现在 superpage 允许中间层就出现最终标签。

所以 superpage 真正改变的是：

> 叶子 PTE 不一定在 level 0，也可能在 level 1。

一旦这个规则变了，查地址、分配内存、fork 复制、释放内存都要跟着变。

### 要实现的行为

普通页是 4KB。2MB 内存需要：

```text
512 个 4KB 页
512 个 level-0 叶子 PTE
```

superpage 用一个 2MB 连续物理块和一个 level-1 叶子 PTE 覆盖同样范围：

```text
1 个 2MB 物理块
1 个 level-1 叶子 PTE
```

这样减少页表项数量，也让 TLB 一项能覆盖更大范围。

### 先抓住一句话

Superpage 的本质是：

> 普通页把叶子 PTE 放在 level 0；superpage 把叶子 PTE 提前放在 level 1，于是一个 PTE 覆盖 2MB。

所以这个任务不是简单把 `PGSIZE` 改成 2MB。因为叶子所在层级变了，凡是“走页表、分配页、复制页、释放页”的代码都要认识这种情况。

### 真实执行路径

用户程序申请大块内存时：

```text
用户程序 sbrk(SZ)
  -> sys_sbrk()
  -> growproc()
  -> uvmalloc()
  -> 当前 va 是否 2MB 对齐？
  -> 剩余空间是否至少 2MB？
  -> 是：superalloc() 分配 2MB 物理块
  -> supermappage() 在 level 1 写叶子 PTE
  -> 否：按普通 4KB 页 kalloc() + mappages()
```

用户程序访问 superpage 中的某个地址时：

```text
walkaddr(pagetable, va)
  -> 查 level 2
  -> 查 level 1
  -> 发现 level-1 PTE 已经是叶子
  -> 物理地址 = PTE2PA(pte) + 2MB 页内偏移
```

`fork()` 时：

```text
uvmcopy()
  -> 发现父进程这里是 superpage
  -> 子进程 superalloc() 新 2MB
  -> 复制整块 2MB
  -> 给子进程建立 level-1 叶子映射
```

释放时：

```text
如果完整释放 2MB:
  -> 清 level-1 PTE
  -> superfree()

如果只释放其中 4KB:
  -> 不能直接释放整块
  -> 先 demote 成 512 个普通 4KB PTE
  -> 再释放目标小页
```

### 怎么知道要改哪些文件

superpage 影响的是整个虚拟内存生命周期：

```text
kernel/kalloc.c    分配/释放 2MB 物理块
kernel/riscv.h     SUPERPGSIZE、对齐宏、PTE_LEAF
kernel/vm.c        映射、walkaddr、uvmalloc、uvmcopy、uvmunmap
kernel/defs.h      superalloc/superfree 声明
```

因为 `sbrk()` 最终走到 `uvmalloc()`，所以用户申请内存时能自动使用 superpage。

### 实现主线

第一步：准备 2MB 物理块分配器。

```text
kinit()
  -> 把一部分 2MB 对齐物理内存放进 supermem.freelist
  -> 其他内存仍交给普通 kmem.freelist
```

第二步：建立 level-1 叶子 PTE。

```text
supermappage()
  -> 检查 va 和 pa 都 2MB 对齐
  -> 找到 level-1 PTE
  -> 写入 PA2PTE(pa) | perm | PTE_V
```

第三步：让 `uvmalloc()` 优先使用 superpage。

```text
如果当前 va 2MB 对齐，且剩余增长空间 >= 2MB:
    superalloc()
    supermappage()
否则:
    kalloc()
    mappages()
```

第四步：让地址翻译认识 level-1 叶子。

普通页的页内偏移是 12 位：

```text
pa + (va & (PGSIZE - 1))
```

superpage 的页内偏移是 21 位：

```text
pa + (va & (SUPERPGSIZE - 1))
```

第五步：让 `fork()` 能复制 superpage。

```text
uvmcopy()
  -> 普通页：kalloc 4KB，复制 4KB
  -> superpage：superalloc 2MB，复制 2MB，建立 level-1 映射
```

第六步：让释放支持“完整释放”和“部分释放”。

完整释放 2MB：

```text
清 level-1 PTE
superfree(pa)
```

只释放 superpage 的一小部分时，必须先降级：

```text
demote_superpage()
  -> 新建 level-0 页表
  -> 把 2MB 映射拆成 512 个 4KB PTE
  -> 替换原 level-1 叶子
  -> 再按普通页释放目标部分
```

### 容易错的点

- superpage 必须虚拟地址和物理地址都 2MB 对齐。
- `walk()` 原来默认中间层不是叶子；支持 superpage 后，遇到 level-1 叶子要停。
- `walkaddr()` 不能总是只加 4KB 偏移。
- `uvmcopy()` 不能把 2MB 映射当成一个 4KB 页复制。
- 部分释放不能直接释放整块 2MB，否则还在使用的内容会丢。
- superpage 专用空闲链表和普通页空闲链表不能重叠，否则同一物理内存可能被分配两次。

### 自检问题

1. 为什么 superpage 的叶子 PTE 在 level 1，而不是 level 0？
2. 为什么 `superpg_free` 会逼着你实现 demote？
3. 为什么 `walkaddr()` 要根据叶子所在层级计算不同大小的偏移？
4. 如果 `superalloc()` 的内存也进入普通 `kalloc()` freelist，会发生什么？

## 这个 Lab 最应该留下的理解

Lab3 的主线可以压缩成三句话：

1. PTE 同时保存物理页号和权限标志，不是单纯的地址。
2. 页表权限可以让同一个虚拟地址空间里的不同页面有不同访问规则。
3. superpage 改变的是“叶子 PTE 所在层级”，所以分配、翻译、复制、释放都要跟着改。

## 写 Markdown 报告时的方向

这一章不要只写“我添加了 USYSCALL、vmprint、superpage”。更好的组织是：

```text
先看懂普通页表
  -> 用只读共享页优化 getpid
  -> 用 vmprint 可视化页表树
  -> 扩展到 level-1 叶子 PTE 的 superpage
```

报告里尤其要写清楚：

- 为什么 `USYSCALL` 可读不可写；
- 为什么 `TRAPFRAME`/`TRAMPOLINE` 在页表里但没有 `PTE_U`；
- 为什么 superpage 不是把 `PGSIZE` 改大这么简单；
- 为什么部分释放需要 demote。
