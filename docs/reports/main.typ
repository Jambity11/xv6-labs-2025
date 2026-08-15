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
  #pagebreak(weak: true)
  #include "./labs/lab1-util.typ"
  #pagebreak(weak: true)
  #include "./labs/lab2-syscall.typ"
  #pagebreak(weak: true)
  #include "./labs/lab3-pgtbl.typ"
  #pagebreak(weak: true)
  #include "./labs/lab4-traps.typ"
  #pagebreak(weak: true)
  #include "./labs/lab5-cow.typ"
  #pagebreak(weak: true)
  #include "./labs/lab6-net.typ"
  #pagebreak(weak: true)
  #include "./labs/lab7-lock.typ"
  #pagebreak(weak: true)
  #include "./labs/lab8-fs.typ"
  #pagebreak(weak: true)
  #include "./labs/lab9-mmap.typ"
]
