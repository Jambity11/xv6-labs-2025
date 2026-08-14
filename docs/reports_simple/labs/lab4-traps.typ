#import "../templates/lab-report.typ": part

= Lab4: Traps

对应源码分支：#link("https://github.com/JambitX11/xv6-labs-2025/tree/traps")[https://github.com/JambitX11/xv6-labs-2025/tree/traps]

本实验围绕 xv6 中的 trap 机制展开。处理器在执行系统调用、发生异常或接收到中断时，需要暂停当前程序并进入内核；内核完成处理后，还要恢复用户程序原有的执行状态。实验先从 RISC-V 汇编入手，观察 C 函数调用在寄存器和指令层面的具体形式；随后利用内核栈帧实现调用栈回溯；最后通过修改时钟中断的处理过程，实现用户级定时告警。

从执行过程看，一次 trap 可以概括为：

```text
用户程序正在运行
  -> 系统调用、异常或中断发生
  -> 保存用户寄存器并进入内核
  -> 内核处理事件
  -> 恢复寄存器并返回用户程序
```

三个任务分别研究这条路径所依赖的指令、内核栈和寄存器现场。

== RISC-V assembly (easy)

#part("实验目的")

本任务要求阅读 `user/call.c` 及其编译生成的 `user/call.asm`，回答 `answers-traps.txt` 中有关函数参数、函数调用、返回地址、字节序和可变参数的问题。通过对照 C 代码与汇编代码，可以直接观察高级语言中的一次函数调用如何落实为寄存器赋值和跳转指令，并为后续分析 trap 保存的寄存器现场打下基础。

函数调用需要调用者和被调用者遵守同一套规则，否则被调用函数无法知道参数放在哪里。RISC-V 规定前八个参数依次放在 `a0` 至 `a7` 中，返回值通常也放在 `a0` 中。例如调用 `printf("%d %d\n", 12, 13)` 时，`a0` 保存格式字符串地址，`a1` 保存 12，`a2` 保存 13。

执行 `jal` 或 `jalr` 时，处理器一方面跳转到目标函数，另一方面把下一条指令地址写入 `ra`。`ra` 记录了函数执行完毕后应该回到哪里，其作用相当于保存返回位置。被调用函数最后执行 `ret`，处理器便根据 `ra` 回到调用者。该任务还涉及 little-endian 字节序，即一个多字节整数的低位字节存放在较低的内存地址中。

#part("实验步骤")

首先，在 `traps` 分支运行 `make fs.img`，由编译系统生成便于阅读的 `user/call.asm`。随后在该文件中定位 `<main>`、`<f>`、`<g>` 和 `<printf>`，检查调用 `printf` 前对参数寄存器的赋值。格式字符串地址位于 `a0`，两个整数参数依次位于 `a1` 和 `a2`，因此题目所问的整数 13 保存在 `a2` 中。`printf` 的地址由 `<printf>` 标签前的地址确定，调用结束后 `ra` 的值则是 `jal` 或 `jalr` 后一条指令的地址。

阅读汇编时还需以实际生成结果为准。由于 `f()` 和 `g()` 的逻辑较短，编译器可能将它们内联并提前计算 `f(8) + 1`，所以 `main()` 中不一定存在对这两个函数的跳转指令。这里没有根据 C 源码推测调用位置，而是通过 `call.asm` 判断编译器最终生成了哪些指令。

对于题目给出的字节序程序，将代码临时放入 `user/call.c` 的 `main()` 中并在 xv6 内运行。整数 `0x00646c72` 在 little-endian 机器中的内存字节为 `72 6c 64 00`，把其地址转换为字符串指针后得到 `"rld"`；十进制数 57616 以 `%x` 输出为 `e110`，因此完整输出为 `He110 World`。若处理器采用 big-endian，要得到相同字符串，应将整数调整为 `0x726c6400`，而 57616 不需要修改。

本任务最终只修改了 `answers-traps.txt`，其中记录各问题的分析结果。`user/call.asm` 是编译产物，`user/call.c` 仅用于临时验证题目中的程序，验证结束后恢复原内容。

#part("实验中遇到的问题和解决方法")

分析函数调用位置时，容易产生的误解是认为 C 源码中写出的函数一定会在汇编中对应一条 `call` 指令。实际检查发现，编译优化可能消除这类简单调用，因此答案必须以 `call.asm` 为依据。

对于 `printf("x=%d y=%d", 3)`，第二个 `%d` 没有对应的实参。`printf` 仍会按照调用约定读取下一个参数位置，但该位置中的内容并未由调用者设置，所以 `y` 的输出不是一个确定值。该现象源于 C 可变参数函数无法自动检查实参数量，属于未定义行为，并非 xv6 的输出错误。

#part("实验心得")

本任务将函数调用约定从概念落实到了具体寄存器和指令上。参数、返回值和返回地址都由明确的寄存器承担，C 代码中的函数结构则可能被编译优化改变。阅读汇编时需要区分源程序表达的逻辑与处理器最终执行的指令，不能简单地在二者之间逐行对应。

== Backtrace (moderate)

#part("实验目的")

本任务要求在内核中实现 `backtrace()`，打印到达当前位置之前经过的函数调用链。当内核发生 panic 或运行结果异常时，单独看到报错位置往往不足以判断原因；调用栈中的返回地址可以说明代码经过哪些函数到达当前状态，再借助 `addr2line` 将地址转换为源码位置，能够提高内核调试效率。

函数 A 调用函数 B，B 又调用函数 C 时，三次调用所需的局部数据和返回信息依次保存在内核栈中。每个函数占用的一段栈空间称为栈帧。xv6 使用 `s0` 作为 frame pointer，指向当前栈帧的固定位置；`fp - 8` 保存当前函数结束后要返回的地址，`fp - 16` 保存调用者的 frame pointer。栈帧之间因此形成了一条可以向上追踪的链。

```text
当前 fp
  fp - 8   -> 当前函数的返回地址
  fp - 16  -> 上一层函数的 fp
                         |
                         -> 再读取上一层返回地址和 fp
```

`backtrace()` 所做的事情就是反复读取这两个位置。它不需要知道每个函数的名字，只先打印返回地址；随后再由 `addr2line` 根据 `kernel/kernel` 中的调试信息，把地址转换为源文件和行号。

#part("实验步骤")

首先修改 `kernel/riscv.h`，增加读取 `s0` 寄存器的内联函数 `r_fp()`，使 C 代码能够取得当前 frame pointer。随后在 `kernel/defs.h` 中声明 `backtrace()`，供其他内核文件调用。

核心实现位于 `kernel/printf.c`。函数先通过 `r_fp()` 获得当前栈帧地址，再使用 `PGROUNDDOWN(fp)` 和 `PGROUNDUP(fp)` 计算该地址所在内存页的上下边界。循环过程中，从 `fp - 8` 读取并打印当前函数保存的返回地址，再从 `fp - 16` 读取上一层 frame pointer。更新后的 `fp` 指向调用者的栈帧，下一轮循环便会打印调用者的返回地址。该过程持续到 `fp` 越过当前内核栈页。

为验证实现，在 `kernel/sysproc.c` 的 `sys_pause()` 中调用 `backtrace()`。运行 `bttest` 后，将打印出的地址输入 `addr2line -e kernel/kernel`，检查其能否依次对应到系统调用处理、系统调用分发和 trap 入口附近的源码。验证通过后，又在 `kernel/printf.c` 的 `panic()` 中调用 `backtrace()`，使内核发生 panic 时可以自动输出调用路径。

本任务涉及的文件及作用如下：

- `kernel/riscv.h`：提供读取 frame pointer 的 `r_fp()`。
- `kernel/defs.h`：加入 `backtrace()` 的函数声明。
- `kernel/printf.c`：实现栈帧遍历，并在 `panic()` 中输出调用栈。
- `kernel/sysproc.c`：在 `sys_pause()` 中触发 backtrace，供 `bttest` 验证。

#part("实验中遇到的问题和解决方法")

回溯过程不能只依靠“frame pointer 是否为 0”决定何时停止。内核栈只占一个页面，如果沿错误的地址继续读取，可能访问当前内核栈之外的内存，得到无意义的返回地址，甚至再次触发异常。为此，程序在循环前确定当前栈页边界，并在每次迭代前检查 `fp` 是否仍位于该页内。

控制台打印的是内核虚拟地址，无法直接看出对应的函数名和源文件。实验使用带有调试信息的 `kernel/kernel` 作为符号文件，通过 `addr2line` 完成地址解析，从而确认打印结果确实反映了 `bttest` 触发的调用链，并排除输出地址只是偶然处于合法范围内的情况。

#part("实验心得")

Backtrace 的实现代码较少，但它清楚地展示了函数调用在栈中的组织方式。每层函数调用都会留下返回地址和上一层栈帧的位置，调试器所展示的调用栈正是根据这些信息恢复出来的。同时，栈遍历必须受到有效内存范围的约束，能够读取一个地址不代表该地址属于当前调用链。

== Alarm (hard)

#part("实验目的")

本任务为 xv6 增加用户级定时告警功能。用户程序调用 `sigalarm(interval, handler)` 后，进程每累计运行 `interval` 个时钟 tick，内核应安排其执行一次用户态 `handler`。处理函数调用 `sigreturn()` 后，程序继续执行被中断前的代码，并保持当时的寄存器值不变。

例如，用户程序执行 `sigalarm(2, periodic)` 后，每消耗两个时钟 tick，内核就应让它执行一次 `periodic()`。`periodic()` 不是一个永久替换原程序的新入口，它执行完 `sigreturn()` 后，原程序仍要从被中断的位置继续运行。

trapframe 可以理解为用户程序进入内核时留下的一份寄存器记录，其中既有程序计数器 `epc`，也有栈指针和通用寄存器。Alarm 使用这份记录改变程序下一步的执行位置，其完整过程如下：

```text
用户程序正常执行
  -> 时钟中断进入 usertrap()
  -> 备份当前 trapframe
  -> 将 epc 改成 handler 地址
  -> 返回用户态并执行 handler
  -> handler 调用 sigreturn()
  -> 恢复原 trapframe
  -> 从中断前的位置继续执行
```

#part("实验步骤")

第一步是为每个进程保存独立的 alarm 状态。在 `kernel/proc.h` 的 `struct proc` 中增加告警间隔、累计 tick 数、handler 地址、handler 是否正在执行的标志，以及一份备份 trapframe。这份备份保存“进入 handler 之前的程序状态”，不能直接使用当前 trapframe 代替，因为当前 trapframe 随后还要被修改为 handler 的入口状态。`kernel/proc.c` 负责在创建进程时初始化这些字段并分配备份空间，在进程释放时回收相应内存；创建子进程时，也需要保证子进程使用自己的计数和现场，不能与父进程共用备份。

第二步是接通两个系统调用。在 `kernel/syscall.h` 中分配 `sigalarm` 和 `sigreturn` 的系统调用号，在 `kernel/syscall.c` 中将编号映射到对应的内核处理函数；`user/user.h` 提供用户态声明，`user/usys.pl` 生成执行 `ecall` 的用户态入口。`kernel/sysproc.c` 中的 `sys_sigalarm()` 读取 interval 和 handler 参数，将其保存到当前进程，并重置计数状态；当 interval 为 0 时停止产生新的告警。`sys_sigreturn()` 将备份的 trapframe 恢复到当前 trapframe，并清除 handler 执行标志。

第三步是在 `kernel/trap.c` 的 `usertrap()` 中处理定时触发。`devintr()` 返回 2 表示本次 trap 来自时钟中断。此时，如果进程已经注册 alarm 且当前没有执行 handler，就将累计 tick 加一。达到 interval 后，内核复制完整 trapframe，清零计数并设置执行标志，然后把当前 `trapframe->epc` 改为用户提供的 handler 地址。内核随后沿原有返回路径进入用户态，处理器便从 handler 开始执行。

handler 最终调用 `sigreturn()` 再次进入内核。恢复原 trapframe 后，原来的 `epc`、通用寄存器和栈指针重新生效，因此系统调用返回时会回到被时钟中断打断的位置。为避免系统调用分发代码把返回值覆盖到 `a0`，`sys_sigreturn()` 还需返回原现场中保存的 `a0`。

最后在 `Makefile` 的 `UPROGS` 中加入 `$U/_alarmtest`，使测试程序被写入 xv6 文件系统。本任务修改的文件包括 `kernel/proc.h`、`kernel/proc.c`、`kernel/syscall.h`、`kernel/syscall.c`、`kernel/sysproc.c`、`kernel/trap.c`、`user/user.h`、`user/usys.pl` 和 `Makefile`。这些改动分别完成进程状态保存、系统调用接入、时钟中断触发、用户态接口和测试程序构建。

#part("实验中遇到的问题和解决方法")

在 `Makefile` 中加入 `alarmtest` 后，首次编译出现 `recipe commences before first target`。检查后确认，该错误来自 `UPROGS` 列表的续行格式被破坏，与 C 代码无关。修正新增行的缩进和前一行末尾的反斜杠，并重新将 `$U/_alarmtest` 放入原有变量定义后，编译恢复正常。

Alarm 功能还需要处理两处容易被忽略的状态问题。其一，若 handler 执行期间继续累计并再次触发告警，第二次保存会覆盖第一次保存的现场，之后无法正确返回。因此使用进程内的执行标志阻止 handler 重入，并在 `sigreturn()` 中解除该标志。其二，普通系统调用会把返回值写入用户寄存器 `a0`。若 `sigreturn()` 直接返回固定值，恢复后的 `a0` 会再次被覆盖，导致 `alarmtest` 的寄存器保持测试失败。解决方法是在恢复 trapframe 的同时保留原 `a0`，并将其作为 `sys_sigreturn()` 的返回值。

#part("实验心得")

Alarm 实现中的主要难点是控制流切换前后的现场管理，tick 计数只负责确定触发时机。将 `epc` 改为 handler 地址只能让程序跳转过去；只有完整保存并恢复 trapframe，用户程序才能在 handler 结束后继续原来的计算。重入保护和 `a0` 恢复也说明，修改 trap 返回路径时必须考虑系统调用框架随后还会对寄存器进行哪些操作。

== 实验结果

完成三个任务后，在 `traps` 分支运行：

```text
$ make grade
```

测试内容包括 `answers-traps.txt`、backtrace、alarmtest 的四个子测试、`usertests -q` 和运行时间检查。最终所有测试均通过，结果如下图所示。

#figure(
  image("../assets/traps/grade.png", width: 92%),
  caption: [Traps Lab 的 make grade 测试结果],
)

本实验依次从指令、内核栈和 trapframe 三个角度分析程序执行状态。RISC-V assembly 任务说明寄存器和跳转指令如何完成函数调用；Backtrace 任务根据栈帧中保存的信息恢复内核调用链；Alarm 任务在时钟中断到来时保存用户现场、改变返回地址，并通过 `sigreturn()` 恢复原状态。最终测试通过表明，新增调试功能和定时告警机制没有破坏 xv6 原有的系统调用、进程运行和用户态返回流程。
