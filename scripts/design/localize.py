#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Выносит русские надписи интерфейса в каталог переводов.

Каждый строковый литерал с кириллицей в файлах интерфейса оборачивается в L("…");
подстановки \\(x) превращаются в %@ с аргументами. Ключи складываются в keys.json.
Запускается один раз; повторный запуск уже обёрнутые строки не трогает.

    python3 scripts/design/localize.py            # показать, что изменится
    python3 scripts/design/localize.py --write    # изменить файлы
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "RayBanClaude")
CYRILLIC = re.compile("[А-Яа-яЁё]")

# Файлы, где строки — не интерфейс: промпты для модели, описания инструментов, демо-данные, журнал.
SKIP_FILES = {
    "SystemPrompt.swift", "DemoMode.swift", "AssistantShortcuts.swift", "DiagnosticLog.swift",
    "LanguageGuess.swift", "AssistantTools.swift", "L10n.swift",
}
SKIP_DIRS = {"Tools"}

# Строки, где литерал нельзя или не нужно оборачивать.
SKIP_LINE = re.compile(r'journal\(|NSLog\(|^\s*case \w+ = "|^\s*//|russianName:|print\(|\[память|silenceMark')

# Области (функция или свойство), где строки предназначены модели или привязаны к языку ассистента.
SKIP_SCOPE = re.compile(
    r"var prompt: String|var promptName|var humorPrompt|var characterPrompt|var acknowledgement|var failureMessage"
    r"|var refusalMessage|private func contextLine|func isAddressed|func translate\(|var greeting: String"
    r"|static func callGreeting|private static func isHangUp|private static let variants|enum HoldingPhrase"
    r"|static let suggestedNames|static let all: \[TranslatorLanguage\]|private func recoverCallAudio"
)

keys = {}


def unescape(text):
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            n = text[i + 1]
            if n == "n":
                out.append("\n"); i += 2; continue
            if n == "t":
                out.append("\t"); i += 2; continue
            if n in "\"\\'":
                out.append(n); i += 2; continue
            if n == "u" and text[i + 2:i + 3] == "{":
                j = text.index("}", i)
                out.append(chr(int(text[i + 3:j], 16))); i = j + 1; continue
        out.append(c)
        i += 1
    return "".join(out)


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


class Parser:
    """Разбирает исходник Swift настолько, чтобы находить строковые литералы и подстановки в них."""

    def __init__(self, source, skip_ranges):
        self.s = source
        self.skip_ranges = skip_ranges

    def skipped(self, index):
        return any(a <= index < b for a, b in self.skip_ranges)

    def transform(self, start, end, top=True):
        """Возвращает преобразованный текст s[start:end] (код, не внутри литерала)."""
        s = self.s
        out = []
        i = start
        while i < end:
            if s.startswith("//", i):
                j = s.find("\n", i)
                j = end if j == -1 or j > end else j
                out.append(s[i:j]); i = j; continue
            if s.startswith("/*", i):
                j = s.find("*/", i) + 2
                out.append(s[i:j]); i = j; continue
            if s.startswith('#"', i):  # сырые строки (регулярные выражения) не трогаем
                j = s.find('"#', i + 2) + 2
                out.append(s[i:j]); i = j; continue
            if s.startswith('"""', i):
                text, j = self.literal(i, multiline=True)
                out.append(text); i = j; continue
            if s[i] == '"':
                text, j = self.literal(i, multiline=False)
                out.append(text); i = j; continue
            out.append(s[i])
            i += 1
        return "".join(out)

    def literal(self, start, multiline):
        """Разбирает литерал с позиции start. Возвращает (новый текст, индекс после литерала)."""
        s = self.s
        quote = '"""' if multiline else '"'
        i = start + len(quote)
        segments = []  # ('text', raw) | ('expr', code)
        buf = []
        while True:
            if s.startswith(quote, i) and (not multiline or True):
                break
            c = s[i]
            if c == "\\" and s[i + 1] == "(":
                # подстановка: ищем парную скобку с учётом вложенных литералов
                depth = 0
                j = i + 1
                while True:
                    ch = s[j]
                    if ch == '"':
                        _, j = self.literal(j, multiline=s.startswith('"""', j))
                        continue
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                segments.append(("text", "".join(buf))); buf = []
                segments.append(("expr", self.transform(i + 2, j, top=False)))
                i = j + 1
                continue
            if c == "\\":
                buf.append(s[i:i + 2]); i += 2; continue
            buf.append(c)
            i += 1
        segments.append(("text", "".join(buf)))
        end = i + len(quote)
        original = s[start:end]

        own_text = "".join(t for kind, t in segments if kind == "text")
        line_start = s.rfind("\n", 0, start) + 1
        line_end = s.find("\n", start)
        line = s[line_start:line_end if line_end != -1 else len(s)]
        before = s[max(0, start - 2):start]
        already = before == "L("
        if not CYRILLIC.search(own_text) or self.skipped(start) or SKIP_LINE.search(line) or already:
            # литерал остаётся как есть, но вложенные подстановки могли измениться
            if any(kind == "expr" for kind, _ in segments) and not multiline:
                rebuilt = '"' + "".join(t if kind == "text" else "\\(" + t + ")" for kind, t in segments) + '"'
                return rebuilt, end
            return original, end

        if multiline:
            segments = self.dedent(segments, start, end)
        key_raw = "".join(t if kind == "text" else "%@" for kind, t in segments)
        key = unescape(key_raw) if not multiline else key_raw
        args = [t for kind, t in segments if kind == "expr"]
        keys.setdefault(key, 0)
        keys[key] += 1
        emitted = 'L("' + (escape(key) if multiline else key_raw) + '"'
        if args:
            emitted += ", " + ", ".join(args)
        emitted += ")"
        return emitted, end

    def dedent(self, segments, start, end):
        """Многострочный литерал → одна строка: убираем отступ, склеиваем строки с «\\» в конце."""
        s = self.s
        closing_line_start = s.rfind("\n", 0, end - 3) + 1
        indent = s[closing_line_start:end - 3]
        marker = "\u0000"
        joined = "".join(t if kind == "text" else marker for kind, t in segments)
        lines = joined.split("\n")[1:-1]  # первая строка после """ и последняя перед """ пустые
        lines = [l[len(indent):] if l.startswith(indent) else l.lstrip() for l in lines]
        text = ""
        for index, l in enumerate(lines):
            if l.endswith("\\"):
                text += unescape(l[:-1])
            else:
                text += unescape(l) + ("\n" if index < len(lines) - 1 else "")
        exprs = [t for kind, t in segments if kind == "expr"]
        parts = text.split(marker)
        result = []
        for index, part in enumerate(parts):
            result.append(("text", part))
            if index < len(exprs):
                result.append(("expr", exprs[index]))
        return result


def skip_ranges(source):
    """Диапазоны символов внутри «областей для модели»."""
    ranges = []
    for m in SKIP_SCOPE.finditer(source):
        line_end = source.find("\n", m.start())
        brace = source.find("{", m.start(), line_end if line_end != -1 else len(source))
        if brace == -1:
            # свойство-значение: до конца выражения (закрывающая скобка массива или конец строки)
            bracket = source.find("[", m.start(), line_end)
            if bracket != -1:
                depth = 0
                j = bracket
                while j < len(source):
                    if source[j] == "[":
                        depth += 1
                    elif source[j] == "]":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                ranges.append((m.start(), j))
            else:
                ranges.append((m.start(), line_end))
            continue
        depth = 0
        j = brace
        while j < len(source):
            if source[j] == "{":
                depth += 1
            elif source[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        ranges.append((m.start(), j))
    return ranges


def main():
    write = "--write" in sys.argv
    changed = 0
    for directory, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in sorted(files):
            if not name.endswith(".swift") or name in SKIP_FILES:
                continue
            path = os.path.join(directory, name)
            source = open(path, encoding="utf-8").read()
            parser = Parser(source, skip_ranges(source))
            result = parser.transform(0, len(source))
            if result != source:
                changed += 1
                if write:
                    open(path, "w", encoding="utf-8").write(result)
    out = os.path.join(os.path.dirname(__file__), "keys.json")
    if write:
        json.dump(sorted(keys), open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("files changed:", changed, "keys:", len(keys))


if __name__ == "__main__":
    main()
