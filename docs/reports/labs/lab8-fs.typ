#import "../templates/lab-report.typ": part

= Lab8: File system

对应源码分支：#link("https://github.com/JambitX11/xv6-labs-2025/tree/fs")[https://github.com/JambitX11/xv6-labs-2025/tree/fs]

本实验围绕 xv6 的文件系统展开。相比前面的内存管理、trap、锁和网络实验，文件系统实验更强调磁盘上的持久化数据结构与内核运行时逻辑之间的一致性。用户看到的是 `open()`、`write()`、`read()`、`unlink()` 这样的接口；内核内部实际需要维护 inode、目录项、数据块位图、日志和路径解析等多层结构。

本 Lab 包含两个任务点。第一个任务 `Large files` 要突破 xv6 原始文件大小限制，使单个文件可以使用二级间接块，从而从最多 268 个 block 扩展到 65803 个 block。第二个任务 `Symbolic links` 要实现符号链接系统调用，并让 `open()` 在默认情况下跟随符号链接，在指定 `O_NOFOLLOW` 时打开符号链接本身。两个任务都围绕 inode 展开：前者改变 inode 中 `addrs[]` 的解释方式，后者增加一种新的 inode 类型并在路径打开过程中解析它保存的目标路径。

从整体上看，本实验训练的是在真实内核代码中把抽象概念落到具体路径上的能力。课堂上容易把文件系统理解成“树形目录”和“文件内容”，但在 xv6 中，文件内容最终要通过 `bmap()` 映射到磁盘块，删除文件时要通过 `itrunc()` 释放所有已分配块，路径名要通过 `namei()` 找到 inode，系统调用还要通过 `syscall.h`、`syscall.c`、`user.h` 和 `usys.pl` 贯通用户态与内核态。

== Large files (moderate)

#part("实验目的")

本任务要求扩大 xv6 单个文件的最大容量。原始 xv6 的磁盘 inode 中有 13 个地址槽，其中前 12 个是直接块地址，最后 1 个是一级间接块地址。由于一个磁盘块大小为 `BSIZE = 1024` 字节，一个块号占 4 字节，因此一个一级间接块可以保存 `1024 / 4 = 256` 个数据块地址。原始最大文件块数为：

```text
12 + 256 = 268 blocks
```

`bigfile` 测试要求文件能够写入 65803 个 block。题目不允许改变磁盘 inode 的总大小，因此不能简单增加 `addrs[]` 数组长度，而是要牺牲一个直接块地址槽，将 inode 地址布局改成：

```text
addrs[0..10]   11 个 direct block
addrs[11]      1 个 singly-indirect block
addrs[12]      1 个 doubly-indirect block
```

二级间接块本身不直接指向文件数据，而是指向 256 个一级间接块，每个一级间接块再指向 256 个数据块。因此新最大文件块数为：

```text
11 + 256 + 256 * 256 = 65803 blocks
```

本任务的核心目标是正确扩展文件逻辑块号到磁盘块号的映射，并保证文件删除或截断时能够释放直接块、一级间接块和二级间接块下的所有数据块。

#part("实验步骤")

实验首先修改 `kernel/fs.h` 中的文件系统格式定义。将 `NDIRECT` 从 12 改为 11，增加二级间接块容量常量，并更新 `MAXFILE`：

```c
#define NDIRECT 11
#define NINDIRECT (BSIZE / sizeof(uint))
#define NDINDIRECT (NINDIRECT * NINDIRECT)
#define MAXFILE (NDIRECT + NINDIRECT + NDINDIRECT)
```

`struct dinode` 中的 `addrs[]` 数组改为 `NDIRECT + 2` 个元素。这里的数组总长度仍然是 13，因为 `NDIRECT` 已经从 12 变为 11。这样既没有改变磁盘 inode 的大小，又为二级间接块保留了最后一个地址槽：

```c
uint addrs[NDIRECT+2];
```

随后在 `kernel/file.h` 中同步修改内存 inode 的 `addrs[]` 长度。`struct dinode` 是磁盘上的 inode 格式，`struct inode` 是内核中的内存副本。`ilock()` 和 `iupdate()` 会在这两个结构之间复制 `addrs[]`，因此二者必须保持一致。如果只修改 `fs.h` 而不修改 `file.h`，内存中的 inode 视图和磁盘上的 inode 视图会不匹配，文件系统行为会变得不可预测。

接着修改 `kernel/fs.c` 中的 `bmap()`。`bmap()` 的参数 `bn` 是文件内部的逻辑块号，它的任务是返回对应的磁盘块号；如果该逻辑块尚未分配，写文件时还会调用 `balloc()` 分配新磁盘块。修改后的 `bmap()` 分三段处理：

```text
bn < NDIRECT
  -> 直接通过 ip->addrs[bn] 找数据块

bn < NDIRECT + NINDIRECT
  -> 通过 ip->addrs[NDIRECT] 找一级间接块

bn < NDIRECT + NINDIRECT + NDINDIRECT
  -> 通过 ip->addrs[NDIRECT+1] 找二级间接块
```

二级间接区域的索引计算是本任务最关键的地方。进入二级间接区域后，需要先减去直接块和一级间接块覆盖的范围，然后用商和余数分别定位中间一级间接块与最终数据块：

```c
bn -= NINDIRECT;
uint i = bn / NINDIRECT;
uint j = bn % NINDIRECT;
```

其中 `i` 表示二级间接块中的第几个一级间接块地址，`j` 表示该一级间接块中的第几个数据块地址。这样，文件逻辑块号就被拆成两级索引：

```text
ip->addrs[NDIRECT+1]
  -> doubly-indirect block
       -> a[i] singly-indirect block
            -> a[j] data block
```

最后修改 `itrunc()`，使删除文件或截断文件时能够释放二级间接块。原始 `itrunc()` 只释放直接块和一级间接块。本实验增加的释放逻辑需要先读出二级间接块，再遍历其中的每个一级间接块；对每个存在的一级间接块，先释放它指向的所有数据块，再释放该一级间接块本身；所有下级块释放完毕后，最后释放二级间接块本身，并将 `ip->addrs[NDIRECT+1]` 清零。

释放顺序可以概括为：

```text
direct block:
  直接释放数据块

singly-indirect block:
  释放其指向的数据块
  释放 singly-indirect block 本身

doubly-indirect block:
  遍历其指向的每个 singly-indirect block
  释放每个 singly-indirect block 指向的数据块
  释放这些 singly-indirect block
  最后释放 doubly-indirect block 本身
```

本任务实际修改文件为 `kernel/fs.h`、`kernel/file.h` 和 `kernel/fs.c`。其中 `fs.h` 和 `file.h` 负责更新 inode 地址数组的定义，`fs.c` 中的 `bmap()` 负责实现二级间接块寻址，`itrunc()` 负责释放新增的二级间接块结构。由于 `mkfs` 会根据 `kernel/fs.h` 构造文件系统镜像，修改 `NDIRECT` 后必须重新生成 `fs.img`，不能继续复用旧镜像。

#part("实验中遇到的问题和解决方法")

本任务的第一个易错点是 inode 地址数组的长度。题目要求不能改变磁盘 inode 的大小，因此不是把 `addrs[]` 直接扩展为更多元素，而是把 `NDIRECT` 减少为 11，再使用 `NDIRECT+2` 保持数组总数仍为 13。这样第 12 个槽位继续表示一级间接块，第 13 个槽位表示二级间接块。

第二个问题是 `itrunc()` 的修改容易被忽略。只修改 `bmap()` 时，`bigfile` 可能可以写出大文件，但删除或截断文件时无法释放二级间接块下的所有数据块，后续测试可能出现磁盘块泄漏或文件系统状态异常。因此本实验在实现二级间接块分配后，同步补充了 `itrunc()` 的递归式释放逻辑。

第三个问题出现在测试阶段。`bigfile` 会写入 65803 个 1KB block，且本 Lab 的 `FSSIZE` 扩大到 200000，测试运行时间明显长于前面章节。调试过程中曾出现 `make grade` 因超时终止的情况，但手工运行 `bigfile` 能输出 `bigfile done; ok`，`usertests -q` 也能输出 `ALL TESTS PASSED`。据此判断问题不是文件系统逻辑错误，而是本地 QEMU 与磁盘镜像运行耗时较长。最终完整等待评分脚本运行，`bigfile`、`symlinktest`、`usertests` 和 time 测试均通过。

#part("实验心得")

Large files 任务加深了我对 inode 地址结构的理解。文件系统中的“文件很大”并不是简单地把文件内容连续放在磁盘上，而是通过多级索引把文件内部的逻辑块号映射到真实磁盘块号。直接块适合小文件，一级间接块扩展一层，二级间接块则用一个索引块组织许多一级索引块，从而在不改变 inode 大小的前提下显著扩大文件容量。

本任务也说明，文件系统修改必须同时考虑分配和释放两条路径。`bmap()` 让文件能够长大，`itrunc()` 让文件被删除时能够把占用资源归还给文件系统。如果只关注写入路径，很容易得到一个短期能通过部分测试、但长期会泄漏磁盘块的实现。

== Symbolic links (moderate)

#part("实验目的")

本任务要求为 xv6 增加符号链接。符号链接是一种特殊文件，它的内容不是普通数据，而是另一个路径名。用户打开符号链接时，内核默认应读取其中保存的目标路径，并继续打开目标文件；如果用户指定 `O_NOFOLLOW`，则不跟随目标，而是打开符号链接文件本身。

符号链接和硬链接的区别在于，硬链接让两个目录项指向同一个 inode，而符号链接拥有自己的 inode，只是在文件内容中保存目标路径字符串。因此，创建符号链接时目标路径可以不存在；只有随后 `open()` 跟随该符号链接时，目标不存在才会导致打开失败。

本任务需要把“新增文件类型”和“新增系统调用”两条路径同时打通：一方面在文件系统中增加 `T_SYMLINK` 类型，另一方面增加用户态可调用的 `symlink(target, path)` 系统调用，并修改 `open()` 的路径解析逻辑。

#part("实验步骤")

首先在 `kernel/stat.h` 中增加新的 inode 类型：

```c
#define T_SYMLINK 4
```

随后在 `kernel/fcntl.h` 中增加打开标志：

```c
#define O_NOFOLLOW 0x800
```

该标志用于区分两种打开行为。普通 `open()` 遇到符号链接时应跟随目标路径；带 `O_NOFOLLOW` 时则返回符号链接自身的文件描述符，测试程序可以通过 `fstat()` 检查其类型是否为 `T_SYMLINK`。

接着按照 xv6 新增系统调用的一般流程，依次修改 `kernel/syscall.h`、`kernel/syscall.c`、`user/user.h` 和 `user/usys.pl`。在 `syscall.h` 中为 `symlink` 分配新的系统调用号；在 `syscall.c` 中声明 `sys_symlink()` 并放入 `syscalls[]` 表；在 `user/user.h` 中声明用户态函数原型；在 `user/usys.pl` 中加入 `entry("symlink")` 以生成用户态汇编桩。这样用户程序调用 `symlink()` 时，才能通过 `ecall` 进入内核中的 `sys_symlink()`。

`sys_symlink()` 实现在 `kernel/sysfile.c` 中。它从用户参数中读取目标路径 `target` 和新链接路径 `path`，通过已有的 `create()` 创建一个类型为 `T_SYMLINK` 的 inode，然后将 `target` 字符串写入该 inode 的文件内容中：

```text
symlink(target, path)
  -> 创建 path 对应的 T_SYMLINK inode
  -> 将 target 字符串写入这个 inode
  -> 返回 0
```

这里需要注意 `create()` 在 `sysfile.c` 中是 `static` 函数。实验中曾因将 `sys_symlink()` 写在 `create()` 前面，导致编译器报出 `implicit declaration of function 'create'` 和返回类型冲突。解决方法是将 `sys_symlink()` 放在 `create()` 定义之后、`sys_open()` 之前，或者提前声明 `create()`。本实验采用前一种方式，使代码顺序也更符合“先有创建 helper，再实现具体创建类系统调用”的逻辑。

随后修改 `sys_open()`。原始 `open()` 在非 `O_CREATE` 情况下通过 `namei(path)` 找到 inode，然后直接打开。加入符号链接后，需要在 inode 加锁后判断其类型：

```text
如果 ip->type == T_SYMLINK 且未设置 O_NOFOLLOW:
  读出符号链接文件中保存的目标路径
  释放当前符号链接 inode
  使用 namei(target) 查找目标 inode
  继续判断目标是否仍然是符号链接
```

为了避免符号链接环导致无限循环，例如 `a -> b`、`b -> a`，`open()` 中设置了最大跟随深度。若超过限制，则认为可能存在循环并返回错误。这样既能支持多层符号链接，也能避免内核在错误路径结构中无限解析。

最后修改 `Makefile`，在 `LAB=fs` 时将 `user/symlinktest.c` 编译进文件系统镜像，使 xv6 shell 中可以运行 `symlinktest`。本任务实际修改文件包括 `kernel/stat.h`、`kernel/fcntl.h`、`kernel/syscall.h`、`kernel/syscall.c`、`kernel/sysfile.c`、`user/user.h`、`user/usys.pl` 和 `Makefile`。

#part("实验中遇到的问题和解决方法")

本任务首先遇到的是 `create()` 的声明顺序问题。`sys_symlink()` 需要复用 `create(path, T_SYMLINK, 0, 0)` 创建符号链接 inode，但 `create()` 是 `kernel/sysfile.c` 内部的 `static` 函数。如果 `sys_symlink()` 写在 `create()` 定义之前，C 编译器会在第一次看到 `create()` 调用时将其视为隐式声明的 `int create()`，随后遇到真实定义 `static struct inode *create(...)` 时就发生类型冲突。最终通过调整函数顺序解决该编译错误。

第二个问题是符号链接的打开语义。`symlink()` 创建时不能要求目标文件已经存在，因为符号链接保存的是路径字符串，而不是目标 inode 的引用。目标路径不存在时，创建符号链接仍应成功；只有在 `open()` 跟随该符号链接时，`namei(target)` 找不到目标才返回失败。本实验在 `sys_symlink()` 中只负责创建 `T_SYMLINK` inode 和保存目标路径，不对目标路径做存在性检查。

第三个问题是符号链接循环。若 `open()` 只是简单地不断跟随 `T_SYMLINK`，遇到 `a -> b`、`b -> a` 这样的结构就会无限循环。实验通过设置最大解析层数解决这一问题；当跟随次数超过上限时，`open()` 返回 `-1`，与测试中对循环链接的预期一致。

#part("实验心得")

Symbolic links 任务展示了文件系统路径解析的另一面。硬链接直接增加 inode 的目录入口引用，而符号链接通过一个独立 inode 保存路径字符串。也就是说，符号链接不是“另一个文件名直接指向同一份文件内容”，而是“打开时请再按这个字符串重新走一次路径查找”。理解这一点后，为什么 `symlink()` 不要求目标存在、为什么 `unlink()` 应删除符号链接本身、为什么 `open()` 需要专门处理跟随逻辑，都变得更清晰。

本任务也再次复习了 xv6 新增系统调用的完整链路。仅在内核中写一个 `sys_symlink()` 不够，还必须分配系统调用号、注册系统调用表、声明用户态原型、生成用户态汇编入口，并把测试程序加入文件系统镜像。这个流程和前面 syscall lab 中的经验一致，但本任务进一步把系统调用和文件系统内部 helper 结合起来。

== 实验结果

完成本 Lab 后，在 `fs` 分支运行：

```text
$ make grade
```

最终 `bigfile`、`symlinktest`、`usertests` 和 time 测试均通过，得分为满分。由于 `bigfile` 需要写入 65803 个 block，`usertests` 也会受到较大的 `FSSIZE` 影响，本 Lab 的评分运行时间明显长于前面章节。测试结果如下图所示。

#figure(
  image("../assets/fs/grade.png", width: 92%),
  caption: [File system Lab 的 make grade 测试结果],
)

测试通过表明，二级间接块扩展、文件截断释放、符号链接创建、符号链接跟随、`O_NOFOLLOW` 语义以及文件系统回归测试均符合实验要求。
