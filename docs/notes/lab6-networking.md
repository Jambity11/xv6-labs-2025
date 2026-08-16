# lab6 networking

> 这个lab和前面的几个研究的问题不是同一类，前面在研究内存、CPU，这里我们要管的是和外部设备打交道——设备驱动+网络协议栈
>
> xv6 作为跑在QEMU里模拟出来的一台机器，却能ping通 宿主机、发DNS请求，怎么做到

答案分两层：

- 设备驱动层`kernel/e1000.c`：负责 把一整块 frame 塞给网卡 / 从网卡取回来
- 协议层`kernel/net.c`：负责 解析 IP、UDP 头，按端口分发

## Part One: NIC

要理解**描述符环**这套协议(descriptor ring)

> 网卡要发数据出去，CPU一个个存到网卡的寄存器里太慢了，所以使用DMA的方式，这样CPU把包放进内存里，然后只要告诉网卡地址就行了

告诉的方式就是descriptor描述符：在内存里放一张双方都能读写的留言条

```C
struct tx_desc {
  uint64 addr;    // 数据 buffer 在内存的哪个地址
  uint16 length;  // 数据多长
  uint8  cmd;     // 给网卡的命令（比如"这是包的结尾、发完回写状态"）
  uint8  status;  // 网卡回写给 CPU 的状态（比如"我发完了"）
};
```

还不够，一张描述符值对应一个包，发完才能发下一张，所以用一个环来存储这些留言条，这类似两个指针+生产者消费者问题

一个槽位处理完了，会把descriptor的`status`修改

## Part Two: UDP Receive

分发逻辑：端口号 → 队列 → 进程

数据结构：一张表 + 每个端口一条队列

```C
struct udp_packet {       // 一个「还没被取走的包」
  char *data;             // payload
  int len;                // payload 长度
  uint32 src;             // 源 IP
  uint16 sport;           // 源端口
  struct udp_packet *next;
};

struct udp_queue {        // 一个已绑定端口对应的队列
  int used;
  uint16 port;
  int count;              // 当前排了多少个包
  struct udp_packet *head;
  struct udp_packet *tail;
};

static struct udp_queue udp_queues[UDP_PORTS];
```

网卡给了一串字节，内核逐层拆出 IP、UDP 头，按目的端口放进对应队列，再用 sleep/wakeup 让「生产者入队、消费者取包」协调起来



