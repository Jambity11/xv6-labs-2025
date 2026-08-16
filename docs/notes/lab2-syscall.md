# lab2 syscall

> 上一个lab做了新增用户程序，这个lab则更深入操作系统内核了，将要自己添加系统调用，让用户程序可以通过syscall陷入内核执行内核代码

> 内核态和用户态是排在CPU上的，不是在代码层面实现的，通过`ecall`这条指令切换

## GDB and system calls

系统调用链：

用户程序执行系统调用-`ecall`-CPU 陷入内核-`usertrap`-`syscall`-根据系统调用好执行对应`sys_xxx`内核函数-返回用户态

## sandbox a command

实现新系统调用`int interpose(int mask, char *path)`

我们新增的这个系统调用就类似`fork`, `open`这种系统调用的地位

`interpose(1<<SYS_open, "/bin/sh")`可以发起请求，请内核帮我设置沙箱规则（因为用户态不能直接修改内核里进程的 mask，因为用户态访问不了内核struct proc）


- mask 是掩码，每一位代表一个系统调用号；`1<<SYS_open`代表屏蔽 open
- 进程执行mask标记的系统调用时，内核直接拒绝

## Sandbox with allowed pathnames 


任务 3 新增一块内核内存，用来存白名字符串：

每次 open /exec 被 mask 命中的时候，内核要再次拿到本次系统调用传入的路径字符串，和存好的白名单比较。

```c
if(num == SYS_open || num == SYS_exec){
  char user_path[MAXPATH];
  // 从寄存器拿到本次系统调用传入的路径参数，拷贝到内核
  argstr(0, user_path, MAXPATH);
  // 和proc保存的白名单路径对比
  if(strcmp(user_path, p->allowed_path) == 0){
    // 路径匹配，放行，不拦截
  }else{
    return -1; // 路径不匹配，拒绝
  }
}else{
  // 不是open/exec，没有白名单，直接拒绝
  return -1;
}
```

## Attack xv6

```c
#ifndef LAB_SYSCALL
  memset(pa, 1, PGSIZE);
#endif
```

1. sbrk(PGSIZE)：增大进程虚拟堆，返回旧 brk 值 p（虚拟地址）。此时还没有物理内存。
2. 用户读写*p → 触发缺页陷阱进入内核
3. 内核调用kalloc()，从空闲链表取出物理页。

实验故意关掉 kalloc.c 里的清页动作。

