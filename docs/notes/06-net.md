# Lab 6 Networking 学习笔记

官网页面：

- <https://pdos.csail.mit.edu/6.1810/2025/labs/net.html>

本地参考：

- 旧报告：`docs/reports_old/labs/lab6-net.typ`
- 代码分支：`origin/net`
- 基线分支：`origin/riscv`

## 这个 Lab 真正在学什么

一句话：

> 网络 Lab 是让 xv6 学会和网卡这个外部设备合作：网卡负责收发字节包，内核负责准备 buffer、操作 descriptor ring、解析 UDP，并把数据交给用户进程。

前面的 lab 多数在内核内部转：页表、trap、fork、锁。网络 lab 多了一个外部角色：E1000 网卡。

可以先分两层：

```text
设备驱动层：
  跟 E1000 网卡打交道，只关心 packet buffer 和 descriptor ring。

协议/用户接口层：
  看懂 Ethernet/IP/UDP 头，按 UDP 端口把数据交给 recv()。
```

## 可见分支改动怎么分类

`origin/riscv...origin/net` 中和理解相关的主要文件：

```text
kernel/e1000.c       E1000 网卡驱动
kernel/e1000_dev.h   E1000 寄存器和 descriptor 定义
kernel/net.c         简化网络栈，ARP/IP/UDP 处理
kernel/net.h         Ethernet/IP/UDP 结构
kernel/trap.c        设备中断进入路径
kernel/plic.c        外部中断控制器
kernel/syscall.*     bind/unbind/send/recv 系统调用
user/nettest.c       xv6 侧测试
nettest.py           宿主机侧测试
```

## 任务一：Part One: NIC

### 先用人话说

NIC 就是网卡。这个任务是在给 xv6 补网卡驱动里最关键的两件事：

```text
发包：
  xv6 把一段内存交给网卡，让网卡发出去。

收包：
  网卡把收到的数据写进内存，xv6 把它取出来交给网络栈。
```

网卡和内核不是通过函数调用交流，而是通过一圈 descriptor。descriptor 可以理解成快递单：

```text
这块 buffer 在哪里？
长度是多少？
网卡处理完了吗？
```

发送环是一圈“待发快递单”，接收环是一圈“等收货的空盒子”。

### 真实执行路径：发送

```text
用户程序 send()
  -> sys_send()
  -> net.c 构造 Ethernet/IP/UDP packet
  -> e1000_transmit(buf, len)
  -> 读取 E1000_TDT，找到下一个发送 descriptor
  -> 检查 DD 位，看这个槽位上一次发送是否完成
  -> 把 buf 地址和 len 写进 descriptor
  -> 设置 EOP/RS 等命令位
  -> 更新 E1000_TDT，通知网卡有新包
  -> 网卡稍后通过 DMA 读取 buffer 并发出去
```

重点：不能成功提交后马上释放 `buf`。因为网卡是稍后异步读这个 buffer。驱动要把它记在 `tx_bufs[]` 里，等这个 descriptor 下次显示发送完成后再释放旧 buffer。

### 真实执行路径：接收

```text
网卡收到 packet
  -> 通过 DMA 写进 rx descriptor 指向的 buffer
  -> 设置 DD 位
  -> 触发中断
  -> trap.c / plic.c 识别 E1000 中断
  -> e1000_intr()
  -> e1000_recv()
  -> 从 RDT 后一个 descriptor 开始检查 DD 位
  -> 取出收到的 buffer 和长度
  -> 给这个 descriptor 补一个新的空 buffer
  -> 更新 RDT，把旧 buffer 交给 net_rx()
```

接收路径里，驱动只负责拿到完整 Ethernet frame。它不关心这是 UDP 还是 ARP。

### 怎么知道要改哪些文件

题目说 NIC，先找设备驱动：

```text
kernel/e1000.c
kernel/e1000_dev.h
```

题目说中断收包，要看中断路径：

```text
kernel/trap.c
kernel/plic.c
```

题目说把收到的包交给上层，要看：

```text
kernel/net.c
```

### 容易错的点

- 不检查发送 descriptor 的 DD 位就覆盖，可能覆盖还没发完的包。
- 成功提交发送后立刻释放 buffer，网卡 DMA 会读到已经被复用的内存。
- 接收后不给 descriptor 补新 buffer，后续收包没地方放。
- 持有网卡锁调用 `net_rx()`，上层可能又要发送 ARP 回复，导致锁重入死锁。

## 任务二：Part Two: UDP Receive

### 先用人话说

第一部分解决“包怎么从网卡进出内核”。第二部分解决：

> 收到一个 UDP 包以后，内核应该把它交给哪个用户进程？

UDP 靠端口号分发。用户进程先 `bind(port)`，意思是：

```text
以后发到这个端口的 UDP 包，交给我。
```

收到包后，内核看 UDP 目的端口，把 payload 放进对应端口的队列。用户调用 `recv()` 时，再从这个队列取走。

### 真实执行路径：收到 UDP 包

```text
E1000 收到 Ethernet frame
  -> e1000_recv()
  -> net_rx(buf, len)
  -> 判断 Ethernet 类型
  -> 如果是 IP，进入 ip_rx()
  -> 检查 IP 头，确认协议是 UDP
  -> 解析 UDP 头，拿到目的端口
  -> 找到这个端口对应的接收队列
  -> 把 payload 入队
  -> wakeup() 唤醒睡在 recv() 里的进程
```

### 真实执行路径：用户 recv

```text
用户程序 bind(2000)
  -> 内核记录 2000 端口有队列

用户程序 recv(2000, ...)
  -> 如果队列里已有 packet：
       取出队头
       copyout 源 IP、源端口、payload
       返回长度
  -> 如果队列为空：
       sleep 在这个端口队列上
       等 ip_rx() 收到包后 wakeup
```

### 怎么知道要改哪些文件

UDP 分发属于网络协议层，不是网卡寄存器层：

```text
kernel/net.c
kernel/net.h
```

用户态接口是系统调用：

```text
kernel/syscall.h
kernel/syscall.c
user/user.h
user/usys.pl
```

测试入口：

```text
user/nettest.c
nettest.py
```

### 容易错的点

- 把 UDP 逻辑写进 `e1000.c`。驱动层不应该理解 UDP。
- 队列无限增长，没绑定或没人收的包把内存吃光。
- `recv()` 阻塞时不检查进程是否 killed，测试里的子进程可能退不掉。
- 忘记用锁保护 UDP 队列，中断路径和系统调用路径会并发访问。
- `recv()` 返回整个 Ethernet frame，而不是用户期待的 UDP payload。

## 这个 Lab 最应该留下的理解

网络路径要分层看：

```text
E1000 驱动：
  管 descriptor ring 和 DMA buffer。

net.c 协议层：
  解析 Ethernet/IP/UDP，把 payload 分发给端口队列。

用户接口：
  bind/send/recv 让用户进程按端口收发数据。
```

