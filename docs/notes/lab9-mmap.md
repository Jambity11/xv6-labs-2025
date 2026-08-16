# lab9 mmap

memory-map 内存映射

VMA: virtual memory area 描述进程地址空间里一段连续区域的性质

## Memory-mapped files

以前读文件：复制文件到缓冲区

mmap:地址是坐标、内容在磁盘、内存里（懒加载后）有内容的拷贝，而 地址对应文件哪一段 这个关系记在内核的 VMA 和页表里——它既不在地址数字里，也不在内存内容里，而是内核额外维护的一份 箭头 表。



