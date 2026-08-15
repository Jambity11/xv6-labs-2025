#import "../templates/lab-report.typ": part

= Lab7: Lock

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/lock")[https://github.com/Jambity11/xv6-labs-2025/tree/lock]

前面的实验大多在解决「功能对不对」，这个实验要解决的是另一个问题：功能都正确了，多核机器上却跑不快——所有 CPU 抢同一把锁，哪怕它们操作的是互不相关的数据，也得排队等锁，锁本身成了瓶颈。既然机器有多个核，为什么实际跑起来却像串行？

这个问题的价值在于它逼我们面对一个事实：正确性只是底线，性能同样是要设计的。多核扩展性是内核设计的核心目标之一，而锁的选择和粒度，直接决定了这个目标能不能达到。

初步想法有两层。一是「拆」：把保护所有空闲页的一把大锁，拆成每 CPU 一把小锁，大多数分配和释放变成 CPU 自己的本地操作，只有本地资源空了才跨 CPU 借。二是「分」：对于读多写少的共享数据，让多个读者同时进临界区、写者独占，而不是不分青红皂白一律互斥。

#part("前置知识")

*锁在保护什么。*多核 CPU 会同时执行内核代码，多个核同时改同一个数据结构就会出错。锁的作用是保证「同一时刻只有一个核在临界区里改这份数据」。xv6 的 spinlock 用一条原子的 test-and-set 指令抢锁：抢到了进临界区，抢不到就原地打转（自旋）等。

*怎么度量「锁太挤」。*`kalloctest` 会统计每把锁在 `acquire()` 里 test-and-set 失败（也就是想抢但没抢到）的次数。这个数越高，说明大家越是在同一把锁上挤。本实验的目标不是删锁，而是让这个次数显著降下来。

*原子操作与 CAS。*光用普通的读-改-写，多个核之间会有竞态（读了旧的、改了被覆盖）。所以读写锁的实现要依赖原子的 compare-and-swap（CAS）：只有当变量还是我读到的那个旧值时，才把它改成新值，否则重试。这是无锁并发里最基础的工具。

*去哪查更详细。*《xv6》教材第 6 章「Locking」；xv6 里看 `kernel/spinlock.c`、`kernel/kalloc.c`。关键词：「spinlock test-and-set」「per-CPU freelist」「read-write lock writer starvation」。

== Memory allocator (moderate)

原始 xv6 里，所有 CPU 共用一条空闲页链表和一把 `kmem.lock`。任何一次 `kalloc`/`kfree` 都要抢这把锁。改法很直接：把 `kmem` 变成 `kmem[NCPU]` 数组，每个 CPU 一条链表、一把锁。

释放时 `kfree()` 把页放回当前 CPU 的链表，分配时 `kalloc()` 先从当前 CPU 的链表取；只有当本地空了，才去别的 CPU「偷」。这里有个必须注意的细节：`cpuid()` 只有在中断关闭时调用才可靠（否则进程可能被调度到别的核上，读到的 CPU 号就错了），所以取 CPU 号前要先 `push_off()` 关中断、用完再 `pop_off()`。

真正决定性能的是「怎么偷」。我最开始用「固定批量偷」，比如一次偷 32 或 1024 页，结果 `kalloctest` 的 test4 还是超阈值：偷少了，本地很快又空、频繁跨 CPU；偷多了，持有别的 CPU 锁的时间变长，大家又挤在 acquire 上自旋。最后的做法是*整体摘下对方链表*：拿到锁、把对方 `freelist` 整个摘走（只改一个头指针）、立刻放锁，不在锁内遍历长链表。这样持锁时间极短，本地又一下子有了一批可用页。

```text
kalloc()
  -> push_off() 关中断，读当前 CPU 号
  -> 本地 freelist 非空：直接取一页返回
  -> 本地为空：摘走另一个 CPU 的整个 freelist
  -> 取下第一页给本次分配，其余挂到本地
```

这个任务让我明白，锁优化的本质不是减少 `acquire` 的调用次数，而是减少多个核围绕同一份共享状态的争用。拆成每 CPU 链表后，大多数操作根本不需要跨核协调，争用自然就降下来了。另外它也提醒我区分「正确」和「高效」：页没丢、`usertests` 能过，只说明分配器基本正确；`kalloctest` 的统计才真正考察锁争用是否降下来。

#part("代码解读")

本任务的实现见 #link("https://github.com/Jambity11/xv6-labs-2025/blob/lock/kernel/kalloc.c")[kernel/kalloc.c]。核心代码集中如下。

`kmem` 从单个结构变成 `NCPU` 个的数组：

```c
struct {
  struct spinlock lock;
  struct run *freelist;
} kmem[NCPU];
```

`kinit()` 循环初始化每把锁：

```c
void
kinit()
{
  for(int i = 0; i < NCPU; i++)
    initlock(&kmem[i].lock, "kmem");
  freerange(end, (void*)PHYSTOP);
}
```

`kfree()` 把页放回当前 CPU 的链表：

```c
void
kfree(void *pa)
{
  struct run *r;
  ...
  r = (struct run*)pa;

  push_off();
  int id = cpuid();

  acquire(&kmem[id].lock);
  r->next = kmem[id].freelist;
  kmem[id].freelist = r;
  release(&kmem[id].lock);

  pop_off();
}
```

`kalloc()` 本地优先，空了就偷：

```c
void *
kalloc(void)
{
  struct run *r;

  push_off();
  int id = cpuid();

  acquire(&kmem[id].lock);
  r = kmem[id].freelist;
  if(r)
    kmem[id].freelist = r->next;
  release(&kmem[id].lock);

  if(r == 0)
    r = steal_pages(id);

  pop_off();

  if(r)
    memset((char*)r, 5, PGSIZE);
  return (void*)r;
}
```

`steal_pages()`——整体摘下别的 CPU 的链表：

```c
static struct run*
steal_pages(int id)
{
  struct run *r;
  struct run *rest;

  for(int off = 1; off < NCPU; off++){
    int i = (id + off) % NCPU;

    acquire(&kmem[i].lock);
    r = kmem[i].freelist;
    if(r)
      kmem[i].freelist = 0;
    release(&kmem[i].lock);

    if(r){
      rest = r->next;
      r->next = 0;

      if(rest){
        acquire(&kmem[id].lock);
        kmem[id].freelist = rest;
        release(&kmem[id].lock);
      }

      return r;
    }
  }

  return 0;
}
```

下面逐段解释。

*每 CPU 一个 freelist。*`kmem[NCPU]` 让每个 CPU 有自己独立的锁和链表。`kinit` 循环 `initlock(&kmem[i].lock, "kmem")`——注意锁名都以 `"kmem"` 开头，因为 `statistics` 系统调用按锁名统计争用，评测时靠这个名字汇总所有 per-CPU 锁的争用次数。

*`cpuid` 为什么要 `push_off`。*`cpuid()` 返回当前 CPU 编号，但它只有在中断关闭时才可靠：如果中断开着，进程可能在被调度到别的核上之后才读 `cpuid`，得到的编号就错了。所以 `kalloc`/`kfree` 都用 `push_off()` 关中断、取编号、操作对应链表、再 `pop_off()` 恢复。

*`kalloc` 的本地优先。*先取当前 CPU 的链表头；如果本地空了（`r == 0`），才调 `steal_pages` 去别的 CPU 借。这样绝大多数分配释放都在本核完成，只竞争本核的锁。

*`steal_pages` 的「整体摘下」。*这是降低争用的关键。它遍历其他 CPU（`(id + off) % NCPU` 让每个 CPU 从自己的下一个核开始找），找到非空链表后，在持锁期间只做一件事：`r = kmem[i].freelist; kmem[i].freelist = 0;`——把整条链表摘下、清空对方指针，立刻放锁。然后摘下链表的头节点 `r` 返回给本次 `kalloc`，剩下的 `rest` 挂到自己的链表上。持锁时间极短（不在锁内遍历长链表），所以别的核在 `acquire` 上自旋的时间也短——这正是 `kalloctest` 的 test-and-set 次数能降下来的原因。

#part("自测与解答")

*问：`kalloc`/`kfree` 里取 CPU 编号前为什么要 `push_off()` 关中断？*

*答：*`cpuid()` 依赖「当前正在哪个核上执行」。如果中断开着，进程可能在读 `cpuid` 前后被调度到别的核，得到的编号和实际操作的链表就对不上了。`push_off` 关中断后，当前核上不会发生调度，`cpuid` 才可靠。

*问：`steal_pages` 为什么「整体摘下」整条链表，而不是固定偷几十页？*

*答：*固定批量偷有两个问题：偷少了，本地很快又空、频繁跨核；偷多了，在持锁期间遍历长链表、持锁时间变长，别的核挤在 `acquire` 上自旋。整体摘下只在锁内改一个头指针，持锁时间极短，同时一次拿到一整批可用页，兼顾了「少跨核」和「短临界区」。

*问：为什么所有 per-CPU 锁的名字都叫 `"kmem"`？*

*答：*`statistics` 系统调用按锁名统计争用次数，评测要的是「kmem 相关锁的总争用」。拆成 per-CPU 后如果每把锁起不同名字，统计就散了；统一叫 `"kmem"` 才能把它们汇总到一起和阈值比较。

== Read-write lock (moderate)

普通 spinlock 是一刀切：不管读还是写，进临界区都得独占。但很多数据读多写少——比如 `ticks`，多个进程同时读它毫无问题，真正要互斥的只是「读写之间」和「写写之间」。读写锁就是为此设计的：多个读者可以同时持有，写者独占；而且当有写者在排队时，新的读者不能再插队（否则写者可能被源源不断的读者饿死）。

实现上，我最开始用三个独立变量分别表示读者数、写者、等待写者，直观但出了两种问题：用内部普通 spinlock 保护时 `rwlktest` 超时；改成三个原子变量后，测试只剩 `3/4 CPUs succeeded`。原因都一样——读者数和写者状态不在同一个变量上，它们之间没有一个「原子的一次转换」，高并发下总会撞出竞态窗口。

最后的解法是把读者数和写者状态*合并进一个 `state` 整数*：最高位是「写者持有」标志，低 31 位是读者数。读者加锁就是把 `state` 加一（CAS 保证只有在没写者时才能加）；写者加锁就是把 `state` 从 0 改成写者标志。二者竞争的是同一个原子变量，所以读写互斥、写写互斥都被「一次 CAS」天然保证。`waiting_writers` 单独计数，用来表达「已经有写者排队了」，读者拿到锁后还要回头检查它，若发现写者已在等，就主动退回去，把机会让给写者——这就是写者优先。

```text
无持有者：state = 0
  reader acquire -> state + 1
  writer acquire -> state = 写者标志（仅当 state == 0）

多个 reader：state = 读者数
  无等待写者时新 reader 可继续进入
  写者到达后 waiting_writers 增，后续 reader 停

写者持有：state = 写者标志
  其他 reader/writer 均等待，写者释放后 state 归 0
```

这个任务给我最深的印象是：并发里最难的往往不是写出「大致正确」的逻辑，而是消灭那些平时根本看不见、跑上百万次才会撞出来的微小竞态窗口。把三个字段压成单个 `state`，本质上是把「并发条件」压缩成「一次不可分割的状态转换」，比多个变量配合判断要可靠得多。

#part("代码解读")

本任务的实现见 #link("https://github.com/Jambity11/xv6-labs-2025/blob/lock/kernel/spinlock.h")[kernel/spinlock.h] 和 #link("https://github.com/Jambity11/xv6-labs-2025/blob/lock/kernel/spinlock.c")[kernel/spinlock.c]。核心代码集中如下。

`spinlock.h` 里的结构：

```c
struct rwspinlock {
  uint state;
  uint waiting_writers;
};
```

`spinlock.c` 里的宏和四个 inner 函数：

```c
#define RW_WRITER 0x80000000U
#define RW_READERS 0x7fffffffU

static void
read_acquire_inner(struct rwspinlock *rwlk)
{
  for(;;){
    while(__atomic_load_n(&rwlk->waiting_writers, __ATOMIC_SEQ_CST) ||
          (__atomic_load_n(&rwlk->state, __ATOMIC_SEQ_CST) & RW_WRITER))
      ;

    uint s = __atomic_load_n(&rwlk->state, __ATOMIC_SEQ_CST);

    if((s & RW_WRITER) == 0){
      if(__sync_bool_compare_and_swap(&rwlk->state, s, s + 1)){
        if(__atomic_load_n(&rwlk->waiting_writers, __ATOMIC_SEQ_CST) == 0)
          return;

        __sync_fetch_and_sub(&rwlk->state, 1);
      }
    }
  }
}

static void
read_release_inner(struct rwspinlock *rwlk)
{
  for(;;){
    uint s = __atomic_load_n(&rwlk->state, __ATOMIC_SEQ_CST);

    if((s & RW_WRITER) || (s & RW_READERS) == 0)
      panic("read_release");

    if(__sync_bool_compare_and_swap(&rwlk->state, s, s - 1))
      return;
  }
}

static void
write_acquire_inner(struct rwspinlock *rwlk)
{
  __sync_fetch_and_add(&rwlk->waiting_writers, 1);

  while(__sync_bool_compare_and_swap(&rwlk->state, 0, RW_WRITER) == 0)
    ;

  __sync_fetch_and_sub(&rwlk->waiting_writers, 1);
}

static void
write_release_inner(struct rwspinlock *rwlk)
{
  if(__sync_bool_compare_and_swap(&rwlk->state, RW_WRITER, 0) == 0)
    panic("write_release");
}
```

下面逐段解释。

*单 `state` 编码读写。*`state` 一个 32 位整数同时表达两种状态：最高位（`RW_WRITER`）是「写者持有」标志，低 31 位（`RW_READERS`）是读者数。为什么要把读者数和写者状态压进一个变量？因为只有它们是同一个变量，读写互斥、写写互斥才能用「一次 CAS」保证——读者加锁就是 `state` 从 `s` 变 `s+1`，写者加锁就是 `state` 从 `0` 变 `RW_WRITER`，两者竞争同一个原子变量，不可能同时成功。如果拆成两个独立变量，读者改 `readers` 和写者改 `writer` 不是一次原子转换，中间就存在竞态窗口。

*`read_acquire_inner` 的两段等待。*读者先自旋等「没有写者持有、也没有写者在等待」；满足后读 `state`，用 CAS 尝试把 `state` 加 1。加成功后还要回头检查 `waiting_writers`：如果加的过程中恰好有写者到达并加了等待计数，读者就主动把 `state` 减回去、重新等待——这就是「写者优先」：不能让新读者插队到等待的写者前面，否则写者会被源源不断的读者饿死。

*`write_acquire_inner`。*写者先 `waiting_writers` 加一（告诉后面的读者「别进来了」），然后不断 CAS 尝试把 `state` 从 0 改成 `RW_WRITER`——只有当没有读者也没有其他写者时这个 CAS 才成功。成功后把 `waiting_writers` 减一（自己从「等待」变成「持有」）。

*释放。*读者释放就是 `state` 减一，但先检查「没有写者持有、读者数不为 0」，否则 panic——这是对调用顺序的校验。写者释放就是把 `state` 从 `RW_WRITER` 改回 0，改不回去说明调用顺序错了，panic。

*外层函数。*`read_acquire`/`write_acquire` 先 `push_off()` 关中断再调 inner，release 后 `pop_off()`。这是 spinlock 的标准做法：关中断是为了避免死锁——如果一个核持锁时被中断、中断处理程序又抢同一把锁，就自己锁死自己了。

#part("自测与解答")

*问：为什么用单个 `state` 而不是三个独立变量分别表示读者、写者、等待写者？*

*答：*三个独立变量之间没有「一次原子转换」：读者改 `readers`、写者改 `writer` 是两步，高并发下会在两步之间撞出竞态窗口。合并成单个 `state` 后，读者加锁、写者加锁竞争的是同一个变量、各靠一次 CAS 完成，互斥关系天然成立。测试跑上百万次，这种微小竞态窗口会被放大到可见。

*问：`waiting_writers` 的作用是什么？为什么读者 CAS 成功后还要回头检查它？*

*答：*`waiting_writers` 表达「已经有写者在排队」。读者 CAS 成功的瞬间，可能恰有写者到达、把等待计数加一；如果不回头检查，这个读者就插队到写者前面了。所以读者加锁成功后要再看一眼，若发现已有写者等待，就主动退回去、把机会让给写者——这是「写者优先」的实现。

*问：读写锁为什么也要 `push_off()` 关中断？*

*答：*和普通 spinlock 同理。如果一个核持锁时发生中断、中断处理程序又来抢同一把锁，就会死锁。关中断后当前核不会在临界区内被中断打断，锁的持有者一定能很快释放，别的核自旋等也不会太久。

== 实验结果

完成本 Lab 后，在 `lock` 分支运行：

```text
$ make grade
```

`kalloctest`、`rwlktest`、`usertests -q` 和 time 均通过，满分。

#figure(
  image("../assets/lock/grade.png", width: 92%),
  caption: [Lock Lab 的 make grade 测试结果],
)

测试通过说明：每 CPU 空闲链表和「整体摘下」的偷页策略有效降低了 `kmem` 锁争用；读写锁也正确实现了多读者并发、写者独占和写者优先。两个任务一起说明了一个道理：锁既要保证正确，也要尽量缩小不必要的共享范围。
