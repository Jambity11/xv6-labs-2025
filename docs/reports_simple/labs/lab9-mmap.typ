#import "../templates/lab-report.typ": part

= Lab9: mmap

对应源码分支：#link("https://github.com/JambitX11/xv6-labs-2025/tree/mmap")[https://github.com/JambitX11/xv6-labs-2025/tree/mmap]

本实验实现 xv6 中面向文件的 `mmap()` 和 `munmap()` 机制。`mmap` 的作用是把文件的一段内容映射到进程的虚拟地址空间中，使用户程序可以像访问普通内存一样访问文件内容；`munmap` 则负责解除映射，并在必要时把用户对映射内存的修改写回文件。与普通 `read()` 和 `write()` 相比，`mmap()` 的特殊之处在于它把文件系统和虚拟内存系统连接在一起：文件内容不再只通过文件描述符顺序读写，而是通过 page fault 懒加载到用户页表中。

这个实验虽然在题目上只有一个任务点，但实际涉及多条内核路径。首先，内核需要新增 `mmap` 和 `munmap` 两个系统调用入口；其次，每个进程需要记录自己的文件映射区域，即 VMA；再次，用户访问尚未加载的映射页时，内核需要在 page fault 路径中分配物理页、读取文件内容并建立页表映射；最后，`munmap()`、`exit()` 和 `fork()` 都必须正确处理 VMA 的生命周期。也就是说，本实验的核心不是“把文件一次性读入内存”，而是建立一种延迟的、按页加载的文件到虚拟地址空间的关系。

== Memory-mapped files (hard)

#part("实验目的")

本任务要求在 xv6 中实现足以通过 `mmaptest` 的内存映射文件功能。用户调用：

```c
mmap(addr, len, prot, flags, fd, offset)
```

时，本实验只需要支持题目限定的子集：`addr` 和 `offset` 可以假定为 0，`prot` 主要包含 `PROT_READ`、`PROT_WRITE` 和 `PROT_EXEC`，`flags` 主要包含 `MAP_SHARED` 与 `MAP_PRIVATE`。`MAP_SHARED` 表示对映射内存的修改需要写回文件，`MAP_PRIVATE` 表示修改只影响当前进程，不写回原文件。

实验要求 `mmap()` 本身采用 lazy 策略，即系统调用返回时不分配物理页，也不读取文件。内核只在进程真正访问映射地址并触发 page fault 时，才分配一个物理页，从文件中读入对应页的数据，并将该页映射到用户页表中。这样的设计保证映射大文件时不会因为 `mmap()` 一次性读入所有内容而变慢，也允许映射文件大小超过可用物理内存。

本实验的正确性目标包括：文件内容能够通过映射地址读取；`MAP_PRIVATE` 的修改不写回文件；`MAP_SHARED` 的修改在 `munmap()` 或进程退出时写回文件；只读映射不允许写入；`munmap()` 后继续访问应触发异常并杀死进程；`fork()` 后子进程能够继承父进程的 VMA，并在访问时独立懒加载映射页。

#part("实验步骤")

实验首先补齐系统调用入口。在 `kernel/syscall.h` 中为 `mmap` 和 `munmap` 分配系统调用号，在 `kernel/syscall.c` 中声明 `sys_mmap()` 和 `sys_munmap()` 并加入 `syscalls[]` 表，在 `user/user.h` 中声明用户态函数原型，在 `user/usys.pl` 中加入对应的系统调用桩。这样，`user/mmaptest.c` 才能从用户态通过 `ecall` 进入内核实现。`kernel/fcntl.h` 已在 `LAB_MMAP` 条件下给出 `PROT_READ`、`PROT_WRITE`、`PROT_EXEC`、`MAP_SHARED` 和 `MAP_PRIVATE` 等常量，后续实现围绕这些标志检查权限。

随后在 `kernel/proc.h` 中增加 VMA 结构。VMA 是 virtual memory area 的缩写，用来描述一个进程地址空间中的一段连续映射区域。本实验采用固定大小数组，因为 xv6 内核没有通用的可变长度内核分配器，题目也提示 16 个 VMA 足够通过测试。结构中记录是否被使用、起始虚拟地址、映射长度、权限、映射标志、文件偏移和对应的 `struct file *`：

```c
#define NVMA 16

struct vma {
  int used;
  uint64 addr;
  uint64 len;
  int prot;
  int flags;
  uint64 offset;
  struct file *file;
};
```

每个 `struct proc` 中增加：

```c
struct vma vmas[NVMA];
```

`kernel/proc.c` 中相应修改 `allocproc()` 和 `freeproc()`，在进程结构被分配或回收时初始化 VMA 表，避免复用 `struct proc` 时残留旧映射信息。

`sys_mmap()` 实现在 `kernel/sysfile.c` 中。由于这里已有 `argfd()`，可以方便地从用户传入的文件描述符取得 `struct file *`。`sys_mmap()` 的主要工作不是读文件，而是验证参数并登记 VMA。它检查 `len` 是否有效、`addr` 和 `offset` 是否符合实验假设、映射权限是否与文件打开权限兼容。例如，如果用户要求 `MAP_SHARED | PROT_WRITE`，则文件必须以可写方式打开；否则用户通过共享映射写入后无法合法写回文件。

在选择映射地址时，实验从 `TRAPFRAME` 下方向低地址分配 VMA 区域。普通用户程序的 text、data、heap 从低地址向上增长，而 `TRAPFRAME` 与 `TRAMPOLINE` 位于用户虚拟地址空间最高处。将 mmap 区域放在高地址并向下分配，可以减少与普通堆空间冲突的可能。`mmap()` 成功后调用 `filedup()` 增加文件引用计数，因为用户可能在 `mmap()` 之后立即 `close(fd)`；VMA 必须独立持有文件引用，映射才能继续有效。

页的真正加载发生在 `kernel/vm.c` 的 `vmfault()` 中。用户访问 mmap 区域时，RISC-V 触发 load page fault 或 store page fault，`kernel/trap.c` 中的 `usertrap()` 调用 `vmfault()`。修改后的 `vmfault()` 先检查地址是否小于 `MAXVA`，然后判断该地址是否属于普通 lazy sbrk 区域或某个 VMA。若地址位于 VMA 中，就按照访问类型检查权限：读 fault 要求 `PROT_READ`，写 fault 要求 `PROT_WRITE`。权限合法时分配物理页，将文件中对应偏移的数据读入该页，再根据 `prot` 设置 `PTE_R`、`PTE_W`、`PTE_X` 和 `PTE_U` 权限并调用 `mappages()` 建立映射。

文件偏移由 VMA 起点和 fault 地址共同决定：

```text
file offset = vma.offset + (fault_va - vma.addr)
```

因此同一个文件映射中的不同虚拟页会从文件的不同位置懒加载。若映射长度超过文件实际大小，`readi()` 只会读到文件已有部分，物理页剩余部分由于 `kalloc()` 后执行了 `memset()`，自然保持为零。这正好符合测试中 1.5 页文件映射为 2 页时，最后半页应读到 0 的要求。

`sys_munmap()` 负责解除映射。实现中先根据用户传入地址找到对应 VMA，再按页遍历需要解除的范围。由于 mmap 是懒加载，有些页可能从未访问过，页表中没有有效 PTE；这种情况应直接跳过，不能 panic。对于已经实际映射的页，如果该 VMA 是 `MAP_SHARED`，则在解除映射前将对应页内容写回文件。写回时按页单独使用 `begin_op()` 和 `end_op()`，避免一个日志事务覆盖太多数据块；同时写回长度不能超过文件当前大小，防止把测试中原本只有 1.5 页的文件错误扩展为 2 页。完成写回后调用 `uvmunmap()` 取消页表映射并释放物理页。

`munmap()` 还需要维护 VMA 的范围。题目保证不会在 VMA 中间“打洞”，只会解除开头、结尾或整个区域。因此实现分三种情况：若解除整个 VMA，则调用 `fileclose()` 释放文件引用并清空 VMA；若解除开头部分，则将 `vma.addr` 向后移动，并同步增加 `vma.offset`；若解除结尾部分，则缩短 `vma.len`。这样，剩余区域仍然能在后续 page fault 中找到正确的文件偏移。

进程退出和 fork 也需要处理 mmap。`kernel/proc.c` 的 `kexit()` 中，在关闭普通文件描述符之前遍历所有 VMA，并按 `munmap()` 的语义写回与释放映射区域。这样即使用户没有显式调用 `munmap()`，`MAP_SHARED` 的修改也不会丢失。`kfork()` 中复制父进程的 VMA 表给子进程，并对每个有效 VMA 调用 `filedup()`。本实验不要求父子进程共享同一物理页，因此 fork 时只复制 VMA 元信息即可；子进程第一次访问映射地址时，会在自己的 page fault 路径中独立分配和读入物理页。

此外，`copyin()` 和 `copyout()` 也需要与懒加载配合。内核从用户地址读取数据时，如果该地址属于尚未加载的 mmap 区域，应允许 `copyin()` 触发 `vmfault()` 来补页；内核向用户地址写数据时，`copyout()` 也可能需要补出可写映射页。这样系统调用读写用户缓冲区时不会因为 mmap 页尚未物理分配而错误失败。

本任务实际修改文件包括 `kernel/syscall.h`、`kernel/syscall.c`、`user/user.h`、`user/usys.pl`、`kernel/proc.h`、`kernel/proc.c`、`kernel/sysfile.c`、`kernel/vm.c`、`kernel/defs.h` 和 `Makefile`。其中系统调用相关文件负责用户态到内核态的入口，`proc.h` 和 `proc.c` 负责 VMA 生命周期，`sysfile.c` 负责 `mmap()` 与 `munmap()` 语义，`vm.c` 负责 page fault 懒加载和用户地址复制路径，`defs.h` 用于暴露进程退出时调用的 mmap 清理函数。

#part("实验中遇到的问题和解决方法")

本实验首先遇到的是头文件依赖问题。在 `kernel/vm.c` 中访问 `struct file` 和 `vma->file->ip` 时，需要包含 `file.h`；但 `file.h` 中的 `struct inode` 包含 `struct sleeplock lock`，因此必须先包含 `sleeplock.h`，同时 `PROT_READ`、`PROT_WRITE` 和 `PROT_EXEC` 定义在 `fcntl.h` 中。最终通过在 `vm.c` 中按顺序包含 `fs.h`、`sleeplock.h`、`file.h` 和 `fcntl.h` 解决了 `field 'lock' has incomplete type` 以及 `PROT_READ undeclared` 等编译错误。

第二个问题出现在 `kernel/sysfile.c`。`sys_mmap()` 选择从 `TRAPFRAME` 下方分配 mmap 虚拟地址，因此需要包含 `memlayout.h`。如果没有包含该头文件，编译器会报出 `TRAPFRAME undeclared`。同时，调试过程中曾定义了未被使用的 `find_vma()` 辅助函数，在 xv6 的 `-Werror` 编译设置下，未使用的 `static` 函数也会导致编译失败。解决方法是补充 `#include "memlayout.h"`，并删除未使用的辅助函数或确保它被实际调用。

第三个问题是 `usertests` 的 `copyin` 测试触发 `panic: walk`。原因是 `copyin()` 在访问坏用户地址时调用了 `vmfault()`，而 `vmfault()` 入口没有先检查 `va >= MAXVA`，后续 `ismapped()` 调用 `walk()` 时触发了 `walk()` 内部的非法地址 panic。正确行为应该是系统调用返回错误，而不是内核 panic。最终在 `vmfault()` 开头加入地址范围检查，并在 `ismapped()` 中也补充保护，使非法用户地址能够被安全拒绝，`usertests` 中的 `copyin` 测试随即通过。

第四个需要特别注意的问题是 `munmap()` 写回长度。`mmaptest` 中构造的文件长度为 1.5 页，却映射了 2 页。如果对第二页写回完整 `PGSIZE`，会把文件错误扩展到两页。实验通过读取 inode 的 `size` 并限制每页写回长度，保证只把文件原本存在的范围写回。未映射或未访问过的页也必须跳过，因为 lazy loading 使 VMA 中的部分虚拟页可能从未建立过 PTE。

最后，`mmaptest` 中“munmap 后访问”和“写只读映射”会故意制造用户态 page fault。测试输出中出现 `usertrap(): unexpected scause` 并不一定表示实验失败；关键是子进程应被杀死，父进程随后确认状态并输出对应 OK。这一现象说明权限位和解除映射后的页表状态都按预期工作。

#part("实验心得")

`mmap` 实验把前面多个 lab 的知识联系在了一起。它既需要 syscall lab 中新增系统调用的完整链路，也需要 lazy allocation 和 COW lab 中对 page fault 的理解，还需要 file system lab 中对 `readi()`、`writei()`、inode 锁和日志事务的认识。只有把这些机制串成一条数据流，才能理解为什么 `mmap()` 本身不读文件，而是在用户第一次访问映射地址时才真正分配和读取。

本实验也让我更清楚地区分了“虚拟地址区域”和“实际物理页”。VMA 只是进程地址空间中的一段承诺：这段地址如果被访问，应当来自某个文件。它并不等于已经分配好的物理内存。真正的物理页只有在 page fault 发生后才出现，并且可以在 `munmap()` 时释放。这种设计使操作系统能够用较低成本支持大文件映射，也解释了为什么现代系统普遍采用按需分页。

此外，`mmap` 的难点不在单个函数，而在生命周期的闭环。`mmap()` 要持有文件引用，page fault 要读入内容，`munmap()` 要写回和释放，`exit()` 要代替用户清理遗留映射，`fork()` 要复制 VMA 并维护引用计数。任何一个环节遗漏，都会表现为文件修改丢失、引用泄漏、页表释放 panic 或子进程访问失败。通过本实验可以更直观地认识到，内核功能往往不是孤立实现的接口，而是一组跨模块状态在多个路径上的一致维护。

== 实验结果

完成本 Lab 后，在 `mmap` 分支运行：

```text
$ make grade
```

最终 `mmaptest` 中的 basic、private、read-only、read/write、dirty、not-mapped unmap、lazy access、two files、fork、munmap_noaccess 和 read_only_write 测试均通过，`usertests` 和 time 测试也通过，得分为满分。测试结果如下图所示。

#figure(
  image("../assets/mmap/grade.png", width: 92%),
  caption: [mmap Lab 的 make grade 测试结果],
)

测试通过表明，VMA 登记、文件映射懒加载、共享映射写回、私有映射隔离、部分解除映射、退出清理、fork 继承以及非法访问保护等关键路径均符合实验要求。
