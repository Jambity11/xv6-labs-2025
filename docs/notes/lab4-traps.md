# lab4 traps

## RISC‑V assembly warm‑up

ra寄存器中报损函数返回地址

## Backtrace

和trap这个lab没有太大直接关系，但是是一个后续debug的工具

这里遍历的是普通函数栈

```
ra = *(fp + 8)
fp = *(fp)
```


## alarm

新增系统调用`sigalarm(interval, handler);`

希望每过 N 个时钟滴答 (tick)，自动跑一遍我写好的用户处理函数。

但是中断会触发进入内核态，那该如何运行用户写的`handler`函数呢？

可以在中断结束后先跳到`handler`函数跑一遍再回到中断前在执行的程序

> 定时跳过去执行一个函数，然后再返回原样

进入内核的瞬间，把下一跳要执行的指令地址`epc`存进`trapframe`里，这样`trapframe->epc`就改成了`handler`的地址，这样内核啊返回时，就从`handler`开始执行

但改之前要把`trapframe`备份一份，所以`struct proc`里多了一块`alarm_trapframe`



