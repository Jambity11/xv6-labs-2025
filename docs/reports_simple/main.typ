#import "./templates/lab-report.typ": project_report

#project_report(
  report_title: "xv6 及 Labs 课程项目",
  class_name: "42028703",
  student_id: "2450333",
  author: "蒋昊沄",
  teacher: "王冬青",
  date: "2026.07-2026.08"
)[
  #include "./labs/lab0-env.typ"
  #include "./labs/lab1-util.typ"
  #include "./labs/lab2-syscall.typ"
  #include "./labs/lab3-pgtbl.typ"
  #include "./labs/lab4-traps.typ"
  #include "./labs/lab5-cow.typ"
  #include "./labs/lab6-net.typ"
  #include "./labs/lab7-lock.typ"
  #include "./labs/lab8-fs.typ"
  #include "./labs/lab9-mmap.typ"
]
