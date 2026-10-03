#!/usr/bin/env python3
"""Binds short words to their neighbours in the built landing page.

Russian typography does not leave a preposition, a conjunction or a
one-letter word at the end of a line ("в", "на", "а", "и" …), and no line
starts with a dash. Writing &nbsp; into site/index.html by hand would make the
source hard to read and is easy to forget in the next paragraph, so
Scripts/build-site.sh runs this over the output instead.

Only text between tags is touched — never attributes, and never what sits in
<script>, <style>, <title>, <pre>, <code> or <kbd>.

    python3 Scripts/site-typography.py build/site/index.html
"""
import re
import sys

NBSP = "&nbsp;"

# Every one- and two-letter word, and the three-letter prepositions and
# conjunctions; all bind to the word after them.
SHORT = r"[а-яё]{1,2}|без|для|при|про|под|над|или|обо|изо|ото"
BEFORE_NEXT = re.compile(r"(?<![\w-])(" + SHORT + r")\s+", re.IGNORECASE)
# Particles bind to the word before them.
AFTER_PREVIOUS = re.compile(r"\s+(ли|же|бы)(?![\w-])", re.IGNORECASE)
# A dash never starts a line, in either language.
DASH = re.compile(r"\s+—")
# A version stays with what it is the version of.
VERSION = re.compile(r"\b(macOS|Stampo|Version|Версия)\s+(?=\d)")

SKIP = re.compile(
    r"(<!--.*?-->"
    r"|<(script|style|title|pre|code|kbd)\b.*?</\2\s*>"
    r"|<[^>]+>)",
    re.IGNORECASE | re.DOTALL,
)


def fix(text):
    text = BEFORE_NEXT.sub(lambda m: m.group(1) + NBSP, text)
    text = AFTER_PREVIOUS.sub(lambda m: NBSP + m.group(1), text)
    text = DASH.sub(NBSP + "—", text)
    text = VERSION.sub(lambda m: m.group(1) + NBSP, text)
    return text


def typeset(html):
    out, last = [], 0
    for m in SKIP.finditer(html):
        out.append(fix(html[last:m.start()]))
        out.append(m.group(0))
        last = m.end()
    out.append(fix(html[last:]))
    return "".join(out)


if __name__ == "__main__":
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as f:
            html = f.read()
        with open(path, "w", encoding="utf-8") as f:
            f.write(typeset(html))
