#import "../templates/lab-report.typ": part

= Lab2: System Calls

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/syscall")[https://github.com/Jambity11/xv6-labs-2025/tree/syscall]

在这个lab开始前，可以先问一个看起来有点奇怪的问题：用户程序为什么不能自己直接读内核的数据？它明明和内核在同一台机器上跑，为什么不能随便翻看别的进程的内存、不能直接往磁盘上写？答案是：不是「不想让」，而是「做不到」——硬件层面就不允许用户态执行特权操作。可矛盾的是，写文件、创建进程、sleep 这些事用户程序又确实需要做。那它该怎么开口？答案是走一条受控的通道：系统调用。本实验研究的正是这条通道本身，三个任务对应三个问题：调用是怎么从用户态走进内核的（用 GDB 观察）；进来了能不能拦（在总入口加一道按进程屏蔽系统调用的关卡）；以及隔离的边界到底在哪（用一个未清零物理页泄漏的实验来说明）。

#part("前置知识")

要看清这条通道，得先回答：从用户态走进内核态，中间到底发生了什么？下面几个概念是理解整个实验的前提。

*系统调用和普通函数调用的本质区别。*普通函数调用（`jal`/`jalr` 加 `ret`）发生在同一个特权级，调用者和被调用者共享同一套内存和权限；系统调用要跨特权级，从用户态（U mode）切到内核态（S mode）。这个切换不能随便跳，必须经过一个受控入口，RISC-V 里就是 `ecall` 指令。

*ecall 之后的流程：*`ecall` 把处理器切到 S mode，程序计数器跳到 `stvec` 寄存器指定的地址，xv6 把这里设成 trampoline 里的 `uservec`，再转入 `usertrap()`。进内核后第一件事是把用户寄存器保存到 `trapframe`（每个进程一份），处理完再把现场恢复回去。`trapframe` 是整个 trap 机制的枢纽，后面 lab4 的 alarm 也靠它。

*系统调用号怎么传：*用户态和内核态约定：调用号放在 `a7`，参数依次放 `a0` 到 `a5`，返回值放 `a0`。用户态那层由 `user/usys.pl` 自动生成汇编 stub——把编号塞进 `a7` 然后 `ecall`。所以你在 `user/user.h` 里声明的每个系统调用，背后都是一段这样的 stub，而不是一个普通 C 函数。

*内核里怎么分发：*`kernel/syscall.c` 的 `syscall()` 从当前进程的 `trapframe->a7` 读出编号，用它查 `syscalls[]` 表（一张函数指针数组），调用对应的 `sys_*` 函数，再把返回值写回 `trapframe->a0`。编号和函数的对应关系就写在这张表里。

*内核从哪读参数：*内核不直接读用户态的寄存器，而是读进内核时保存下来的那份 `trapframe`。所以取参数要用 `argint`、`argstr` 这类函数去 `trapframe` 里取，而不是直接看 `a0`。

*更详细的资料：*xv6 教材第 4 章「Traps and system calls」；RISC-V 特权规范里 `ecall`、`stvec`、`sstatus.SPP` 的定义。关键词：「xv6 syscall 流程」「RISC-V ecall stvec」「trapframe」。关键文件是 `kernel/trampoline.S`（切换现场的汇编）、`kernel/trap.c`（`usertrap`）、`kernel/syscall.c`（分发）。

== GDB and system calls (easy)

第一个任务用 GDB 亲眼跟踪一次系统调用，回答几个具体问题：调用号放在哪个寄存器？内核怎么知道当前进程要什么服务？参数是怎么传进去的？做法是先在 `syscall()` 打断点，等用户程序发起系统调用时停住，再一步步看：`p->trapframe->a7` 是调用号，`a0` 等是参数；`backtrace` 能看到 `syscall()` 是被 `usertrap()` 调上来的；查 `sstatus` 的 SPP 位能确认 trap 之前处理器在用户态。

#figure(
  image("../assets/syscall/gdb.png", width: 88%),
  caption: [使用 GDB 观察 xv6 系统调用路径],
)

我觉得这个任务最值钱的是两个观察。第一，`syscall()` 里读到的参数不是「寄存器现在的值」，而是 `trapframe` 里保存的值——这正好印证了前置知识里说的：进内核时现场已经被存下来了。第二，故意访问地址 0 触发 load page fault 之后，`scause`、`stval`、`sepc` 三个寄存器分别告诉你「发生了什么异常」「出错地址是几」「是哪条指令出的错」。这三个寄存器是后面所有 page fault 处理（COW、mmap）都要看的，这里先混个脸熟。

两个容易踩的坑：刚进 `syscall()` 时局部变量 `p` 还没赋值，直接 `p->trapframe` 会看到无效地址，得先单步越过 `p = myproc()` 再看；连接 GDB 后看不到函数名，往往是因为没加载带符号的 `kernel/kernel`，只连了 QEMU。

== Sandbox a command (moderate)

看到所有系统调用都要经过 `syscall()` 这同一个入口之后，自然会冒出一个念头：既然都得从这儿过，那我能不能在这儿设一道闸门，按我自己的规则决定放行还是拦下？这就是 sandbox 任务。它新加一个 `interpose(mask, path)` 系统调用：给当前进程设一份「禁用系统调用」的名单，然后让它 `exec` 别的程序，限制继续生效。目标程序一旦调用被禁用的系统调用，内核直接返回 -1。

`mask` 是一张位图：第 n 位对应第 n 号系统调用，1 表示禁用。一个整数就能同时表达几十项限制。

*核心知识点一：拦在总入口，而不是逐点打补丁。*限制逻辑放哪？选项一是改每一个 `sys_*` 函数、在每个开头检查——要改几十处还容易漏；选项二是放在 `syscall()` 这个所有系统调用的必经之路上，一处就覆盖全部。xv6 的设计本来就强制所有调用经过 `syscall()` 统一分发，这里天然是个「网关」位置。这个任务让我记住一条经验：要找共同路径，不要逐点打补丁。

*核心知识点二：状态要放进进程结构。*`mask` 不能放在用户程序的普通变量里，因为 `exec()` 会用新程序整个替换掉用户地址空间，变量就没了；必须放进 `struct proc`——`exec` 换的是内存映像，进程这个内核对象还在。这就是「用户态状态」和「内核态状态」生命周期不同的一个具体例子：前者随 `exec` 消失，后者随进程存在。同理，`kfork()` 里要显式把 `mask` 复制给子进程，限制才能继承。

```text
sandbox 启动目标命令
  -> fork() 创建子进程
  -> 子进程调用 interpose() 保存 mask
  -> 子进程 exec() 运行目标程序
  -> 目标程序每次系统调用都经过 syscall()
  -> 命中 mask 时返回 -1
```

实现上，`user/sandbox.c` 负责 fork 出子进程、在子进程里设好 `interpose` 再 `exec` 目标；内核侧 `sys_interpose()` 把 mask 存进当前进程，`syscall()` 分发前先检查 mask 的对应位，命中就把 -1 写回 `trapframe->a0`。`Makefile` 把 `sandbox` 加进文件系统。

#part("代码解读")

本任务的代码改动分散在四个文件里，完整改动见仓库：

#link("https://github.com/Jambity11/xv6-labs-2025/blob/syscall/kernel/proc.h")[kernel/proc.h]
#link("https://github.com/Jambity11/xv6-labs-2025/blob/syscall/kernel/sysproc.c")[kernel/sysproc.c]
#link("https://github.com/Jambity11/xv6-labs-2025/blob/syscall/kernel/syscall.c")[kernel/syscall.c]
#link("https://github.com/Jambity11/xv6-labs-2025/blob/syscall/user/sandbox.c")[user/sandbox.c]

核心代码集中如下。

`kernel/proc.h` 里 `struct proc` 新增两个字段：

```c
uint64 syscall_mask;
char allowed_path[MAXPATH];
```

`kernel/sysproc.c` 里的 `sys_interpose()`：

```c
sys_interpose(void)
{
  int mask;
  char path[MAXPATH];
  struct proc *p = myproc();

  argint(0, &mask);

  if(argstr(1, path, MAXPATH) < 0)
    return -1;

  p->syscall_mask = (uint64)(uint)mask;
  safestrcpy(p->allowed_path, path, MAXPATH);

  return 0;
}
```

`kernel/syscall.c` 的 `syscall()` 里，分发前先检查 mask：

```c
  if(num > 0 &&
     num < NELEM(syscalls) &&
     syscalls[num]){

    int blocked =
      (p->syscall_mask & (1ULL << num)) != 0;

    if(blocked &&
       !pathname_exception(p, num)){
      p->trapframe->a0 = -1;
      return;
    }

    p->trapframe->a0 = syscalls[num]();
  }
```

`user/sandbox.c` 的用户态骨架：

```c
int
main(int argc, char *argv[])
{
  ...
  int pid = fork();
  if(pid < 0) {
    printf("%s: exec fork failed\n", argv[0]);
    exit(1);
  }
  if(pid == 0) {
    if (interpose(atoi(argv[mask]), argv[mask+1]) < 0) {
      printf("%s: interpose failed", argv[0]);
      exit(1);
    }
    exec(nargv[0], nargv);
    printf("%s: exec %s failed\n", argv[0], nargv[0]);
    exit(1);
  } else {
    wait(0);
  }

  return 0;
}
```

下面逐段解释这些代码在做什么、为什么这么写。

*进程结构里的两个字段。*`syscall_mask` 保存禁用名单（位图），`allowed_path` 保存路径例外。为什么放 `struct proc` 而不是用户程序的普通变量？因为 `exec()` 会用新程序整个替换掉用户地址空间，普通变量随 `exec` 消失；而 `struct proc` 是内核对象，随进程存在，能跨 `exec` 存活。这就是「用户态状态」和「内核态状态」生命周期不同的具体体现。

*`sys_interpose`。*它做的事很简单：用 `argint` 取第 0 个参数（mask）、`argstr` 取第 1 个参数（路径字符串），存进当前进程。注意参数是从 `trapframe` 里取的（`argint`/`argstr` 内部读 `trapframe`），而不是直接看寄存器——这是 xv6 取系统调用参数的标准方式。`safestrcpy` 把路径复制进进程的固定数组，而不是只存一个用户态指针：那个指针用户随时能改，`exec` 后还可能失效，必须复制到内核自己的缓冲区。

*`syscall()` 里的网关检查。*这是整个任务的核心。`blocked = (p->syscall_mask & (1ULL << num)) != 0`——把 1 左移 `num` 位、和 mask 做与运算，判断第 `num` 号系统调用是否被禁用。如果 `blocked` 且没有路径例外，就把 `-1` 写回 `trapframe->a0` 并 `return`，**不调用真正的 `syscalls[num]()`**。为什么拦在这里？因为 `syscall()` 是所有系统调用的必经之路，在这里一处检查就覆盖了进程可能调用的全部内核服务——不用去改每一个 `sys_*` 函数，也绝不会漏。

*`sandbox.c` 的骨架。*用户态的逻辑是 fork 出一个子进程，子进程先 `interpose(atoi(argv[mask]), argv[mask+1])` 设好限制，再 `exec` 目标程序；父进程 `wait` 等它结束。关键在顺序：必须先 `interpose` 再 `exec`——`exec` 换的是内存映像，而 `interpose` 写入的是 `struct proc`，所以 `exec` 之后限制仍然生效。这正是「状态放进内核结构」这个设计在用户侧的用法。

#part("自测与解答")

*问：mask 为什么用位图（`1ULL << num`）而不是数组或链表？*

*答：*一个 64 位整数能同时表达 64 项开关，判断「第 num 项是否禁用」只需一次位移加一次按位与，O(1) 完成。用数组要么遍历、要么维护长度，既慢又占空间。位图是表达「集合」最紧凑、最快的方式。

*问：为什么限制要放进 `struct proc`，放进用户态变量不行吗？*

*答：*不行。`exec()` 会用新程序整个替换用户地址空间，用户态变量随之消失，限制就失效了。而 `struct proc` 是内核对象，随进程存在，`exec` 只换内存映像、不销毁进程结构。这就是「内核态状态跨 exec 存活、用户态状态随 exec 消失」的差别。

*问：为什么拦在 `syscall()` 这一个总入口，而不是改每个 `sys_*` 函数？*

*答：*因为 `syscall()` 是所有系统调用的必经之路，一处检查覆盖全部；改每个 `sys_*` 函数要动几十处、还容易漏。找到共同路径、在网关处统一处理，是内核设计里反复出现的思路。

== Sandbox with allowed pathnames (easy)

按调用号整块地拦，有时候太粗了。更常见的要求是：禁止这个进程 `open`，但唯独允许它打开某一个文件。要做到这种「拦一类、放一个」，内核就得多看一样东西——这次调用带的路径参数。这就是本任务要加的路径例外。

这里有个很典型的内核安全习惯：不能直接信任用户态传来的指针。用户传的路径字符串在用户地址空间里，内核要先用 `argstr()` 把它复制到内核缓冲区，再和保存的 `allowed_path` 比较。而且 `sys_interpose()` 在设置策略时就要把字符串复制进 `struct proc`，不能只存一个用户态指针——那个地址用户随时能改，`exec` 后还可能失效。

我在这里还踩了个小坑：直接在内核里用 `strcmp()` 编译不过，因为 xv6 内核不链接宿主机的标准 C 库，只有内核自己实现的那几个字符串函数，改用 `strncmp()` 并限制长度 `MAXPATH` 才通过。「内核没有 libc」这个约束，是写 xv6 内核代码和写普通 C 程序的一个差别。

#part("代码解读")

路径例外的实现就是 `kernel/syscall.c` 里的一个辅助函数 `pathname_exception()`，完整见 #link("https://github.com/Jambity11/xv6-labs-2025/blob/syscall/kernel/syscall.c")[kernel/syscall.c]：

```c
static int
pathname_exception(struct proc *p, int num)
{
  char path[MAXPATH];

  // "-" 表示没有允许的例外路径。
  if(strncmp(p->allowed_path, "-", MAXPATH) == 0)
    return 0;

  // 只有 open 和 exec 可以使用路径例外。
  if(num != SYS_open && num != SYS_exec)
    return 0;

  // open 和 exec 的第 0 个参数都是路径。
  if(argstr(0, path, MAXPATH) < 0)
    return 0;

  return strncmp(path, p->allowed_path, MAXPATH) == 0;
}
```

逻辑很短，但每一行都有讲究。`"-"` 表示「没有例外路径」，先排除这个情况；然后只对 `SYS_open` 和 `SYS_exec` 这两个系统调用做路径例外——因为只有它们的第 0 个参数是路径字符串；接着用 `argstr(0, ...)` 把用户传来的路径复制到内核缓冲区 `path`；最后和 `allowed_path` 比较，相等才放行。这里最值得记的是 `argstr` 这一步：内核*不直接读用户态的指针*，而是先把字符串复制到自己的缓冲区再比较。因为用户传的地址属于用户地址空间，内核直接解引用它既不安全（用户可能传个野指针）、也不可靠（用户可能并发修改）。

== Attack xv6 (moderate)

页表保证两个正在运行的进程不能互访对方地址空间，这我们已经知道了。但顺着问下去还有个更隐蔽的问题：一个进程退出、它的内存被回收之后，后来者就再也看不到它写过的东西了吗？这个任务用一个实验来回答——答案恰恰相反。它故意利用实验版本的一个漏洞：物理页释放时不清零。`secret` 进程申请一页、写上标记和秘密字符串后退出；`attack` 进程随后用 `sbrk()` 申请内存，可能分到同一块物理页，扫描标记就能读到前一个进程的秘密。

*核心知识点：隔离的边界到底在哪。*页表隔离解决的是「两个正在运行的进程不能互相访问对方的地址空间」——A 的虚拟地址翻译不到 B 的物理页。但它管不了「物理页复用」：A 退出后，它的物理页回到空闲池，如果不清零就交给 B，B 就能读到 A 留下的字节。所以进程隔离其实有两层：一层是空间上的（页表，运行时隔离），一层是时间上的（清零，跨进程复用时隔离）。这个实验说明：如果内核偷懒不清物理页，即使第一层隔离完美，第二层也会失效。

这也解释了为什么 xv6 的正常 `kfree()` 会把页面填上垃圾字节再放回链表。实验版本把这一步拿掉了，attack 才有机会。

#part("代码解读")

本任务的关键改动在 `kernel/kalloc.c`，另外两个是用户态程序。完整代码见仓库：

#link("https://github.com/Jambity11/xv6-labs-2025/blob/syscall/kernel/kalloc.c")[kernel/kalloc.c]
#link("https://github.com/Jambity11/xv6-labs-2025/blob/syscall/user/secret.c")[user/secret.c]
#link("https://github.com/Jambity11/xv6-labs-2025/blob/syscall/user/attack.c")[user/attack.c]

`kernel/kalloc.c` 里，实验版本用条件编译把「清页」这步拿掉了。`kfree()` 里：

```c
#ifndef LAB_SYSCALL
  // Fill with junk to catch dangling refs.
  memset(pa, 1, PGSIZE);
#endif
```

`kalloc()` 里同样：

```c
#ifndef LAB_SYSCALL
  if(r)
    memset((char*)r, 5, PGSIZE); // fill with junk
#endif
```

也就是说，在 `LAB_SYSCALL` 下，页面释放时不再清空、分配时也不再填充垃圾字节——旧内容原样保留，这就是漏洞所在。

`user/secret.c` 申请一块静态数组、写固定标记和秘密：

```c
char data[DATASIZE];

int
main(int argc, char *argv[])
{
  if(argc != 2){
    printf("Usage: secret the-secret\n");
    exit(1);
  }

  strcpy(data, "This may help.");
  strcpy(data + 16, argv[1]);

  exit(0);
}
```

`user/attack.c` 申请内存、扫描标记、读取秘密：

```c
  memory = sbrk(DATASIZE);
  ...
  for(i = 0; i + 16 < DATASIZE; i++){
    if(!matches(memory + i, marker))
      continue;

    secret = memory + i + 16;

    len = 0;
    while(i + 16 + len < DATASIZE && is_alnum(secret[len]))
      len++;

    if(len > 0 && i + 16 + len < DATASIZE && secret[len] == '\0'){
      printf("%s\n", secret);
      exit(0);
    }
  }
  exit(1);
}
```

下面解释这几段代码在做什么、为什么这么写。

*清页被拿掉。*xv6 正常的 `kfree` 会在放回空闲链表前 `memset(pa, 1, PGSIZE)` 把整页填成 1，`kalloc` 分配时再填成 5——这不是洁癖，而是在做「跨进程复用的隔离」：把上一个进程留下的字节抹掉，后来者就看不到。`#ifndef LAB_SYSCALL` 把这个动作关掉了，于是 `secret` 退出后、它的物理页带着原内容回到空闲池，`attack` 再申请时可能拿到同一块页，直接读到秘密。

*secret 的写法。*`data` 是全局静态数组，编译进程序的 data 段，它把标记 `"This may help."` 写在偏移 0 处、秘密写在偏移 16 处，然后 `exit(0)`。进程退出后虚拟地址空间被销毁，但物理页没被清空。

*attack 的扫描。*`sbrk(DATASIZE)` 一次申请 8 页，然后逐字节扫描找 `"This may help."` 标记；找到后读标记后 16 字节处的字符串。为什么还要 `is_alnum` 和 `'\0'` 的校验？因为扫描的是原始内存，可能遇到随机残留字节恰好匹配标记，必须确认「标记后的内容确实是一个以空字符结尾的字母数字串」，才能确定这是 secret 留下的秘密而不是巧合。这个校验体现了一个朴素道理：攻击程序在垃圾内存里找数据，要自己判断「找到的东西像不像真的」。

#part("自测与解答")

*问：页表隔离明明保证了进程互访，为什么 attack 还是读到了 secret 的秘密？*

*答：*页表隔离挡的是「两个*正在运行*的进程互相访问对方地址空间」——A 的虚拟地址翻译不到 B 的物理页。但 secret *已经退出*了，它的物理页回到空闲池；如果不清零就交给 attack，attack 读到的就是「上一任进程留下的残留数据」。所以进程隔离其实有两层：空间上的（页表，运行时隔离）和时间上的（清页，跨进程复用隔离）。这个实验说明：内核偷懒不清页，第一层隔离再完美，第二层也会失效。

*问：attack 为什么扫描整个申请区域、还做字母数字校验，而不是读一个固定地址？*

*答：*分配器把哪块物理页分给 attack 是不确定的，不能假设固定地址，必须扫描整片内存。而扫描的是垃圾内存，可能碰上随机字节恰好匹配标记，所以要用「标记 + 字母数字 + 空字符结尾」三重校验，确认找到的确实是 secret 留下的秘密串，而不是巧合。

== 实验结果

完成本 Lab 后，在 `syscall` 分支运行：

```text
$ make grade
```

`answers-syscall.txt`、sandbox mask、fork 继承、路径例外、attack 和 time 测试均通过。

#figure(
  image("../assets/syscall/grade.png", width: 88%),
  caption: [System Calls Lab 的 make grade 测试结果],
)

三个任务合起来，把「系统调用」从一个抽象概念落实成了具体路径：调用经 `ecall` 进内核、现场存进 `trapframe`、编号在 `syscall()` 里分发；而 `syscall()` 这个总入口既能被拿来观察，也能被拿来当沙箱的闸门。最后一个实验则提醒：隔离不只是页表的事，内存的清理同样是一道边界。
