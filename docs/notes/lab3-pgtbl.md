# lab3 page table


## Inspect a user-process page table 

看一个页表长什么样：

一行有四个字段：va（虚拟地址）、pte（完整的 64 位表项）、pa（物理页地址）、perm（权限）

pte 里面高 44 位才是物理页号，低 10 位是权限

![](../reports/assets/pgtbl/address%20transition.png)

## Speed up system calls

弄明白页表长什么样之后

我们这里要加速一个系统调用`getpid()`

方案是内核和用户共享一个只读物理页

物理页里分配一块内存

内核可以通过内核虚拟地址，直接读写这块物理页

用户态则使用页表只读这块共享页

> 没有页表这个概念，就没法把一块物理内存两边用不同虚拟地址访问

## Print a page table 

整个 39 位虚拟地址，从高位到低位：

[ L2(9bit) | L1(9bit) | L0(9bit) | Offset(12bit) ]

1. Offset：低 12 位（bit0‑bit11）页内偏移


## Use superpages (moderate)/(hard)

正常情况：L2→L1→L0，L0 才是叶子 PTE 指向数据页。

1GB 超级页：L2 层 PTE 直接当叶子！不再往下找 L1、L0。