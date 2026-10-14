#!/usr/bin/env python3
# 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
# Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

"""Builds the app's string catalogs from keys.json and the per-language files beside it, and checks that the
strings in the code and the strings in keys.json are the same set.

    build_catalog.py           writes the catalogs (and reports problems)
    build_catalog.py --check   reports problems only, exit 1 if any: for Tools/check.sh
"""
import json, re, sys
from pathlib import Path

HERE = Path(__file__).parent
APP = HERE.parent / "App" / "Oushi"
LANGS = ["zh-Hant", "zh-HK", "en", "en-US", "ja", "ko", "vi", "nl", "fi", "fr", "de", "it", "lt", "pl", "pt-BR", "ru", "es", "th", "tr", "uk"]
PLACEHOLDER = re.compile(r"%(\d+\$)?(lld|@|d)")
CJK = re.compile(r"[㐀-鿿＀-￯　-〿]")
INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")
# A literal given verbatim is not a key: taken off the line before its literals are read.
VERBATIM = re.compile(r'verbatim:\s*"(?:[^"\\]|\\.)*"')


def placeholders(s):
    """The placeholders as (position, type), positions counted from one in order of appearance when not written:
    a translation must use each of the key's placeholders once, by position and type."""
    found = []
    for index, m in enumerate(PLACEHOLDER.finditer(s), 1):
        position = int(m.group(1)[:-1]) if m.group(1) else index
        found.append((position, m.group(2)))
    return sorted(found)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value):
    if isinstance(value, dict):
        return {"variations": {"plural": {form: unit(v) for form, v in value.items()}}}
    return unit(value)


def literals(line):
    """The string literals on a Swift source line, with their interpolations kept as written (an interpolation
    may itself hold a string, like `\\(Image(systemName: "heart"))`)."""
    found = []
    i = 0
    while i < len(line):
        if line[i] != '"' or (i > 0 and line[i - 1] == "\\"):
            i += 1
            continue
        j = i + 1
        depth = 0
        inner = False
        text = ""
        while j < len(line):
            c = line[j]
            if depth == 0:
                if c == "\\" and j + 1 < len(line):
                    if line[j + 1] == "(":
                        depth = 1
                    text += c + line[j + 1]
                    j += 2
                    continue
                if c == '"':
                    break
            else:
                if inner:
                    if c == '"' and line[j - 1] != "\\":
                        inner = False
                elif c == '"':
                    inner = True
                elif c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
            text += c
            j += 1
        found.append(text)
        i = j + 1
    return found


def without_comment(line):
    """The line up to a `//` that is not inside a string literal."""
    inside = False
    i = 0
    while i < len(line) - 1:
        c = line[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            inside = not inside
        elif not inside and line[i:i + 2] == "//":
            return line[:i]
        i += 1
    return line


def code_keys():
    """Every Chinese string literal in the Swift sources, as the key it would look up: each interpolation may be
    a count (%lld) or anything else (%@), so a literal with interpolations yields every combination. The app's
    user-facing strings are Chinese, so these are localization keys unless the line says `verbatim` or keys.json
    lists them under notLocalized."""
    keys = {}
    for path in sorted(APP.rglob("*.swift")):
        for number, line in enumerate(path.read_text().split("\n"), 1):
            line = VERBATIM.sub("", without_comment(line))
            if not line.strip():
                continue
            for literal in literals(line):
                if not CJK.search(INTERPOLATION.sub("", literal)):
                    continue
                literal = literal.replace('\\"', '"')
                parts = INTERPOLATION.split(literal)
                count = len(parts) - 1
                variants = []
                for bits in range(1 << count):
                    key = parts[0]
                    for index in range(count):
                        key += ("%lld" if bits >> index & 1 else "%@") + parts[index + 1]
                    variants.append(key)
                keys.setdefault(tuple(variants), []).append(f"{path.relative_to(APP)}:{number}")
    return keys


def main():
    check_only = "--check" in sys.argv
    keys = json.loads((HERE / "keys.json").read_text())
    translations = {}
    for lang in LANGS:
        source = "en" if lang == "en-US" else lang
        path = HERE / f"{source}.json"
        if path.exists():
            translations[lang] = json.loads(path.read_text())
        elif source == "en":
            translations[lang] = {k: v["en"] for k, v in keys["strings"].items()} | {k: v["en"] for k, v in keys["infoPlist"].items()}
    problems = []

    # The code against keys.json, both ways.
    known = set(keys["strings"])
    ignored = set(keys.get("notLocalized", []))
    used = set()
    for variants, places in code_keys().items():
        hits = [v for v in variants if v in known]
        if hits:
            used.update(hits)
        elif not any(v in ignored for v in variants):
            problems.append(f"code: {variants[0]!r} at {places[0]} is not in keys.json")
    for key in sorted(known - used):
        problems.append(f"keys.json: {key!r} is not used by the code")
    for key in sorted(ignored & known):
        problems.append(f"keys.json: {key!r} is both a string and notLocalized")
    seen_ignored = {v for variants in code_keys() for v in variants if v in ignored}
    for key in sorted(ignored - seen_ignored):
        problems.append(f"keys.json: notLocalized {key!r} is not in the code")

    # Every language against keys.json: nothing left over.
    for lang, table in translations.items():
        for key in table:
            if key not in known and key not in keys["infoPlist"]:
                problems.append(f"{lang}: {key!r} is not in keys.json")

    def catalog(section):
        strings = {}
        for key, info in keys[section].items():
            entry = {"localizations": {}}
            if note := info.get("note"):
                entry["comment"] = note
            if section == "infoPlist":
                entry["extractionState"] = "manual"
            # Info.plist keys are not text: the source language needs a value of its own too.
            sources = {"zh-Hans": {k: v["zh-Hans"] for k, v in keys["infoPlist"].items()}} if section == "infoPlist" else {}
            for lang, table in list(sources.items()) + list(translations.items()):
                value = table.get(key)
                if value is None:
                    problems.append(f"{lang}: missing {key!r}")
                    continue
                values = value.values() if isinstance(value, dict) else [value]
                for v in values:
                    if placeholders(v) != placeholders(key) and section != "infoPlist":
                        problems.append(f"{lang}: placeholders differ in {key!r}: {v!r}")
                entry["localizations"][lang] = localization(value)
            strings[key] = entry
        return {"sourceLanguage": "zh-Hans", "version": "1.0", "strings": strings}

    for section, name in (("strings", "Localizable"), ("infoPlist", "InfoPlist")):
        out = APP / "Resources" / f"{name}.xcstrings"
        text = json.dumps(catalog(section), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        if check_only:
            if not out.exists() or out.read_text() != text:
                problems.append(f"{out.relative_to(HERE.parent)} is out of date: run build_catalog.py")
        else:
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(text)
    for p in problems:
        print(p)
    print(f"{len(translations)} languages, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
