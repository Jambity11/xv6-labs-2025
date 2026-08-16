# Lab 4 Traps 学习笔记

官网页面：

- <https://pdos.csail.mit.edu/6.1810/2025/labs/traps.html>

本地参考：

- 旧报告：`docs/reports_old/labs/lab4-traps.typ`
- 代码分支：`origin/traps`
- 基线分支：`origin/riscv`

## 先说明一个代码核对问题

当前可见的 `origin/riscv...origin/traps` diff 只显示了课程框架和测试程序：

```text
user/alarmtest.c
user/bttest.c
user/call.c
Makefile
conf/lab.mk
grade-lab-traps
gradelib.py
```

没有看到旧报告里提到的这些内核实现改动：

```text
kernel/riscv.h
kernel/defs.h
kernel/printf.c
kernel/sysproc.c
kernel/proc.h
kernel/proc.c
kernel/syscall.h
kernel/syscall.c
kernel/trap.c
user/user.h
user/usys.pl
```

所以这份笔记先写“这个 lab 应该怎么理解、应该怎么定位文件”。等后面如果找到你当时真正的 traps 实现分支，再把“你的具体 diff”补进去。

## 这个 Lab 真正在学什么

trap 是处理器从当前执行流切到内核的一类事件。xv6 里常见 trap 有三种：

- 系统调用：用户程序主动执行 `ecall`。
- 异常：例如非法访问地址、page fault。
- 中断：例如时钟中断、设备中断。

可以把一次用户态 trap 理解成：

```text
用户程序正在执行
  -> 发生 syscall / exception / interrupt
  -> trampoline.S 保存用户寄存器
  -> usertrap() 判断原因
  -> 内核处理事件
  -> usertrapret() 准备返回
  -> trampoline.S 恢复用户寄存器
  -> 用户程序继续执行
```

Lab4 的三个任务分别从不同角度观察这件事：

- RISC-V assembly：理解函数调用和寄存器约定。
- Backtrace：理解内核栈帧如何保存调用链。
- Alarm：理解时钟中断如何临时改变用户程序的返回位置，并在之后恢复现场。

## 任务一：RISC-V assembly

### 先用人话说

这个任务是在看：

> C 语言里的一次函数调用，在 CPU 眼里到底是怎么传参数、跳过去、再跳回来的。

比如你写：

```c
printf("%d %d\n", 12, 13);
```

C 代码看起来很自然，但 CPU 不认识“第一个参数”“第二个参数”这种说法。大家必须提前约好：第一个参数放 `a0`，第二个参数放 `a1`，第三个参数放 `a2`，返回地址放 `ra`。

所以题目问“13 在哪个寄存器”，其实是在问：按照 RISC-V 的约定，第三个参数放哪里？答案就是 `a2`。

这个任务不是为了让你成为汇编专家，而是为了后面的 trap 做准备：trap 本质上也是在保存和恢复寄存器现场。

### 要理解的行为

这一步主要读 `user/call.c` 和编译产物 `user/call.asm`。目标是看懂 C 函数调用最后如何变成寄存器和跳转指令。

RISC-V 调用约定里：

- `a0` 到 `a7` 保存前 8 个参数。
- `a0` 通常也保存返回值。
- `ra` 保存返回地址。
- `s0` 常用作 frame pointer。

例如：

```c
printf("%d %d\n", 12, 13);
```

通常对应：

```text
a0 = 格式字符串地址
a1 = 12
a2 = 13
call printf
```

### 先抓住一句话

这个任务是在告诉你：

> C 语言里的“调用函数”，到了 CPU 眼里就是把参数放进约定好的寄存器，然后跳到函数地址，最后靠 `ra` 跳回来。

所以它不是让你学完整汇编，而是让你看懂后面 trap、syscall、alarm 都会用到的寄存器现场。

### 真实执行路径

以 `printf("%d %d\n", 12, 13)` 为例：

```text
C 代码调用 printf
  -> 编译器把格式字符串地址放进 a0
  -> 把 12 放进 a1
  -> 把 13 放进 a2
  -> 执行 jal / jalr 跳到 printf
  -> CPU 同时把下一条指令地址保存到 ra
  -> printf 执行完 ret
  -> ret 根据 ra 回到调用点之后
```

所以题目问“13 在哪里”，不是问 C 变量，而是在问“按照 RISC-V 调用约定，第几个参数放在哪个寄存器”。

### 怎么知道要看哪些文件

这个任务不要求新增内核功能，所以先看：

```text
user/call.c
user/call.asm
answers-traps.txt
```

如果要理解寄存器含义，再看：

```text
kernel/riscv.h
RISC-V calling convention
```

### 关键理解

C 源码里有函数调用，不代表汇编里一定有对应的 `call`。编译器可能把很短的函数内联，甚至直接算出结果。所以回答这类问题时不能只看 C 代码，要看实际生成的 `.asm`。

小端序也在这个任务里出现：多字节整数的低位字节放在低地址。如果把整数地址当字符串地址读，输出取决于内存中的字节顺序。

### 自检问题

1. 为什么 `printf("%d %d", 12, 13)` 的 13 通常在 `a2`？
2. `ra` 保存的是被调用函数地址，还是调用结束后要回去的地址？
3. 为什么 C 代码里的 `f()`、`g()` 不一定在汇编里还能看到调用？

## 任务二：Backtrace

### 先用人话说

`backtrace` 就是“程序走到这里之前，是从哪些函数一路调用过来的”。

如果内核崩了，只看到最后一行错误经常不够。你还想知道：

```text
是谁调用了它？
上一层又是谁？
再上一层又是谁？
```

函数调用时会在栈里留下痕迹：返回地址和上一层栈帧的位置。`backtrace()` 就是顺着这些痕迹往回找。

可以把它想成沿着脚印倒着走：

```text
当前函数
  -> 调用它的函数
  -> 再上一层函数
  -> 再上一层...
```

它一开始打印的是地址，不是函数名；地址再通过 `addr2line` 才能翻译成源码位置。

### 要实现的行为

`backtrace()` 打印当前内核调用链中的返回地址。它通常用于调试：panic 时只知道最后崩在哪不够，调用链能告诉你代码是怎么走到这里的。

函数调用时，栈帧里保存了返回地址和上一层 frame pointer。xv6/RISC-V 中，`s0` 作为 frame pointer 时，常见布局是：

```text
当前 fp
  fp - 8   保存返回地址
  fp - 16  保存上一层 fp
```

沿着 `fp - 16` 一层层往上走，就能打印调用链。

### 先抓住一句话

Backtrace 的本质是：

> 每次函数调用都会在栈里留下“我从哪里来、上一层栈帧在哪”的痕迹；`backtrace()` 就是顺着这些痕迹往回走。

它打印的不是函数名，而是返回地址。函数名和行号要之后用符号信息解析。

### 真实执行路径

以 `bttest` 触发 `pause()` 为例：

```text
用户程序 bttest 调用 pause(1)
  -> ecall 进入内核
  -> usertrap()
  -> syscall()
  -> sys_pause()
  -> sys_pause() 中调用 backtrace()
  -> backtrace() 读取当前 fp，也就是 s0
  -> 从 fp - 8 读返回地址
  -> 从 fp - 16 读上一层 fp
  -> 重复，直到走出当前内核栈页
```

打印出来的一串地址，大概对应：

```text
backtrace 的调用者
sys_pause
syscall
usertrap
```

具体函数名要用 `addr2line -e kernel/kernel <地址>` 解析。

### 怎么知道要改哪些文件

要从 C 代码读取 frame pointer，需要：

```text
kernel/riscv.h     增加 r_fp()，读取 s0
```

要实现并声明 backtrace：

```text
kernel/printf.c    实现 backtrace()，也适合在 panic() 中调用
kernel/defs.h      声明 backtrace()
```

要触发测试：

```text
kernel/sysproc.c   在 sys_pause() 或测试要求的位置调用 backtrace()
user/bttest.c      用户态触发 pause()
```

如果输出地址后要对应源码行，用：

```text
addr2line -e kernel/kernel <address>
```

### 实现主线

```text
fp = r_fp()
栈页下界 = PGROUNDDOWN(fp)
栈页上界 = PGROUNDUP(fp)

while fp 在当前栈页内:
    ra = *(uint64 *)(fp - 8)
    print ra
    fp = *(uint64 *)(fp - 16)
```

### 为什么要限制在当前栈页

不能一直沿着 fp 走到 0，因为一旦 fp 错了，就可能把无关内存解释成栈帧。xv6 的内核栈按页分配，所以用当前 fp 所在页作为边界是一种简单保护。

### 容易错的点

- `fp - 8` 是返回地址，`fp - 16` 是上一层 fp，顺序不要反。
- 打印出来的是地址，不是函数名；函数名要靠符号表解析。
- backtrace 只能在编译保留 frame pointer 的前提下可靠工作。xv6 Makefile 使用 `-fno-omit-frame-pointer`，这正是原因。

### 自检问题

1. 为什么 backtrace 不需要知道每个函数的名字？
2. 为什么要用 `PGROUNDDOWN(fp)` 和 `PGROUNDUP(fp)` 找栈页边界？
3. 如果编译器省略 frame pointer，backtrace 会遇到什么问题？

## 任务三：Alarm

### 先用人话说

`alarm` 就是给用户程序设一个闹钟。

用户程序说：

```text
每运行 2 个 tick，就先去执行一下 periodic()
```

但是这里有个关键点：内核不是像普通 C 函数那样直接调用 `periodic()`。因为 `periodic()` 是用户态函数，应该在用户态执行。

内核真正做的是：

> 时钟中断来时，把“这次返回用户态后要执行的位置”改成 handler 的地址。

也就是说，程序本来被打断在某一行，正常应该回到那一行继续执行。alarm 触发后，内核先保存原来的现场，然后把返回地址改成 handler。handler 做完后调用 `sigreturn()`，内核再把原来的现场恢复，程序继续从刚才被打断的地方跑。

它像这样：

```text
原程序正在跑
  -> 闹钟响了
  -> 先跳去 handler
  -> handler 说 sigreturn
  -> 回到原程序刚才被打断的位置
```

所以这个任务最难的地方不是数 tick，而是“跳去 handler 前保存现场，handler 结束后完整恢复现场”。

### 要实现的行为

`sigalarm(interval, handler)` 让当前进程每运行一定数量的 tick 后，进入用户提供的 handler。handler 调用 `sigreturn()` 后，程序要回到被打断的位置继续执行。

最核心的流程是：

```text
用户程序注册 sigalarm(interval, handler)
  -> 用户程序继续运行
  -> 时钟中断进入 usertrap()
  -> 内核发现 tick 数达到 interval
  -> 备份当前 trapframe
  -> 把 trapframe->epc 改成 handler 地址
  -> 返回用户态，开始执行 handler
  -> handler 调用 sigreturn()
  -> 内核恢复备份 trapframe
  -> 回到被中断的位置继续运行
```

这里的难点不是 tick 计数，而是保存和恢复用户现场。

### 先抓住一句话

Alarm 的本质是：

> 时钟中断来的时候，内核偷偷把“这次返回用户态要去哪里”从原来的位置改成 handler；handler 结束后，再通过 `sigreturn()` 把原来的寄存器现场恢复回来。

所以它不是开了一个新线程，也不是内核直接调用用户函数。它只是修改了 trap 返回用户态时的 `epc`。

### 真实执行路径

注册 alarm：

```text
用户程序 sigalarm(2, periodic)
  -> a0 = 2
  -> a1 = periodic 的用户虚拟地址
  -> ecall 进入内核
  -> sys_sigalarm()
  -> 把 interval 和 handler 地址保存到当前 struct proc
```

触发 alarm：

```text
用户程序继续正常执行
  -> 时钟中断发生
  -> usertrap()
  -> devintr() 判断这是 timer interrupt
  -> 当前进程 alarm_ticks++
  -> ticks 达到 interval
  -> 复制当前 trapframe 作为备份
  -> 设置 alarm_active，防止重入
  -> 把当前 trapframe->epc 改成 handler 地址
  -> 返回用户态
  -> CPU 从 handler 开始执行
```

从 handler 返回：

```text
handler 调用 sigreturn()
  -> ecall 再次进入内核
  -> sys_sigreturn()
  -> 把备份 trapframe 恢复回来
  -> 清 alarm_active
  -> 返回原来的 a0
  -> 回到最初被时钟中断打断的位置
```

最容易误解的是“内核调用 handler”。更准确地说，内核没有像 C 函数那样调用 handler；它只是修改 `epc`，让 `sret` 返回用户态时跳到 handler。

### 怎么知道要改哪些文件

这是新增系统调用，所以先套 syscall 五件套：

```text
kernel/syscall.h
kernel/syscall.c
kernel/sysproc.c
user/user.h
user/usys.pl
```

因为 alarm 是每个进程自己的状态，所以看：

```text
kernel/proc.h
kernel/proc.c
```

因为触发点是时钟中断，所以看：

```text
kernel/trap.c
```

因为测试程序要进入 xv6 文件系统，所以看：

```text
Makefile
user/alarmtest.c
```

### 进程里需要保存什么

通常需要这些状态：

```text
alarm_interval      每隔多少 tick 触发一次
alarm_ticks         当前已经累计多少 tick
alarm_handler       用户态 handler 地址
alarm_active        当前是否已经在 handler 中，防止重入
alarm_trapframe     进入 handler 前的用户寄存器备份
```

这些字段放在 `struct proc`，因为 alarm 是当前进程属性，不是全局属性。

### `sys_sigalarm()` 做什么

读取用户参数：

```text
interval
handler
```

保存到当前进程：

```text
p->alarm_interval = interval
p->alarm_handler = handler
p->alarm_ticks = 0
p->alarm_active = 0
```

如果 `interval == 0`，通常表示关闭 alarm。

### `usertrap()` 做什么

时钟中断来到时，`devintr()` 会告诉内核这是 timer interrupt。然后：

```text
if 当前进程设置了 alarm 且不在 handler 中:
    alarm_ticks++
    if alarm_ticks == alarm_interval:
        alarm_ticks = 0
        alarm_active = 1
        保存完整 trapframe
        trapframe->epc = alarm_handler
```

修改 `epc` 的意思是：这次从内核返回用户态时，不回到原来被打断的位置，而是先去 handler。

### `sys_sigreturn()` 做什么

handler 执行完后调用 `sigreturn()`。这会再次进入内核，内核需要：

```text
恢复之前保存的 trapframe
alarm_active = 0
返回原来的 a0
```

为什么要注意 `a0`？因为系统调用分发逻辑会把 `sys_sigreturn()` 的返回值写进 `trapframe->a0`。如果随便返回 0，可能覆盖被中断程序原来保存在 `a0` 的值，`alarmtest` 会检查这个问题。

### 为什么要防止 handler 重入

如果 handler 很慢，还没调用 `sigreturn()`，新的时钟中断又来了。如果内核再次触发 alarm，就会覆盖第一次保存的 trapframe：

```text
第一次 alarm 保存原现场 A
  -> 进入 handler
  -> handler 还没 sigreturn
第二次 alarm 又保存现场 B
  -> A 丢失
  -> 无法回到真正被中断的位置
```

所以需要 `alarm_active` 之类的标志，handler 运行期间不再触发新的 handler。

### `alarmtest` 在测什么

`user/alarmtest.c` 不是只测“能不能打印 alarm”。它主要测：

- handler 至少会被调用一次；
- handler 能被周期性调用；
- handler 返回后，普通寄存器值保持不变；
- handler 不能重入；
- `sigreturn()` 不能破坏 `a0`。

这也是为什么保存整个 trapframe，而不是只保存 `epc`。

### 容易错的点

- 只改 `epc` 不保存完整 trapframe，会破坏寄存器。
- handler 期间允许重入，会覆盖原现场。
- `sys_sigreturn()` 返回固定值，会破坏 `a0`。
- alarm 状态不放在 `struct proc`，无法做到每个进程独立。
- fork 时是否继承 alarm 状态要按题目测试要求处理，不能让父子共用同一个 trapframe 备份页。

### 自检问题

1. 为什么 alarm handler 是用户态函数，而不是内核函数？
2. 为什么触发 handler 只需要改 `trapframe->epc`？
3. 为什么只保存 `epc` 不够？
4. 为什么 `sigreturn()` 的返回值会影响 `a0`？
5. handler 重入会破坏哪一份状态？

## 这个 Lab 最应该留下的理解

Lab4 的主线可以压缩成三句话：

1. trap 是处理器从用户程序转入内核的统一机制，syscall、异常、中断都靠它。
2. backtrace 依赖函数调用留下的栈帧链，alarm 依赖 trapframe 保存的用户寄存器现场。
3. 修改 trap 返回路径时，最重要的是保存、修改、恢复现场的边界要清楚。

## 写 Markdown 报告时的方向

这一章建议按“程序状态”组织，而不是按代码文件堆：

```text
RISC-V assembly: 函数调用时状态放在哪些寄存器
Backtrace: 内核函数调用时状态如何留在栈帧
Alarm: 用户程序被中断时状态如何保存在 trapframe
```

这样三部分是连起来的：

- assembly 解释寄存器；
- backtrace 解释内核栈；
- alarm 解释 trapframe。

在找到你的实际 traps 实现 diff 后，再补一节“我的实现具体改了哪些文件”，把旧报告中的实现描述和真实代码逐项对上。
