#import "../templates/lab-report.typ": part

= Lab9: mmap

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/mmap")[https://github.com/Jambity11/xv6-labs-2025/tree/mmap]

程序要读一个文件，通常用 `read()` 一段一段拷进自己的缓冲区。但你有没有想过另一种用法：能不能让文件的内容直接「出现在」内存地址里，用访问内存的方式去访问文件？比如把文件映射到地址 `A` 之后，读 `A` 处的字节就是读文件的第一个字节，写 `A` 处还能写回文件？这就是 `mmap` 要解决的问题。

它的价值在于两点：一是省掉反复的 `read`/`write` 拷贝；二是可以「按需」加载——映射一个超大文件时，不需要一开始就把整个文件读进内存。现代操作系统的按需分页、共享库，底层都是这套机制。

初步想法很克制：`mmap()` 调用时*只登记、不干活*。在进程地址空间里记一段「映射区」（起始地址、长度、对应的文件、偏移、权限），不分配物理页、也不读文件。等用户真的访问这段地址、触发 page fault 时，内核才分配一页物理内存、从文件对应位置读入内容、建立页表映射。这就是懒加载——把「读文件」推迟到「真正用到那一页」的那一刻。

#part("前置知识")

*VMA：一段地址空间的承诺。*VMA（virtual memory area）描述进程地址空间里一段连续区域的性质——它对应哪个文件、什么偏移、什么权限。VMA 本身不是物理内存，它只是「如果这段地址被访问，应该来自哪里」的登记表。这是理解 mmap 的核心。

*page fault 是加载的触发点。*用户访问一段没建立映射的地址，硬件触发 page fault（load 或 store），`stval` 给出出错地址。内核在 `usertrap()` 里认出「这是 mmap 区域的懒加载」，就去补页。这跟 lab5 的 COW、lab3 里 sbrk 的懒分配是同一套「缺页即补」的思路。

*文件读取与写回。*补页时用 `readi()` 从 inode 读对应偏移；`MAP_SHARED` 的映射在 `munmap()`/退出时要反过来用 `writei()` 把脏页写回文件。`readi`/`writei` 是文件系统层提供的、按字节偏移读写 inode 的接口。

*去哪查更详细。*《xv6》教材第 3 章（page tables）和第 8 章（file system）；xv6 里看 `kernel/vm.c`（`vmfault`、`mappages`）、`kernel/sysfile.c`（`sys_mmap`/`sys_munmap`）。关键词：「mmap lazy allocation」「xv6 VMA」「mmap MAP_SHARED writeback」。

== Memory-mapped files (hard)

`mmap(addr, len, prot, flags, fd, offset)` 的参数在实验里只支持一个子集：`addr`/`offset` 假定为 0，`prot` 是读/写/执行权限，`flags` 是 `MAP_SHARED`（改动写回文件）或 `MAP_PRIVATE`（改动只在当前进程）。整个实现按「生命周期」分成登记、加载、写回、继承、退出清理五段。

登记（`sys_mmap`）。在 `struct proc` 里放一个固定大小（`NVMA = 16`）的 VMA 数组，`sys_mmap()` 做的事只是校验参数、找一个空槽位、记下「哪个文件、多长、什么权限」。注意两点：一是要 `filedup()` 持有文件引用，否则用户 `mmap` 后立刻 `close(fd)` 映射就失效了；二是映射地址从 `TRAPFRAME` 下方往低地址分配，避开低地址的 text/data/heap。

加载（`vmfault`）。用户访问映射地址触发 page fault，内核判断地址落在某个 VMA 里，按访问类型查权限（读要 `PROT_READ`、写要 `PROT_WRITE`），然后分配物理页、用 `readi()` 读入文件对应偏移的内容、按权限设 PTE 并 `mappages()`。文件偏移由「VMA 起点 + fault 地址与 VMA 起点的差」算出，所以同一段映射里的不同页，会各自懒加载文件的不同位置。映射长度超过文件大小时，超出部分读不到就保持为零——这正是测试里「1.5 页文件映射 2 页，最后半页应是 0」的来源。

写回（`sys_munmap`）。解除映射时，`MAP_SHARED` 的页要先写回文件再 `uvmunmap`。两个细节容易错：懒加载意味着有些页从没建立过 PTE，解除时直接跳过、不能 panic；写回长度不能超过文件当前大小，否则会把 1.5 页的文件错误扩成 2 页。

继承与退出。`fork()` 要复制父进程的 VMA 表（每个 `filedup`），子进程第一次访问时在自己的 page fault 里独立加载；`exit()` 要在关文件描述符之前，把所有遗留映射按 munmap 语义写回释放。这是 mmap 最容易漏的一环——用户忘了 `munmap`，共享映射的改动也得落盘。

另外 `copyin()`/`copyout()` 也要配合懒加载：系统调用读写用户缓冲区时，若地址落在还没加载的 mmap 页上，要允许它先 `vmfault` 补页，而不是直接报错。

```text
mmap(fd) 登记 VMA，不读文件
  -> 用户访问映射地址，触发 page fault
  -> vmfault() 认领该地址：查权限、分配物理页
  -> readi() 读入文件对应偏移
  -> 建立页表映射，返回用户态继续访问
  -> munmap()/exit() 时 MAP_SHARED 写回文件、释放
```

这个实验把前面好几个 lab 串了起来：加系统调用（lab2）、page fault 和懒分配（lab3、lab5）、文件系统接口（lab8）。它最让我受益的一点，是彻底分清了「虚拟地址区域」和「实际物理页」：VMA 只是进程地址空间里的一段承诺，真正的物理页要等 page fault 发生后才出现。理解了这一点，「为什么 mmap 能映射大于内存的文件」「为什么现代系统普遍用按需分页」就都顺理成章了。

== 实验结果

完成本 Lab 后，在 `mmap` 分支运行：

```text
$ make grade
```

`mmaptest` 里的 basic、private、read-only、read/write、dirty、not-mapped unmap、lazy access、two files、fork、munmap_noaccess、read_only_write 子测试，以及 `usertests` 和 time 均通过，满分。

#figure(
  image("../assets/mmap/grade.png", width: 92%),
  caption: [mmap Lab 的 make grade 测试结果],
)

测试通过说明：VMA 登记、懒加载、共享写回、私有隔离、部分解除、退出清理、fork 继承和非法访问保护这些关键路径都符合要求。mmap 的难点从来不在单个函数，而在「登记—加载—写回—继承—退出」这条生命周期链上的每一环都保持一致的维护。
