# Lab 2 System Calls 学习笔记

官网页面：

- <https://pdos.csail.mit.edu/6.1810/2025/labs/syscall.html>

本地参考：

- 旧报告：`docs/reports_old/labs/lab2-syscall.typ`
- 代码分支：`origin/syscall`
- 基线分支：`origin/riscv`

## 这个 Lab 真正在学什么

Lab2 的核心不是“新增一个函数”，而是看懂系统调用这条完整路径：

```text
用户程序调用函数
  -> user/usys.pl 生成的 stub 把系统调用号放进 a7
  -> ecall 触发 trap
  -> kernel/trap.c 的 usertrap() 进入内核处理
  -> kernel/syscall.c 的 syscall() 读取 a7
  -> syscalls[num]() 调用具体 sys_* 函数
  -> 返回值写回 trapframe->a0
  -> 回到用户程序
```

所以一旦题目要求“新增系统调用”，就要本能地想到这几个位置：

```text
user/user.h       用户态声明
user/usys.pl      用户态 ecall stub
kernel/syscall.h  系统调用号
kernel/syscall.c  系统调用分发表
kernel/sysproc.c  或 kernel/sysfile.c 中的具体实现
```

如果系统调用需要保存“某个进程自己的状态”，还要看：

```text
kernel/proc.h     struct proc 新字段
kernel/proc.c     初始化、fork 继承、释放
```

## 可见分支改动怎么分类

`origin/riscv...origin/syscall` 中，和理解任务直接相关的文件主要是：

```text
answers-syscall.txt
kernel/proc.c
kernel/proc.h
kernel/syscall.c
kernel/syscall.h
kernel/sysproc.c
user/attack.c
user/sandbox.c
user/secret.c
user/user.h
user/usys.pl
kernel/kalloc.c
```

其中：

- `answers-syscall.txt`：GDB 观察题的答案。
- `user/sandbox.c`：用户态包装命令，负责先设置限制再执行目标程序。
- `kernel/sysproc.c`：实现 `sys_interpose()`。
- `kernel/syscall.c`：真正拦截系统调用的公共入口。
- `kernel/proc.h` / `kernel/proc.c`：保存并继承每个进程的 sandbox 策略。
- `user/attack.c` / `user/secret.c`：内存残留攻击实验程序。
- `kernel/kalloc.c`：在这个 lab 下故意不清零新分配/释放的物理页，让 attack 能观察到旧内容。

`Makefile`、`conf/lab.mk`、`grade-lab-syscall`、`gradelib.py` 属于课程框架和评分入口，写报告时不用把它们当作主要实现。

## 任务一：GDB and system calls

### 先用人话说

这个任务其实不是让你“学 GDB 命令”，而是让你看一件事：

> 用户程序喊内核帮忙时，内核到底怎么知道它要帮什么忙。

比如用户程序写了 `pause(10)`。用户程序自己不能真的去暂停时钟，也不能直接跑进内核函数里。它只能按一下 `ecall` 这个“叫内核”的按钮。可是光按按钮不够，内核还得知道你要办什么业务，所以用户程序会提前把一个编号放进 `a7`。这个编号就是系统调用号。

所以 GDB 要看的不是神秘操作，而是确认这几件简单的事：

```text
用户程序说：我要 pause
  -> stub 把 SYS_pause 这个编号放进 a7
  -> ecall 进入内核
  -> 内核从 a7 看到编号
  -> 内核查表，找到 sys_pause()
  -> 执行完，把结果放回 a0
```

你把它当成“柜台业务编号”就行。`a7` 是业务编号，`a0` 是参数和返回结果，`syscall()` 是柜台分发员。

### 要理解的行为

这个任务不是改功能，而是用 GDB 确认系统调用经过哪里。重点是：

- 系统调用号在 `a7`。
- 返回值在 `a0`。
- `syscall()` 是从 `usertrap()` 进入的。
- 发生异常时，`scause`、`sepc`、`stval` 能说明原因、出错指令和相关地址。

### 先抓住一句话

系统调用号就是一个整数，用来告诉内核“我这次要调用哪一个内核服务”。例如当前 xv6 中：

```text
SYS_getpid = 11
SYS_pause  = 13
SYS_write  = 16
```

用户程序不能直接跳进内核函数，所以它只能在进入内核前把“业务编号”放进 `a7`，再执行 `ecall`。GDB 这一步就是让你亲眼看见：`a7` 里的编号被 `syscall()` 读出来，然后拿去查 `syscalls[]` 表。

### 真实执行路径

以 `pause(10)` 为例：

```text
用户代码 pause(10)
  -> 用户态 stub 设置 a0 = 10, a7 = SYS_pause = 13
  -> ecall 进入内核
  -> trampoline.S 保存寄存器到 p->trapframe
  -> usertrap() 看到 scause == 8，确认是系统调用
  -> usertrap() 把 epc 加 4，避免回去后重复执行 ecall
  -> syscall() 读取 p->trapframe->a7，得到 num = 13
  -> syscalls[13]()，也就是 sys_pause()
  -> 返回值写入 p->trapframe->a0
  -> 回到用户程序，继续执行 pause 后面的代码
```

这里最应该盯住四行源码：

```text
user/usys.pl       li a7, SYS_xxx; ecall
kernel/trap.c      r_scause() == 8 时调用 syscall()
kernel/syscall.c   num = p->trapframe->a7
kernel/syscall.c   p->trapframe->a0 = syscalls[num]()
```

### GDB 单步到底在看什么

GDB 不是在调算法，而是在确认这几个事实：

1. 用户态确实通过 `ecall` 进了内核。
2. `usertrap()` 确实把 `scause == 8` 当作系统调用。
3. 系统调用号确实保存在 `p->trapframe->a7`。
4. `syscall()` 确实用这个编号查 `syscalls[]`。
5. 返回值确实写回 `p->trapframe->a0`。

刚在 `syscall()` 停下时，局部变量 `p` 可能还没执行赋值，所以要先单步过 `struct proc *p = myproc();`，再看：

```text
p p->trapframe->a7
```

如果这次触发的是 `pause()`，你应该能看到 `13`；如果是 `getpid()`，你应该能看到 `11`。

### 怎么知道看哪些文件

题目说要观察系统调用，所以先看系统调用路径：

```text
user/usys.pl
kernel/trap.c
kernel/syscall.c
kernel/proc.h
kernel/riscv.h
```

这里不需要改内核，因为目标是观察。`answers-syscall.txt` 只是记录观察结果。

### 关键理解

用户程序里看起来像普通函数调用，例如 `pause(1)`，但它不是直接跳到内核函数。用户态 stub 会执行 `ecall`，处理器进入内核，内核再从当前进程的 `trapframe` 里读取寄存器。

可以把 `trapframe` 理解为“用户程序被打断那一刻的寄存器快照”。系统调用号、参数和返回值都靠它在用户态和内核态之间传递。

### 自检问题

1. 为什么刚进 `syscall()` 时不能保证局部变量 `p` 已经有值？
2. 为什么系统调用号放在 `a7` 而不是由函数名传给内核？
3. `scause`、`sepc`、`stval` 各自回答了异常的哪个问题？

## 任务二：Sandbox a command

### 先用人话说

`sandbox` 就是沙箱：给一个进程套个限制，让它不是想干什么就能干什么。

在 xv6 里，用户程序只要想让内核帮忙，就必须走系统调用。打开文件是系统调用，执行新程序是系统调用，写输出也是系统调用。所以如果我们想限制一个程序，最自然的办法就是：

> 在它每次系统调用时检查一下：这个服务它有没有被禁止。

比如我们规定某个进程不能用 `open`，那它以后每次想打开文件，内核都直接返回失败。程序还在跑，但它被关在沙盒里，能做的事情变少了。

这里的 `mask` 可以理解成一排开关：

```text
第 5 位是 1  -> 禁止 5 号系统调用
第 7 位是 1  -> 禁止 7 号系统调用
第 16 位是 1 -> 禁止 16 号系统调用
```

而每次系统调用的编号正好在 `a7` 里。内核拿 `a7` 去看 mask，就知道这次要不要拦。

### 要实现的行为

新增 `interpose(mask, path)` 系统调用和 `sandbox` 用户程序。`sandbox` 运行一个命令前，先让内核记录“这个进程禁止哪些系统调用”。目标命令之后每次进入 `syscall()`，内核都检查 mask；命中就直接返回 `-1`。

```text
sandbox 8 - echo hi
  -> fork()
  -> 子进程 interpose(mask, path)
  -> 子进程 exec("echo", ...)
  -> echo 的系统调用仍受限制
```

### 先抓住一句话

Sandbox 的本质是：

> 在所有系统调用都会经过的总入口 `syscall()` 处，加一个“这个进程不准调用哪些 syscall”的检查。

所以它不是给 `open()`、`write()`、`exec()` 每个函数都单独加判断，而是在统一分发前拦住。

### 真实执行路径

运行一个受限命令时：

```text
用户输入 sandbox <mask> <path> <command>
  -> sandbox 自己先 fork()
  -> 子进程调用 interpose(mask, path)
  -> sys_interpose() 把 mask/path 保存到当前 struct proc
  -> 子进程 exec(command)
  -> exec 替换用户地址空间，但 struct proc 还在
  -> command 每次 syscall 都进入 kernel/syscall.c
  -> syscall() 检查当前进程的 mask
  -> 命中：a0 = -1，不调用真正 sys_* 函数
  -> 未命中：正常调用 syscalls[num]()
```

这条路径解释了为什么状态必须放在 `struct proc`：`exec()` 会把原来的 `sandbox.c` 地址空间换掉，但不会换掉当前进程的内核结构。

### 怎么知道要改哪些文件

因为题目要求新增系统调用，所以先套新增 syscall 模板：

```text
user/user.h
user/usys.pl
kernel/syscall.h
kernel/syscall.c
kernel/sysproc.c
```

因为限制要在 `exec()` 后继续存在，状态不能放在 `sandbox.c` 的普通变量里。`exec()` 会替换用户地址空间，普通变量会消失。状态应该放进 `struct proc`：

```text
kernel/proc.h
kernel/proc.c
```

因为限制要对所有系统调用统一生效，检查位置不应该散落在每个 `sys_*` 函数里，而应该放在：

```text
kernel/syscall.c: syscall()
```

### 实现主线

进程结构里新增：

```text
syscall_mask
allowed_path
```

`sys_interpose()` 做两件事：

```text
argint(0, &mask)
argstr(1, path, MAXPATH)
保存到 myproc()
```

`syscall()` 原本是：

```text
num = p->trapframe->a7
p->trapframe->a0 = syscalls[num]()
```

加 sandbox 后变成：

```text
num = p->trapframe->a7
if mask 命中 num 且没有路径例外:
    p->trapframe->a0 = -1
else:
    p->trapframe->a0 = syscalls[num]()
```

`kfork()` 里要复制父进程的 `syscall_mask` 和 `allowed_path`。否则受限程序再 `fork()` 出来的子进程就会绕过限制。

### 容易错的点

- 只在 `sandbox.c` 保存 mask 是错的，因为内核根本看不到这个用户变量，`exec()` 后变量也没了。
- 只限制当前进程、不在 `fork()` 继承限制，会让子进程绕过 sandbox。
- 在每个 `sys_*` 里分别判断 mask 不合适，因为容易漏，而且系统调用统一入口就是 `syscall()`。

### 自检问题

1. 为什么 `interpose()` 的状态应该属于进程，而不是属于用户程序里的变量？
2. 为什么 `exec()` 不会清掉 `struct proc`？
3. 如果不修改 `kfork()`，哪类测试会失败？
4. 为什么 `syscall()` 是比 `sys_open()`、`sys_exec()` 更合适的拦截位置？

## 任务三：Sandbox with allowed pathnames

### 先用人话说

这个任务是在沙箱上加“白名单”。

前一个任务是粗暴地说：这个进程不能 `open`，那它所有文件都打不开。但现实里有时需要更细一点：

```text
大多数文件不准打开
但是 README 可以打开
```

所以这一步不是只看“它调用了哪个系统调用”，还要看“它这次想操作哪个对象”。对 `open` 和 `exec` 来说，这个对象就是路径名。

可以这样理解：

```text
普通 sandbox：
  你调用 open？不准。

带路径白名单的 sandbox：
  你调用 open？
  你打开的是 README 吗？
  是 README 就放行，不是就拒绝。
```

这就是 allowed pathnames。

### 要实现的行为

在 mask 拦截基础上加一个路径例外：如果被禁止的是 `open` 或 `exec`，但这次操作的路径等于允许路径，就放行。

```text
系统调用编号被 mask 命中
  -> 是 open 或 exec 吗？
  -> 不是：拒绝
  -> 是：读取第 0 个参数里的路径
  -> 路径等于 allowed_path：放行
  -> 否则：拒绝
```

### 先抓住一句话

上一任务只看“调用号”，这一任务还要看“调用对象”。也就是说，内核不只问：

```text
你是不是调用了 open？
```

还要继续问：

```text
你这次 open 的是不是允许路径？
```

### 真实执行路径

以 `open("README", 0)` 为例，如果 `SYS_open` 被 mask 禁止：

```text
用户程序 open("README", 0)
  -> a7 = SYS_open
  -> a0 = 用户地址空间里的 "README" 字符串地址
  -> ecall 进入内核
  -> syscall() 发现 SYS_open 被 mask 命中
  -> pathname_exception() 判断这是 open/exec
  -> argstr(0, path, MAXPATH) 把用户字符串复制到内核
  -> 比较 path 和 p->allowed_path
  -> 相同：放行，调用 sys_open()
  -> 不同：拒绝，a0 = -1
```

注意这里比较的是“字符串内容”，不是用户传进来的指针地址。

### 怎么知道要改哪些文件

这个任务不是新增系统调用，而是扩展上一任务的拦截策略。所以主要仍然在：

```text
kernel/syscall.c
kernel/proc.h
kernel/sysproc.c
```

其中 `sys_interpose()` 保存允许路径，`syscall()` 判断本次系统调用是否符合路径例外。

### 为什么要用 `argstr()`

`open(path, mode)` 和 `exec(path, argv)` 的第 0 个参数都是用户地址空间里的字符串指针。内核不能直接相信这个指针，也不能长期保存这个指针，因为：

- 用户程序之后可能修改该地址的内容；
- `exec()` 后原地址空间会被替换；
- 用户地址需要通过当前进程页表安全复制。

所以设置策略时，要把 path 复制到 `struct proc` 的 `allowed_path` 里；检查本次调用时，也要用 `argstr()` 把用户传入的路径复制到内核缓冲区再比较。

### 容易错的点

- `"-"` 表示没有例外路径，不能把它当成真实允许路径。
- 只有 `open` 和 `exec` 的第 0 个参数能按路径解释；其他 syscall 即使被 mask 命中，也不能随便读第 0 个参数当字符串。
- xv6 内核不是宿主机 libc，不能想当然使用所有标准库函数。这里应该用内核已有字符串工具，并限制长度为 `MAXPATH`。

### 自检问题

1. 为什么内核不能只保存用户传进来的 `char *path` 指针？
2. 为什么路径例外只适用于 `open` 和 `exec`？
3. `argstr()` 在这里解决了什么问题？

## 任务四：Attack xv6

### 先用人话说

这个任务是在演示一个内存安全问题：别人用过的内存，如果归还后不擦干净，下一个拿到这块内存的人可能看到旧内容。

更直白地说：

```text
secret 程序住进一间房，写下一张纸条
secret 退房
房间没有打扫，纸条还在
attack 程序住进同一间房
attack 看到了上一位留下的纸条
```

对应到 xv6 里：

```text
房间 = 物理页
退房 = 进程退出后释放物理页
没打扫 = kalloc/kfree 没有清零页面内容
下一位 = 后来的进程重新申请内存
纸条 = secret 写过的字符串
```

它不是 attack 直接访问了 secret 的虚拟地址。secret 退出以后，attack 读的是自己的虚拟地址。问题在于这块虚拟地址背后映射到的物理页，曾经被 secret 用过，而且里面的数据没有清掉。

### 要理解的行为

这个任务利用“物理页复用但内容未清零”的漏洞。它不是绕过页表直接读别的进程，而是等待别的进程退出后，重新申请内存，碰巧拿到同一批物理页，于是读到旧内容。

```text
secret 进程写入秘密
  -> secret 退出
  -> 物理页回到空闲链表
  -> 页内容没有清零
  -> attack 申请新内存
  -> 分配器把旧页交给 attack
  -> attack 扫描旧内容并恢复秘密
```

### 先抓住一句话

Attack 任务想说明：

> 页表隔离只能阻止你直接访问别的进程正在使用的地址；如果物理页释放后不清零，下一次分配给别人时，旧数据仍然可能被读出来。

所以这不是“访问别的进程的虚拟地址”，而是“拿到了别人用过的物理页”。

### 真实执行路径

```text
secret 启动
  -> 在自己的用户内存里写入 marker 和 secret
  -> 进程退出
  -> xv6 回收这些虚拟页对应的物理页
  -> 实验版本没有清掉物理页里的字节

attack 启动
  -> sbrk() 申请多页内存
  -> kalloc() 可能把 secret 刚释放的物理页分给 attack
  -> attack 扫描自己新申请到的虚拟内存
  -> 找到 marker
  -> 从 marker 后固定偏移读出 secret
```

从 attack 的角度看，它没有访问非法地址；它读的是“自己的”虚拟地址。问题出在这块物理内存以前属于别人，且内容没被清理。

### 怎么知道要看哪些文件

用户态攻击程序在：

```text
user/secret.c
user/attack.c
```

物理页是否清零由分配器决定，所以看：

```text
kernel/kalloc.c
```

这个 lab 的分支里，在 `LAB_SYSCALL` 下跳过了 `kalloc()` / `kfree()` 中用于调试的 `memset()`，让物理页残留可见。

### 实现主线

`secret.c` 写入固定标记和秘密：

```text
"This may help."
偏移 16 字节处写 argv[1]
```

`attack.c` 申请 8 页内存，然后扫描：

```text
找到 "This may help."
  -> 从后面固定偏移读字符串
  -> 检查是否是非空字母数字串并以 '\0' 结束
  -> 打印秘密
```

### 容易错的点

- 不能假设目标内容一定出现在某个固定虚拟地址。
- 不能只申请一页；分配器顺序会影响拿到哪一页。
- 不能把任何随机字节都当秘密，需要用 marker 和字符串格式过滤。

### 自检问题

1. 页表隔离为什么没有阻止这个攻击？
2. 这个攻击依赖的是虚拟地址复用，还是物理页复用？
3. 为什么生产内核通常要在分配给用户前清理页面？

## 这个 Lab 最应该留下的理解

Lab2 的主线可以压缩成三句话：

1. 系统调用是用户态进入内核态的受控入口，编号、参数、返回值都经过 trapframe。
2. 想统一控制所有系统调用，应该抓住 `syscall()` 分发点，而不是到处改单个 `sys_*`。
3. 进程级策略要放在 `struct proc`，因为它要跨越 `exec()`，还可能被 `fork()` 继承。

## 写 Markdown 报告时的方向

建议把这一章写成“系统调用路径 + 统一拦截 + 内存残留攻击”三段，不要按代码文件堆列表。

重点写清楚：

- 新增 syscall 为什么有固定五件套；
- sandbox 为什么放在 `syscall()`；
- mask 为什么放在 `struct proc`；
- 路径为什么要从用户空间复制到内核；
- attack 为什么说明“释放页不清零”会破坏隔离。
