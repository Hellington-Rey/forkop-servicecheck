"""Structural sanity checks for the ucode / LuCI JS sources.

ucode is close enough to JavaScript that a hand written tokenizer can verify
bracket balance and collect the identifiers that are called, which is what
actually breaks when writing these files blind.
"""

import json
import re
import sys
from pathlib import Path

BUILTINS = {
    # ucode core
    "print", "warn", "exit", "length", "push", "pop", "shift", "unshift", "index",
    "rindex", "require", "include", "json", "match", "replace", "split", "join",
    "substr", "trim", "ltrim", "rtrim", "sprintf", "printf", "lc", "uc", "type",
    "keys", "values", "sort", "reverse", "filter", "map", "int", "getenv", "system",
    "clock", "sleep", "exists", "die", "assert", "uchr", "ord", "chr", "hex", "hexenc",
    "hexdec", "b64enc", "b64dec", "min", "max", "abs", "slice", "splice", "uniq",
    "localtime", "gmtime", "timelocal", "timegm", "arrtoip", "iptoarr", "wildcard",
    "regexp", "call", "loadstring", "loadfile", "gc", "sourcepath", "render",
    # browser / LuCI side
    "E", "L", "parseInt", "parseFloat", "isNaN", "String", "Number", "Boolean",
    "Array", "Object", "Promise", "Error", "Date", "Math", "JSON", "setTimeout",
    "clearTimeout", "encodeURIComponent", "decodeURIComponent", "_",
}


def strip_code(text):
    """Return the source with comments, strings and regex literals blanked out."""
    out = []
    i = 0
    n = len(text)
    prev_significant = ""

    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue

        if ch == "/" and nxt == "*":
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                i += 1
            i += 2
            continue

        if ch in "'\"`":
            quote = ch
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            out.append('""')
            prev_significant = '"'
            continue

        if ch == "/" and prev_significant in "(,=:[!&|?{;+*%~^" + "":
            # regex literal
            i += 1
            in_class = False
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == "[":
                    in_class = True
                elif text[i] == "]":
                    in_class = False
                elif text[i] == "/" and not in_class:
                    i += 1
                    break
                elif text[i] == "\n":
                    break
                i += 1
            while i < n and text[i] in "gims":
                i += 1
            out.append("RE")
            prev_significant = "E"
            continue

        out.append(ch)
        if not ch.isspace():
            prev_significant = ch
        i += 1

    return "".join(out)


def check_balance(name, code):
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    problems = []

    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                problems.append(f"{name}:{line}: closing '{ch}' with nothing open")
            elif stack[-1][0] != pairs[ch]:
                opener, opened_at = stack[-1]
                problems.append(
                    f"{name}:{line}: '{ch}' closes '{opener}' opened at line {opened_at}"
                )
                stack.pop()
            else:
                stack.pop()

    for opener, opened_at in stack:
        problems.append(f"{name}:{opened_at}: '{opener}' never closed")

    return problems


def check_forward_references(name, code):
    """В ucode нет подъёма объявлений: функция, объявленная ниже, не видна
    функции, объявленной выше - вызов компилируется как обращение к глобали
    и падает в рантайме с 'left-hand side is not a function'."""
    definitions = []
    for match in re.finditer(r"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", code):
        definitions.append((match.group(1), match.start()))

    order = {fname: position for fname, position in definitions}
    problems = []

    for index, (fname, position) in enumerate(definitions):
        end = definitions[index + 1][1] if index + 1 < len(definitions) else len(code)
        body = code[position:end]

        for call in re.finditer(r"(?<![.\w])([A-Za-z_][A-Za-z0-9_]*)\s*\(", body):
            callee = call.group(1)
            if callee not in order or callee == fname:
                continue
            if order[callee] > position:
                line = code[:position + call.start()].count("\n") + 1
                problems.append(
                    f"{name}:{line}: {fname}() вызывает {callee}(), объявленную ниже"
                )

    return problems


def check_calls(name, code):
    defined = set(re.findall(r"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", code))
    defined |= set(re.findall(r"\b(?:let|const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function", code))
    called = set()

    for match in re.finditer(r"(?<![.\w])([A-Za-z_][A-Za-z0-9_]*)\s*\(", code):
        called.add(match.group(1))

    keywords = {"if", "for", "while", "switch", "catch", "return", "function", "delete", "in", "typeof", "new"}
    unknown = sorted(called - defined - BUILTINS - keywords)
    return defined, unknown


def main():
    problems = []

    for path in sys.argv[1:]:
        p = Path(path)
        text = p.read_text(encoding="utf-8")

        if text.startswith("#!/bin/sh"):
            print(f"OK   {p.name}: POSIX shell wrapper (check with sh -n)")
            continue

        if p.suffix == ".json":
            try:
                json.loads(text)
                print(f"OK   {p.name}: валидный JSON")
            except json.JSONDecodeError as error:
                problems.append(f"{p.name}: невалидный JSON - {error}")
            continue

        code = strip_code(text)
        balance_problems = check_balance(p.name, code)
        problems.extend(balance_problems)

        if p.suffix == ".uc" or p.name == "forkop-servicecheck":
            problems.extend(check_forward_references(p.name, code))

        defined, unknown = check_calls(p.name, code)
        print(f"OK   {p.name}: {len(defined)} функций, скобки {'сбалансированы' if not balance_problems else 'СЛОМАНЫ'}")
        if unknown:
            print(f"     внешние/неизвестные вызовы: {', '.join(unknown)}")

    if problems:
        print("\nПРОБЛЕМЫ:")
        for problem in problems:
            print(" -", problem)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
