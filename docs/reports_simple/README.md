# reports 目录说明

本目录是 `report` 分支的主体内容，用于维护 xv6-labs-2025 的 Typst 实验报告。根目录 [README.md](../README.md) 说明整个报告分支的用途；本文档只说明 `reports/` 内部的文件组织和写作约定。

## 参考格式

参考 `reports/draft/OS-Report.pdf` 后，报告采用下面的组织方式：

- 封面：学校、课程、项目报告、报告名称、班级、学号、姓名、指导老师、日期。
- 目录：自动生成，显示 Lab 和各任务点。
- `Lab0: Environment Setup`：记录 WSL、工具链、QEMU、Git/GitHub 等环境配置。
- 后续每个 Lab 按任务点分节，例如 `sleep (easy)`、`find (moderate)`、`System call tracing (moderate)`。
- 每个任务点内部使用固定小节：“实验目的”“实验步骤”“实验中遇到的问题和解决方法”“实验心得”。这些小节使用普通粗体标题，不加方括号。
- 代码仓库链接需要在正文中给出：`https://github.com/JambitX11/xv6-labs-2025`。

## 目录约定

```text
reports/
  README.md
  main.typ
  templates/
    lab-report.typ
  labs/
    lab0-env.typ
    lab1-util.typ
    lab2-syscall.typ
    ...
  assets/
    lab0/
    lab1-util/
    lab2-syscall/
  draft/
    OS-Report.pdf
  out/
    xv6-labs-report.pdf
```

- `main.typ`：总报告入口，负责导入模板并 include 各 Lab。
- `templates/lab-report.typ`：统一封面、目录、页面、页脚、代码块和提示块样式。
- `labs/lab*.typ`：每个 Lab 的正文，按任务点组织。
- `assets/<lab>/`：少量截图或图片，只保留报告确实需要的材料。
- `draft/`：参考报告、草稿资料，默认不提交。
- `out/`：Typst 编译输出，默认不提交。

## 分支策略

推荐保持：

- `util`、`syscall`、`pgtbl` 等分支：只放对应实验源码。
- `report` 分支：只放 Typst 报告、截图素材和说明文档。

写报告时从远端实验分支读取代码上下文，而不是把源码复制进 `report` 分支。常用命令：

```powershell
git log --oneline origin/riscv..origin/util
git diff --stat origin/riscv...origin/util
git diff origin/riscv...origin/util -- user/sleep.c user/find.c
git show origin/util:user/find.c
```

如果 WSL 中的实验分支还没有 push 到 GitHub，Windows 侧 Codex 读不到最新实现。此时先在 WSL 中 push，或直接把关键 diff、测试输出和实验小结贴给 Codex。

## 每次实验完成后给 Codex 的小结模板

```text
实验：syscall
源码分支：syscall
基线分支：riscv
最新 commit：……

任务点：
1. System call tracing (moderate)
   - 完成内容：……
   - 关键文件：kernel/syscall.c、kernel/proc.h、user/trace.c……
   - 遇到的问题：……
2. Sysinfo (moderate)
   - 完成内容：……
   - 关键文件：kernel/sysproc.c、kernel/kalloc.c、kernel/proc.c……
   - 遇到的问题：……

测试结果：
- 运行命令：make grade / make GRADEFLAGS=trace grade / 其他
- 结果：……
- 截图：reports/assets/lab2-syscall/xxx.png 或“不放截图”

希望报告强调：
- ……
```

## 编译

在仓库根目录运行：

```powershell
typst compile reports/main.typ reports/out/xv6-labs-report.pdf
```

当前模板会自动生成目录和页脚页码。输出 PDF 位于 `reports/out/xv6-labs-report.pdf`。
