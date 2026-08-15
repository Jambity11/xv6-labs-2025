#import "../templates/lab-report.typ": part

= Lab8: File system

对应源码分支：#link("https://github.com/Jambity11/xv6-labs-2025/tree/fs")[https://github.com/Jambity11/xv6-labs-2025/tree/fs]

程序里写文件、读文件，看起来再平常不过。但往深想一步：这些数据要存在磁盘上，断电也不丢；文件可能非常大，远超过一块磁盘块；还要支持目录、路径、删除。文件系统就是负责把这些「用户看到的文件」和「磁盘上的字节」对应起来的那整套机制。本实验处理两个具体问题：一是 xv6 现在的单个文件最多只有 268 块，太小，怎么让它能装下大文件；二是用户想要一种「链接」——一个文件指向另一个路径，打开它时能顺藤摸瓜找到目标。

这两个问题背后是文件系统里两个很基础的能力：大文件靠的是「多级索引」，链接靠的是「一种特殊文件 + 路径解析」。所以本实验的两个任务都围绕 inode 展开。

#part("前置知识")

*inode 与磁盘块。*磁盘按固定大小的块（xv6 里 `BSIZE = 1024` 字节）组织。每个文件对应一个 inode，它记录文件的类型、大小、以及「内容放在哪些块里」。inode 里存的是块号，不是内容本身——这是理解文件系统的第一道坎。

*文件内容怎么存：直接块与间接块。*小文件用直接块就够：inode 里直接记数据块的块号。文件一大，inode 里就放不下那么多块号了，于是引入间接块：inode 里记一个「索引块」的块号，索引块里再记一堆数据块的块号。xv6 的一个块号占 4 字节，一个 1KB 的索引块能装 256 个块号，这就是「间接」的含义。本实验的大文件任务，就是在间接块之上再加一层「二级间接块」。

*路径怎么找到文件：目录项与 namei。*目录本身也是文件，内容是一串目录项（`struct dirent`），每个目录项是「名字 + inode 号」的对应。`open("/a/b/c")` 时，内核用 `namei()` 从根目录开始，一段一段地把路径名解析成 inode。符号链接任务要改的，正是这个解析过程。

*去哪查更详细。*《xv6》教材第 8 章「File system」；xv6 里看 `kernel/fs.c`（`bmap`、`itrunc`、`namei`）、`kernel/fs.h`（inode 和磁盘布局定义）。关键词：「xv6 inode bmap」「indirect block」「xv6 symlink」。

== Large files (moderate)

原始 xv6 的 inode 里有 13 个地址槽：前 12 个直接块，最后 1 个一级间接块。一个一级间接块装 256 个块号，所以单文件最大 `12 + 256 = 268` 块。`bigfile` 测试要求能写 65803 块，而题目又不让增大 inode——怎么办？

思路很自然：既然「一级间接」不够，就牺牲一个直接块槽位，把它升级成「二级间接块」。二级间接块自己不指向数据，而是指向 256 个一级间接块，每个再指向 256 个数据块。于是布局变成 11 个直接块 + 1 个一级间接块 + 1 个二级间接块，最大 `11 + 256 + 256 × 256 = 65803` 块。

```text
addrs[0..10]  11 个直接块
addrs[11]     1 个一级间接块（256 个数据块）
addrs[12]     1 个二级间接块（256 个一级间接块，各 256 个数据块）
```

真正要动脑的地方是 `bmap()`：给定文件内的逻辑块号 `bn`，返回它对应的磁盘块号（没有就分配）。原来的逻辑只分「直接区 / 一级间接区」两段，现在要分三段。进二级间接区后，先减去前面区域覆盖的块数，再用 `i = bn / 256` 定位「第几个一级间接块」、`j = bn % 256` 定位「该一级间接块里的第几个数据块」。这两级索引，就是「大文件」在地址计算上的核心。

另一个必须同步改的是 `itrunc()`——只让文件能变大、不让它删除时归还块，就会泄漏磁盘块。释放二级间接块要按「从里到外」的顺序：先释放每个一级间接块指向的数据块，再释放一级间接块本身，最后释放二级间接块。这个「分配和释放两条路径都要改」的教训，在文件系统里反复出现。

还有一个容易被忽略的点：`struct dinode`（磁盘上的 inode）和 `struct inode`（内核里的内存副本）里的 `addrs[]` 长度必须同步改，否则 `ilock`/`iupdate` 在两者之间复制时会不一致。改 `NDIRECT` 后 `fs.img` 也必须重新生成。

#part("代码解读")

本任务的实现见 #link("https://github.com/Jambity11/xv6-labs-2025/blob/fs/kernel/fs.h")[kernel/fs.h] 和 #link("https://github.com/Jambity11/xv6-labs-2025/blob/fs/kernel/fs.c")[kernel/fs.c]。核心代码集中如下。

`kernel/fs.h` 里的常量改动：

```c
#define NDIRECT 11
#define NINDIRECT (BSIZE / sizeof(uint))
#define NDINDIRECT (NINDIRECT * NINDIRECT)
#define MAXFILE (NDIRECT + NINDIRECT + NDINDIRECT)
```

`struct dinode` 里的地址数组：

```c
uint addrs[NDIRECT+2];   // Data block addresses
```

`kernel/fs.c` 里 `bmap()` 的三段寻址（省略了部分重复的错误处理）：

```c
static uint
bmap(struct inode *ip, uint bn)
{
  uint addr, *a;
  struct buf *bp;

  if(bn < NDIRECT){
    if((addr = ip->addrs[bn]) == 0){
      addr = balloc(ip->dev);
      if(addr == 0)
        return 0;
      ip->addrs[bn] = addr;
    }
    return addr;
  }
  bn -= NDIRECT;

  if(bn < NINDIRECT){
    if((addr = ip->addrs[NDIRECT]) == 0){
      addr = balloc(ip->dev);
      ...
    }
    bp = bread(ip->dev, addr);
    a = (uint*)bp->data;
    if((addr = a[bn]) == 0){
      addr = balloc(ip->dev);
      ...
    }
    brelse(bp);
    return addr;
  }
  bn -= NINDIRECT;

  if(bn < NDINDIRECT){
    uint i = bn / NINDIRECT;
    uint j = bn % NINDIRECT;

    if((addr = ip->addrs[NDIRECT+1]) == 0){
      addr = balloc(ip->dev);
      ...
    }

    bp = bread(ip->dev, addr);
    a = (uint*)bp->data;

    if((addr = a[i]) == 0){
      addr = balloc(ip->dev);
      ...
      a[i] = addr;
      log_write(bp);
    }
    brelse(bp);

    bp = bread(ip->dev, addr);
    a = (uint*)bp->data;

    if((addr = a[j]) == 0){
      addr = balloc(ip->dev);
      ...
    }
    brelse(bp);
    return addr;
  }
  ...
}
```

`itrunc()` 里释放二级间接块（嵌套循环）：

```c
  if(ip->addrs[NDIRECT+1]){
    bp = bread(ip->dev, ip->addrs[NDIRECT+1]);
    a = (uint*)bp->data;

    for(j = 0; j < NINDIRECT; j++){
      if(a[j]){
        bp2 = bread(ip->dev, a[j]);
        a2 = (uint*)bp2->data;

        for(k = 0; k < NINDIRECT; k++){
          if(a2[k])
            bfree(ip->dev, a2[k]);
        }

        brelse(bp2);
        bfree(ip->dev, a[j]);
      }
    }

    brelse(bp);
    bfree(ip->dev, ip->addrs[NDIRECT+1]);
    ip->addrs[NDIRECT+1] = 0;
  }
```

下面逐段解释。

*常量布局。*`NDIRECT` 从 12 改成 11，腾出第 13 个槽位给二级间接块。`NDINDIRECT = 256 × 256` 是二级间接块能覆盖的数据块数。`MAXFILE = 11 + 256 + 65536 = 65803`。`addrs[NDIRECT+2]` 保持数组总数 13——`addrs[0..10]` 直接块、`addrs[11]` 一级间接、`addrs[12]` 二级间接，既不改变磁盘 inode 大小，又给二级间接块留了位置。

*`bmap` 的三段。*`bmap(bn)` 把文件内的逻辑块号 `bn` 映射到磁盘块号，分三段处理：`bn < NDIRECT` 直接读 `addrs[bn]`；否则 `bn -= NDIRECT`，`bn < NINDIRECT` 走一级间接（读 `addrs[NDIRECT]` 指向的索引块、取第 `bn` 项）；再 `bn -= NINDIRECT`，`bn < NDINDIRECT` 走二级间接。二级间接的关键是 `i = bn / NINDIRECT`、`j = bn % NINDIRECT`——先定位「第几个一级间接块」，再定位「该一级间接块里的第几个数据块」，两次 `bread` 才拿到最终数据块。

*`itrunc` 的递归释放。*删除/截断文件时要按「从里到外」的顺序释放：先释放每个一级间接块指向的数据块（内层 k 循环），再释放一级间接块本身（`bfree(a[j])`），最后释放二级间接块（`bfree(addrs[NDIRECT+1])`）。如果只改 `bmap` 不改 `itrunc`，文件能变大但删不掉，磁盘块就泄漏了。

#part("自测与解答")

*问：`addrs` 数组总数为什么还是 13，而不是直接扩成更多？*

*答：*题目要求不改变磁盘 inode 的大小。inode 在磁盘上的布局是固定的，`addrs` 数组长度变了，整个磁盘格式就变了。所以做法是「减一个直接块、加一个二级间接块」，总数保持不变：`NDIRECT` 从 12 改成 11，`addrs[NDIRECT+2]` 还是 13 个槽。

*问：`i = bn / NINDIRECT`、`j = bn % NINDIRECT` 分别表示什么？*

*答：*进入二级间接区后，`bn` 要先减去直接块和一级间接块覆盖的块数，剩下的才是「二级间接块管辖的第几个数据块」。`i = bn / 256` 表示它在第几个一级间接块里，`j = bn % 256` 表示它是该一级间接块里的第几个数据块。商和余数把一维的逻辑块号拆成了两级索引。

*问：为什么 `itrunc` 也要改，只改 `bmap` 不行吗？*

*答：*`bmap` 负责「文件变大」，`itrunc` 负责「文件删除时归还块」。只改 `bmap`，文件能写到 65803 块；但删除时 `itrunc` 不认识二级间接块，那些数据块就永远不会被 `bfree` 归还，磁盘块泄漏。文件系统的修改必须同时照顾「分配」和「释放」两条路径。

== Symbolic links (moderate)

第二个任务给 xv6 加符号链接。符号链接是一种特殊文件：它自己有一个 inode，但文件内容不是数据，而是「目标路径」这个字符串。打开符号链接时，默认应该读出目标路径、继续去打开目标；如果带 `O_NOFOLLOW`，则打开链接本身。

理解符号链接，关键是把它和硬链接区分开：硬链接是两个目录项指向同一个 inode，删掉一个另一个还在；符号链接则拥有自己的 inode，只是内容存了目标路径。所以创建符号链接时，目标可以不存在——它只是在「记一个路径」，真正要等 `open()` 跟随它时才去解析。

实现要打通两条路：一是新增 `symlink(target, path)` 系统调用（照 xv6 的老规矩：`syscall.h` 分配号、`syscall.c` 注册、`user.h` 声明、`usys.pl` 生成桩），内核侧 `sys_symlink()` 用现成的 `create()` 建一个 `T_SYMLINK` inode、把 target 写进去；二是改 `sys_open()`，加锁后判断类型，是符号链接且没带 `O_NOFOLLOW`，就读出目标路径、重新 `namei()` 目标。这里有个必须处理的坑：符号链接可能成环（`a -> b`、`b -> a`），所以跟随要设最大深度，超过就返回错误。

```text
open(符号链接)
  -> 判断 ip->type == T_SYMLINK 且未设 O_NOFOLLOW
  -> 读出链接内容（目标路径）
  -> 释放当前链接 inode
  -> 用 namei(target) 找目标
  -> 目标还是符号链接则继续跟随（有限深度）
```

我在实现里踩的坑基本是「工程顺序」问题：`sys_symlink()` 要复用 `create()`，但 `create()` 是文件内 `static` 函数，写在它前面编译器会报 implicit declaration，把 `sys_symlink()` 放到 `create()` 定义之后就好了。这类问题提醒我：xv6 内核的编译约束（`-Werror`、无 libc、static 函数顺序）会一直影响写代码的方式。

#part("代码解读")

本任务的实现见 #link("https://github.com/Jambity11/xv6-labs-2025/blob/fs/kernel/sysfile.c")[kernel/sysfile.c]。核心代码集中如下。

`sys_symlink()`：

```c
uint64
sys_symlink(void)
{
  char target[MAXPATH], path[MAXPATH];
  struct inode *ip;
  int len;

  if(argstr(0, target, MAXPATH) < 0 || argstr(1, path, MAXPATH) < 0)
    return -1;

  begin_op();

  if((ip = create(path, T_SYMLINK, 0, 0)) == 0){
    end_op();
    return -1;
  }

  len = strlen(target) + 1;
  if(writei(ip, 0, (uint64)target, 0, len) != len){
    iunlockput(ip);
    end_op();
    return -1;
  }

  iunlockput(ip);
  end_op();
  return 0;
}
```

`sys_open()` 里的跟随逻辑：

```c
      int depth = 0;
      while(ip->type == T_SYMLINK && (omode & O_NOFOLLOW) == 0){
        char target[MAXPATH];

        if(depth++ >= 10){
          iunlockput(ip);
          end_op();
          return -1;
        }

        memset(target, 0, sizeof(target));
        if(readi(ip, 0, (uint64)target, 0, MAXPATH) <= 0){
          iunlockput(ip);
          end_op();
          return -1;
        }

        iunlockput(ip);

        if((ip = namei(target)) == 0){
          end_op();
          return -1;
        }
        ilock(ip);
      }
```

下面逐段解释。

*`sys_symlink`。*它做的事情是「创建一个类型为 `T_SYMLINK` 的文件，把目标路径写进这个文件的内容」。`create(path, T_SYMLINK, 0, 0)` 创建符号链接 inode，`writei` 把 `target` 字符串写进去。注意它*不检查目标是否存在*——符号链接存的是路径字符串，不是目标 inode 的引用，目标可以不存在，只有 `open` 跟随时才解析。

*`sys_open` 的跟随。*`while(ip->type == T_SYMLINK && (omode & O_NOFOLLOW) == 0)`——只要当前 inode 是符号链接、且没带 `O_NOFOLLOW`，就循环跟随：`readi` 读出链接内容（目标路径），`namei(target)` 找到目标 inode，继续判断。带 `O_NOFOLLOW` 时直接跳过循环、打开链接本身。

*深度限制。*`if(depth++ >= 10) return -1;`——符号链接可能成环（`a -> b`、`b -> a`），无限跟随会死循环，所以限制最大 10 层，超过就返回错误。

#part("自测与解答")

*问：`symlink` 创建时为什么不检查目标路径是否存在？*

*答：*符号链接存的是「目标路径」这个字符串，而不是目标 inode 的引用。它只是一个「指路牌」，指的路可以暂时不存在。所以创建时不做存在性检查，只有 `open` 跟随它、`namei(target)` 找不到目标时才失败。这也是符号链接和硬链接的本质区别——硬链接指向 inode，目标必须存在；符号链接指向路径，目标可以悬空。

*问：跟随符号链接为什么要设深度限制？*

*答：*防止成环死循环。如果 `a -> b`、`b -> a`，`open(a)` 会无限地在两个链接之间来回解析。设一个最大深度（这里是 10），超过就返回错误，内核就不会陷入无限循环。

*问：`O_NOFOLLOW` 的作用是什么？*

*答：*让 `open` 打开符号链接「本身」而不是跟随到目标。普通 `open` 默认跟随（解析目标路径）；带 `O_NOFOLLOW` 时跳过跟随循环，返回符号链接自己的文件描述符，测试程序可以据此 `fstat` 检查它的类型是 `T_SYMLINK`。

== 实验结果

完成本 Lab 后，在 `fs` 分支运行：

```text
$ make grade
```

`bigfile`、`symlinktest`、`usertests` 和 time 均通过，满分。因为 `bigfile` 要写 65803 个块、`FSSIZE` 也扩大到 200000，本 Lab 的评分耗时明显长于前面的实验。

#figure(
  image("../assets/fs/grade.png", width: 92%),
  caption: [File system Lab 的 make grade 测试结果],
)

测试通过说明：二级间接块的寻址与释放、符号链接的创建与跟随、`O_NOFOLLOW` 语义、以及文件系统回归测试都符合要求。两个任务合起来，把文件系统里「文件怎么变大的」和「路径怎么被解析的」这两件事，从概念落到了具体的 inode 和块操作上。
