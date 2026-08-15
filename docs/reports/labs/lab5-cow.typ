#import "../templates/lab-report.typ": part

= Lab5: Copy-on-Write Fork

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/cow")[https://github.com/Jambity11/xv6-labs-2025/tree/cow]

先想一个很常见的场景：在 shell 里敲一个命令，shell 会先 `fork()` 出一个子进程，子进程再 `exec()` 成你要跑的程序。`fork()` 的语义是「创建和父进程几乎一样的子进程」，最朴素的实现是把父进程所有内存原样复制一份。可问题是：这个子进程紧接着就 `exec()` 了，刚辛辛苦苦复制的那一大块内存，立刻就被新程序整个替换掉——等于白复制。

这不是个例，而是 Unix 里最高频的操作路径之一。每次都完整复制，浪费的物理页和内存带宽非常可观。所以问题变成：能不能在「保证用户看到的行为不变」的前提下，把这个复制偷懒掉？

初步想法很自然：让父子进程先共用同一批物理页，谁都不复制；等某一方真的要「写」某页了，再单独为它复制一份。读多写少时几乎零开销。可怎么才能「在写的那一刻才发现」？答案是借助页表权限——把这些共享页暂时设成只读，一旦有人写，硬件就触发 page fault，内核在 fault 处理里补做复制，再把这一页改成可写。这就是 copy-on-write（写时复制）。

#part("前置知识")

*fork 的语义与实现入口。*`fork()` 创建子进程，用户可见的语义是「父子进程初始内存相同、之后各自独立」。xv6 里真正复制用户地址空间的不是 `fork()` 本身，而是它调用的 `kernel/vm.c` 里的 `uvmcopy()`——这是本实验改造的主要入口。

*页表权限与只读陷阱。*每个 PTE 都带 `PTE_R`/`PTE_W`/`PTE_X` 权限位。COW 的思路是「先共享、后复制」，触发点就是「写」：把共享页的 `PTE_W` 摘掉，写的时候硬件会因为没写权限而 trap 进内核。

*page fault 的三个线索。*上一条说的「写只读页」在 RISC-V 里表现为 store page fault：`scause == 15`，`stval` 是出错的虚拟地址。内核在 `usertrap()` 里看到这两个值，就知道「有人要写一个 COW 页」，进而完成复制。

*引用计数。*COW 之后，同一个物理页可能被父子（甚至更多）进程的页表同时引用。谁退出都不能随便把物理页还回空闲池——得用引用计数记录「还有几个页表指向它」，减到 0 才真正释放。

*去哪查更详细。*《xv6》教材第 3 章「Page tables」和第 4 章里 page fault 的部分；本实验的关键文件是 `kernel/vm.c`（`uvmcopy`、`copyout`）、`kernel/trap.c`（`usertrap`）、`kernel/kalloc.c`（`kalloc`/`kfree`）。关键词：「copy-on-write fork」「xv6 uvmcopy」「store page fault scause」。

== Copy-on-Write fork (hard)

整个实验可以浓缩成三件事：fork 时共享、写时复制、退出时按引用计数释放。代码分散在好几个文件里，但只要抓住「页表项」这个枢纽，路径就清楚了。

第一件事，fork 时共享。改 `uvmcopy()`：原来它给子进程逐页 `kalloc` + 复制；现在改成让子进程的 PTE 直接指向父进程原来的物理页。对原来带 `PTE_W` 的页，父子双方的 PTE 都摘掉 `PTE_W`、加上一个软件标志位 `PTE_COW`（用 RISC-V 保留给软件用的位）。注意必须区分「COW 只读页」和「本来就只读的页」：代码段本来就是只读的，写它应该判非法；而 COW 页写它应该复制后放行——所以只对原来可写的页设 `PTE_COW`。每建立一个共享映射，物理页的引用计数加一。

第二件事，写时复制。在 `usertrap()` 里识别 store page fault，检查 `stval` 对应 PTE 是否带 `PTE_COW`。若是：看引用计数，大于 1 就分配新页、复制旧内容、把当前进程的 PTE 改成指向新页并恢复 `PTE_W`；等于 1 说明当前进程是唯一引用者，直接恢复写权限即可，不用真复制。这里有个极易遗漏的坑：`copyout()` 是内核替用户进程往用户地址写数据（比如 `read` 把文件内容写进用户缓冲区、`wait` 写退出状态），它不走用户态 page fault，所以 `copyout()` 在 `memmove` 之前也要主动做一遍同样的 COW 检查，否则这类系统调用会撞上只读页。

第三件事，退出时按引用计数释放。`kfree()` 不再直接还页，而是先把引用计数减 1，减到 0 才真正放回空闲链表；计数的读写用锁保护。这样 `uvmunmap`、`uvmfree` 等原有释放路径不用大改，释放动作被引用计数兜住了。

```text
写入 COW 页
  -> usertrap() 识别 store page fault
  -> 找到 fault 地址对应的 PTE，检查 PTE_COW
  -> 共享者 >1：分配新页、复制内容、改当前 PTE 指向新页
  -> 恢复 PTE_W、清 PTE_COW
  -> 返回用户态，重新执行那条写指令
```

实现里还有一个细节不能忘：改了 PTE 权限后要 `sfence_vma()` 刷 TLB，否则 CPU 可能继续用缓存的旧权限。

#part("代码解读")

本实验的代码改动分布在四个文件里：`kernel/riscv.h`（加 `PTE_COW` 位）、`kernel/kalloc.c`（引用计数）、`kernel/vm.c`（`uvmcopy`、`cowalloc`、`copyout`）、`kernel/trap.c`（`usertrap` 里识别 COW 写）。完整改动见仓库对应分支：

#link("https://github.com/Jambity11/xv6-labs-2025/blob/cow/kernel/riscv.h")[kernel/riscv.h]　#link("https://github.com/Jambity11/xv6-labs-2025/blob/cow/kernel/kalloc.c")[kernel/kalloc.c]　#link("https://github.com/Jambity11/xv6-labs-2025/blob/cow/kernel/vm.c")[kernel/vm.c]　#link("https://github.com/Jambity11/xv6-labs-2025/blob/cow/kernel/trap.c")[kernel/trap.c]

先把核心代码集中贴出来，下面再统一逐段解释。

`kernel/riscv.h` 里新增的软件标志位：

```c
#define PTE_V (1L << 0) // valid
#define PTE_R (1L << 1)
#define PTE_W (1L << 2)
#define PTE_X (1L << 3)
#define PTE_U (1L << 4) // user can access

#define PTE_COW (1L << 8) // 这一页原来可写，现在为了COW临时变成只读
```

`kernel/kalloc.c` 里给每个物理页加一个引用计数：

```c
struct {
  struct spinlock lock;
  struct run *freelist;
  int refcnt[(PHYSTOP - KERNBASE) / PGSIZE];
} kmem;

static int
pa_index(void *pa)
{
  return ((uint64)pa - KERNBASE) / PGSIZE;
}
```

`kfree()` 改成「先减计数、减到 0 才真释放」：

```c
void
kfree(void *pa)
{
  struct run *r;
  int idx;

  if(((uint64)pa % PGSIZE) != 0 || (char*)pa < end || (uint64)pa >= PHYSTOP)
    panic("kfree");

  idx = pa_index(pa);

  acquire(&kmem.lock);
  if(kmem.refcnt[idx] < 1)
    panic("kfree: refcnt");

  kmem.refcnt[idx]--;
  if(kmem.refcnt[idx] > 0){
    release(&kmem.lock);
    return;
  }

  // Fill with junk to catch dangling refs.
  memset(pa, 1, PGSIZE);

  r = (struct run*)pa;
  r->next = kmem.freelist;
  kmem.freelist = r;
  release(&kmem.lock);
}
```

`kalloc()` 取出页时把计数重置为 1，并新增 `kaddref`/`krefcnt` 两个辅助函数：

```c
  r = kmem.freelist;
  if(r){
    kmem.freelist = r->next;
    kmem.refcnt[pa_index((void*)r)] = 1;
  }
```

```c
// fork 共享一页时，引用计数加 1。
void
kaddref(void *pa)
{
  if(((uint64)pa % PGSIZE) != 0 || (uint64)pa < KERNBASE || (uint64)pa >= PHYSTOP)
    panic("kaddref");

  acquire(&kmem.lock);
  kmem.refcnt[pa_index(pa)]++;
  release(&kmem.lock);
}

// 查询某一页当前的引用计数。
int
krefcnt(void *pa)
{
  int n;

  if(((uint64)pa % PGSIZE) != 0 || (uint64)pa < KERNBASE || (uint64)pa >= PHYSTOP)
    panic("krefcnt");

  acquire(&kmem.lock);
  n = kmem.refcnt[pa_index(pa)];
  release(&kmem.lock);

  return n;
}
```

`kernel/vm.c` 里改造后的 `uvmcopy()`——fork 时共享、不再复制：

```c
uvmcopy(pagetable_t old, pagetable_t new, uint64 sz)
{
  pte_t *pte;
  uint64 pa, i;
  uint flags;

  for(i = 0; i < sz; i += PGSIZE){
    if((pte = walk(old, i, 0)) == 0)
      continue;   // page table entry hasn't been allocated
    if((*pte & PTE_V) == 0)
      continue;   // physical page hasn't been allocated

    pa = PTE2PA(*pte);
    flags = PTE_FLAGS(*pte);

    if(flags & PTE_W){
      flags = (flags & ~PTE_W) | PTE_COW;
      *pte = PA2PTE(pa) | flags;
    }

    if(mappages(new, i, PGSIZE, pa, flags) != 0)
      goto err;

    kaddref((void*)pa);
  }

  sfence_vma();
  return 0;

 err:
  sfence_vma();
  uvmunmap(new, 0, i / PGSIZE, 1);
  return -1;
}
```

处理「写 COW 页」的 `cowalloc()`：

```c
uint64
cowalloc(pagetable_t pagetable, uint64 va)
{
  pte_t *pte;
  uint64 pa;
  uint64 mem;
  uint flags;

  if(va >= MAXVA)
    return 0;

  va = PGROUNDDOWN(va);

  pte = walk(pagetable, va, 0);
  if(pte == 0)
    return 0;
  if((*pte & (PTE_V | PTE_U | PTE_COW)) != (PTE_V | PTE_U | PTE_COW))
    return 0;

  pa = PTE2PA(*pte);
  flags = PTE_FLAGS(*pte);

  if(krefcnt((void*)pa) == 1){
    *pte = PA2PTE(pa) | ((flags | PTE_W) & ~PTE_COW);
    sfence_vma();
    return pa;
  }

  mem = (uint64)kalloc();
  if(mem == 0)
    return 0;

  memmove((void*)mem, (void*)pa, PGSIZE);

  *pte = PA2PTE(mem) | ((flags | PTE_W) & ~PTE_COW);
  sfence_vma();

  kfree((void*)pa);

  return mem;
}
```

`copyout()` 里补上的 COW 检查：

```c
      pte = walk(pagetable, va0, 0);
      if(pte == 0)
        return -1;

      if(*pte & PTE_COW){
        if((pa0 = cowalloc(pagetable, va0)) == 0)
          return -1;
        pte = walk(pagetable, va0, 0);
        if(pte == 0)
          return -1;
      }

      // forbid copyout over read-only user text pages.
      if((*pte & PTE_W) == 0)
        return -1;
```

`kernel/trap.c` 的 `usertrap()` 里识别 store page fault：

```c
  } else if(r_scause() == 15 && cowalloc(p->pagetable, r_stval()) != 0){
    // page fault on a copy-on-write page
  } else if((r_scause() == 15 || r_scause() == 13) &&
            vmfault(p->pagetable, r_stval(), (r_scause() == 13)? 1 : 0) != 0) {
    // page fault on lazily-allocated page
  } else {
    printf("usertrap(): unexpected scause 0x%lx pid=%d\n", r_scause(), p->pid);
    setkilled(p);
  }
```

下面统一解释每段代码在做什么、为什么这么写。

*`PTE_COW` 标志位。*RISC-V 的 PTE 除了硬件定义的 `V/R/W/X/U` 几位，还有保留给操作系统软件使用的位，`PTE_COW` 用的是第 8 位。它标记「这页本来是用户可写的，现在为了 COW 临时摘掉了写权限」。这个标记是必要的——否则内核分不清「COW 只读页」和「本来就只读的页」：代码段本来就只读，写它应该判非法；COW 页写它应该复制后放行。

*引用计数。*`refcnt` 是一个按物理页号索引的整型数组，`pa_index(pa) = (pa - KERNBASE) / PGSIZE` 把物理地址换算成数组下标，每个物理页一个计数。COW 之后同一个物理页可能被多个进程的页表同时引用，这个数组记录「还有几个页表指向它」。

*`kfree` 的改造。*这是引用计数的核心。原来的 `kfree` 直接 `memset` 清空页面、放回空闲链表；现在先 `refcnt[idx]--`，如果减完还大于 0，说明还有别的进程在引用，就直接 `return`，什么都不做；只有减到 0 才真正清空、放回链表。这样 `uvmunmap`/`uvmfree` 等原有释放路径不用改——它们照常调 `kfree`，释放动作被引用计数兜住了。`kalloc` 在取出页时把计数重置为 1，`kaddref` 在共享一页时加 1，`krefcnt` 供 `cowalloc` 查询。

*`uvmcopy` 的改造。*原来的 fork 会 `kalloc` + `memmove` 完整复制每一页；现在改成：对每一页，如果它带 `PTE_W`（用户语义上可写），就把 `flags` 改成 `(flags & ~PTE_W) | PTE_COW`（摘写权限、加 COW 标记），并把**父进程的 PTE 也同步改掉**；然后 `mappages` 让子进程的 PTE 指向同一个 `pa`，`kaddref` 把引用计数加 1。注意两点：一是只对原来带 `PTE_W` 的页设 COW，本来只读的页保持原样共享、不加 COW；二是 `sfence_vma()` 刷 TLB，否则 CPU 可能继续用缓存的旧写权限。

*`cowalloc`。*写 COW 页触发 page fault 后，内核调它来「补做复制」。它先 `PGROUNDDOWN(va)` 把地址按页对齐，`walk` 找到 PTE，然后检查 `(PTE_V | PTE_U | PTE_COW)` 三位置齐——不齐说明这不是合法的 COW 页，返回 0。接着看引用计数：`krefcnt == 1` 说明只有当前进程在用，根本不用复制，直接把 `PTE_W` 加回来、清掉 `PTE_COW` 就行；`> 1` 才真正 `kalloc` 新页、`memmove` 复制旧内容、把 PTE 改指向新页（恢复 `PTE_W`、清 `PTE_COW`），最后 `kfree` 旧页（旧页计数减 1）。这个「先看计数再决定要不要复制」的分支，是 COW 省内存的关键——很多页 fork 后只有一方在写，另一方的引用早就没了。

*`copyout` 的补丁。*这是最容易漏的一点。用户进程自己写 COW 页会走 page fault → `usertrap` → `cowalloc`；但 `copyout()` 是内核替用户进程往用户地址写数据（比如 `read` 把文件内容写进用户缓冲区、`wait` 写退出状态），它发生在内核里、不走用户态 page fault。所以 `copyout` 在 `memmove` 之前要主动检查 `PTE_COW` 并调 `cowalloc`，否则内核会撞上只读的 COW 页。

*`usertrap` 的识别。*`r_scause() == 15` 是 store page fault（写缺页）。处理顺序是：先试 `cowalloc`——成功说明是 COW 写；不成功再试 `vmfault`（懒分配，lab3 的 sbrk 用）；都不行才是真错误，`setkilled` 杀掉进程。这个 `else if` 链把「COW 写、懒分配、非法访问」三种 page fault 区分开。

#part("自测与解答")

*问：`uvmcopy` 为什么只对原来带 `PTE_W` 的页设 `PTE_COW`，而不是对所有只读页都设？*

*答：*COW 页和普通只读页的语义不同。代码段本来就只读，写它应该判非法（杀死进程）；COW 页只是「临时」只读，写它应该复制后放行。如果对所有只读页都设 `PTE_COW`，就会错误地允许用户写代码段，破坏只读保护。所以只对「本来可写、因共享而临时只读」的页做标记。

*问：`cowalloc` 里引用计数等于 1 时为什么不用复制？*

*答：*引用计数等于 1 说明这个物理页只有当前进程还在用，没有共享者了（另一个进程可能早就退出、计数已减）。这时候直接把写权限加回来即可，复制一份纯属浪费。这个分支让「写时复制」退化成「写时不复制」，是 COW 能真正省内存的关键。

*问：`copyout` 为什么也要做 COW 检查，不能只靠 `usertrap`？*

*答：*`copyout` 是内核替用户进程写用户地址空间，发生在内核代码里，不经过用户态的 store page fault，所以不会自动触发 `usertrap` 里的 `cowalloc`。如果不主动检查，内核会往只读的 COW 页写数据，要么写失败、要么破坏「父子共享」的语义。`cowtest` 里的 `filetest` 正是测这条路径。

*问：`kfree` 为什么在计数减到 0 之前不能 `memset`、不能放回空闲链表？*

*答：*因为还有别的进程的页表在引用这页。如果提前清空或放回链表，这页可能被分配给别的用途，还在引用它的进程就会读到被篡改的内容或别人的数据。只有减到 0、确认无人引用后，才能安全地清空并回收。

这个实验最让我有收获的不是代码本身，而是两点认识。其一，用户看到的语义和内核的实现方式是可以分离的：用户以为 fork 之后各有各的内存，内核却可以先共享、后按需复制。其二，page fault 并不一定是「程序出错了」——它也可以是内核有意埋下的一个控制点，COW 就是「先撤写权限、再在写异常里补复制」的主动设计。缺页异常在这里从「错误信号」变成了「机制触发点」，这个视角转变很关键。

== 实验结果

完成本 Lab 后，在 `cow` 分支运行：

```text
$ make grade
```

`cowtest`、`usertests -q` 和相关评分项均通过，满分。

#figure(
  image("../assets/cow/grade.png", width: 92%),
  caption: [Copy-on-Write Lab 的 make grade 测试结果],
)

测试通过说明：fork 共享、写 COW 页复制、`copyout()` 写用户 COW 页、以及按引用计数回收这几条关键路径都符合要求。把「复制」从 fork 时推迟到真正写入时，就是本实验的全部精髓。
