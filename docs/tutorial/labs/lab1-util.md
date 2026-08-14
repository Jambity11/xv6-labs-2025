# Lab1: Utilities —— 用户程序是怎么"住进" xv6 并变成命令的

> 文档定位：这是 lab1 的讲解文档，延续 `00-xv6-overview.md` 的写法——先讲清楚前置知识，再对着你
> `util` 分支里的**真实代码**逐行讲解每个任务。它回答三个问题：① 我写的 `user/*.c` 是怎么跑到
> xv6 shell 里、变成一个能敲的命令的；② 做这 5 个任务前要会哪些东西；③ 每个任务的代码是怎么写的、
> 每一段为什么这么写。
>
> 读法建议：**第二部分（前置知识）先读**，它是后面所有任务的地基；第三部分按任务顺序读，每个任务
> 都能独立看懂。已经懂的部分可以跳，但自检问题别跳——那是检验你是"看懂了"还是"以为看懂了"。

---

## 第一部分　这个 lab 到底在学什么

### 1.1 一句话主线

> 你写的 `user/*.c` **不会**因为躺在 `user/` 目录里就自动出现在 xv6 里。它要先被交叉编译成
> RISC-V 用户程序，再被 `mkfs` 打包进磁盘镜像 `fs.img`，最后才能被 xv6 shell 加载执行。

完整路径是一条流水线：

```text
你写 user/sleep.c
  -> 在 Makefile 的 UPROGS 里登记 $U/_sleep
  -> make 用 RISC-V 工具链交叉编译出 user/_sleep
  -> mkfs 把 _sleep 写进磁盘镜像 fs.img
  -> QEMU 启动 xv6
  -> xv6 shell 运行 sleep
```

**只要这条流水线没通，代码写得再对，shell 里也找不到你的命令。** 这是 lab1 最重要的认知，
后面每一个任务都会踩一遍这条线。

### 1.2 lab1 的定位：只动用户态，不碰内核

lab0 是搭环境，lab1 是第一次真正写代码。它故意把难度压在**用户态**这一侧：5 个任务需要的所有
服务（等待、读文件、看文件信息、创建进程）**内核早就提供了**，你只是"消费"这些现成的系统调用，
不需要改 `kernel/` 里任何一行。

所以 lab1 真正在教的，是 6 件事：

1. 一个 `user/` 里的 C 文件如何成为 xv6 命令（流水线）；
2. 命令行参数怎么进 `argc`/`argv`；
3. 用户程序怎么调用**已有**的系统调用（`pause`、`open`、`read`、`fstat`、`fork`、`exec`、`wait`）；
4. 文件描述符怎么把"文件、管道、控制台"统一成同一种读写接口；
5. 目录怎么被当成"装满 `struct dirent` 的文件"来读；
6. `fork`/`exec`/`wait` 三件套怎么配合。

### 1.3 五个任务一览

| 任务 | 难度 | 本质 | 你学到的 |
| --- | --- | --- | --- |
| Boot xv6 | easy | 验证环境 + 区分两个 shell | `make qemu` 全流程 |
| sleep | easy | 参数解析 + 调 `pause` | 一个完整命令的最小骨架 |
| sixfive | moderate | 状态机 | 逐字符读文件、边界处理 |
| memdump | easy | 指针重解释 | C 的类型与内存模型 |
| find | moderate | 目录递归 | 目录 = 文件、`struct dirent` |
| find -exec | moderate | fork/exec/wait | 进程三件套 |

---

## 第二部分　前置知识（做 lab1 前要会的）

### 2.1 用户程序 vs 内核程序

这个 `00-xv6-overview.md` 第一部分已经详细讲过，这里只留一句结论：`kernel/` 跑在特权态，能碰所有
硬件；`user/` 跑在非特权态，想干任何"大事"（读文件、开进程、写屏幕）都得**举手求内核**——通过
系统调用。lab1 写的所有程序都在 `user/`，它们唯一的"超能力来源"就是系统调用。

### 2.2 一个命令是怎么"住进" xv6 的（lab1 的命脉）

这是 lab1 最该彻底弄懂的一段。拆开讲：

**第一步：登记（Makefile 的 `UPROGS`）。** 打开 `Makefile`，能看到一长串 `UPROGS`，lab1 往里加了
`$U/_sleep`、`$U/_sixfive`、`$U/_find`、`$U/_memdump`（`memdump` 只在 `LAB=util` 时加入）。`$U`
展开就是 `user/` 目录。**没登记的程序，即使源码写得完美，也不会被编译、更不会进 xv6。**

**第二步：交叉编译。** 你的电脑是 x86，xv6 跑在 RISC-V 上，所以要用"RISC-V 交叉编译器"把
`user/sleep.c` 编译成 RISC-V 能执行的 `user/_sleep`（下划线开头是 xv6 对用户程序的命名习惯）。

**第三步：打进磁盘镜像（`mkfs`）。** xv6 里没有"安装程序"这回事，它的文件系统是启动前就用
`mkfs/mkfs` 工具**预先做好**的，产物叫 `fs.img`。`Makefile` 第 146–147 行把 `UPROGS`（程序）和
`UEXTRA`（非程序文件，如 lab1 的 `findtest.sh`、`sixfive.txt`）一起写进 `fs.img`。

**第四步：shell 执行。** 你在 xv6 shell 里敲 `sleep 10`，shell 先在 `fs.img` 里找到可执行文件
`sleep`，然后 `fork` + `exec` 把它加载进内存运行。

**自检问题 1**：`user/sleep.c` 存在，但你把 `$U/_sleep` 从 `UPROGS` 里删掉再 `make qemu`，在 xv6
shell 里敲 `sleep 10` 会发生什么？为什么？

### 2.3 命令行参数 argc / argv

每个用户程序的主函数都是 `int main(int argc, char *argv[])`：

- `argc` = 参数的**个数**（含命令名本身）；
- `argv[0]` = 命令名（如 `"sleep"`），`argv[1]` = 第一个参数，以此类推；
- **所有参数都是字符串**，哪怕你敲的是数字 `10`，拿到手也是 `"10"` 这个字符串。

所以敲 `sleep 10` 时：`argc == 2`，`argv[0]=="sleep"`，`argv[1]=="10"`。程序要自己把 `"10"` 转成
整数 `10`（用 `atoi`）。**忘了"参数是字符串"这件事，是 lab1 最常见的错误来源。**

### 2.4 文件描述符 fd：统一读写接口

`open()` 打开一个文件后，返回一个小整数，叫**文件描述符**（fd）。之后 `read(fd, ...)`、
`write(fd, ...)`、`close(fd)` 都用这个整数，而不是文件名。

它的精髓是**统一**：不管这个 fd 背后是普通文件、目录、还是终端，读写方式都一样。xv6 约定三个
特殊 fd 进程一出生就有：

| fd | 含义 |
| --- | --- |
| 0 | 标准输入 stdin |
| 1 | 标准输出 stdout |
| 2 | 标准错误 stderr |

这就是为什么代码里到处是 `fprintf(2, ...)`（往标准错误写，报错信息）和 `read(0, ...)`（从标准输入读）。

### 2.5 目录也是文件，内容是 `struct dirent`

xv6 里**目录就是文件**，只是它的"内容"不是文字，而是一串固定大小的记录：

```c
struct dirent {
  ushort inum;          // 这个目录项的 inode 编号
  char name[DIRSIZ];    // 文件名（DIRSIZ = 14，定长）
};
```

读目录就是 `read(fd, &de, sizeof(de))`，一次读出一条 `struct dirent`。`name` 是**定长 14 字节**、
**不一定以 `\0` 结尾**——这就是 find 里要手动补 `\0` 的原因（第三部分 3.4 细讲）。

### 2.6 fork / exec / wait 三件套

这是 lab1 最后两个任务的核心，也是整个操作系统最经典的三个调用：

- **`fork()`**：克隆当前进程。调用一次，返回两次——父进程里返回"子进程的 pid"（>0），子进程里
  返回 0。父和子各有一份独立的内存，`fork` 之后它们分道扬镳。
- **`exec(path, argv)`**：用新程序**替换**当前进程。**成功就不返回**（因为当前进程已经被替换成新
  程序了）；如果 `exec` 之后还有代码执行，说明它失败了。
- **`wait(0)`**：父进程等一个子进程结束再继续，防止父进程跑太快、子进程还没收尸。

三件套的标准配合：`fork` 造一个分身 → 子进程 `exec` 变成新程序 → 父进程 `wait` 等它干完。find -exec
里你会完整用到。

**自检问题 2**：为什么 find -exec 里必须 `fork` 之后再 `exec`，而不能直接 `exec`？（提示：`exec`
会把**当前进程**替换掉，替换后 find 自己就没了，还能继续遍历吗？）

### 2.7 C 指针与"类型重解释"（memdump 的地基）

内存里存的**只有字节**，没有类型。所谓类型，是"你怎么**读**这些字节"：

```c
int n = 0x41424344;
printf("%c\n", *(char*)&n);   // 把 n 的 4 个字节按 char 读，只会看到第一个字节
```

`(char*)&n` 这行**没有拷贝任何字节**，只是换了一种"读法"去看同一块内存。这正是 memdump 的全部
本质：给你一段裸字节和一个格式串，格式串决定"按 int / short / char / 指针 / 字符串来读这段字节"。

### 2.8 本 lab 用到的系统调用和用户函数清单

| 名字 | 在哪声明 | 作用 |
| --- | --- | --- |
| `pause(int)` | `user/user.h` | 睡 n 个 tick（这个 fork 里代替标准 xv6 的 `sleep` 系统调用） |
| `open/read/close` | `user/user.h` + `kernel/fcntl.h` | 打开 / 读 / 关文件 |
| `fstat` | `user/user.h` + `kernel/stat.h` | 拿文件元信息（类型、大小） |
| `fork/exec/wait/exit` | `user/user.h` | 进程三件套 + 退出 |
| `printf/fprintf/atoi/strchr/strcpy/memmove/memset/strlen` | `user/user.h`（实现都在 `user/ulib.c`） | 用户态迷你库 |

**一个重要的命名坑**：这个 fork 里"睡一会"的系统调用叫 **`pause`**（`SYS_pause = 13`），不叫
`sleep`。原因是本 lab 的用户命令正好要叫 `sleep`，如果系统调用也叫 `sleep` 就会重名冲突。所以
`sleep.c` 里调的是 `pause(ticks)`。你在别的资料里看到 `sys_sleep`，就是同一件事、换了个名字。

---

## 第三部分　逐任务讲解

### 3.0 Boot xv6（easy）——先确认流水线是通的

**行为**：`make qemu` 启动 xv6，看到 `init: starting sh` 和 `$` 提示符，敲 `ls` 能列出 xv6 文件系统
里的东西。

**要理解的点**：注意区分**两个 shell**——你宿主机（WSL/Linux）的 shell 和 xv6 自己的 shell。两者
提示符都是 `$`，怎么区分？看 `ls` 的结果：xv6 shell 里 `ls` 列出的是 `fs.img` 里的文件（有 `echo`、
`ls`、`cat`、以及你后来加的 `sleep` 等），不是宿主机目录。另一个判断法：宿主机敲 `ls` 能看到的
是 `kernel/`、`user/` 这些源码目录，xv6 里没有。

**这个任务不改任何代码**，它的意义是：确认工具链、QEMU、`fs.img` 构建流程都正常——流水线通了，
后面写代码才有意义。

### 3.1 sleep（easy）——最小的完整命令

**行为**：`sleep ticks` 让当前进程等 `ticks` 个时钟节拍后退出。

**先想清楚改哪些文件**：这是一个**新命令**，所以答案必然在 `user/`（写程序）+ `Makefile`（登记），
不用碰 `kernel/`——因为"等待"这个服务内核已经通过 `pause` 系统调用提供了。这是 lab1 反复用到的
元技能：**新命令 → user/ + Makefile；只有内核缺了某个服务时才需要动 kernel/**。

**代码**（`user/sleep.c`）：

```c
#include "kernel/types.h"
#include "kernel/stat.h"
#include "user/user.h"

int
main(int argc, char *argv[])
{
  if(argc != 2){
    fprintf(2, "usage: sleep ticks\n");
    exit(1);
  }

  int ticks = atoi(argv[1]);
  pause(ticks);

  exit(0);
}
```

逐段看：

- 三个 `#include`：`types.h` 给 `uint` 这类类型，`stat.h` 给 `struct stat`（这个程序其实用不到，
  但 xv6 用户程序习惯性带上），`user.h` 是用户程序**必带**的头——它声明了 `atoi`、`pause`、`exit`、
  `fprintf` 等一切你能调用的东西。**没有 `user.h`，编译器不认识 `pause`、`atoi`。**
- `if(argc != 2)`：为什么是 2？因为 `sleep 10` 有两个参数（`argv[0]="sleep"`，`argv[1]="10"`）。
  少了 tick 参数时 `argc == 1`，此时读 `argv[1]` 就是**越界访问不存在的参数**，是严重 bug，所以
  先拦截，打印用法并 `exit(1)`（非 0 表示异常退出）。
- `atoi(argv[1])`：把字符串 `"10"` 转成整数 `10`。`atoi` 是 xv6 用户库自带的（在 `user/ulib.c`），
  实现极简：逐字符 `n = n*10 + (*s - '0')`。
- `pause(ticks)`：**系统调用**。这一行会陷入内核，内核在 `sys_pause` 里数 tick，数够了才让进程
  醒来。这就是"用户程序求内核办事"的现场。
- `exit(0)`：正常结束，把控制权还给 shell。

**Makefile**：在 `UPROGS` 里加一行 `$U/_sleep\`（xv6 的用户程序名带 `_` 前缀）。

**自检问题 3**：把 `if(argc != 2)` 删掉，然后敲 `sleep`（不带参数）会怎样？为什么这一步是必须的？

### 3.2 sixfive（moderate）——状态机

**行为**：`sixfive file...` 扫描每个文件，打印所有能被 5 或 6 整除的**完整十进制整数**。

**难点不在"整除"，在"完整"**。看题目给的测试数据 `user/sixfive.txt`：

```text
5
3
127
100
18-4
06
```

正确答案是 `5、100、18、6`。关键是这些边界：`18-4` 里的 `-` 是分隔符，所以 `18` 和 `4` 是两个数；
`06` 按整数读是 `6`；而如果文件里出现 `xv6`，那个 `6` **不能**算——因为它嵌在单词里，不是独立的
数字。**判断一个数字是否独立，必须记住"它前面是什么"**，这就是状态机的由来。

**三个状态**：

```text
SEP_STATE      刚经过分隔符：这里出现的数字可以开始一个新整数
NUMBER_STATE   正在读一个整数：数字继续往后拼
INVALID_STATE  正在一个非数字片段里：这里的数字要忽略，直到再遇到分隔符
```

**代码**（`user/sixfive.c`，核心是 `scan_file`）：

```c
static char *separators = " -\r\t\n./,";   // 哪些字符算"分隔符"

static void
scan_file(int fd)
{
  char c;
  int state = SEP_STATE;
  int value = 0;
  int n;

  // 题目要求：每次只读一个字符。
  while((n = read(fd, &c, 1)) == 1){
    if(strchr(separators, c) != 0){        // 遇到分隔符
      if(state == NUMBER_STATE)
        print_if_needed(value);            // 前面在读的数，在这里收尾
      state = SEP_STATE;
      value = 0;
    }
    else if(c >= '0' && c <= '9'){         // 遇到数字
      if(state == SEP_STATE){              // 分隔符后的数字：开新数
        state = NUMBER_STATE;
        value = c - '0';
      } else if(state == NUMBER_STATE){    // 数字继续：拼到后面
        value = value * 10 + (c - '0');
      }
      // state == INVALID_STATE 时，什么都不做（忽略这个数字）
    }
    else {                                 // 既不是数字也不是分隔符（如字母）
      state = INVALID_STATE;               // 丢弃之前读到的半截数字
      value = 0;
    }
  }

  if(n < 0){
    fprintf(2, "sixfive: read error\n");
    exit(1);
  }

  // 文件末尾也要当成一个隐含的分隔符
  if(state == NUMBER_STATE)
    print_if_needed(value);
}
```

几个关键点：

- **`read(fd, &c, 1)` 一次读一个字节**：把"字符边界"暴露得清清楚楚。如果一次读一大块再处理，
  反而要自己操心缓冲区的边界。
- **`value = value * 10 + (c - '0')`**：这是"字符串数字转整数"的标准手法，和 `atoi` 内部一模一样。
- **为什么要有 `INVALID_STATE`**：读 `xv6` 时，`x` 进入 `INVALID_STATE`，后面的 `6` 因为是
  `INVALID_STATE` 就被忽略，于是 `xv6` 不会被拆出 `6`。如果只按"遇非数字就结束当前数"写，
  `xv6` 会错误地提取出 `6`——这就是本任务最经典的一个坑。
- **为什么要"丢弃半截数字"**：读 `12abc` 时，`12` 已经拼出来了，但后面跟的是字母，说明 `12` 是
  某个单词的一部分，不是独立整数，必须整个丢掉。所以遇到字母时 `value = 0`。
- **文件末尾的补充处理**：文件最后如果没有换行符（比如 `06` 后面直接 EOF），循环结束后状态还是
  `NUMBER_STATE`，这个数没被"收尾"。所以循环结束后要**再检查一次**，否则最后一个数会漏掉。

**主函数**的剩余部分很简单：`argc < 2` 报用法错误；否则遍历 `argv[1..]` 逐个 `open` → `scan_file`
→ `close`。注意"支持多文件"是题目明确要求的（`file...` 里的省略号）。

**Makefile**：登记 `$U/_sixfive`，并把测试数据 `user/sixfive.txt` 加进 `UEXTRA`（非程序文件，也要
打进 `fs.img` 才能在 xv6 里被读取）。

**自检问题 4**：读 `18-4` 时，`-` 为什么必须列在 `separators` 里？如果 `separators` 里没有 `-`，
`18-4` 会被怎么解析？

### 3.3 memdump（easy）——指针重解释

**行为**：`memdump(fmt, data)` 按格式串 `fmt` 解释一段裸字节 `data`。这是为理解"内存里只有字节、
类型由读法决定"而设计的任务，也是后面读 trapframe、页表项、磁盘结构体的思维预演。

**格式对照表**（不同格式 = 不同"读法" + 不同前进步长）：

| 格式 | 含义 | 读完 `data` 前进多少 |
| --- | --- | --- |
| `i` | 按 `int`（4 字节）读 | `sizeof(int)` |
| `p` | 按 64 位指针大小读 | `sizeof(uint64)` |
| `h` | 按 `short`（2 字节）读 | `sizeof(short)` |
| `c` | 一个字符 | 1 |
| `s` | `data` 处存的是一个**指向字符串的指针** | `sizeof(char *)` |
| `S` | `data` 处**本身就是**内联字符串 | `strlen(data) + 1` |

**代码**（`user/memdump.c` 的 `memdump`，`// Your code here` 那处就是让你填的地方）：

```c
void
memdump(char *fmt, char *data)
{
  for(; *fmt != '\0'; fmt ++){
    if(*fmt == 'i'){
      printf("%d\n", *(int*)data);       // 把 data 当 int* 读
      data += sizeof(int);
    } else if (*fmt == 'p'){
      printf("%lx\n", *(uint64*)data);   // 按 64 位读
      data += sizeof(uint64);
    } else if (*fmt == 'h'){
      printf("%d\n", *(short *)data);    // 按 short 读
      data += sizeof(short);
    } else if (*fmt == 'c') {
      printf("%c\n", *data);             // 读一个字节
      data += 1;
    } else if (*fmt == 's') {
      printf("%s\n", *(char**)data);     // data 处是"指针"，先解引用拿地址
      data += sizeof(char *);
    } else if (*fmt == 'S') {
      printf("%s\n", data);              // data 处就是字符串本身
      data += strlen(data) + 1;          // 越过字符串 + 结尾的 \0
    } else {
      fprintf(2, "memdump: unknown format %c\n", *fmt);
    }
  }
}
```

最值得嚼的是 **`s` 和 `S` 的区别**：

```text
S 的情况：  data -> ['h']['e']['l']['l']['o']['\0']
           data 指向的位置就是字符串内容，直接打印 data

s 的情况：  data -> [一个地址] -> ['h']['e']['l']['l']['o']['\0']
           data 指向的位置存的是"字符串的地址"，要先 *(char**)data 取出地址
```

`main` 里的 Example 3 就是 `s` 的现场：先有一个字符串 `"another"`，然后 `char *s = "another"`，
再把 **`&s`**（也就是"存放指针的那个变量"的地址）传给 `memdump("s", &s)`。所以 `data` 处存的
不是字符，而是一个指向 `"another"` 的指针。

几个要点：

- **`(int*)data` 不拷贝字节**，只是"换一种读法"看同一块内存。这是理解 C 指针最该建立的直觉。
- **前进步长不能错**：`i` 前进 4、`c` 前进 1、`S` 前进 `strlen+1`（要算上 `\0`）。步长错一步，
  后面所有字段都从错误位置开始解释，整串输出全乱。
- 这个任务几乎不考算法，考的是**你对"类型 = 读法"这件事的直觉**。

**Makefile**：`$U/_memdump` 加进 `UPROGS`（只在 `LAB=util` 时）。

**自检问题 5**：Example 3 里为什么传的是 `&s` 而不是 `s`？如果误传成 `s`，`memdump("s", s)` 会
打印出什么？

### 3.4 find（moderate）——目录递归

**行为**：`find path name` 从 `path` 开始递归搜索，打印**路径最后一段**等于 `name` 的文件或目录的
完整路径。

**先想清楚"目录怎么读"**：xv6 里目录是文件，内容是一串 `struct dirent`（2.5 节）。所以遍历目录 =
`open` 目录 + 循环 `read` 出 `dirent` + 对每个子项递归。

**代码结构**（`user/find.c`）分四块：`last_component`（取路径最后一段）、`run_match`（命中后处理）、
`find`（递归遍历）、`main`（解析参数）。

**① 取路径最后一段**：

```c
static char *
last_component(char *path)
{
  char *p = path + strlen(path);        // 指向字符串末尾的 '\0'

  while(p > path && *(p - 1) != '/')    // 从后往前，找到最后一个 '/'
    p--;

  return p;                             // 返回 '/' 后面的那段
}
```

题目要求比较"名字"而不是整个路径：`./a/aa/b` 要匹配的是 `b`，所以得把最后一段剥出来。

**② 递归遍历（核心）**：

```c
static void
find(char *path, char *target,
     int exec_mode, char **cmd_argv, int cmd_argc)
{
  char buf[512];
  char *p;
  int fd;
  struct dirent de;
  struct stat st;

  if((fd = open(path, 0)) < 0){
    fprintf(2, "find: cannot open %s\n", path);
    return;
  }

  if(fstat(fd, &st) < 0){ ... close(fd); return; }

  if(strcmp(last_component(path), target) == 0)   // 命中：当前路径最后一段 == target
    run_match(path, exec_mode, cmd_argv, cmd_argc);

  switch(st.type){
  case T_FILE:
  case T_DEVICE:
    break;                                        // 普通文件/设备：不再递归

  case T_DIR:                                     // 目录：读子项，递归
    if(strlen(path) + 1 + DIRSIZ + 1 > sizeof(buf)){ ... break; }

    strcpy(buf, path);                            // 先复制父路径到 buf
    p = buf + strlen(buf);
    if(p == buf || *(p - 1) != '/')               // 确保父路径末尾有 '/'
      *p++ = '/';

    while(read(fd, &de, sizeof(de)) == sizeof(de)){ // 逐个读 dirent
      if(de.inum == 0)                             // inum==0 表示空目录项
        continue;

      memmove(p, de.name, DIRSIZ);                 // 把子项名拼到 '/' 后面
      p[DIRSIZ] = '\0';                            // 手动补 '\0'！

      if(strcmp(p, ".") == 0 || strcmp(p, "..") == 0)
        continue;                                  // 跳过 . 和 ..

      find(buf, target, exec_mode, cmd_argv, cmd_argc);  // 递归
    }
    break;
  }

  close(fd);
}
```

这段里有四个必踩的坑，也是四个必懂的点：

1. **`fstat` 判断类型**：`open` 只能拿到 fd，不知道打开的是文件还是目录。`fstat(fd, &st)` 把元信息
   填进 `struct stat`，`st.type` 告诉我们它是 `T_FILE` / `T_DIR` / `T_DEVICE`，据此决定是否递归。
2. **`de.name` 是定长 14 字节、不一定有 `\0`**：`struct dirent` 的 `name[DIRSIZ]` 是固定数组，
   短文件名后面是垃圾字节。所以 `memmove` 之后必须手动 `p[DIRSIZ] = '\0'`，否则 `strcmp` 会越过
   名字读到垃圾、比较必然出错。**这是最经典的 bug。**
3. **跳过 `.` 和 `..`**：每个目录里都有 `.`（指向自己）和 `..`（指向父目录）。如果不跳过，递归会
   在 `.` → `..` → `.` 之间**无限循环**，直到栈溢出。**这是目录递归的头号死法。**
4. **路径拼接的缓冲区**：子路径 = 父路径 + `/` + 子名，拼之前要检查 `buf[512]` 装不装得下，否则
   越界写坏内存。

**③ 主函数**：`argv[1]` 是起始路径，`argv[2]` 是目标名；`argc` 多于 3 时进入 `-exec` 分支（见 3.5）。

**Makefile**：登记 `$U/_find`，测试脚本 `user/findtest.sh` 进 `UEXTRA`。

**自检问题 6**：如果忘了 `p[DIRSIZ] = '\0'`，`find` 会表现出什么症状？为什么 `memmove` 而不是
`strcpy` 来拷贝 `de.name`？（提示：`de.name` 可能没有 `\0`，`strcpy` 会一直读下去。）

### 3.5 find -exec（moderate）——fork/exec/wait 三件套

**行为**：`find path name -exec cmd args...` 在 find 基础上，每命中一个路径，就执行
`cmd args... <命中路径>`。例如 `find . b -exec grep hello` 对每个名为 `b` 的文件执行 `grep hello <路径>`。

**为什么不能直接 `exec`**：`exec` 会用新程序**替换当前进程**。如果 find 直接 `exec`，第一次命中
后 find 自己就没了，遍历戛然而止。所以必须：**`fork` 一个子进程去 `exec`，父进程 `wait` 完继续遍历**。

**代码**（`run_match`）：

```c
static void
run_match(char *path, int exec_mode, char **cmd_argv, int cmd_argc)
{
  char *args[MAXARG];
  int i;
  int pid;

  if(!exec_mode){              // 非 -exec 模式：直接打印路径
    printf("%s\n", path);
    return;
  }

  if(cmd_argc + 2 > MAXARG){   // 参数个数别超过上限
    fprintf(2, "find: too many arguments for -exec\n");
    return;
  }

  for(i = 0; i < cmd_argc; i++)
    args[i] = cmd_argv[i];     // 复制命令及其参数

  args[cmd_argc] = path;       // 把命中路径追加成最后一个参数
  args[cmd_argc + 1] = 0;      // exec 要求 argv 以空指针结尾！

  pid = fork();

  if(pid < 0){ ... return; }   // fork 失败

  if(pid == 0){                // 子进程
    exec(args[0], args);       // 变成新程序；成功就不回来了
    fprintf(2, "find: exec %s failed\n", args[0]);
    exit(1);                   // 能走到这，说明 exec 失败了
  }

  wait(0);                     // 父进程等子进程干完
}
```

逐点讲：

- **`args[cmd_argc + 1] = 0`**：`exec` 靠 `argv` 数组的**空指针结尾**来判断参数到哪为止。少写这行，
  `exec` 会读越界。这是 `exec` 用法里最常见的坑。
- **`fork` 之后用 `pid` 分流**：`fork` 返回两次。父进程里 `pid > 0`（是子进程的 pid），继续往下走
  到 `wait(0)`；子进程里 `pid == 0`，走进 `if(pid == 0)` 分支去 `exec`。**靠 `pid` 的值区分"我是谁"**，
  这是所有 fork 程序的套路。
- **`exec` 成功不返回**：所以 `exec(...)` 后面的 `fprintf(... failed)` 和 `exit(1)` 只有失败才会执行。
- **`wait(0)` 的意义**：父进程等子进程结束。没有它，父进程可能早就跑完退出了，留下一堆孤儿/僵尸
  进程。在 `-exec` 里它还保证"每次只跑一个命令、按顺序跑"。

**主函数解析 `-exec`**：`argv[3]` 必须是 `"-exec"`，从 `argv[4]` 开始是命令及参数，`cmd_argc = argc - 4`。
然后把这些信息一路传进递归的 `find`，这样子目录里的命中也能执行命令。

**自检问题 7**：`exec(args[0], args)` 成功后，`fprintf` 那一行为什么不执行？这背后是什么机制？

---

## 第四部分　加一个用户命令的固定套路（速查）

做完整个 lab1，可以总结出"新增一个 xv6 用户命令"的标准五步：

1. **写源码**：在 `user/` 下新建 `xxx.c`，`main(argc, argv)` 里解析参数、调用系统调用。
2. **登记**：`Makefile` 的 `UPROGS` 加 `$U/_xxx\`（若是数据/脚本文件，加进 `UEXTRA`）。
3. **编译**：`make` 用 RISC-V 交叉编译器生成 `user/_xxx`。
4. **打包**：`mkfs` 把 `_xxx` 写进 `fs.img`。
5. **运行**：`make qemu` 进 xv6，shell 里敲 `xxx`。

以及一条"元技能"：**接到任务先判断它属于用户态还是内核态**。lab1 全是"新命令"，所以只动
`user/` + `Makefile`；只有当需求涉及"内核没有的服务"时（比如 lab2 要新增系统调用）才需要改
`kernel/`。

---

## 第五部分　自检问题汇总（确认你真的懂了）

1. `user/sleep.c` 存在，但 `$U/_sleep` 不在 `UPROGS` 里，`make qemu` 后敲 `sleep` 会怎样？为什么？
2. find -exec 为什么必须 `fork` 再 `exec`，不能直接 `exec`？
3. `sleep.c` 里删掉 `if(argc != 2)`，敲 `sleep`（不带参数）会发生什么？
4. `18-4` 里的 `-` 为什么必须在 `separators` 里？如果不在，`18-4` 被解析成什么？
5. memdump Example 3 为什么传 `&s` 而不是 `s`？
6. find 里忘了 `p[DIRSIZ] = '\0'` 会怎样？为什么用 `memmove` 不用 `strcpy` 拷 `de.name`？
7. `exec` 成功后，它后面的 `fprintf` 为什么不执行？

（答案都在正文里；答不上的，回对应小节重读，别跳过去。）

---

## 下一步建议

- **动手前**：跑一次 `make qemu`，敲 `ls`、`echo hi`、`cat README`，感受"用户程序的世界"；
  再打开 `Makefile` 找到 `UPROGS`，确认 `_sleep` 等已经登记。
- **做 lab2 前**：精读 `00-xv6-overview.md` 第三部分（一次系统调用的完整链路），因为 lab2 要
  亲手新增系统调用，正是那条链路的"反着走"。
- 每写完一个任务，回头对照第四部分的"五步套路"，把套路和刚做的事对上——套路用多了就内化了。
