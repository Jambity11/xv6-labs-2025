# Lab 9 mmap 学习笔记

官网页面：

- <https://pdos.csail.mit.edu/6.1810/2025/labs/mmap.html>

本地参考：

- 旧报告：`docs/reports_old/labs/lab9-mmap.typ`
- 代码分支：`origin/mmap`
- 基线分支：`origin/riscv`

## 先说明一个代码核对问题

当前可见的 `origin/riscv...origin/mmap` diff 主要是测试、系统调用常量和部分头文件，没有看到旧报告中描述的 `kernel/proc.c`、`kernel/sysfile.c`、`kernel/vm.c` 等完整实现。

所以这份笔记先写“mmap 应该怎么理解、怎么定位”。等找到真实实现分支后，再补具体 diff。

## 这个 Lab 真正在学什么

一句话：

> mmap 是把文件伪装成内存：用户读写一段虚拟地址，看起来像普通内存，背后其实对应文件内容。

普通文件读写是：

```text
read(fd, buf, n)
  -> 内核把文件内容复制到用户 buf

write(fd, buf, n)
  -> 内核把用户 buf 复制到文件
```

`mmap()` 是：

```text
addr = mmap(file)
用户直接读写 addr 这段内存
内核在 page fault 时把文件内容搬进内存
munmap/exit 时必要的话写回文件
```

所以 mmap 把三个东西接到一起：

```text
系统调用
  + 虚拟内存/page fault
  + 文件系统 readi/writei
```

## 任务：Memory-mapped files

### 先用人话说

把文件想成一本书。普通 `read()` 是你每次让图书管理员帮你复印几页到你的桌上。`mmap()` 是管理员说：这本书的某几页以后就映射到你桌上的这一片位置了；你第一次翻到某页时，我再把那页拿过来。

也就是说，`mmap()` 本身不应该立刻把整个文件读进内存。它只是登记一个承诺：

```text
如果用户以后访问这段虚拟地址，
就从这个文件的对应位置读内容进来。
```

这段承诺叫 VMA，virtual memory area。

### 真实执行路径：mmap

```text
用户程序 mmap(0, len, prot, flags, fd, 0)
  -> sys_mmap()
  -> 检查 len/prot/flags/fd 是否合法
  -> 找一个空 VMA 槽
  -> 选择一段用户虚拟地址
  -> 记录：
       起始地址
       长度
       权限 prot
       MAP_SHARED / MAP_PRIVATE
       文件偏移
       struct file *
  -> filedup() 增加文件引用
  -> 返回起始虚拟地址
```

注意：这里不分配物理页，也不读文件。

### 真实执行路径：第一次访问映射地址

```text
用户程序读取 mmap 返回的地址
  -> 这个虚拟地址还没有 PTE
  -> 触发 load page fault
  -> usertrap()
  -> vmfault()
  -> 查找这个地址属于哪个 VMA
  -> 检查权限允许读
  -> kalloc() 分配一页物理内存
  -> 根据 fault_va 算出文件 offset
  -> readi() 从文件读一页内容到物理页
  -> mappages() 建立 PTE
  -> 返回用户态，重新执行刚才的读指令
```

如果是写映射地址：

```text
store page fault
  -> 检查 VMA 是否有 PROT_WRITE
  -> 有：加载并映射为可写
  -> 没有：非法访问，杀死进程
```

### 真实执行路径：munmap

```text
用户程序 munmap(addr, len)
  -> sys_munmap()
  -> 找到覆盖 addr 的 VMA
  -> 遍历这段范围里的页
  -> 没访问过、没有 PTE 的页：跳过
  -> 已映射的页：
       如果 MAP_SHARED 且可能被修改，需要 writei() 写回文件
       uvmunmap() 解除映射并释放物理页
  -> 更新 VMA 范围
  -> 如果整个 VMA 都解除，fileclose()
```

### MAP_SHARED 和 MAP_PRIVATE

这两个标志可以用人话理解：

```text
MAP_SHARED：
  你改了映射内存，最后要写回文件。

MAP_PRIVATE：
  你改了映射内存，只影响你自己，不写回文件。
```

所以 `munmap()` 或 `exit()` 时，`MAP_SHARED` 需要考虑写回，`MAP_PRIVATE` 不需要。

### exit 和 fork 为什么也要管 mmap

如果进程退出前没手动 `munmap()`：

```text
exit()
  -> 内核必须替它清理 VMA
  -> MAP_SHARED 修改要写回
  -> 文件引用要关闭
  -> 物理页要释放
```

如果进程 fork：

```text
fork()
  -> 子进程应该继承 VMA 记录
  -> filedup() 增加文件引用
  -> 不一定立刻复制物理页
  -> 子进程以后访问时自己 page fault 懒加载
```

### 怎么知道要改哪些文件

新增系统调用：

```text
kernel/syscall.h
kernel/syscall.c
user/user.h
user/usys.pl
```

保存每个进程的 VMA：

```text
kernel/proc.h
kernel/proc.c
```

实现 `mmap()` / `munmap()`：

```text
kernel/sysfile.c
kernel/fcntl.h
```

访问映射地址时按需加载：

```text
kernel/trap.c
kernel/vm.c
```

文件读写和写回：

```text
kernel/file.c
kernel/fs.c
kernel/log.c
```

### 容易错的点

- `mmap()` 时立刻读整个文件，违背 lazy loading。
- 用户 `close(fd)` 后映射失效，因为忘记 `filedup()`。
- page fault 时没有根据 `prot` 检查读/写/执行权限。
- `munmap()` 遇到没访问过的页就 panic；lazy mmap 中没访问过的页本来就没有 PTE。
- `MAP_SHARED` 写回长度超过原文件大小，把文件错误扩展。
- `exit()` 忘记清理 VMA，导致文件修改丢失或引用泄漏。
- `fork()` 忘记复制 VMA 或增加文件引用。
- `copyin()` / `copyout()` 遇到未加载 mmap 页时直接失败，而不是触发补页。

## 这个 Lab 最应该留下的理解

`mmap()` 不是“读文件”的另一个写法，而是在进程地址空间里登记一段文件映射关系：

```text
这段虚拟地址
  -> 对应这个文件
  -> 从这个 offset 开始
  -> 权限是 prot
  -> 是否写回由 flags 决定
```

真正的数据搬运发生在 page fault 和 munmap/exit 里。这个实验把虚拟内存和文件系统真正接到了一起。

