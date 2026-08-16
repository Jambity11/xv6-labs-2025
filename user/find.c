#include "kernel/types.h"
#include "kernel/stat.h"
#include "kernel/fs.h"
#include "kernel/param.h"
#include "user/user.h"

// 拿到路径最后的文件名
static char *
last_component(char *path)
{
  char *p;
  // 指向字符串末尾 '\0'
  p = path + strlen(path); 

  while(p > path && *(p - 1) != '/')
    p--;

  return p;
}

// 
static void
run_match(char *path, int exec_mode,
          char **cmd_argv, int cmd_argc)
{
  char *args[MAXARG];
  int i;
  int pid;

  if(!exec_mode){
    printf("%s\n", path);
    return;
  }

  if(cmd_argc + 2 > MAXARG){
    fprintf(2, "find: too many arguments for -exec\n");
    return;
  }

  for(i = 0; i < cmd_argc; i++)
    args[i] = cmd_argv[i];

  args[cmd_argc] = path;
  args[cmd_argc + 1] = 0;

  pid = fork(); // 父进程返回pid，子进程返回0，这决定了下面两个分支父子进程分别走哪一条

  if(pid < 0){
    fprintf(2, "find: fork failed\n");
    return;
  }

  if(pid == 0){ // 子进程会跑这里
    exec(args[0], args);

    fprintf(2, "find: exec %s failed\n", args[0]);
    exit(1);
  }

  wait(0);
}

static void
find(char *path, char *target,
     int exec_mode, char **cmd_argv, int cmd_argc)
{
  char buf[512];
  char *p;
  int fd;
  struct dirent de;
  struct stat st;

  if((fd = open(path, 0)) < 0){
    fprintf(2, "find: cannot open %s\n", path);
    return;
  }

  if(fstat(fd, &st) < 0){
    fprintf(2, "find: cannot stat %s\n", path);
    close(fd);
    return;
  }

  if(strcmp(last_component(path), target) == 0)
    run_match(path, exec_mode, cmd_argv, cmd_argc);

  switch(st.type){
  case T_FILE:
  case T_DEVICE:
    break;

  case T_DIR:
    if(strlen(path) + 1 + DIRSIZ + 1 > sizeof(buf)){
      fprintf(2, "find: path too long\n");
      break;
    }

    strcpy(buf, path);
    p = buf + strlen(buf);

    if(p == buf || *(p - 1) != '/')
      *p++ = '/';

    while(read(fd, &de, sizeof(de)) == sizeof(de)){
      if(de.inum == 0)
        continue;

      memmove(p, de.name, DIRSIZ);
      p[DIRSIZ] = '\0';

      if(strcmp(p, ".") == 0 ||
         strcmp(p, "..") == 0)
        continue;
      // 递归目录里的文件
      find(buf, target,
           exec_mode, cmd_argv, cmd_argc);
    }

    break;
  }

  close(fd);
}

int
main(int argc, char *argv[])
{
  int exec_mode;
  char **cmd_argv;
  int cmd_argc;

  if(argc < 3){
    fprintf(2,
      "usage: find path name [-exec command arguments...]\n");
    exit(1);
  }

  exec_mode = 0;
  cmd_argv = 0;
  cmd_argc = 0;

  if(argc > 3){
    if(argc < 5 || strcmp(argv[3], "-exec") != 0){
      fprintf(2,
        "usage: find path name [-exec command arguments...]\n");
      exit(1);
    }

    exec_mode = 1;
    cmd_argv = &argv[4];
    cmd_argc = argc - 4;

    if(cmd_argc + 2 > MAXARG){
      fprintf(2, "find: too many arguments for -exec\n");
      exit(1);
    }
  }

  find(argv[1], argv[2],
       exec_mode, cmd_argv, cmd_argc);

  exit(0);
}