"""Agrupa grafias diferentes do mesmo participante nos JSON do vox-content.

Uso:
    python scripts/participants_normalize.py                  # variantes de grafia
    python scripts/participants_normalize.py --min-podcasts 3 # pessoas em >=3 podcasts
    python scripts/participants_normalize.py --csv out.csv    # exporta tudo

Normalização: sem acento, minúsculo, sem pontuação/títulos (Dr., Prof.).
Agrupamento: chave idêntica, ou mesmo primeiro nome + similaridade >= --threshold
(pega "Thomas Trauman" x "Thomas Traumann"). Grupos fuzzy saem marcados com ~
para revisão manual.
"""
import argparse
import csv
import glob
import json
import os
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from difflib import SequenceMatcher

CONTENT = os.environ.get("VOX_CONTENT", r"E:\vox-content")
TITLES = {"dr", "dra", "prof", "profa", "sr", "sra", "mr", "mrs", "ms", "dr.", "phd"}


def norm(name: str) -> str:
    s = unicodedata.normalize("NFKD", name)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = re.sub(r"[^a-z0-9 ]+", " ", s)
    return " ".join(t for t in s.split() if t not in TITLES)


class DSU:
    def __init__(self):
        self.p = {}

    def find(self, x):
        self.p.setdefault(x, x)
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a, b):
        self.p[self.find(a)] = self.find(b)


def load():
    spellings = Counter()            # grafia original -> nº de episódios
    podcasts = defaultdict(set)      # chave normalizada -> podcasts
    episodes = defaultdict(int)      # chave normalizada -> nº de episódios
    by_key = defaultdict(Counter)    # chave -> grafias
    for f in glob.glob(os.path.join(CONTENT, "**", "*.json"), recursive=True):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        parts = d.get("participants") or []
        pod = (d.get("metadata") or {}).get("podcast") or "?"
        for p in {p.strip() for p in parts if isinstance(p, str) and p.strip()}:
            k = norm(p)
            if not k:
                continue
            spellings[p] += 1
            by_key[k][p] += 1
            podcasts[k].add(pod)
            episodes[k] += 1
    return by_key, podcasts, episodes


def cluster(keys, threshold):
    dsu = DSU()
    fuzzy = set()
    blocks = defaultdict(list)
    for k in keys:
        dsu.find(k)
        blocks[k.split()[0]].append(k)
    for block in blocks.values():
        for i, a in enumerate(block):
            for b in block[i + 1:]:
                if len(a.split()) < 2 or len(b.split()) < 2:
                    continue  # só primeiro nome é ambíguo demais
                if SequenceMatcher(None, a, b).ratio() >= threshold:
                    dsu.union(a, b)
                    fuzzy.add(a)
                    fuzzy.add(b)
    groups = defaultdict(list)
    for k in keys:
        groups[dsu.find(k)].append(k)
    return groups.values(), fuzzy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--threshold", type=float, default=0.9)
    ap.add_argument("--min-podcasts", type=int, default=0,
                    help="lista pessoas presentes em >= N podcasts distintos")
    ap.add_argument("--csv", help="exporta todos os grupos para CSV")
    args = ap.parse_args()

    by_key, podcasts, episodes = load()
    groups, fuzzy = cluster(list(by_key), args.threshold)

    rows = []
    for g in groups:
        spell = Counter()
        pods = set()
        for k in g:
            spell.update(by_key[k])
            pods |= podcasts[k]
        rows.append({
            "canonical": spell.most_common(1)[0][0],
            "variants": [s for s, _ in spell.most_common()],
            "episodes": sum(episodes[k] for k in g),
            "podcasts": sorted(pods),
            "fuzzy": any(k in fuzzy for k in g),
        })

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["canonical", "variants", "episodes", "n_podcasts", "podcasts", "fuzzy"])
            for r in sorted(rows, key=lambda r: -r["episodes"]):
                w.writerow([r["canonical"], " | ".join(r["variants"]), r["episodes"],
                            len(r["podcasts"]), " | ".join(r["podcasts"]), r["fuzzy"]])
        print(f"CSV: {args.csv} ({len(rows)} pessoas)")
        return

    if args.min_podcasts:
        # nome de uma palavra só ("Rafael", "Host") junta pessoas diferentes
        sel = [r for r in rows if len(r["podcasts"]) >= args.min_podcasts
               and len(norm(r["canonical"]).split()) > 1]
        sel.sort(key=lambda r: (-len(r["podcasts"]), -r["episodes"]))
        for r in sel:
            alt = f"  [{' | '.join(r['variants'][1:])}]" if len(r["variants"]) > 1 else ""
            print(f"{len(r['podcasts']):>3} pods {r['episodes']:>4} eps  {r['canonical']}{alt}")
            print(f"           {', '.join(r['podcasts'])}")
        print(f"\n{len(sel)} pessoas em >= {args.min_podcasts} podcasts")
        return

    sel = [r for r in rows if len(r["variants"]) > 1]
    sel.sort(key=lambda r: -r["episodes"])
    for r in sel:
        mark = "~" if r["fuzzy"] else " "
        print(f"{mark} {r['canonical']}  <-  {' | '.join(r['variants'][1:])}  ({r['episodes']} eps)")
    print(f"\n{len(sel)} pessoas com mais de uma grafia (~ = agrupado por similaridade, revisar)")


if __name__ == "__main__":
    sys.exit(main())
