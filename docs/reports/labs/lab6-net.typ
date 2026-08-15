#import "../templates/lab-report.typ": part

= Lab6: Networking

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/net")[https://github.com/Jambity11/xv6-labs-2025/tree/net]

xv6 跑在 QEMU 模拟出来的一台机器里，可它却能 ping 通宿主机、发 DNS 请求。这引出一个问题：一个操作系统，是怎么和「外面的设备」打交道的？它靠什么把数据送出去、又怎么知道有数据来了？

这个问题代表的是内核里一大类工作——设备驱动和网络协议栈。前面的实验都在管 CPU 和内存，而这次 xv6 要操作一块网卡，还要和宿主机上跑着的网络进程对话。理解这条链路，是理解「操作系统怎么和外部世界协作」的关键。

初步想法是先分层。网卡其实很「笨」：它只认一串串字节（完整的 Ethernet frame），完全不理解里面装的是 UDP 还是 DNS。所以自然的做法是两层各司其职——设备驱动层负责「把整块 frame 塞给网卡 / 从网卡取回来」，协议层负责「解析 IP、UDP 头，按端口分发」。xv6 已经提供了协议层的大部分代码，本实验要补的，就是这两层之间、以及设备层内部缺的那几段。

#part("前置知识")

*数据长什么样。*网络数据一层包一层：最外层是 Ethernet frame（含 MAC 地址、类型），里面是 IP packet（含源/目的 IP、协议号），再里面是 UDP datagram（含源/目的端口、载荷）。网卡只收发最外层的 frame；内核逐层拆到 UDP 后，才能知道「这个包该交给哪个进程」。

*驱动和设备怎么握手：描述符环。*E1000 网卡通过 DMA 直接读写内存里的描述符环（一组环形数组项），每个 descriptor 记录一个 buffer 的地址、长度和状态。发送时驱动填好 descriptor、移动 tail 寄存器通知硬件；接收时硬件把数据写进 descriptor 指向的 buffer、置好完成位并触发中断。这里的「完成位」（`DD`）不是普通变量，而是驱动和设备之间的同步协议——没看到它置位，就不能碰这个槽位。

*接收方怎么等包：队列与睡眠。*用户进程 `bind(port)` 表示要收这个端口的包；包到了，如果有进程在 `recv()` 里睡等就唤醒它，否则先放进一个有限队列，等它稍后来取。`sleep`/`wakeup` 配合锁，是内核里「生产者放包、消费者取包」的标准姿势。

*去哪查更详细。*《xv6》教材第 5 章「Interrupts and device drivers」；E1000 的寄存器定义看 `kernel/e1000.c` 头部的宏，协议结构看 `kernel/net.h`。关键词：「E1000 descriptor ring」「DMA descriptor DD bit」「xv6 net.c UDP」。

== Part One: NIC (moderate)

第一个任务补设备驱动层：完成 `kernel/e1000.c` 里的 `e1000_transmit()` 和 `e1000_recv()`。上层代码已经能构造、能解析 frame，缺的只是「frame 和网卡之间的交接」。

发送方向有个容易被忽略、却决定成败的点：buffer 的生命周期。驱动把 buffer 地址写进 descriptor、通知硬件后，网卡是异步地、通过 DMA 去读这块内存的，不会等你。所以函数返回后绝不能立刻释放 buffer——否则网卡随后读到的可能已经是别人重写的物理页。正确做法是给每个发送槽位配一个 `tx_bufs` 数组记着旧 buffer，等下次复用同一个槽位、看到 `DD` 位置位（说明上一次发送完成了），才释放旧的。

接收方向则是一个「换页」循环：从 `RDT` 的下一个槽位开始扫，看到 `DD` 置位就把 buffer 和长度取出来，*立刻*给这个槽位补一块新的空页、清状态、更新 `RDT`，再把取出的 buffer 交给上层 `net_rx()`。

还有一个锁的细节值得一提：不要在持有 `e1000_lock` 的时候调用 `net_rx()`。因为 `net_rx()` 收到 ARP 请求时可能马上调 `e1000_transmit()` 发回复，而发送路径也要拿同一把锁——在中断处理里就会自己锁死自己。所以接收函数只负责更新 descriptor，把「交给上层」这件事放到锁外。

这个任务让我体会到，设备驱动的代码通常不长，难的是精确遵守硬件约定：地址、长度、`DD` 位、`EOP`/`RS` 命令位、tail 寄存器，任何一个更新顺序错了，都会表现为丢包、复用错误、死锁或泄漏。驱动层也不该去理解 UDP 的语义——它只关心「完整的 frame 在哪、多长、发完/收完没有」。

#part("代码解读")

本任务的实现见 #link("https://github.com/Jambity11/xv6-labs-2025/blob/net/kernel/e1000.c")[kernel/e1000.c]。核心代码集中如下。

发送描述符环和配套的 buffer 记录数组：

```c
#define TX_RING_SIZE 16
static struct tx_desc tx_ring[TX_RING_SIZE] __attribute__((aligned(16)));
static char *tx_bufs[TX_RING_SIZE];
```

`e1000_transmit()`：

```c
e1000_transmit(char *buf, int len)
{
  int idx;
  struct tx_desc *desc;

  acquire(&e1000_lock);

  idx = regs[E1000_TDT];
  desc = &tx_ring[idx];

  if((desc->status & E1000_TXD_STAT_DD) == 0){
    release(&e1000_lock);
    return -1;
  }

  if(tx_bufs[idx]){
    kfree(tx_bufs[idx]);
    tx_bufs[idx] = 0;
  }

  desc->addr = (uint64)buf;
  desc->length = len;
  desc->cso = 0;
  desc->cmd = E1000_TXD_CMD_EOP | E1000_TXD_CMD_RS;
  desc->status = 0;
  desc->css = 0;
  desc->special = 0;

  tx_bufs[idx] = buf;

  regs[E1000_TDT] = (idx + 1) % TX_RING_SIZE;

  release(&e1000_lock);

  return 0;
}
```

`e1000_recv()`：

```c
e1000_recv(void)
{
  int idx;

  idx = (regs[E1000_RDT] + 1) % RX_RING_SIZE;

  while(rx_ring[idx].status & E1000_RXD_STAT_DD){
    char *buf = (char *)rx_ring[idx].addr;
    int len = rx_ring[idx].length;

    char *newbuf = kalloc();
    if(newbuf == 0)
      break;

    rx_ring[idx].addr = (uint64)newbuf;
    rx_ring[idx].status = 0;

    regs[E1000_RDT] = idx;

    net_rx(buf, len);

    idx = (idx + 1) % RX_RING_SIZE;
  }
}
```

下面逐段解释。

*描述符环和 head/tail。*E1000 网卡通过 DMA 直接读写内存里的描述符环。发送方向有两个寄存器：`E1000_TDT`（tail）是「操作系统放新任务的位置」，head 是「网卡正在处理的位置」。驱动要发送时，读 `TDT` 找到下一个可用槽位，填好 descriptor，把 `TDT` 后移一格通知硬件。

*发送：先确认旧任务完成。*`if((desc->status & E1000_TXD_STAT_DD) == 0) return -1;`——`DD` 位是「descriptor done」标志，网卡发送完成后置位。如果没置位，说明这个槽位上一次的发送还没完成，不能再覆盖，返回 -1 让调用者释放 buffer。

*发送：buffer 的生命周期。*`if(tx_bufs[idx]) kfree(tx_bufs[idx]);`——如果这个槽位上次挂过一个 buffer，而现在已经 `DD`（发送完成），就可以安全释放它了。为什么不能发送完立刻释放？因为网卡是异步通过 DMA 读内存的，驱动更新 tail 后网卡才去读，过早释放会让网卡读到别人重写的物理页。所以用 `tx_bufs` 数组把 buffer 的生命周期延长到「下次复用这个槽位、看到 DD 为止」。

*发送：填 descriptor。*`cmd = E1000_TXD_CMD_EOP | E1000_TXD_CMD_RS`——`EOP` 表示这是完整包的结尾，`RS` 要求设备发送完成后回写状态（即置 DD）。写完 descriptor、记录 `tx_bufs`、后移 `TDT`。

*接收：换页循环。*从 `(RDT + 1) % RX_RING_SIZE` 开始扫——`RDT` 是「软件已经交还给硬件的最后一个 descriptor」，下一项才可能是新收到的包。只要 `DD` 置位，就把 buffer 取出来、立刻给这个槽位补一块新的空页（`kalloc` + 更新 `addr`）、清 `status`、更新 `RDT`，再把旧 buffer 交给 `net_rx`。

*接收：不在持锁时调 net_rx。*`e1000_recv` 本身没持 `e1000_lock`，因为 `net_rx` 收到 ARP 请求时可能调 `e1000_transmit` 发回复，而发送路径要拿同一把锁——如果接收持锁调上层，就会在中断处理里自己锁死自己。

#part("自测与解答")

*问：发送 buffer 为什么不能发送完立刻释放？*

*答：*网卡是通过 DMA 异步读内存的，驱动更新 tail 之后网卡才去读 descriptor 指向的 buffer。如果驱动在函数返回后就 `kfree`，那块物理页可能被分配给别的用途，网卡随后读到的内容就不是原来的 frame 了。所以要用 `tx_bufs` 把 buffer 留到「下次复用槽位、看到 DD」才释放。

*问：`DD` 位的作用是什么？*

*答：*`DD`（descriptor done）是设备和驱动之间的同步协议。发送方向，没看到 `DD` 就覆盖 descriptor 会破坏未完成的发送；接收方向，没看到 `DD` 就取 buffer 会把空 buffer 当成有效包交给上层。它告诉软件「这个槽位现在的状态能不能被软件重新使用」。

*问：接收路径为什么不持 `e1000_lock` 调 `net_rx`？*

*答：*`net_rx` 收到 ARP 请求时可能立即调 `e1000_transmit` 发回复，而发送路径要拿 `e1000_lock`。如果接收函数持锁调用 `net_rx`，就会在同一个中断处理里再次申请同一把锁，死锁。所以接收只负责更新 descriptor，把「交给上层」放到锁外。

== Part Two: UDP Receive (moderate)

第二个任务补协议层：在 `kernel/net.c` 里实现 UDP 接收。`net_rx()` 已经按 Ethernet 类型把 IP 包交给 `ip_rx()`，我们要做的是解析 IP/UDP 头、按目的端口入队、并让用户进程用 `recv()` 取走。

最核心的数据结构是按端口分的队列。每个已绑定端口一个队列，队列节点存「还没被取走的包」：payload、长度、源 IP、源端口。收到包时若对应端口没人等，就入队并 `wakeup` 睡在队列上的进程；用户 `recv()` 时队列为空就 `sleep`，被唤醒后取队头，用 `copyout()` 把源地址、源端口、payload 写回用户空间。

这里有几个「正确性藏在边界里」的点。一是队列要有上限：如果每个包都无限入队，某个端口长时间不读就会吃光物理页，`ping3` 和最终的 `free` 测试会暴露它。二是阻塞的 `recv()` 要能被 `kill` 掉：睡等循环里得检查 `killed(p)`，否则测试里用来统计队列的子进程会退不出来。三是 `sleep` 和 `netlock` 的配合：`sleep` 会在入睡时释放锁、醒来再拿回，所以接收路径不会因为有人睡等而卡住后续入队。

分层思想在这里体现得最清楚：网卡给了一串字节，内核要逐层解释 Ethernet、IP、UDP 头，最后按 UDP 目的端口把 payload 放进对应队列。用户看到的只是 `bind()` 和 `recv()` 两个接口，背后却是中断、协议解析、队列保护、阻塞唤醒一起在配合。沿着「设备中断 → 驱动取包 → 协议解析 → 端口排队 → 用户取走」这条数据流读代码，比漫无目的地翻文件要快得多。

#part("代码解读")

本任务的实现见 #link("https://github.com/Jambity11/xv6-labs-2025/blob/net/kernel/net.c")[kernel/net.c]。核心代码集中如下。

`ip_rx()` 的解析和入队（核心部分，前面省略了长度、IP 版本、协议号等一系列合法性检查）：

```c
ip_rx(char *buf, int len)
{
  ...
  // 一系列合法性检查：长度、IP 版本、协议号、头长度
  if(ip->ip_p != IPPROTO_UDP){
    kfree(buf);
    return;
  }
  ...
  udp = (struct udp *)((char *)ip + iphdrlen);
  ...
  payload_len = udplen - sizeof(struct udp);
  payload = (char *)(udp + 1);
  dport = ntohs(udp->dport);

  pkt = (struct udp_packet *)kalloc();
  ...
  memmove(buf, payload, payload_len);

  pkt->data = buf;
  pkt->len = payload_len;
  pkt->src = ntohl(ip->ip_src);
  pkt->sport = ntohs(udp->sport);
  pkt->next = 0;

  acquire(&netlock);

  q = find_queue(dport);
  if(q == 0 || q->count >= UDP_QUEUE_LIMIT){
    release(&netlock);
    free_packet(pkt);
    return;
  }

  if(q->tail)
    q->tail->next = pkt;
  else
    q->head = pkt;
  q->tail = pkt;
  q->count++;

  wakeup(q);

  release(&netlock);
}
```

`sys_recv()` 的取包（核心部分）：

```c
sys_recv(void)
{
  ...
  acquire(&netlock);

  q = find_queue((uint16)dport);
  if(q == 0){
    release(&netlock);
    return -1;
  }

  while(q->head == 0){
    if(killed(p)){
      release(&netlock);
      return -1;
    }
    sleep(q, &netlock);
  }

  pkt = q->head;
  q->head = pkt->next;
  if(q->head == 0)
    q->tail = 0;
  q->count--;

  release(&netlock);

  n = pkt->len;
  if(n > maxlen)
    n = maxlen;

  if(copyout(p->pagetable, srcaddr, (char *)&pkt->src, sizeof(pkt->src)) < 0 ||
     copyout(p->pagetable, sportaddr, (char *)&pkt->sport, sizeof(pkt->sport)) < 0 ||
     copyout(p->pagetable, bufaddr, pkt->data, n) < 0){
    free_packet(pkt);
    return -1;
  }

  free_packet(pkt);
  return n;
}
```

下面逐段解释。

*逐层解析。*`buf` 进来时是完整的 Ethernet frame，`ip_rx` 先把 `buf` 强转成 `struct eth *`、再 `(struct ip *)(eth + 1)` 拿到 IP 头、再 `(struct udp *)((char *)ip + iphdrlen)` 拿到 UDP 头。这一串指针运算就是「逐层剥头」：每剥一层，指针往后跳一个头的大小。剥到 UDP 后拿到目的端口 `dport`、源端口、源 IP、payload。

*入队。*找到 `dport` 对应的队列（没绑定或队列满了就丢弃并释放），把 `pkt` 挂到队尾，`count++`，然后 `wakeup(q)` 唤醒睡在这个队列上的 `recv` 进程。这里 `memmove(buf, payload, payload_len)` 把 payload 挪到 buffer 开头，方便后面 `copyout` 时直接拷贝。

*`sys_recv` 的睡眠与取包。*拿 `dport` 找队列，队列为空就 `while(q->head == 0) sleep(q, &netlock)` 睡等。`sleep` 会在入睡时释放 `netlock`、被唤醒后再拿回，所以接收路径不会因为有人睡等而卡住后续入队。睡等循环里还要检查 `killed(p)`——否则被 `kill` 的进程退不出来。取到包后出队、`count--`、释放锁，再用 `copyout` 把源 IP、源端口、payload 拷到用户地址空间，最后释放 packet。

*队列上限和内存生命周期。*`UDP_QUEUE_LIMIT` 限制每个端口最多排多少包，满了就丢——否则某个端口长时间不读会吃光物理页。收到但没人取的包要暂存，队列满或端口没绑定时必须释放，`unbind`/退出时也要清理，否则功能测试能过、内存泄漏测试会暴露。

#part("自测与解答")

*问：为什么每个端口的队列要有上限？*

*答：*如果每个收到的 UDP 包都无限入队，某个端口长时间不读就会一直吃物理页，直到内存耗尽，最终在 `free` 测试里暴露内存泄漏。设上限、满了就丢，才能保证「接收但无人消费」的情况下内存有界。

*问：`sys_recv` 里 `sleep` 和 `netlock` 是怎么配合的，为什么睡等不会卡住后续入队？*

*答：*`sleep(q, &netlock)` 会在入睡时自动释放 `netlock`、被唤醒后再重新获取。所以一个进程睡在空队列上时，它不持有锁，`ip_rx` 仍能拿到锁、入队、`wakeup` 唤醒它。如果睡等时不放锁，接收路径就被卡死了。

*问：`ip_rx` 里 `memmove(buf, payload, payload_len)` 把 payload 挪到 buffer 开头，是为了什么？*

*答：*`buf` 原来是完整的 Ethernet frame，payload 在中间、前面是各层头。把 payload 挪到开头后，`sys_recv` 用 `copyout` 拷贝 `pkt->data` 时，拷的就是干净的 payload，而不是带着一堆网络头的整包——这正好符合用户接口的期望：`recv` 返回的是 UDP payload。

== 实验结果

完成本 Lab 后，在 `net` 分支运行（评分脚本会在宿主机启动 `nettest.py grade`，同时在 xv6 内跑 `nettest grade`）：

```text
$ make grade
```

`txone`、`arp_rx`、`ip_rx`、`ping0`、`ping1`、`ping2`、`ping3`、`dns`、`free` 和 time 均通过，满分。

#figure(
  image("../assets/net/grade.png", width: 92%),
  caption: [Networking Lab 的 make grade 测试结果],
)

测试通过说明：E1000 收发描述符环、ARP/IP/UDP 分发、UDP 端口队列、阻塞接收和网络 buffer 释放这些关键路径都符合要求。回头再看，整个实验补的其实是「frame 从网卡到协议层、再从协议层到用户进程」这条流水线上缺的几节。
