#!/usr/bin/env python3
"""The app's translations: what there is to translate, whether each language
has all of it, and the .lproj folders build.sh puts in the bundle.

The English is the source code. Every string a person reads goes through
L("…"), LF("…", args) or LP("… %lld things", one: "… %lld thing", n)
(app/captions/Localized.swift), and this reads those calls out of the Swift,
with the comment each one carries for its translators and the places it is
used. The two usage descriptions macOS shows in its permission prompts come
from build.sh's Info.plist.

Each language is app/Localization/<lproj>.json: {key: string}, and for a
string that changes with a count, {key: {"one": …, "few": …, "other": …}} in
that language's own plural categories. A key is its English, or
"context|English" where one English says two things another language would
say differently.

  tools/strings.py source            the English, with context, as JSON
  tools/strings.py check [lang …]    what is missing, extra or broken
  tools/strings.py build <Resources> write the .lproj folders into a bundle
"""

import json
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCALIZATION = ROOT / "app" / "Localization"
LANGUAGES = ["es", "fr", "it", "pt-BR", "de", "nl", "tr", "ru", "ar", "hi",
             "ja", "ko", "vi", "uk", "zh-Hans"]
INFO_PLIST_KEYS = ["NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"]

# The plural categories each language's numbers fall into (CLDR, integers).
# A count's form must be given for each; "other" always.
PLURALS = {
    "es": {"one", "many", "other"}, "fr": {"one", "many", "other"},
    "it": {"one", "many", "other"}, "pt-BR": {"one", "many", "other"},
    "de": {"one", "other"}, "nl": {"one", "other"}, "tr": {"one", "other"},
    "ru": {"one", "few", "many", "other"}, "uk": {"one", "few", "many", "other"},
    "ar": {"zero", "one", "two", "few", "many", "other"}, "hi": {"one", "other"},
    "ja": {"other"}, "ko": {"other"}, "vi": {"other"}, "zh-Hans": {"other"},
}
# Required rather than merely allowed: "many" in the Romance languages is for
# millions, which no count here reaches, so it may be left to "other".
REQUIRED_PLURALS = {lang: cats - {"many"} if lang in ("es", "fr", "it", "pt-BR") else cats
                    for lang, cats in PLURALS.items()}

# What must come through a translation unchanged, when the English has it.
# Units and Apple's own names are the language's (583 Mo, Confidentialité et
# sécurité), so they are not here.
KEEP = ["Subtitles", "subtitles-live.com", "Gumroad", "Mac", "⌥", "⇧", "⌃", "RTF",
        "Neural Engine", "Nemotron", "Parakeet", "HTTP", "Audio Borealis"]
# Words the app never shows, in any language.
BANNED = ["—"]   # the em dash


# ── reading the Swift ─────────────────────────────────────────────────────────

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def unescape(body):
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt == "u":
            end = body.index("}", i)
            out.append(chr(int(body[i + 3:end], 16)))
            i = end + 1
        elif nxt == "(":
            raise ValueError("interpolation inside a localized string")
        else:
            out.append(ESCAPES[nxt])
            i += 2
    return "".join(out)


def literal_chain(src, i):
    """One or more string literals joined by +, starting at src[i] (after
    whitespace). Returns (text, index after), or (None, i) when there is no
    literal there."""
    parts = []
    j = i
    while True:
        m = re.compile(r'\s*').match(src, j)
        j = m.end()
        if j >= len(src) or src[j] != '"':
            break
        k = j + 1
        while src[k] != '"':
            k += 2 if src[k] == "\\" else 1
        parts.append(unescape(src[j + 1:k]))
        j = k + 1
        m = re.compile(r'\s*\+').match(src, j)
        if not m:
            break
        j = m.end()
    if not parts:
        return None, i
    return "".join(parts), j


CALL = re.compile(r'(?<![\w.])(L|LF|LP)\(')


def source():
    """Every localized string in the app: {key: {english, one?, comment, where}}."""
    found = {}
    files = sorted((ROOT / "app").rglob("*.swift"))
    for path in files:
        if path.name == "Localized.swift":
            continue
        src = path.read_text()
        # Blank out comments, keeping offsets, so a call named in one is not
        # read as a call.
        code = re.sub(r'//[^\n]*', lambda m: " " * len(m.group()), src)
        for m in CALL.finditer(code):
            kind = m.group(1)
            key, j = literal_chain(code, m.end())
            if key is None:
                raise SystemExit(f"{path.relative_to(ROOT)}:{src.count(chr(10), 0, m.start()) + 1}: "
                                 f"{kind}( takes a string literal")
            line = src.count("\n", 0, m.start()) + 1
            entry = {"english": key.split("|", 1)[-1] if "|" in key else key}
            rest = code[j:j + 400]
            if kind == "LP":
                one = re.match(r'\s*,\s*one:', rest)
                if not one:
                    raise SystemExit(f"{path.relative_to(ROOT)}:{line}: LP needs one:")
                entry["one"], _ = literal_chain(code, j + one.end())
            if kind == "L":
                comma = re.match(r'\s*,', rest)
                if comma:
                    comment, _ = literal_chain(code, j + comma.end())
                    if comment:
                        entry["comment"] = comment
            where = f"{path.relative_to(ROOT)}:{line}"
            if key in found:
                prev = found[key]
                if kind == "LP" and prev.get("one") != entry.get("one"):
                    raise SystemExit(f"{where}: {key!r} has two different singulars")
                prev["where"].append(where)
                if "comment" in entry and "comment" not in prev:
                    prev["comment"] = entry["comment"]
            else:
                entry["where"] = [where]
                found[key] = entry
    # The permission prompts, from build.sh's Info.plist.
    build = (ROOT / "build.sh").read_text()
    for name in INFO_PLIST_KEYS:
        m = re.search(r"<key>%s</key>\s*<string>(.*?)</string>" % name, build, re.S)
        found["InfoPlist|" + name] = {
            "english": m.group(1),
            "comment": "macOS shows this in its permission prompt, under the question "
                       "whether Subtitles may " + ("capture the audio the Mac plays"
                                                   if "Audio" in name else "use the microphone"),
            "where": ["build.sh (Info.plist)"],
        }
    return found


# ── checking a language ───────────────────────────────────────────────────────

SPEC = re.compile(r'%(?:(\d+)\$)?(@|lld|d|%)')


def specs(text):
    """The format arguments a string takes, by position."""
    out, n = {}, 0
    for m in SPEC.finditer(text):
        if m.group(2) == "%":
            continue
        n += 1
        out[int(m.group(1)) if m.group(1) else n] = m.group(2)
    return out


def load(lang):
    path = LOCALIZATION / f"{lang}.json"
    return json.loads(path.read_text()) if path.exists() else {}


def check(lang, src):
    problems = []
    have = load(lang)
    for key in sorted(set(src) - set(have)):
        problems.append(f"missing: {key!r}")
    # A key the app no longer asks for is left over, not broken: the 0BSD
    # edition has no license window, and its strings stay in the shared files.
    unused = sorted(set(have) - set(src))  # noqa: F841, reported by nothing
    for key, entry in src.items():
        if key not in have:
            continue
        value = have[key]
        english = entry["english"]
        plural = "one" in entry
        if plural != isinstance(value, dict):
            problems.append(f"{key!r}: {'a count wants plural forms' if plural else 'not a count'}")
            continue
        forms = value if plural else {"": value}
        if plural:
            missing = REQUIRED_PLURALS[lang] - set(forms)
            extra = set(forms) - PLURALS[lang]
            if missing:
                problems.append(f"{key!r}: no {', '.join(sorted(missing))} form")
            if extra:
                problems.append(f"{key!r}: {', '.join(sorted(extra))} is not a {lang} category")
        want = specs(english)
        for cat, text in forms.items():
            label = f"{key!r}" + (f" [{cat}]" if cat else "")
            if not isinstance(text, str) or not text.strip():
                problems.append(f"{label}: empty")
                continue
            got = specs(text)
            # A plural form may leave the number out ("один" for one), never
            # add or change one.
            if plural and cat != "other":
                if any(got.get(p) != t for p, t in got.items() if p in want) or set(got) - set(want):
                    problems.append(f"{label}: arguments {got} against {want}")
            elif got != want:
                problems.append(f"{label}: arguments {got} against {want}")
            for word in KEEP:
                if word in english and word not in text:
                    problems.append(f"{label}: lost {word!r}")
            for word in BANNED:
                if word in text:
                    problems.append(f"{label}: has {word!r}")
            if english.count("\n") != text.count("\n"):
                problems.append(f"{label}: line breaks differ from the English")
    return problems


# ── building ─────────────────────────────────────────────────────────────────

def plural_entry(forms):
    rule = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": "lld"}
    rule.update(forms)
    return {"NSStringLocalizedFormatKey": "%#@count@", "count": rule}


def build(resources, src):
    resources = pathlib.Path(resources)
    # English has no table of its own, the source being English; the folder
    # is what tells the bundle English is one of its languages, and the one
    # to fall back on.
    en = resources / "en.lproj"
    en.mkdir(parents=True, exist_ok=True)
    (en / "Localizable.strings").write_bytes(plistlib.dumps({}, fmt=plistlib.FMT_BINARY))
    for lang in LANGUAGES:
        have = load(lang)
        if not have:
            continue
        folder = resources / f"{lang}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        strings, plurals, info = {}, {}, {}
        for key, value in have.items():
            if key not in src:
                continue
            if key.startswith("InfoPlist|"):
                info[key.split("|", 1)[1]] = value
            elif isinstance(value, dict):
                plurals[key] = plural_entry(value)
            else:
                strings[key] = value
        (folder / "Localizable.strings").write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_BINARY))
        if plurals:
            (folder / "Localizable.stringsdict").write_bytes(
                plistlib.dumps(plurals, fmt=plistlib.FMT_XML))
        if info:
            (folder / "InfoPlist.strings").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        missing = len(set(src) - set(have))
        print(f"    {lang}: {len(strings)} strings, {len(plurals)} counts"
              + (f", {missing} missing (English shows)" if missing else ""))


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    src = source()
    if args[0] == "source":
        print(json.dumps(src, ensure_ascii=False, indent=1))
    elif args[0] == "check":
        bad = 0
        for lang in args[1:] or LANGUAGES:
            problems = check(lang, src)
            bad += len(problems)
            print(f"{lang}: " + ("ok" if not problems else f"{len(problems)} problems"))
            for p in problems:
                print("   ", p)
        sys.exit(1 if bad else 0)
    elif args[0] == "build":
        build(args[1], src)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
