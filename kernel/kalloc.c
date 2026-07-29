// Physical memory allocator, for user processes,
// kernel stacks, page-table pages,
// and pipe buffers. Allocates whole 4096-byte pages.

#include "types.h"
#include "param.h"
#include "memlayout.h"
#include "spinlock.h"
#include "riscv.h"
#include "defs.h"

void freerange(void *pa_start, void *pa_end);

extern char end[]; // first address after kernel.
                   // defined by kernel.ld.

struct run {
  struct run *next;
};

struct {
  struct spinlock lock;
  struct run *freelist;
  int refcnt[(PHYSTOP - KERNBASE) / PGSIZE];
} kmem;

static int
pa_index(void *pa)
{
  return ((uint64)pa - KERNBASE) / PGSIZE;
}

void
kinit()
{
  initlock(&kmem.lock, "kmem");
  freerange(end, (void*)PHYSTOP);
}

void
freerange(void *pa_start, void *pa_end)
{
  char *p;
  p = (char*)PGROUNDUP((uint64)pa_start);
  for(; p + PGSIZE <= (char*)pa_end; p += PGSIZE){
    acquire(&kmem.lock);
    kmem.refcnt[pa_index(p)] = 1;
    release(&kmem.lock);
    kfree(p);
  }
}

// Free the page of physical memory pointed at by pa,
// which normally should have been returned by a
// call to kalloc().  (The exception is when
// initializing the allocator; see kinit above.)
// 原来的 kfree: 不用一个页了，把他放回空闲列表
// 现在有了 cow，一个屋里也可能有多个使用者
void
kfree(void *pa)
{
  struct run *r;
  int idx;

  if(((uint64)pa % PGSIZE) != 0 || (char*)pa < end || (uint64)pa >= PHYSTOP)
    panic("kfree");

  idx = pa_index(pa);

  acquire(&kmem.lock);
  if(kmem.refcnt[idx] < 1)
    panic("kfree: refcnt");

  kmem.refcnt[idx]--;
  if(kmem.refcnt[idx] > 0){
    release(&kmem.lock);
    return;
  }

  // Fill with junk to catch dangling refs.
  memset(pa, 1, PGSIZE);

  r = (struct run*)pa;
  r->next = kmem.freelist;
  kmem.freelist = r;
  release(&kmem.lock);
}

// Allocate one 4096-byte page of physical memory.
// Returns a pointer that the kernel can use.
// Returns 0 if the memory cannot be allocated.
// 新分配一页，引用计数设为 1。
void *
kalloc(void)
{
  struct run *r;

  acquire(&kmem.lock);
  r = kmem.freelist;
  if(r){
    kmem.freelist = r->next;
    kmem.refcnt[pa_index((void*)r)] = 1;
  }
  release(&kmem.lock);

  if(r)
    memset((char*)r, 5, PGSIZE); // fill with junk
  return (void*)r;
}

// fork 共享一页时，引用计数加 1。
void
kaddref(void *pa)
{
  if(((uint64)pa % PGSIZE) != 0 || (uint64)pa < KERNBASE || (uint64)pa >= PHYSTOP)
    panic("kaddref");

  acquire(&kmem.lock);
  kmem.refcnt[pa_index(pa)]++;
  release(&kmem.lock);
}

// 解除映射时，引用计数减 1；减到 0 才真的释放。
int
krefcnt(void *pa)
{
  int n;

  if(((uint64)pa % PGSIZE) != 0 || (uint64)pa < KERNBASE || (uint64)pa >= PHYSTOP)
    panic("krefcnt");

  acquire(&kmem.lock);
  n = kmem.refcnt[pa_index(pa)];
  release(&kmem.lock);

  return n;
}