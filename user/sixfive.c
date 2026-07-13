#include "kernel/types.h"
#include "kernel/stat.h"
#include "kernel/fcntl.h"
#include "user/user.h"

#define SEP_STATE     0
#define NUMBER_STATE  1
#define INVALID_STATE 2

static char *separators = " -\r\t\n./,";

// 如果数字是 5 或 6 的倍数，就打印。
static void
print_if_needed(int value)
{
  if(value % 5 == 0 || value % 6 == 0)
    printf("%d\n", value);
}

// 处理一个已经打开的文件。
static void
scan_file(int fd)
{
  char c;
  int state = SEP_STATE;
  int value = 0;
  int n;

  // 按题目要求，每次只读取一个字符。
  while((n = read(fd, &c, 1)) == 1){
    // 当前字符是规定的分隔符。
    if(strchr(separators, c) != 0){
      if(state == NUMBER_STATE)
        print_if_needed(value);

      state = SEP_STATE;
      value = 0;
    }
    // 当前字符是十进制数字。
    else if(c >= '0' && c <= '9'){
      if(state == SEP_STATE){
        // 分隔符后面出现数字：开始一个新数字。
        state = NUMBER_STATE;
        value = c - '0';
      } else if(state == NUMBER_STATE){
        // 原来已经在读取数字：把新的一位接到后面。
        value = value * 10 + (c - '0');
      }

      // 如果 state 是 INVALID_STATE，就忽略这个数字。
    }
    // 既不是数字，也不是规定的分隔符。
    else {
      // 如果前面已经读了一部分数字，也要丢弃。
      // 例如 12abc 中的 12 不是合法的完整数字。
      state = INVALID_STATE;
      value = 0;
    }
  }

  if(n < 0){
    fprintf(2, "sixfive: read error\n");
    exit(1);
  }

  // 文件末尾也被视为隐含的分隔符。
  if(state == NUMBER_STATE)
    print_if_needed(value);
}

int
main(int argc, char *argv[])
{
  int fd;
  int i;

  if(argc < 2){
    fprintf(2, "usage: sixfive file...\n");
    exit(1);
  }

  // 题目说“for each input file”，所以支持多个文件。
  for(i = 1; i < argc; i++){
    fd = open(argv[i], O_RDONLY);

    if(fd < 0){
      fprintf(2, "sixfive: cannot open %s\n", argv[i]);
      exit(1);
    }

    scan_file(fd);
    close(fd);
  }

  exit(0);
}