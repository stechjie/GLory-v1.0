# -*- coding: utf-8 -*-
"""只读探针：打印 PrepBoardController 四个 handler 区域的原字节（含行尾），
用来给变异脚本取**逐字节精确**的 FIXED/OLD 片段。不写任何文件。"""
import io
import os

TARGET = r"C:\Users\WINDOWS\Desktop\GLory-work\scenes\prep\PrepBoardController.gd"
REPORT = r"C:\Users\WINDOWS\Desktop\GLory-work\work\_qa_922\probe_bench_bytes_report.txt"

with open(TARGET, "rb") as fh:
    raw = fh.read()

out = []
out.append("size = %d" % len(raw))
out.append("crlf = %d  bare_lf = %d"
           % (raw.count(b"\r\n"), raw.count(b"\n") - raw.count(b"\r\n")))

text = raw.decode("utf-8")
lines = text.split("\r\n")

for i, ln in enumerate(lines, start=1):
    if 588 <= i <= 614:
        out.append("%4d | %s" % (i, ln.replace("\t", "<TAB>")))

with open(REPORT, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
