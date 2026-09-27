# -*- coding: utf-8 -*-
"""只读：把 docx 的正文段落抽成纯文本清单（不依赖 python-docx，不碰编辑器）。

用法: python read_docx_text.py <docx 绝对路径> [输出 txt 绝对路径]
"""
import re
import sys
import zipfile

src = sys.argv[1]
dst = sys.argv[2] if len(sys.argv) > 2 else None

with zipfile.ZipFile(src) as z:
    xml = z.read("word/document.xml").decode("utf-8", "replace")

# 段落：<w:p ...>...</w:p>
paras = re.findall(r"<w:p\b[^>]*>(.*?)</w:p>", xml, re.S)
lines = []
for i, p in enumerate(paras):
    # <w:t> 里的就是文本
    texts = re.findall(r"<w:t\b[^>]*>(.*?)</w:t>", p, re.S)
    text = "".join(texts)
    text = (text.replace("&amp;", "&").replace("&lt;", "<")
                .replace("&gt;", ">").replace("&quot;", '"'))
    lines.append("[%03d] %s" % (i, text))

report = "\n".join(lines) + "\n"
if dst:
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(report)
    print("written", dst, len(lines), "paragraphs")
else:
    sys.stdout.reconfigure(encoding="utf-8")
    print(report)
