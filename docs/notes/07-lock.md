# Lab 7 Lock 学习笔记

官网页面：

- <https://pdos.csail.mit.edu/6.1810/2025/labs/lock.html>

本地参考：

- 旧报告：`docs/reports_old/labs/lab7-lock.typ`
- 代码分支：`origin/lock`
- 基线分支：`origin/riscv`

## 这个 Lab 真正在学什么

一句话：

> Lock Lab 不是让程序从错变对，而是让已经正确的内核在多 CPU 下少抢同一把锁。

锁的作用是保护共享数据。但如果所有 CPU 都围着同一把锁排队，多核机器就变成了单核排队。

这个 lab 两个任务都围绕一个问题：

```text
哪些共享其实没必要这么共享？
哪些读操作其实可以并发？
```

## 任务一：Memory allocator

### 先用人话说

原始 xv6 的物理页分配器像一个全校共用的仓库窗口：

```text
所有 CPU 要申请空闲页
  -> 都去同一个窗口排队
  -> 抢同一把 kmem.lock
```

这个任务要改成每个 CPU 先有自己的小仓库：

```text
CPU0 有自己的 freelist
CPU1 有自己的 freelist
CPU2 有自己的 freelist
```

大多数时候，CPU 从自己的仓库拿页、还页，不用和别的 CPU 抢。只有自己仓库空了，才去别的 CPU 那里偷一些页。

### 真实执行路径：释放页面

```text
kfree(pa)
  -> 关闭中断，稳定当前 CPU 编号
  -> cpuid() 得到当前 CPU
  -> 把 pa 放进 kmem[id].freelist
  -> 打开中断
```

为什么要关中断？因为如果读取 CPU 编号期间发生调度/迁移，当前进程可能跑到另一个 CPU 上，拿到的 id 就不可靠。

### 真实执行路径：分配页面

```text
kalloc()
  -> 关闭中断，得到当前 CPU id
  -> 先锁 kmem[id]
  -> 如果本 CPU freelist 有页，直接拿
  -> 如果本 CPU freelist 空：
       去其他 CPU 的 freelist 偷取
       拿一批回来
  -> 返回一个 4KB 物理页
```

偷页不是为了功能正确，而是为了性能。如果完全不偷，某个 CPU 本地页用完后就分配失败，但别的 CPU 可能还有很多空闲页。

### 怎么知道要改哪些文件

题目说物理页分配器，入口就是：

```text
kernel/kalloc.c
```

需要当前 CPU 编号：

```text
kernel/proc.c / kernel/riscv.h 中的 cpuid 相关逻辑
```

测试看锁争用：

```text
user/kalloctest.c
kernel/spinlock.c 的统计支持
```

### 容易错的点

- 每 CPU freelist 做了，但偷页太频繁，锁竞争还是高。
- 偷页时持有别人锁太久，反而增加争用。
- 忘记关中断就调用 `cpuid()`。
- 只看 `usertests` 通过，以为完成了；这个任务还要看 `kalloctest` 的锁统计。

## 任务二：Read-write lock

### 先用人话说

普通锁像一个厕所门锁：进去一个人，别人全不能进。不管你只是看一眼，还是要改东西，都得独占。

读写锁更细：

```text
读者：
  只看数据，不改数据。
  多个读者可以一起进。

写者：
  要改数据。
  必须独占，不能和读者或其他写者同时进。
```

但还有一个坑：如果读者源源不断进来，写者可能永远等不到机会。所以实验还要求：

```text
一旦有写者在等，新的读者不要再插队。
```

这叫避免 writer starvation。

### 真实执行路径：读者

```text
read_acquire()
  -> 如果有 writer 正在写，等
  -> 如果有 writer 已经在排队，也等
  -> 否则 readers +1
  -> 进入临界区读数据

read_release()
  -> readers -1
```

### 真实执行路径：写者

```text
write_acquire()
  -> waiting_writers +1，告诉后来的 reader 别插队
  -> 等 state 变成 0，也就是没有 reader、没有 writer
  -> 把 state 改成 writer 持有
  -> waiting_writers -1
  -> 进入临界区写数据

write_release()
  -> state 变回 0
```

### 怎么知道要改哪些文件

读写锁结构定义：

```text
kernel/spinlock.h
```

读写锁实现：

```text
kernel/spinlock.c
```

测试：

```text
user/rwlktest.c
```

### 容易错的点

- 只允许一个 reader，退化成普通锁。
- 允许 reader 源源不断进入，writer 饿死。
- reader 数量和 writer 状态用多个变量分开维护，但没有一次性原子更新，出现竞态窗口。
- 忘记 release 时检查状态，错误释放没有持有的锁。

## 这个 Lab 最应该留下的理解

锁不只是“有没有保护共享数据”。在多 CPU 内核里，还要问：

```text
这把锁保护的共享范围是不是太大？
读操作是不是没必要互相排斥？
等待策略会不会让某类线程一直饿着？
```

Memory allocator 是减少共享范围；read-write lock 是利用读操作可并发的性质。

