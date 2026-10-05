"""Aplica scripts/participants-aliases.csv (variant -> canonical) no vox-content.

Altera, em cada episódio, o JSON sidecar e o frontmatter do .md:
  - participants: grafia variante -> canônica (sem duplicar)
  - tags: slug da variante -> slug da canônica (sem duplicar)

Uso:
    python scripts/participants_apply_aliases.py --dry-run
    python scripts/participants_apply_aliases.py
"""
import argparse
import csv
import glob
import json
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.environ.get("VOX_CONTENT", r"E:\vox-content")


def slug(name: str) -> str:
    # mesmo formato das tags do Toscanini: sem acento, minúsculo, pontuação
    # (inclusive hífen) removida, espaço -> hífen. "Kasten-Smith" -> "kastensmith"
    s = unicodedata.normalize("NFKD", name)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return "-".join(re.sub(r"[^a-z0-9\s]", "", s).split())


def detect_format(raw, data):
    """(ensure_ascii, trailing) que reproduz o arquivo original, ou None."""
    for ea in (False, True):
        for nl in ("", "\n"):
            if json.dumps(data, ensure_ascii=ea, indent=2) + nl == raw:
                return ea, nl
    return None


def dedup(seq):
    seen, out = set(), []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def load_aliases(path):
    names, tags = {}, {}
    with open(path, encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            v, c = row["variant"].strip(), row["canonical"].strip()
            if not v or not c or v == c:
                continue
            names[v] = c
            if slug(v) != slug(c):
                tags[slug(v)] = slug(c)
    return names, tags


def fix_list(items, mapping):
    return dedup([mapping.get(x, x) for x in items])


def yaml_unquote(v):
    if len(v) >= 2 and v[0] == v[-1] == "'":
        return v[1:-1].replace("''", "'")
    if len(v) >= 2 and v[0] == v[-1] == '"':
        return json.loads(v)
    return v


def yaml_scalar(v):
    plain_ok = (re.fullmatch(r"[^\s\-?:,\[\]{}#&*!|>'\"%@`].*", v)
                and ": " not in v and " #" not in v and not v.endswith(":")
                and not re.fullmatch(r"[-+.\d][\d_.eE+-]*|true|false|yes|no|null|~", v, re.I))
    return v if plain_ok else "'" + v.replace("'", "''") + "'"


def patch_md(md_path, names, tagmap):
    """Troca itens dos blocos participants:/tags: do frontmatter, linha a linha.
    Linhas não afetadas ficam byte a byte iguais (preserva aspas do Toscanini)."""
    with open(md_path, encoding="utf-8", newline="") as fh:
        text = fh.read()
    nl = "\r\n" if "\r\n" in text else "\n"
    m = re.match(r"---\r?\n(.*?)\r?\n---", text, re.S)
    if not m:
        return False
    fm = m.group(1)

    def block(key, mapping):
        nonlocal fm
        pat = re.compile(rf"^{key}:\r?\n((?:- .*(?:\r?\n|$))*)", re.M)
        m2 = pat.search(fm)
        if not m2:
            return
        out, seen = [], set()
        for line in m2.group(1).splitlines():
            val = yaml_unquote(line[2:].strip())
            new = mapping.get(val, val)
            if new in seen:
                continue
            seen.add(new)
            out.append(line if new == val else f"- {yaml_scalar(new)}")
        tail = nl if m2.group(1).endswith(("\n",)) else ""
        body = f"{key}:{nl}" + nl.join(out) + tail
        fm = fm[:m2.start()] + body + fm[m2.end():]

    block("participants", names)
    block("tags", tagmap)
    fm = fm.rstrip("\r\n")
    new = text[:m.start(1)] + fm + text[m.end(1):]
    if new == text:
        return False
    with open(md_path, "w", encoding="utf-8", newline="") as fh:
        fh.write(new)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--aliases", default=os.path.join(HERE, "participants-aliases.csv"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    names, tagmap = load_aliases(args.aliases)
    changed = 0
    skipped = []
    for jf in glob.glob(os.path.join(CONTENT, "**", "*.json"), recursive=True):
        try:
            with open(jf, encoding="utf-8", newline="") as fh:
                raw = fh.read()
            d = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        parts = d.get("participants") or []
        tags = d.get("tags") or []
        if not isinstance(parts, list) or not isinstance(tags, list):
            continue
        new_parts = fix_list(parts, names)
        new_tags = fix_list(tags, tagmap)
        if new_parts == parts and new_tags == tags:
            continue
        rel = os.path.relpath(jf, CONTENT)
        fmt = detect_format(raw, d)
        if fmt is None:
            skipped.append(rel)  # formatação fora do padrão: não regravar às cegas
            continue
        changed += 1
        if args.dry_run:
            diff = [f"{a} -> {b}" for a, b in zip(parts, [names.get(x, x) for x in parts]) if a != b]
            print(f"{rel}: {'; '.join(diff) or 'tags'}")
            continue
        d["participants"], d["tags"] = new_parts, new_tags
        ea, nl = fmt
        with open(jf, "w", encoding="utf-8", newline="") as fh:
            fh.write(json.dumps(d, ensure_ascii=ea, indent=2) + nl)
        md = jf[:-5] + ".md"
        if os.path.exists(md):
            patch_md(md, names, tagmap)

    print(f"\n{changed} episódios {'seriam ' if args.dry_run else ''}alterados")
    for s in skipped:
        print(f"PULADO (formato JSON não reconhecido, corrigir à mão): {s}")


if __name__ == "__main__":
    sys.exit(main())
