#import "../templates/lab-report.typ": part

= Lab2: System Calls

对应源码分支：#link("https://github.com/JambitX11/xv6-labs-2025/tree/syscall")[https://github.com/JambitX11/xv6-labs-2025/tree/syscall]

本实验围绕 xv6 的系统调用路径展开。用户程序没有权限直接操作内核数据，只能通过 `ecall` 请求内核完成工作。实验先用 GDB 观察一次请求如何到达内核，再在统一分发位置加入进程级拦截规则，最后通过未清零物理页实验观察内存复用带来的信息泄漏。

```text
用户程序调用函数
  -> 用户态 stub 把系统调用号放入 a7
  -> ecall 进入内核
  -> usertrap() 保存现场
  -> syscall() 根据编号选择 sys_* 函数
  -> 返回值写入 a0
  -> 恢复用户程序
```

== GDB and system calls(easy)

#part("实验目的")

本任务使用 GDB 跟踪系统调用，确认用户态 `ecall`、内核 trap 入口、`trapframe` 和 `syscall()` 之间的关系。观察的重点是：系统调用编号保存在哪里，内核如何知道当前进程请求了什么服务，以及错误的内存访问会留下哪些异常信息。

#part("实验步骤")

首先执行 `make qemu-gdb`，让 QEMU 启动后等待调试器；随后使用 `gdb-multiarch kernel/kernel` 加载内核符号并连接 QEMU。在 `syscall()` 设置断点后继续运行，当用户程序发起系统调用时，GDB 会停在内核的系统调用分发函数中。

此时先单步执行到 `p = myproc()` 之后，再查看 `p->trapframe->a7`。`a7` 中保存系统调用号，`a0`、`a1` 等位置保存参数。执行 `backtrace` 可以看到 `syscall()` 是由 `usertrap()` 调用的；检查 `sstatus` 的 SPP 位，则可以判断 trap 发生前处理器处于用户态。

题目还通过故意访问地址 0 触发 load page fault。异常发生后，`scause` 说明异常类型，`stval` 保存出错的虚拟地址，`sepc` 指向触发异常的指令。将 `sepc` 与 `kernel/kernel.asm` 对照，可以定位具体的加载指令和目标寄存器。答案记录在 `answers-syscall.txt` 中。

#figure(
  image("../assets/syscall/gdb.png", width: 88%),
  caption: [使用 GDB 观察 xv6 系统调用路径],
)

该任务主要涉及 `answers-syscall.txt`，没有新增内核功能。`kernel/syscall.c`、`kernel/trap.c`、`kernel/proc.h` 和汇编输出文件用于调试观察。

#part("实验中遇到的问题和解决方法")

在断点刚进入 `syscall()` 时，局部变量 `p` 可能尚未赋值。若立即执行 `p->trapframe`，GDB 会显示无效地址。单步越过 `p = myproc()` 后再读取即可。连接 GDB 后若看不到函数名，则需要确认加载的是带符号的 `kernel/kernel`，而不是只连接 QEMU 后直接查看地址。

#part("实验心得")

系统调用表面上像一次函数调用，实际包含用户态到内核态的特权级切换。trapframe 保存了进入内核前的寄存器状态，所以 `syscall()` 可以从中读取编号和参数，也能把返回值放回用户程序将要恢复的 `a0`。

== Sandbox a command(moderate)

#part("实验目的")

本任务新增 `interpose(mask, path)` 系统调用和用户程序 `sandbox`。它允许一个进程把指定系统调用设为禁止状态，并让该限制在执行其他程序后继续生效。目标命令一旦请求被禁止的系统调用，内核直接返回 `-1`。

mask 可以理解为一排开关。第 `n` 位对应第 `n` 号系统调用：该位为 1 表示禁止，为 0 表示允许。使用一个整数就能同时保存多项限制。

#part("实验步骤")

首先在 `kernel/proc.h` 的 `struct proc` 中增加 `syscall_mask` 和允许路径。限制必须保存在进程结构中，因为用户程序执行 `exec()` 后，原来的用户态变量会被新程序替换，而 `struct proc` 仍然属于同一个进程。

随后在 `kernel/syscall.h` 中分配 `interpose` 的系统调用号，在 `kernel/syscall.c` 中登记对应的内核处理函数，在 `user/user.h` 与 `user/usys.pl` 中加入用户态声明和 stub。`kernel/sysproc.c` 中的 `sys_interpose()` 读取 mask 与路径参数，并保存到当前进程。

统一检查放在 `kernel/syscall.c` 的 `syscall()` 中。该函数原本根据 `a7` 中的编号直接调用 `syscalls[num]`；修改后，它先检查 mask 的第 `num` 位。若该位为 1 且不存在路径例外，就不再调用实际处理函数，而是把 `-1` 写入 trapframe 的 `a0`。

用户态 `user/sandbox.c` 负责启动受限命令。它先创建子进程，在子进程中调用 `interpose()` 设置限制，再通过 `exec()` 运行目标程序；父进程等待目标程序结束。

```text
sandbox 启动目标命令
  -> fork() 创建子进程
  -> 子进程调用 interpose() 保存 mask
  -> 子进程 exec() 运行目标程序
  -> 目标程序每次系统调用都经过 syscall()
  -> 命中 mask 时返回 -1
```

`kernel/proc.c` 的 `kfork()` 还需要把 mask 和路径复制给子进程。这样受限程序再次 `fork()` 时，新创建的进程也会继承相同规则。`Makefile` 则把 `sandbox` 加入 xv6 文件系统。

#figure(
  image("../assets/syscall/Sandbox a command.png", width: 88%),
  caption: [Sandbox a command 任务测试结果],
)

#part("实验中遇到的问题和解决方法")

如果限制只保存在 `sandbox.c` 的普通变量中，`exec()` 后这些变量会随原地址空间一起消失，内核也无法在系统调用入口读取它们。将状态放入 `struct proc` 后，限制可以跨越 `exec()`。测试还要求限制能够传递给后续子进程，因此 `kfork()` 中必须显式复制相关字段。

#part("实验心得")

所有系统调用都经过 `syscall()`，因此在这个统一入口检查 mask，可以覆盖进程可能调用的全部内核服务。沙箱功能并不需要修改每一个 `sys_*` 函数，关键是找到共同的分发位置，并把策略保存在生命周期合适的进程结构中。

== Sandbox with allowed pathnames(easy)

#part("实验目的")

本任务在系统调用屏蔽基础上增加路径例外。某个进程可能需要禁止大多数 `open` 或 `exec`，但仍允许访问一个指定路径。内核在判断系统调用编号后，还需要继续检查本次调用携带的路径参数。

#part("实验步骤")

路径例外只处理 `SYS_open` 和 `SYS_exec`，因为这两个系统调用的第 0 个参数都是路径字符串。检查过程位于 `kernel/syscall.c`：先判断当前编号是否属于这两个系统调用，再通过 `argstr()` 把用户地址空间中的路径复制到内核缓冲区，最后与进程保存的 `allowed_path` 比较。

```text
系统调用被 mask 命中
  -> 是否为 open 或 exec
  -> 否：拒绝
  -> 是：复制路径到内核
  -> 路径等于 allowed_path：放行
  -> 路径不同：拒绝
```

内核不能只保存用户态字符串指针。该地址属于用户页表，用户程序可能修改其内容，进程执行 `exec()` 后原地址也可能失效。`sys_interpose()` 因此在设置策略时就把字符串复制到 `struct proc` 的固定数组中。

#figure(
  image("../assets/syscall/Sandbox with allowed pathnames.png", width: 88%),
  caption: [Allowed pathnames 任务测试结果],
)

#part("实验中遇到的问题和解决方法")

实现时在内核中直接使用 `strcmp()`，编译器报告函数未声明。xv6 内核不链接宿主机的标准 C 库，只能使用内核已有的字符串函数。改用 `strncmp()` 并限制比较长度为 `MAXPATH` 后，编译通过。参数 `"-"` 表示没有允许路径，遇到该值时不应产生任何例外。

#part("实验心得")

权限判断除了检查“调用了哪个系统调用”，还可能需要检查“这次调用操作了什么对象”。路径来自用户地址空间，内核必须先安全复制再比较，不能直接信任用户传入的地址。

== Attack xv6(moderate)

#part("实验目的")

本任务利用实验环境中故意保留的未清零物理页，恢复前一个进程写入的秘密字符串。它用于说明页表隔离只能阻止两个正在运行的进程直接访问对方地址；如果物理页回收后保留旧内容，后来的进程仍可能通过内存复用读到这些数据。

#part("实验步骤")

`user/secret.c` 申请内存页，在其中写入固定标记 `This may help.`，并在偏移 16 字节处写入秘密。进程退出后，虚拟地址空间被销毁，对应物理页回到空闲链表，但实验版本没有清除页中的字节。

`user/attack.c` 随后通过 `sbrk()` 申请 8 个页面。物理分配器可能把刚释放的旧页面分配给 attack。程序扫描整段新内存，先查找固定标记，找到后再读取偏移 16 字节处的字符串。

```text
secret 获得物理页并写入数据
  -> secret 退出
  -> 物理页回到空闲链表，内容仍保留
  -> attack 通过 sbrk() 申请页面
  -> 分配器可能交回同一物理页
  -> attack 搜索标记并读取秘密
```

为了避免把随机残留字节误认为秘密，`attack.c` 还检查结果是否为非空字母数字字符串，并确认存在字符串结束符。`Makefile` 负责把 attack 测试程序加入文件系统。

#part("实验中遇到的问题和解决方法")

空闲链表的分配顺序会影响 attack 是否立即得到目标页，因此测试可能连续运行 attack。程序不能只检查某个固定页面或固定地址，而要遍历整个申请区域。检查固定标记与字符串格式后，可以减少误判。

#part("实验心得")

该任务说明物理页的清理也是进程隔离的一部分。旧进程已经退出、原虚拟地址也已经失效，但页中的数据仍然存在。内核重新把该页交给用户进程前应清零，否则新的地址映射会暴露旧数据。

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

本实验从实际系统调用路径出发，在 `syscall()` 入口增加统一限制，并通过物理页残留观察内存生命周期问题。最终测试通过说明系统调用 mask、子进程继承、路径例外和攻击程序均按要求工作。
