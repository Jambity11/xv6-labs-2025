#import "../templates/lab-report.typ": part

= Lab6: Networking

对应源码分支：#link("https://github.com/JambitX11/xv6-labs-2025/tree/net")[https://github.com/JambitX11/xv6-labs-2025/tree/net]

本实验实现 xv6 的网络通信功能。相比前面的系统调用、页表、trap 和 COW 实验，Networking Lab 面对的是另一类内核问题：内核如何与外部设备协作。课堂上的操作系统概念通常会讲“设备驱动”“中断”“DMA”“网络协议栈”，但进入 xv6 代码后，真正困难的是判断这些概念分别落在哪个文件、哪条调用路径和哪组数据结构上。

题目本身分为两个任务点。第一部分是 NIC，即 Network Interface Card，要求完成 E1000 网卡驱动的发送和接收函数。此时 xv6 只需要把完整 Ethernet frame 交给网卡，或从网卡取回完整 frame；驱动不需要理解 UDP 载荷内容。第二部分是 UDP Receive，要求在 `kernel/net.c` 中接收 UDP 包、按目的端口排队，并允许用户进程通过 `recv()` 读取。二者合起来构成一条完整路径：

```text
宿主机或用户程序产生 UDP 数据
  -> Ethernet/IP/UDP packet
  -> E1000 描述符环
  -> xv6 网络栈
  -> 按 UDP 目的端口入队
  -> 用户进程 recv() 取走 payload
```

因此，本实验不是从零实现完整 TCP/IP 协议栈，而是在 xv6 已提供的简化网络协议代码和 QEMU 模拟网卡之间补上关键连接。做题时应先区分“设备驱动层”和“协议/用户接口层”，再分别沿发送和接收数据流定位代码。

== Part One: NIC (moderate)

#part("实验目的")

本任务要求完成 `kernel/e1000.c` 中的 `e1000_transmit()` 和 `e1000_recv()`，使 xv6 能够通过 QEMU 模拟的 Intel E1000 网卡发送和接收 packet。QEMU 为 xv6 提供了一个虚拟局域网环境，xv6 的 IP 地址为 `10.0.2.15`，宿主机地址为 `10.0.2.2`。在这一部分中，上层网络代码已经能够构造或处理 Ethernet frame，实验需要补齐的是 frame 与 E1000 设备之间的交接。

E1000 驱动的核心不是逐字节读写网络数据，而是操作描述符环。描述符环是一组环形数组项，每个 descriptor 描述一个 packet buffer 的地址、长度和状态。发送方向上，驱动把待发送 buffer 写入发送描述符，并移动 `E1000_TDT` 通知硬件；接收方向上，硬件通过 DMA 把数据写入接收描述符指向的 buffer，再设置完成位并触发中断。

从题目到代码定位，可以沿着以下路径理解：

```text
发送 packet
  -> kernel/net.c 构造 Ethernet frame
  -> e1000_transmit(buf, len)
  -> tx_ring 和 E1000_TDT

接收 packet
  -> E1000 触发中断
  -> e1000_intr()
  -> e1000_recv()
  -> rx_ring 和 net_rx(buf, len)
```

#part("实验步骤")

首先阅读 `kernel/e1000.c` 中已有的 `e1000_init()`。初始化代码已经完成设备复位、发送环和接收环的配置、MAC 地址过滤、中断开启等工作，并设置了两个关键数组：`tx_ring` 和 `rx_ring`。这说明本任务不需要重新设计设备初始化流程，而是要在已有 ring 的基础上补齐运行时收发逻辑。

发送路径中，为每个发送 descriptor 增加 `tx_bufs` 记录数组，用来保存该 descriptor 当前挂着的内核 buffer。`e1000_transmit()` 先读取 `E1000_TDT`，找到当前软件准备使用的发送槽位，然后检查该 descriptor 的 `E1000_TXD_STAT_DD` 位。如果 `DD` 位没有设置，说明网卡尚未完成该槽位上一次发送，函数返回 `-1`，由调用者释放本次 buffer。若 `DD` 位已经设置，并且 `tx_bufs` 中保存了旧 buffer，则说明旧 packet 已经被网卡读取并发送完成，可以安全释放。

随后，发送函数把新 buffer 的地址写入 descriptor 的 `addr` 字段，把 frame 长度写入 `length` 字段，并设置 `E1000_TXD_CMD_EOP | E1000_TXD_CMD_RS`。`EOP` 表示这是一个完整 packet 的结尾，`RS` 要求设备发送完成后回写状态位。写入新 descriptor 前需要清空旧 status，最后将 `E1000_TDT` 向后移动一格，通知硬件有新的发送任务。

这里不能在 `e1000_transmit()` 返回成功后立即释放新 buffer。因为 E1000 通过 DMA 异步读取内存，驱动更新 tail 之后，设备才会去读 descriptor 指向的内存。如果过早释放，物理页可能被分配给其他用途，网卡随后读到的内容就不再是原来的 packet。本实验通过 `tx_bufs` 把 buffer 生命周期延长到设备报告 descriptor done 之后。

接收路径中，`e1000_recv()` 从 `(E1000_RDT + 1) % RX_RING_SIZE` 开始检查。`RDT` 表示软件已经交还给硬件的最后一个 descriptor，因此下一项才可能是新收到的 packet。只要当前 descriptor 的 `E1000_RXD_STAT_DD` 位被设置，就说明网卡已经把一个 packet 写入该 descriptor 指向的 buffer。驱动取出该 buffer 和长度，立即为同一 descriptor 分配新的空页作为后续接收缓冲区，清除 status，更新 `E1000_RDT`，再把旧 buffer 交给 `net_rx(buf, len)`。

接收函数特别注意不在持有 `e1000_lock` 时调用 `net_rx()`。`net_rx()` 如果收到 ARP 请求，可能调用 `arp_rx()` 构造 ARP reply，而 `arp_rx()` 会再次进入 `e1000_transmit()`。若接收路径持锁调用上层网络代码，就可能在同一个中断处理过程中再次申请发送锁，导致死锁。因此本实验仅在发送路径保护发送 descriptor ring，接收路径在交给上层前完成 descriptor 更新。

本部分实际修改 `kernel/e1000.c`。新增的 `tx_bufs` 数组用于记录发送 buffer；`e1000_transmit()` 实现发送 descriptor 填写、发送完成检查、旧 buffer 释放和 tail 更新；`e1000_recv()` 实现接收 descriptor 扫描、buffer 替换、status 清理、tail 更新以及向 `net_rx()` 交付 packet。

#part("实验中遇到的问题和解决方法")

本部分的第一个难点是理解 descriptor 的状态位含义。`DD` 不是普通的软件标志，而是设备和驱动之间的同步协议。发送时，如果没有检查 `E1000_TXD_STAT_DD` 就覆盖 descriptor，可能破坏尚未完成的发送；接收时，如果没有检查 `E1000_RXD_STAT_DD` 就取 buffer，可能把空 buffer 当成有效 packet 交给上层。

第二个问题是发送 buffer 的释放时机。`kernel/net.c` 中 `sys_send()` 分配的 buffer 被写入发送 descriptor 后，网卡并不会同步完成发送，因此不能立即释放。解决方法是在 `tx_bufs` 中保存每个 descriptor 的旧 buffer，并在下次复用同一 descriptor 且看到 `DD` 位时释放，从而保证设备 DMA 读取期间 buffer 仍然有效。

第三个问题是接收路径的锁使用。若在 `e1000_recv()` 中持有 `e1000_lock` 调用 `net_rx()`，收到 ARP 请求时 `arp_rx()` 可能立即调用 `e1000_transmit()` 发送回复，从而再次申请 `e1000_lock`。解决方法是让接收函数只负责更新接收 descriptor，并在不持发送锁的情况下调用上层网络处理函数。

#part("实验心得")

NIC 部分展示了设备驱动开发的基本特点：代码本身并不长，但必须准确遵守硬件约定。descriptor 的地址字段、长度字段、`DD` 位、`EOP` 和 `RS` 命令位、tail 寄存器都不是普通变量，而是内核和设备之间共享的协议。任何一个状态更新顺序错误，都可能表现为丢包、重复使用 buffer、死锁或内存泄漏。

本部分也说明，驱动层并不负责理解 UDP 或 DNS 的语义。它只关心完整 Ethernet frame 在哪块内存、长度是多少、设备是否已经发送或接收完成。把驱动层职责限定清楚后，`kernel/e1000.c` 的修改就集中在描述符环和 buffer 生命周期上。

== Part Two: UDP Receive (moderate)

#part("实验目的")

本任务要求在 `kernel/net.c` 中实现 UDP 接收。UDP 允许不同主机上的进程通过 IP 地址和端口号交换单个 datagram。一个 UDP packet 包含源端口和目的端口；接收端内核需要根据目的端口判断该 packet 应交给哪个用户进程。题目已经提供了构造并发送 UDP packet 的大部分代码，第二部分要补齐的是：收到 IP packet 后解析 UDP 头，将 payload 按目的端口排队，并让用户进程通过 `recv()` 读取。

这一部分的核心不是 E1000 硬件寄存器，而是内核中的协议分发和进程等待机制。用户调用 `bind(port)` 表示愿意接收该端口上的 UDP packet；如果 packet 到达时已经有进程在 `recv()` 中等待，内核应唤醒它；如果 packet 先到达而用户稍后调用 `recv()`，内核应暂时把 packet 放入有限队列。

#part("实验步骤")

首先在 `kernel/net.c` 中新增 UDP 端口队列结构。每个队列对应一个已经绑定的目的端口，队列节点保存一个已经收到但尚未被用户取走的 UDP packet，包括 payload buffer、payload 长度、源 IP、源端口和 next 指针。队列数量和每个端口的队列长度都设置为有限值，避免某个端口长时间不读取时无限消耗物理页。

`sys_bind()` 读取用户传入的端口号，在全局 UDP 队列表中查找是否已有绑定；若没有，则分配一个空队列槽位并初始化。重复绑定同一端口时直接返回成功。`sys_unbind()` 释放对应端口队列中所有尚未读取的 packet，并清空队列状态。由于网络中断路径和用户系统调用路径都可能访问这些队列，所有队列操作都使用 `netlock` 保护。

随后实现 `ip_rx()`。`net_rx()` 已经根据 Ethernet 类型区分 ARP 和 IP，ARP packet 由已有 `arp_rx()` 处理，IP packet 进入 `ip_rx()`。实验在 `ip_rx()` 中检查 IP 版本、IP 头长度、总长度和协议号，只处理 UDP packet。解析 UDP 头后，取得目的端口、源端口和 payload 长度，将 payload 移到 buffer 开头，并构造队列节点保存源地址、源端口和 payload 信息。若目的端口没有绑定，或对应队列已经达到上限，则释放该 packet；否则追加到队尾，并调用 `wakeup(q)` 唤醒睡在该端口队列上的 `recv()` 进程。

接着实现 `sys_recv()`。该系统调用读取目的端口、源 IP 输出地址、源端口输出地址、用户缓冲区地址和最大长度。若端口没有绑定，则返回错误；若队列为空，则通过 `sleep(q, &netlock)` 阻塞等待。`sleep()` 会在进入睡眠时释放 `netlock`，被 `ip_rx()` 唤醒后再重新获得锁，因此不会阻塞网络中断继续入队。取到 packet 后，`sys_recv()` 从队列头删除该节点，释放锁，然后使用 `copyout()` 将源 IP、源端口和最多 `maxlen` 字节 payload 写入用户地址空间，最后释放内核中的 packet 节点和 payload buffer。

本部分还修改 `sys_send()` 的错误处理。`sys_send()` 已经能够构造 Ethernet、IP 和 UDP 头部，并把用户缓冲区中的 payload 复制到内核 buffer 中。实验将其末尾改为检查 `e1000_transmit()` 的返回值：若发送 ring 暂无可用 descriptor，则释放刚分配的 buffer 并返回 `-1`。这虽然和接收队列不属于同一方向，但属于网络 buffer 生命周期管理的一部分，可以避免发送失败时泄漏物理页。

UDP 接收流程可以概括为：

```text
E1000 收到 Ethernet frame
  -> e1000_recv() 交给 net_rx()
  -> net_rx() 判断 Ethernet 类型
  -> ip_rx() 解析 IP/UDP 头
  -> 根据 UDP 目的端口找到接收队列
  -> 入队并 wakeup 等待的 recv()
  -> sys_recv() copyout 源地址、源端口和 payload
```

本部分实际修改 `kernel/net.c`。新增 UDP 队列和 packet 节点结构；实现 `sys_bind()`、`sys_unbind()`、`sys_recv()` 和 `ip_rx()`；并补充 `sys_send()` 的发送失败清理。实验过程中还重点阅读了 `kernel/net.h` 中的 Ethernet、IP、UDP、ARP 和 DNS 结构定义，以及 `user/nettest.c`、`nettest.py` 中对收包、发包、多端口分发、DNS 和内存释放的测试逻辑。

#part("实验中遇到的问题和解决方法")

本部分的第一个难点是区分协议层和驱动层职责。刚开始容易以为 UDP Receive 需要修改 E1000 接收逻辑。实际数据流显示，`e1000_recv()` 只交付完整 Ethernet frame，UDP 目的端口分发应在 `kernel/net.c` 的 `ip_rx()` 中完成。明确层次后，`kernel/net.c` 中的逻辑就集中在协议头解析、端口队列和用户进程唤醒上。

第二个问题是 UDP 队列不能无限增长。`ping3` 测试会从部分端口持续发送大量 packet，并检查是否出现过多排队。若每个收到的 UDP 包都无限入队，短期内看似不丢包，但会消耗大量物理页，并导致最终 `free` 测试失败。实验为每个端口设置固定队列上限，超过上限时主动丢弃并释放 packet。

第三个问题是阻塞式 `recv()` 的退出条件。若用户进程在没有 packet 时睡眠等待，而另一个进程对其执行 `kill()`，`recv()` 必须能检测 `killed(p)` 并返回错误，否则测试中用于统计队列长度的子进程无法退出。实验在等待循环中检查进程 killed 状态，从而使阻塞系统调用可以被终止。

第四个问题是内核和用户空间的数据复制。`recv()` 返回的不应是整个 Ethernet frame，而是 UDP payload，同时还要把源 IP 和源端口写回用户提供的地址。实验在 `ip_rx()` 中将 payload 移到 buffer 开头，在 `sys_recv()` 中使用 `copyout()` 分别写回源地址、源端口和 payload，从而保持用户接口与 `user/nettest.c` 的期望一致。

#part("实验心得")

UDP Receive 部分体现了网络协议栈中“分发”的思想。网卡只提供一串收到的字节，内核需要逐层解释 Ethernet、IP 和 UDP 头部，最终根据 UDP 目的端口把 payload 放入对应队列。用户进程看到的是 `bind()` 和 `recv()` 这样的接口，但背后需要中断处理、协议解析、队列保护和阻塞唤醒共同完成。

从代码定位角度看，本部分说明面对一个较大的内核项目时，应先按数据流划分边界。接收路径从设备中断开始，经过驱动取包、协议解析、端口排队，最终由用户 `recv()` 取走。沿着这条路径阅读代码，问题就从“网络代码很多不知道看哪里”变成了“每一段代码负责把 packet 交给下一层”。

本部分也再次体现了内存生命周期的重要性。收到但无人接收的 packet 需要暂存，队列满或端口未绑定时必须释放，`unbind()` 时也要释放已排队数据。否则功能测试可能暂时通过，但最终会在 `free` 测试中暴露内存泄漏。

== 实验结果

完成本 Lab 后，在 `net` 分支运行：

```text
$ make grade
```

测试过程中，评分脚本在宿主机启动 `nettest.py grade`，同时在 xv6 内运行 `nettest grade`。最终 `txone`、`arp_rx`、`ip_rx`、`ping0`、`ping1`、`ping2`、`ping3`、`dns`、`free` 和 time 测试均通过，得分为满分。测试结果如下图所示。

#figure(
  image("../assets/net/grade.png", width: 92%),
  caption: [Networking Lab 的 make grade 测试结果],
)

测试通过表明，E1000 发送描述符环、接收描述符环、ARP/IP/UDP 分发、UDP 端口队列、阻塞接收和网络 buffer 释放等关键路径均符合实验要求。
