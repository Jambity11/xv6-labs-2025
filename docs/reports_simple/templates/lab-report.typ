#let cover_page(
  report_title: "",
  course: "",
  school: "",
  school_en: "",
  class_name: "",
  student_id: "",
  author: "",
  teacher: "",
  repo: "",
  date: "",
) = {
  align(center)[
    #v(2.8cm)
    #text(size: 32pt, weight: "bold")[#school]
    #v(8pt)
    #text(size: 17pt)[#school_en]
    #v(2.3cm)
    #text(size: 25pt, weight: "bold")[#course]
    #v(14pt)
    #text(size: 25pt, weight: "bold")[项目报告]
    #v(2.0cm)
  ]

  grid(
    columns: (34%, 66%),
    row-gutter: 12pt,
    column-gutter: 8pt,
    align: (right, left),
    text(weight: "bold")[报告名称：], box(width: 8.5cm)[#align(center)[#report_title]],
    text(weight: "bold")[课号：], box(width: 8.5cm)[#align(center)[#class_name]],
    text(weight: "bold")[学号：], box(width: 8.5cm)[#align(center)[#student_id]],
    text(weight: "bold")[姓名：], box(width: 8.5cm)[#align(center)[#author]],
    text(weight: "bold")[指导老师：], box(width: 8.5cm)[#align(center)[#teacher]],
    text(weight: "bold")[日期：], box(width: 8.5cm)[#align(center)[#date]],
  )
}

#let project_report(
  body,
  report_title: "xv6及Labs课程项目",
  course: "《操作系统课程设计》",
  school: "同济大学",
  school_en: "Tongji University",
  class_name: "",
  student_id: "",
  author: "",
  teacher: "",
  repo: "https://github.com/Jambity11/xv6-labs-2025",
  date: ""
) = {
  set document(title: report_title, author: author)
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.1cm, left: 2.55cm, right: 2.35cm),
    footer: context align(center)[
      #counter(page).display() / #counter(page).final().first()
    ],
  )
  set text(
    font: ("SimSun", "Microsoft YaHei", "Times New Roman"),
    size: 12pt,
    lang: "zh",
  )
  set par(
    justify: true,
    leading: 0.86em,
    first-line-indent: (amount: 2em, all: true),
  )
  set heading(numbering: none)
  show raw.where(block: true): it => block(
    width: 100%,
    fill: rgb("#f7f7f8"),
    stroke: rgb("#d8dce2"),
    inset: 8pt,
    radius: 2pt,
  )[#it]
  show heading.where(level: 1): it => [
    #set par(first-line-indent: 0em)
    #v(10pt)
    #text(font: ("Microsoft YaHei", "SimSun"), size: 20pt, weight: "bold")[#it.body]
    #v(7pt)
  ]
  show heading.where(level: 2): it => [
    #set par(first-line-indent: 0em)
    #v(8pt)
    #text(font: ("Microsoft YaHei", "SimSun"), size: 15pt, weight: "bold")[#it.body]
    #v(4pt)
  ]
  show heading.where(level: 3): it => [
    #set par(first-line-indent: 0em)
    #v(6pt)
    #text(font: ("Microsoft YaHei", "SimSun"), size: 12pt, weight: "bold")[#it.body]
    #v(2pt)
  ]

  cover_page(
    report_title: report_title,
    course: course,
    school: school,
    school_en: school_en,
    class_name: class_name,
    student_id: student_id,
    author: author,
    teacher: teacher,
    repo: repo,
    date: date,
  )

  pagebreak()

  align(center)[#text(size: 20pt, weight: "bold")[目录]]
  v(8pt)
  outline(title: none, depth: 2)

  pagebreak()

  body
}

#let lab_meta(branch: "", base: "origin/riscv", commit: "", tests: ()) = {
  table(
    columns: (26%, 74%),
    stroke: rgb("#d9dde3"),
    inset: 5pt,
    [源码分支], [#branch],
    [基线分支], [#base],
    [实验提交], [#commit],
    [测试结果], [
      #if tests.len() == 0 {
        [待补充]
      } else {
        for item in tests [
          - #item
        ]
      }
    ],
  )
}

#let part(title) = {
  v(8pt)
  block(width: 100%)[
    #set par(first-line-indent: 0em)
    #text(font: ("Microsoft YaHei", "SimSun"), size: 12pt, weight: "bold")[#title]
  ]
  v(2pt)
}

#let code_ref(path, desc: none) = {
  if desc == none {
    emph(path)
  } else {
    emph(path + "：" + desc)
  }
}

#let todo(text) = {
  block(
    width: 100%,
    fill: rgb("#fff8df"),
    stroke: rgb("#ead27a"),
    inset: 8pt,
    radius: 2pt,
  )[
    #strong[待补充：] #text
  ]
}
