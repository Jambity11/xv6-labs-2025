#import "../templates/lab-report.typ": part

= Lab9: mmap

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/mmap")[https://github.com/Jambity11/xv6-labs-2025/tree/mmap]

程序要读一个文件，通常用 `read()` 一段一段拷进自己的缓冲区。但你有没有想过另一种用法：能不能让文件的内容直接「出现在」内存地址里，用访问内存的方式去访问文件？比如把文件映射到地址 `A` 之后，读 `A` 处的字节就是读文件的第一个字节，写 `A` 处还能写回文件？这就是 `mmap` 要解决的问题。

它的价值在于两点：一是省掉反复的 `read`/`write` 拷贝；二是可以「按需」加载——映射一个超大文件时，不需要一开始就把整个文件读进内存。现代操作系统的按需分页、共享库，底层都是这套机制。

初步想法很克制：`mmap()` 调用时*只登记、不干活*。在进程地址空间里记一段「映射区」（起始地址、长度、对应的文件、偏移、权限），不分配物理页、也不读文件。等用户真的访问这段地址、触发 page fault 时，内核才分配一页物理内存、从文件对应位置读入内容、建立页表映射。这就是懒加载——把「读文件」推迟到「真正用到那一页」的那一刻。

#part("前置知识")

*VMA：一段地址空间的承诺。*VMA（virtual memory area）描述进程地址空间里一段连续区域的性质——它对应哪个文件、什么偏移、什么权限。VMA 本身不是物理内存，它只是「如果这段地址被访问，应该来自哪里」的登记表。这是理解 mmap 的核心。

*page fault 是加载的触发点。*用户访问一段没建立映射的地址，硬件触发 page fault（load 或 store），`stval` 给出出错地址。内核在 `usertrap()` 里认出「这是 mmap 区域的懒加载」，就去补页。这跟 lab5 的 COW、lab3 里 sbrk 的懒分配是同一套「缺页即补」的思路。

*文件读取与写回。*补页时用 `readi()` 从 inode 读对应偏移；`MAP_SHARED` 的映射在 `munmap()`/退出时要反过来用 `writei()` 把脏页写回文件。`readi`/`writei` 是文件系统层提供的、按字节偏移读写 inode 的接口。

*去哪查更详细。*《xv6》教材第 3 章（page tables）和第 8 章（file system）；xv6 里看 `kernel/vm.c`（`vmfault`、`mappages`）、`kernel/sysfile.c`（`sys_mmap`/`sys_munmap`）。关键词：「mmap lazy allocation」「xv6 VMA」「mmap MAP_SHARED writeback」。

== Memory-mapped files (hard)

`mmap(addr, len, prot, flags, fd, offset)` 的参数在实验里只支持一个子集：`addr`/`offset` 假定为 0，`prot` 是读/写/执行权限，`flags` 是 `MAP_SHARED`（改动写回文件）或 `MAP_PRIVATE`（改动只在当前进程）。整个实现按「生命周期」分成登记、加载、写回、继承、退出清理五段。

登记（`sys_mmap`）。在 `struct proc` 里放一个固定大小（`NVMA = 16`）的 VMA 数组，`sys_mmap()` 做的事只是校验参数、找一个空槽位、记下「哪个文件、多长、什么权限」。注意两点：一是要 `filedup()` 持有文件引用，否则用户 `mmap` 后立刻 `close(fd)` 映射就失效了；二是映射地址从 `TRAPFRAME` 下方往低地址分配，避开低地址的 text/data/heap。

加载（`vmfault`）。用户访问映射地址触发 page fault，内核判断地址落在某个 VMA 里，按访问类型查权限（读要 `PROT_READ`、写要 `PROT_WRITE`），然后分配物理页、用 `readi()` 读入文件对应偏移的内容、按权限设 PTE 并 `mappages()`。文件偏移由「VMA 起点 + fault 地址与 VMA 起点的差」算出，所以同一段映射里的不同页，会各自懒加载文件的不同位置。映射长度超过文件大小时，超出部分读不到就保持为零——这正是测试里「1.5 页文件映射 2 页，最后半页应是 0」的来源。

写回（`sys_munmap`）。解除映射时，`MAP_SHARED` 的页要先写回文件再 `uvmunmap`。两个细节容易错：懒加载意味着有些页从没建立过 PTE，解除时直接跳过、不能 panic；写回长度不能超过文件当前大小，否则会把 1.5 页的文件错误扩成 2 页。

继承与退出。`fork()` 要复制父进程的 VMA 表（每个 `filedup`），子进程第一次访问时在自己的 page fault 里独立加载；`exit()` 要在关文件描述符之前，把所有遗留映射按 munmap 语义写回释放。这是 mmap 最容易漏的一环——用户忘了 `munmap`，共享映射的改动也得落盘。

另外 `copyin()`/`copyout()` 也要配合懒加载：系统调用读写用户缓冲区时，若地址落在还没加载的 mmap 页上，要允许它先 `vmfault` 补页，而不是直接报错。

```text
mmap(fd) 登记 VMA，不读文件
  -> 用户访问映射地址，触发 page fault
  -> vmfault() 认领该地址：查权限、分配物理页
  -> readi() 读入文件对应偏移
  -> 建立页表映射，返回用户态继续访问
  -> munmap()/exit() 时 MAP_SHARED 写回文件、释放
```

#part("代码解读")

本实验的代码改动分布在四个文件里，完整改动见仓库：

#link("https://github.com/Jambity11/xv6-labs-2025/blob/mmap/kernel/proc.h")[kernel/proc.h]
#link("https://github.com/Jambity11/xv6-labs-2025/blob/mmap/kernel/sysfile.c")[kernel/sysfile.c]
#link("https://github.com/Jambity11/xv6-labs-2025/blob/mmap/kernel/vm.c")[kernel/vm.c]
#link("https://github.com/Jambity11/xv6-labs-2025/blob/mmap/kernel/proc.c")[kernel/proc.c]

核心代码集中如下。

`kernel/proc.h` 里的 VMA 结构：

```c
#define NVMA 16 // 每个进程最多记录16个 mmap 区域

struct vma {
  int used;
  uint64 addr;
  uint64 len;
  int prot;
  int flags;
  uint64 offset;
  struct file *file;
};
```

每个 `struct proc` 里放一张 VMA 表：

```c
struct vma vmas[NVMA];
```

`kernel/sysfile.c` 里的 `sys_mmap()`——只登记、不读文件：

```c
sys_mmap(void)
{
  uint64 addr;
  int len, prot, flags, fd, offset;
  struct file *f;
  struct proc *p = myproc();
  struct vma *v = 0;

  argaddr(0, &addr);
  argint(1, &len);
  argint(2, &prot);
  argint(3, &flags);
  argint(5, &offset);

  if(argfd(4, &fd, &f) < 0)
    return -1;

  if(addr != 0)
    return -1;
  if(len <= 0)
    return -1;
  if(offset != 0)
    return -1;

  if((prot & PROT_READ) && !f->readable)
    return -1;

  if((flags & MAP_SHARED) && (prot & PROT_WRITE) && !f->writable)
    return -1;

  if((flags & (MAP_SHARED | MAP_PRIVATE)) == 0)
    return -1;

  for(int i = 0; i < NVMA; i++){
    if(p->vmas[i].used == 0){
      v = &p->vmas[i];
      break;
    }
  }

  if(v == 0)
    return -1;

  uint64 maplen = PGROUNDUP(len);

  uint64 top = TRAPFRAME;
  for(int i = 0; i < NVMA; i++){
    if(p->vmas[i].used && p->vmas[i].addr < top)
      top = p->vmas[i].addr;
  }

  uint64 va = top - maplen;
  if(va < p->sz)
    return -1;

  v->used = 1;
  v->addr = va;
  v->len = maplen;
  v->prot = prot;
  v->flags = flags;
  v->offset = offset;
  v->file = filedup(f);

  return va;
}
```

`kernel/vm.c` 的 `vmfault()` 里，认领 mmap 区域的懒加载（下半段）：

```c
  struct vma *v = 0;
  for(int i = 0; i < NVMA; i++){
    if(p->vmas[i].used && va >= p->vmas[i].addr && va < p->vmas[i].addr + p->vmas[i].len){
      v = &p->vmas[i];
      break;
    }
  }

  if(v == 0)
    return 0;

  if(read){
    if((v->prot & PROT_READ) == 0)
      return 0;
  } else {
    if((v->prot & PROT_WRITE) == 0)
      return 0;
  }

  mem = (uint64) kalloc();
  if(mem == 0)
    return 0;
  memset((void *)mem, 0, PGSIZE);

  uint64 off = v->offset + (va - v->addr);

  ilock(v->file->ip);
  int n = readi(v->file->ip, 0, mem, off, PGSIZE);
  iunlock(v->file->ip);

  if(n < 0){
    kfree((void *)mem);
    return 0;
  }

  int perm = PTE_U;
  if(v->prot & PROT_READ)
    perm |= PTE_R;
  if(v->prot & PROT_WRITE)
    perm |= PTE_W | PTE_R;
  if(v->prot & PROT_EXEC)
    perm |= PTE_X;

  if(mappages(pagetable, va, PGSIZE, mem, perm) != 0){
    kfree((void *)mem);
    return 0;
  }

  return mem;
}
```

`kernel/sysfile.c` 里的 `do_munmap()`——写回、解除、维护 VMA 范围：

```c
do_munmap(uint64 addr, uint64 len)
{
  struct proc *p = myproc();
  struct vma *v = 0;
  ...
  // 找到覆盖 addr 的 VMA，略去查找过程

  uint64 end = addr + len;
  uint64 vend = v->addr + v->len;

  if(end > vend)
    end = vend;

  for(uint64 a = addr; a < end; a += PGSIZE){
    pte_t *pte = walk(p->pagetable, a, 0);
    if(pte && (*pte & PTE_V)){
      if(v->flags & MAP_SHARED){
        uint64 fileoff = v->offset + (a - v->addr);
        uint n = PGSIZE;

        ilock(v->file->ip);
        if(fileoff < v->file->ip->size){
          if(fileoff + n > v->file->ip->size)
            n = v->file->ip->size - fileoff;
          iunlock(v->file->ip);

          begin_op();
          ilock(v->file->ip);
          writei(v->file->ip, 1, a, fileoff, n);
          iunlock(v->file->ip);
          end_op();
        } else {
          iunlock(v->file->ip);
        }
      }

      uvmunmap(p->pagetable, a, 1, 1);
    }
  }

  if(addr == v->addr && end == vend){
    fileclose(v->file);
    v->used = 0;
    v->file = 0;
  } else if(addr == v->addr){
    v->addr = end;
    v->offset += end - addr;
    v->len = vend - end;
  } else if(end == vend){
    v->len = addr - v->addr;
  } else {
    return -1;
  }

  return 0;
}
```

`kernel/proc.c` 里 fork 复制 VMA、exit 清理 VMA：

```c
// kfork()：子进程继承父进程的 VMA 表
  for(i = 0; i < NVMA; i++){
    if(p->vmas[i].used){
      np->vmas[i] = p->vmas[i];
      np->vmas[i].file = filedup(p->vmas[i].file);
    } else {
      np->vmas[i].used = 0;
      np->vmas[i].file = 0;
    }
  }
```

```c
// kexit()：关文件描述符前，先把遗留映射按 munmap 语义写回释放
  for(int fd = 0; fd < NOFILE; fd++){
    for(int i = 0; i < NVMA; i++){
      if(p->vmas[i].used)
        mmap_unmap(p->vmas[i].addr, p->vmas[i].len);
    }
    ...
  }
```

下面逐段解释这些代码在做什么、为什么这么写。

*VMA 结构。*VMA 就是「一段地址空间的承诺」：记录这段地址对应哪个文件（`file`）、从文件哪个偏移开始（`offset`）、多长（`len`）、什么权限（`prot`）、共享还是私有（`flags`）。`NVMA = 16` 用固定数组而不是动态分配，因为 xv6 内核没有通用的动态内存分配器，16 个够测试用。注意：VMA 里*不存任何物理页*，它只是元信息——这正是「只登记、不干活」的数据基础。

*`sys_mmap` 的登记。*它做的事情只有「校验参数 + 填一个 VMA 槽位」。值得注意的几个点：一是 `argfd` 从文件描述符拿到 `struct file *` 后，最后用 `filedup(f)` 增加引用计数——因为用户可能 `mmap` 后立刻 `close(fd)`，VMA 必须独立持有文件引用，映射才能继续有效；二是映射地址从 `TRAPFRAME` 往下找、避开低地址的 text/data/heap，这样 mmap 区域和普通内存不冲突；三是整个函数里**没有一次 `kalloc`、没有一次 `readi`**——它真的只是登记，不读文件。

*`vmfault` 的懒加载。*用户访问映射地址触发 page fault，内核先扫 VMA 表，找到覆盖这个地址的 VMA；按访问类型查权限（读要 `PROT_READ`、写要 `PROT_WRITE`）；然后才 `kalloc` 一页、`readi` 从文件读对应偏移、按 `prot` 拼出 PTE 权限、`mappages` 建立映射。文件偏移的算法是 `off = v->offset + (va - v->addr)`——VMA 起始偏移加上 fault 地址相对 VMA 起点的距离，所以同一段映射里的不同页会各自懒加载文件的不同位置。`readi` 只读文件已有部分，超出文件大小的部分保持 `memset` 出来的零——这正是「1.5 页文件映射 2 页，最后半页读到 0」的来源。

*`do_munmap` 的三件事。*一是写回：`MAP_SHARED` 的脏页用 `writei` 写回文件，写回长度限制在文件当前大小以内，避免把文件错误扩大；二是解除：`uvmunmap` 取消映射、释放物理页；三是维护 VMA 范围：分「整段解除、砍头、砍尾」三种情况，砍头时 `v->addr` 后移、`v->offset` 同步增加，砍尾时缩短 `v->len`，保证剩余区域在后续 page fault 里还能找到正确的文件偏移。懒加载带来的一个细节是：有些页从没被访问过、没有 PTE，解除时 `walk` 拿到空就跳过，不能 panic。

*`kfork`/`kexit`。*fork 时复制 VMA 表（每个 `filedup`），子进程第一次访问时在自己的 page fault 里独立加载，不共享物理页；exit 时在关文件描述符之前，把所有遗留 VMA 按 munmap 语义写回释放——这样即使用户忘了 `munmap`，`MAP_SHARED` 的改动也不会丢。

#part("自测与解答")

*问：`mmap` 为什么「只登记、不读文件」，不能一开始就把文件读进内存吗？*

*答：*这是懒加载的核心。映射一个大文件时，如果 `mmap` 时一次性读入全部内容，既慢又占内存，甚至可能映射比物理内存还大的文件。只登记、等到真正访问某一页时才读那一页，才能用低成本支持大文件映射——这也是现代系统普遍用按需分页的原因。

*问：`vmfault` 里文件偏移 `off = v->offset + (va - v->addr)` 是怎么来的？*

*答：*`va - v->addr` 是 fault 地址相对 VMA 起点的距离，`v->offset` 是这段映射在文件里的起始偏移，两者相加就是「这个虚拟页对应文件的哪个字节偏移」。所以同一段映射里的不同页，会各自懒加载文件的不同位置。

*问：`do_munmap` 写回 `MAP_SHARED` 页时，为什么要限制写回长度不超过文件大小？*

*答：*如果映射长度超过文件实际大小，把整页写回会把文件错误地扩大。比如测试里 1.5 页的文件映射了 2 页，第二页只应该写回「文件里真实存在的那半页」，否则文件会被扩成 2 页。所以写回前要读 `file->ip->size`、按页裁剪长度。

*问：`sys_mmap` 为什么要在登记时 `filedup(f)`？*

*答：*用户可能在 `mmap` 之后立刻 `close(fd)`。如果 VMA 只是存一个裸的 `struct file *` 而不增加引用计数，`close` 会把文件结构释放掉，映射就失效了。`filedup` 增加引用计数，让 VMA 独立持有文件引用，映射在 `fd` 关闭后依然有效。

这个实验把前面好几个 lab 串了起来：加系统调用（lab2）、page fault 和懒分配（lab3、lab5）、文件系统接口（lab8）。它最让我受益的一点，是彻底分清了「虚拟地址区域」和「实际物理页」：VMA 只是进程地址空间里的一段承诺，真正的物理页要等 page fault 发生后才出现。理解了这一点，「为什么 mmap 能映射大于内存的文件」「为什么现代系统普遍用按需分页」就都顺理成章了。

== 实验结果

完成本 Lab 后，在 `mmap` 分支运行：

```text
$ make grade
```

`mmaptest` 里的 basic、private、read-only、read/write、dirty、not-mapped unmap、lazy access、two files、fork、munmap_noaccess、read_only_write 子测试，以及 `usertests` 和 time 均通过，满分。

#figure(
  image("../assets/mmap/grade.png", width: 92%),
  caption: [mmap Lab 的 make grade 测试结果],
)

测试通过说明：VMA 登记、懒加载、共享写回、私有隔离、部分解除、退出清理、fork 继承和非法访问保护这些关键路径都符合要求。mmap 的难点从来不在单个函数，而在「登记—加载—写回—继承—退出」这条生命周期链上的每一环都保持一致的维护。
