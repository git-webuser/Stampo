#!/usr/bin/env python3
"""Binds short words to their neighbours in the built landing page.

No line ends on a preposition, a conjunction, an article or a one- or
two-letter word ("в", "на", "а", "и"; "a", "to", "the", "or" …), no line
starts with a dash or an arrow, and a hyphenated word is not split at its
hyphen. Russian typography asks for it; the English half follows suit so the
two read alike. Writing
&nbsp; and nowrap spans into site/index.html by hand would make the source
hard to read and is easy to forget in the next paragraph, so
Scripts/build-site.sh runs this over the output instead.

Only text between tags is touched — never attributes, and never what sits in
<script>, <style>, <title>, <pre>, <code> or <kbd>.

    python3 Scripts/site-typography.py build/site/index.html
"""
import re
import sys

NBSP = "&nbsp;"

# Every one- and two-letter word, prepositions and conjunctions, articles,
# and the pronouns that lean on the next word — «все QR-коды», «ваш Mac»,
# "every QR code", "your Mac"; all bind to the word after them. Adjectives
# and ordinals («первый», "whole") may end a line and are left alone.
SHORT = (r"[а-яё]{1,2}|без|для|при|про|под|над|или|обо|изо|ото"
         r"|через|поверх|после|перед|между|около|вокруг"
         r"|как|что|чем|если|пока|когда|чтобы|только"
         r"|все|всё|вся|всех|всем|всей|всю|всего|это|эти|его|один"
         r"|ваш(?:а|е|и|у|его|ему|им|ем|ей|их|ими)?"
         r"|сво(?:й|ё|е|я|и|ю|его|ему|им|ём|ей|их|ими)"
         r"|люб(?:ой|ая|ое|ые|ого|ому|ым|ом|ую|ых|ыми)"
         r"|[a-z]{1,2}|the|and|for|but|nor|via|its|all|any|than"
         r"|with|from|into|onto|over|above|after|before|under|about|across"
         r"|between|when|where|while|until|whatever|that|this"
         r"|your|each|every|other|several")
BEFORE_NEXT = re.compile(r"(?<![\w-])(" + SHORT + r")\s+", re.IGNORECASE)
# Particles bind to the word before them.
AFTER_PREVIOUS = re.compile(r"\s+(ли|же|бы)(?![\w-])", re.IGNORECASE)
# A dash or an arrow (Settings → Hotkeys) never starts a line.
DASH = re.compile(r"\s+([—→])")
# A version stays with what it is the version of.
VERSION = re.compile(r"\b(macOS|Stampo|Version|Версия)\s+(?=\d)")
# A browser may break a line right after a hyphen, leaving «QR-» on one line
# and «коды» on the next; hyphenated words stay whole.
HYPHENATED = re.compile(r"(?<![\w-])\w+(?:-\w+)+(?![\w-])")
# The same for a key and the word hyphenated to it: <kbd>⌘</kbd>-click.
KEY_HYPHEN = re.compile(r"<kbd>[^<]*</kbd>-\w+")
NOWRAP = '<span class="nowrap">{}</span>'

SKIP = re.compile(
    r"(<!--.*?-->"
    r"|<(script|style|title|pre|code|kbd)\b.*?</\2\s*>"
    r"|<[^>]+>)",
    re.IGNORECASE | re.DOTALL,
)


def fix(text):
    text = BEFORE_NEXT.sub(lambda m: m.group(1) + NBSP, text)
    text = AFTER_PREVIOUS.sub(lambda m: NBSP + m.group(1), text)
    text = DASH.sub(lambda m: NBSP + m.group(1), text)
    text = VERSION.sub(lambda m: m.group(1) + NBSP, text)
    text = HYPHENATED.sub(lambda m: NOWRAP.format(m.group(0)), text)
    return text


def typeset(html):
    html = KEY_HYPHEN.sub(lambda m: NOWRAP.format(m.group(0)), html)
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
