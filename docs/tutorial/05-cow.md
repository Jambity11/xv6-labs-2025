# Lab 5 Copy-on-Write Fork 学习笔记

官网页面：

- <https://pdos.csail.mit.edu/6.1810/2025/labs/cow.html>

本地参考：

- 旧报告：`docs/reports_old/labs/lab5-cow.typ`
- 代码分支：`origin/cow`
- 基线分支：`origin/riscv`

## 先说明一个代码核对问题

当前可见的 `origin/riscv...origin/cow` diff 主要只有课程框架和 `user/cowtest.c`，没有看到旧报告里描述的 `kernel/vm.c`、`kernel/kalloc.c`、`kernel/trap.c` 等实现改动。

所以这份笔记先写“COW 应该怎么理解、做题时应该怎么定位代码、报告应该怎么讲”。如果后面找到真实实现分支，再把具体 diff 对上。

## 这个 Lab 真正在学什么

一句话：

> COW fork 是在骗用户程序：看起来 fork 后父子各有一份内存，实际上刚 fork 完先共用同一份；直到谁真的要写，内核才复制那一页。

原始 xv6 的 `fork()` 很直接：

```text
父进程有 100 页内存
  -> fork()
  -> 立刻分配 100 页给子进程
  -> 把父进程 100 页内容全部复制过去
```

这样正确，但很浪费。因为常见模式是：

```text
shell fork()
  -> 子进程马上 exec()
  -> exec 把刚复制的内存全扔掉，换成新程序
```

COW 的想法是：

```text
fork 时先别复制
  -> 父子页表都指向同一批物理页
  -> 这些页先设成只读
  -> 谁写，谁触发 page fault
  -> 内核这时才给写入者复制一页
```

这就是 copy-on-write：写的时候才复制。

## 任务：Copy-on-Write fork

### 先用人话说

把内存想成一叠讲义。原始 `fork()` 是：父进程有一整套讲义，子进程一出生就完整复印一套。COW 是：先让父子共用同一套讲义，并规定暂时谁都不能在上面写字。等父进程或子进程真的要写字时，再给它单独复印那一页，让它在自己的页上写。

这个方法省事的地方在于：如果很多页一直没人写，它们就永远不用复制。

但是它也带来两个问题：

```text
1. 怎么发现有人想写共享页？
2. 什么时候才能真正释放共享物理页？
```

第一个问题靠页表权限和 page fault。第二个问题靠物理页引用计数。

### 真实执行路径

fork 时：

```text
用户程序 fork()
  -> sys_fork()
  -> kfork()
  -> uvmcopy()
  -> 原本：给子进程 kalloc 新页并 memmove 复制
  -> COW：父子 PTE 都指向同一物理页
  -> 清掉 PTE_W，让它们暂时不可写
  -> 加上 PTE_COW，说明这是“写时复制页”
  -> 物理页引用计数 +1
```

父或子读这一页：

```text
读共享页
  -> PTE_R 还在
  -> 正常读，不触发异常
```

父或子写这一页：

```text
写共享页
  -> PTE_W 被清掉了
  -> CPU 触发 store page fault
  -> usertrap()
  -> 判断 fault 地址对应 PTE 有 PTE_COW
  -> 如果物理页引用计数 > 1：
       kalloc 新页
       memmove 复制旧内容
       当前进程 PTE 指向新页
       新 PTE 恢复 PTE_W，清 PTE_COW
       旧物理页引用计数 -1
  -> 如果引用计数 == 1：
       不用复制
       直接恢复 PTE_W，清 PTE_COW
  -> 返回用户态，重新执行刚才那条写指令
```

进程退出或释放内存：

```text
uvmunmap()
  -> 对每个映射调用 kfree(pa)
  -> kfree() 先让引用计数 -1
  -> 如果还有别的页表指向它，不真正释放
  -> 只有引用计数变成 0，才放回 freelist
```

内核替用户写内存时：

```text
read(fd, user_buffer, n)
  -> 内核 copyout() 把数据写进用户地址
  -> 如果目标页是 COW 页
  -> 不能等用户态 store page fault
  -> copyout() 自己也要先做 COW 复制
```

### 怎么知道要改哪些文件

从任务语义倒推：

`fork()` 的内存复制在页表代码里：

```text
kernel/vm.c       uvmcopy()
```

写只读 COW 页会触发异常：

```text
kernel/trap.c     usertrap()
kernel/riscv.h    scause / PTE 标志
```

物理页共享后不能随便释放：

```text
kernel/kalloc.c   引用计数、kalloc、kfree
```

页表项需要区分“普通只读页”和“COW 只读页”：

```text
kernel/riscv.h    PTE_COW
```

内核往用户地址写数据也要处理 COW：

```text
kernel/vm.c       copyout()
```

函数跨文件调用要声明：

```text
kernel/defs.h
```

### 为什么不能只清掉 PTE_W

普通代码页本来也是不可写的。如果只看到“不可写”就当成 COW，那用户写代码段时，内核会错误地给它复制一页并允许写入。

所以必须有 `PTE_COW`：

```text
没有 PTE_W，也没有 PTE_COW：
  这是真只读页，写它是非法的。

没有 PTE_W，但有 PTE_COW：
  这是 fork 时临时改成只读的共享页，写它时应该复制。
```

### 为什么需要引用计数

COW 后，一个物理页可能被多个进程同时映射：

```text
父进程 PTE -> 物理页 X
子进程 PTE -> 物理页 X
```

如果父进程退出时直接 `kfree(X)`，子进程还在用 X，就坏了。

引用计数就是在问：

```text
还有几个页表指向这张物理页？
```

只有答案变成 0，才能真正释放。

### 测试在验证什么

`cowtest` 不只是测 fork 能不能跑，它主要测：

- fork 大进程时不会立刻复制所有页，避免内存不够。
- 父子写同一页后内容互不影响。
- 进程退出后共享页不会提前释放，也不会泄漏。
- `copyout()` 写用户缓冲区时也能处理 COW。
- `usertests` 仍然通过，说明普通 fork、exec、exit、sbrk 没被破坏。

### 容易错的点

- 把所有只读页都当 COW，错误允许写代码段。
- 只改 `uvmcopy()`，忘记处理写 page fault。
- 只处理用户态写 fault，忘记 `copyout()`。
- 没有引用计数，导致提前释放或内存泄漏。
- 修改父进程 PTE 后不刷新 TLB，CPU 可能继续用旧的可写权限缓存。

## 这个 Lab 最应该留下的理解

COW 是利用页表权限制造一个“有意的错误”：先把共享页设成只读，让写入触发 page fault；内核在 fault 里补做复制，然后让原来的写指令重新执行。

它把 `fork()` 的大成本拆成很多小成本，而且只有真正写过的页才付这个成本。

