#import "../templates/lab-report.typ": part

= Lab7: Lock

对应源码分支：#link("https://github.com/JambitX11/xv6-labs-2025/tree/lock")[https://github.com/JambitX11/xv6-labs-2025/tree/lock]

本实验围绕 xv6 内核中的锁展开。前面的实验更多关注“怎样实现一个功能”，例如系统调用、页表映射、异常处理或网络收发；Lock Lab 则进一步关注“功能已经正确时，内核在多核环境下是否还能高效、可扩展地运行”。在多核操作系统中，锁是保护共享数据结构的基本工具，但锁本身也可能成为性能瓶颈。如果所有 CPU 都频繁等待同一把锁，那么即使机器有多个 CPU，实际运行效果也会接近串行执行。

本实验包含两个任务点。第一个任务是优化物理内存分配器，将原来所有 CPU 共用的一条空闲页链表拆分为每 CPU 一条空闲链表，从而减少 `kalloc()` 和 `kfree()` 对同一把 `kmem` 锁的竞争。第二个任务是实现读写自旋锁，使多个读者可以并发进入临界区，而写者仍然保持独占，并且在有写者等待时阻止新的读者插队，避免写者长期饥饿。

这两个任务体现的是同一类内核设计问题：锁不仅要保证正确性，还要尽量缩小不必要的共享范围。内存分配器任务通过拆分数据结构减少锁竞争，读写锁任务通过区分读路径和写路径提高并发度。

== Memory allocator (moderate)

#part("实验目的")

本任务要求优化 xv6 的物理内存分配器，降低多 CPU 同时执行 `kalloc()` 和 `kfree()` 时对 `kmem` 锁的竞争。原始 xv6 在 `kernel/kalloc.c` 中维护一个全局空闲页链表，所有物理页分配和释放都必须经过同一个 `kmem.lock`。这种设计实现简单，但在多核环境中会造成明显瓶颈：多个 CPU 即使操作的是不同物理页，也必须轮流抢同一把锁。

`kalloctest` 正是用来暴露这个问题的测试程序。它通过多个进程反复增长和收缩地址空间，制造大量 `sbrk()`、`kalloc()` 和 `kfree()` 调用，并统计每把锁在 `acquire()` 中执行 test-and-set 但失败的次数。这个次数越高，说明锁竞争越激烈。实验目标是在不破坏内存分配正确性的前提下，让 `kmem` 相关锁的争用次数显著下降。

从概念上看，本任务不是删除锁，而是把“一把保护所有空闲页的大锁”改造成“每个 CPU 各自维护一条空闲页链表和一把锁”。大多数情况下，CPU 只访问自己的 freelist；只有当前 CPU 没有空闲页时，才从其他 CPU 的 freelist 中偷取空闲页。

#part("实验步骤")

实验主要修改 `kernel/kalloc.c`。原始代码中 `kmem` 是单个全局结构体，包含一把锁和一条 freelist。实验将其改为以 `NCPU` 为长度的数组：

```c
struct {
  struct spinlock lock;
  struct run *freelist;
} kmem[NCPU];
```

这样每个 CPU 都有独立的 `kmem[id].lock` 和 `kmem[id].freelist`。`NCPU` 定义在 `kernel/param.h` 中，表示 xv6 支持的最大 CPU 数量。`kinit()` 中需要循环初始化每一把锁，并保证锁名以 `"kmem"` 开头，因为 `statistics()` 系统调用会按照锁名统计 `kmem` 相关锁的争用情况：

```c
for(int i = 0; i < NCPU; i++)
  initlock(&kmem[i].lock, "kmem");
```

释放页面时，`kfree()` 不再把页放回全局 freelist，而是放回当前 CPU 对应的 freelist。由于 `cpuid()` 只有在中断关闭时才能安全调用，因此 `kfree()` 需要先使用 `push_off()` 关闭中断，取得 CPU 编号后再操作对应链表：

```c
push_off();
int id = cpuid();
acquire(&kmem[id].lock);
r->next = kmem[id].freelist;
kmem[id].freelist = r;
release(&kmem[id].lock);
pop_off();
```

分配页面时，`kalloc()` 也首先访问当前 CPU 的 freelist。如果本地 freelist 非空，就直接取出头结点并返回，这条路径只需要竞争本 CPU 的锁。当本地 freelist 为空时，再调用偷页逻辑从其他 CPU 获取空闲页。

本实验最终采用的偷页策略是：当前 CPU 缺页时，从其他 CPU 的 freelist 中找一条非空链表，将其整体摘下；第一张页返回给当前这次 `kalloc()`，剩余页面挂到当前 CPU 的 freelist。这个策略的关键是缩短持有其他 CPU 锁的时间。偷页时只需要执行：

```c
r = kmem[i].freelist;
if(r)
  kmem[i].freelist = 0;
```

也就是拿到锁、摘下链表头、清空对方 freelist、释放锁。它不在持锁期间遍历长链表，因此可以显著降低 test-and-set 失败次数。随后再把摘下链表中的第一张页与剩余部分拆开，第一张页给本次分配，剩余部分作为当前 CPU 后续分配的本地缓存。

整体执行逻辑可以概括为：

```text
kfree(pa)
  -> 关闭中断并读取当前 CPU 编号
  -> 将 pa 插入当前 CPU 的 freelist

kalloc()
  -> 关闭中断并读取当前 CPU 编号
  -> 优先从当前 CPU 的 freelist 取页
  -> 若本地为空，则从其他 CPU 的 freelist 偷取
  -> 返回一个 4KB 物理页
```

本任务实际修改文件为 `kernel/kalloc.c`。其中 `kmem` 数据结构被改为每 CPU 数组；`kinit()` 初始化每 CPU 锁；`kfree()` 将释放的物理页放回当前 CPU 的链表；`kalloc()` 本地优先分配，并在缺页时调用偷页函数；新增的偷页函数负责在本地 freelist 为空时从其他 CPU 转移空闲页。

#part("实验中遇到的问题和解决方法")

本任务调试的主要问题出现在 `kalloctest` 的 `test4`。最初虽然已经把全局 `kmem` 拆分为每 CPU freelist，但 `test4` 仍然失败，输出中的 `tot` 明显高于测试允许的阈值。这说明问题已经不是内存分配正确性，而是锁争用仍然过高。

第一次尝试中，偷页函数采用固定批量偷页，例如一次偷 32、64、1024 页。小批量偷页会导致当前 CPU 在压力测试中频繁访问其他 CPU 的 freelist；大批量偷页则会在持有其他 CPU 的 `kmem` 锁时遍历较长链表。两种方式都会导致 `#test-and-set` 次数偏高，只是表现形式不同。尤其当批量过大时，临界区变长，其他 CPU 更容易在 `acquire()` 中自旋。

最终解决方法是将偷页逻辑改为“整体摘下对方 freelist”。这样持有受害 CPU 锁的时间极短，不需要在锁内遍历链表；同时当前 CPU 获得一批本地可用页，后续大量 `kalloc()` 可以在本 CPU freelist 内完成。修改后 `kalloctest` 的 `test1` 和 `test4` 均通过，说明该实现同时满足正确性和低争用要求。

本任务还需要注意 `cpuid()` 的使用位置。`cpuid()` 依赖当前 CPU 状态，若在中断开启时调用，当前进程可能因中断和调度而迁移到其他 CPU，导致得到的 CPU 编号不可靠。因此 `kalloc()` 和 `kfree()` 都在 `push_off()` 和 `pop_off()` 包围范围内读取并使用 CPU 编号。

#part("实验心得")

物理内存分配器任务说明，锁优化的本质不是简单地减少 `acquire()` 调用次数，而是减少多个 CPU 对同一共享状态的争用。原始 xv6 使用一个全局 freelist，所有 CPU 都必须围绕同一个数据结构同步；改成每 CPU freelist 后，大多数分配和释放都变成了本地操作，只有本地资源耗尽时才需要跨 CPU 协调。

本任务也展示了性能测试和正确性测试的区别。内存页没有丢失、`usertests` 能通过，只能说明分配器基本正确；`kalloctest` 中的 test-and-set 统计则进一步检查实现是否真正降低了锁竞争。调试过程中，固定批量偷页虽然在功能上可行，但在压力测试下仍会暴露临界区过长或跨 CPU 偷页过频的问题。最终通过缩短偷页时持锁时间，才达到实验要求。

== Read-write lock (moderate)

#part("实验目的")

本任务要求在 xv6 中实现读写自旋锁。普通 spinlock 只提供互斥语义：只要一个 CPU 持有锁，其他 CPU 无论是读还是写都不能进入临界区。然而在很多内核场景中，共享数据以读取为主，多个读者之间并不会互相破坏状态。例如题目中提到的 `ticks` 变量，多个系统调用读取 `ticks` 时彼此不冲突，真正需要互斥的是读写并发和写写并发。

读写锁的语义可以概括为三条：多个 reader 可以同时持有锁；writer 必须独占锁；当 writer 已经在等待时，新的 reader 不能继续插队。最后一条用于避免 writer starvation。如果读者源源不断进入，写者可能永远等不到 `readers == 0` 的时刻，因此实验要求实现 writer priority。

#part("实验步骤")

本任务主要修改 `kernel/spinlock.h` 和 `kernel/spinlock.c`。`kernel/spinlock.c` 已经提供了读写锁 API 的外层函数：

```c
void read_acquire(struct rwspinlock *rwlk);
void read_release(struct rwspinlock *rwlk);
void write_acquire(struct rwspinlock *rwlk);
void write_release(struct rwspinlock *rwlk);
void initrwlock(struct rwspinlock *rwlk);
```

外层 `read_acquire()`、`write_acquire()` 会调用 `push_off()` 关闭中断，外层 release 函数会调用 `pop_off()` 恢复中断。因此实验只需要实现 inner 函数和读写锁内部状态，不需要在 inner 函数中再次关闭或恢复中断。

在 `kernel/spinlock.h` 中，读写锁结构被改为：

```c
struct rwspinlock {
  uint state;
  uint waiting_writers;
};
```

其中 `state` 同时编码 writer 状态和 reader 数量。实验使用最高位表示是否有 writer 正在持有锁，低 31 位表示当前 reader 数量：

```c
#define RW_WRITER 0x80000000U
#define RW_READERS 0x7fffffffU
```

这种设计的好处是，reader 增加计数和 writer 获得独占状态都围绕同一个原子变量 `state` 完成。reader 只有在 `state` 中没有 writer 位时，才能通过 CAS 将 `state` 从 `s` 改为 `s + 1`；writer 只有在 `state == 0` 时，才能通过 CAS 将 `state` 改为 `RW_WRITER`。这样读写互斥和写写互斥都由同一个原子状态保证，避免多个独立变量之间出现竞态窗口。

`read_acquire_inner()` 的逻辑是：先等待没有 writer 正在持有锁，并且没有 writer 正在等待；随后读取 `state`，尝试通过 CAS 增加 reader 数量。CAS 成功后还需要再次检查 `waiting_writers`，因为可能出现 reader 刚刚增加计数、writer 同时到达并增加等待计数的情况。如果此时发现已有 writer 等待，reader 主动将 `state` 减回去并重新等待，从而保证 writer priority。

`write_acquire_inner()` 的逻辑是：writer 到达后先将 `waiting_writers` 加一，阻止新的 reader 进入；随后不断尝试将 `state` 从 `0` 原子地改为 `RW_WRITER`。只有当没有 reader 且没有其他 writer 时，这个 CAS 才能成功。成功后再将 `waiting_writers` 减一，表示该 writer 已经从等待状态变为持有写锁状态。

释放路径相对直接。`read_release_inner()` 通过 CAS 将 reader 数量减一，并检查不能在 writer 持有状态或 reader 数量为 0 时释放读锁。`write_release_inner()` 只允许将 `state` 从 `RW_WRITER` 改回 `0`，如果释放时状态不匹配，则说明调用顺序错误，直接 `panic`。

读写锁的整体状态转换可以概括为：

```text
无持有者：state = 0
  reader acquire -> state = state + 1
  writer acquire -> state = RW_WRITER

多个 reader：state = reader 数量
  新 reader 在无等待 writer 时可以继续进入
  writer 到达后 waiting_writers 增加，后续 reader 停止进入

writer 持有：state = RW_WRITER
  reader 和其他 writer 均等待
  writer release 后 state 回到 0
```

本任务实际修改文件为 `kernel/spinlock.h` 和 `kernel/spinlock.c`。`spinlock.h` 中重新定义 `struct rwspinlock`；`spinlock.c` 中实现 `initrwlock()`、`read_acquire_inner()`、`read_release_inner()`、`write_acquire_inner()` 和 `write_release_inner()`，并通过 GCC 原子操作完成状态检查和更新。

#part("实验中遇到的问题和解决方法")

本任务调试过程中先后遇到两个典型问题。第一次实现采用内部普通 `spinlock` 保护 `readers`、`writer` 和 `waiting_writers` 三个字段。该版本虽然思路直观，但在 `rwlktest` 中出现超时，测试停在多个锁组合获取的阶段。这说明读写锁内部实现过于依赖普通 spinlock 或等待逻辑没有正确释放内部锁时，容易在嵌套获取不同读写锁时造成长时间等待。

随后尝试使用三个独立原子变量分别表示 `readers`、`writer` 和 `waiting_writers`。这个版本不再超时，但 `rwlktest` 只显示 `3/4 CPUs succeeded`。根据测试代码可以判断，失败 CPU 很可能出现在写锁路径，说明读者计数和写者状态分散在不同变量上时，仍可能存在微小竞态窗口：reader 修改 `readers` 与 writer 修改 `writer` 并不是对同一个状态的一次原子转换，测试在高并发循环中会捕捉到这种边界问题。

最终解决方法是将 reader 数量和 writer 状态合并到单个 `state` 字段。reader 和 writer 都通过 CAS 修改同一个变量，因此不再依赖多个变量之间的组合判断来保证互斥。`waiting_writers` 只用于表达“已有 writer 排队”，并通过 reader acquire 后的复查和回滚保证新 reader 不会插队到等待 writer 前面。修改后，`rwlktest` 中所有 4 个 CPU 均成功，说明读读并发、读写互斥、写写互斥和 writer priority 均满足测试要求。

#part("实验心得")

读写锁任务说明，并发控制中最困难的部分往往不是写出大致逻辑，而是消除微小竞态窗口。用三个字段分别描述 reader、writer 和等待 writer，在概念上很容易理解，但如果这些字段不是作为一个整体被原子更新，就可能在极短时间内出现不一致状态。测试循环执行上百万次后，这类平时难以观察的问题就会暴露出来。

将状态合并为单个 `state` 后，读写锁的核心互斥关系变得更清晰：reader 获取锁就是将 `state` 加一，writer 获取锁就是将 `state` 从 0 改成 writer 标志。两者不能同时成功，因为它们竞争的是同一个原子变量。这种实现方式比多个变量配合判断更接近“把并发条件压缩为一次不可分割的状态转换”。

本任务也加深了对 writer priority 的理解。仅仅保证 writer 独占并不够，如果新 reader 可以不断进入，那么 writer 仍然可能长期无法执行。`waiting_writers` 的作用不是表示锁已经被 writer 持有，而是表达“从现在开始 reader 不应继续插队”。这种设计使已有 reader 能正常退出，同时阻止新的 reader 扩大读者集合，为等待中的 writer 创造进入临界区的机会。

== 实验结果

完成本 Lab 后，在 `lock` 分支运行：

```text
$ make grade
```

最终 `kalloctest`、`rwlktest`、`usertests -q` 和 time 测试均通过，得分为满分。测试结果如下图所示。

#figure(
  image("../assets/lock/grade.png", width: 92%),
  caption: [Lock Lab 的 make grade 测试结果],
)

测试通过表明，每 CPU 物理页空闲链表和偷页机制有效降低了 `kmem` 锁争用；读写自旋锁也正确支持多读者并发、写者独占以及写者优先等待策略。
