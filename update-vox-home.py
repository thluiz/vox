#!/usr/bin/env python3
"""update-vox-home.py — atualiza index.md com publicações recentes e top tags"""

import re
import sys
from collections import Counter
from pathlib import Path

CONTENT_DIR = Path("/home/hermes/vox-content")
INDEX_MD    = CONTENT_DIR / "index.md"
N_RECENT    = 10
N_TOP_TAGS  = 10

YEAR_DIR_RE = re.compile(r"^\d{4}$")


def parse_frontmatter(text):
    """Retorna (frontmatter_dict_raw_str_map, body_after_closing_fence).
    frontmatter_dict_raw_str_map: dict with raw string values (unparsed)."""
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    fm_block = text[3:end]          # conteúdo entre --- e ---
    body     = text[end + 4:]       # tudo depois do --- de fechamento

    # Extrai campos simples (scalar) e bloco tags
    result = {}
    result["_raw"] = fm_block

    # published (pode ter ou não aspas: published: 2025-05-28 ou published: "2025-05-28")
    m = re.search(r'^published:\s*"?(\d{4}-\d{2}-\d{2})"?\s*$', fm_block, re.MULTILINE)
    if m:
        result["published"] = m.group(1)

    # title (pode ter aspas)
    m = re.search(r'^title:\s*"?(.+?)"?\s*$', fm_block, re.MULTILINE)
    if m:
        result["title"] = m.group(1).strip().strip('"')

    # tags: só as que estão sob "tags:" (não aliases, participants, etc.)
    tags_match = re.search(r"^tags:\n((?:\s+-\s+.+\n?)+)", fm_block, re.MULTILINE)
    if tags_match:
        result["tags"] = re.findall(r"^\s+-\s+(.+)$", tags_match.group(1), re.MULTILINE)
    else:
        result["tags"] = []

    # participants: lista sob "participants:"
    participants_match = re.search(r"^participants:\n((?:\s+-\s+.+\n?)+)", fm_block, re.MULTILINE)
    if participants_match:
        result["participants"] = re.findall(r"^\s+-\s+\"?(.+?)\"?\s*$", participants_match.group(1), re.MULTILINE)
    else:
        result["participants"] = []

    # podcast: campo simples
    m = re.search(r'^podcast:\s*"?(.+?)"?\s*$', fm_block, re.MULTILINE)
    result["podcast"] = m.group(1).strip() if m else None

    return result, body


def name_to_kebab(name):
    """'Gregório Duvivier' → 'gregorio-duvivier'"""
    import unicodedata
    nfkd = unicodedata.normalize("NFKD", name)
    ascii_str = nfkd.encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "-", ascii_str.lower()).strip("-")


def collect_posts():
    posts = []
    tag_counter = Counter()
    excluded_tags = set()  # participantes + nomes de podcasts em kebab-case

    for year_dir in sorted(CONTENT_DIR.iterdir()):
        if not year_dir.is_dir() or not YEAR_DIR_RE.match(year_dir.name):
            continue
        for md_file in sorted(year_dir.glob("*.md")):
            text = md_file.read_text(encoding="utf-8")
            fm, _ = parse_frontmatter(text)
            if not fm.get("published"):
                continue  # draft / sem data

            link_path = f"{year_dir.name}/{md_file.stem}"
            title     = fm.get("title", md_file.stem)
            published = fm["published"]

            posts.append({
                "link":      link_path,
                "title":     title,
                "published": published,
            })

            for tag in fm.get("tags", []):
                tag_counter[tag] += 1

            for name in fm.get("participants", []):
                excluded_tags.add(name_to_kebab(name))

            if fm.get("podcast"):
                excluded_tags.add(name_to_kebab(fm["podcast"]))

    posts.sort(key=lambda p: p["published"], reverse=True)
    return posts, tag_counter, excluded_tags


def display_title(title: str) -> str:
    """Remove episode number prefix (#82, #447, etc.) from title for display."""
    return re.sub(r"^#\d+\s+", "", title).strip()


def build_recent_section(recent_posts):
    lines = ["## Publicações Recentes", ""]
    for p in recent_posts:
        lines.append(f"- [[{p['link']}|{display_title(p['title'])}]] — {p['published']}")
    lines.append("")
    return "\n".join(lines)


def update_index(recent_posts, top_tags):
    text = INDEX_MD.read_text(encoding="utf-8")

    # --- Atualiza frontmatter ---
    if text.startswith("---"):
        end_fence = text.find("\n---", 3)
        if end_fence != -1:
            fm_block = text[3:end_fence]
            after_fm  = text[end_fence + 4:]   # inclui newline depois do ---

            tags_yaml = "tags:\n" + "".join(f"  - {t}\n" for t in top_tags)

            # Substitui bloco tags existente ou insere antes do fechamento
            tags_section_re = re.compile(r"^tags:\n(?:\s+-\s+.+\n)*", re.MULTILINE)
            if tags_section_re.search(fm_block):
                fm_block = tags_section_re.sub(tags_yaml, fm_block)
            else:
                # Insere antes do último newline do fm_block
                fm_block = fm_block.rstrip("\n") + "\n" + tags_yaml

            text = "---" + fm_block + "\n---" + after_fm
    else:
        # Sem frontmatter: cria um
        tags_yaml = "tags:\n" + "".join(f"  - {t}\n" for t in top_tags)
        text = "---\n" + tags_yaml + "---\n\n" + text

    # --- Atualiza seção "Publicações Recentes" ---
    new_section = build_recent_section(recent_posts)

    # Só match na seção: título + linhas em branco + itens de lista (- ...)
    section_re = re.compile(
        r"^## Publicações Recentes\n(?:[ \t]*\n|- .+\n)*",
        re.MULTILINE,
    )

    # Remove a seção existente (onde quer que esteja)
    text = section_re.sub("", text)

    # Insere logo após o primeiro H1 (# Título) — no topo do corpo
    h1_re = re.compile(r"^(# .+\n)", re.MULTILINE)
    m = h1_re.search(text)
    if m:
        insert_pos = m.end()
        text = text[:insert_pos] + "\n" + new_section + "\n" + text[insert_pos:]
    else:
        # Sem H1: insere logo após o frontmatter
        after_fm = text.find("\n---\n")
        if after_fm != -1:
            insert_pos = after_fm + 5
            text = text[:insert_pos] + "\n" + new_section + "\n" + text[insert_pos:]
        else:
            text = new_section + "\n\n" + text

    INDEX_MD.write_text(text, encoding="utf-8")
    print(f"[update-vox-home] index.md atualizado — {len(recent_posts)} posts recentes, top tags: {top_tags}")


def main():
    if not CONTENT_DIR.exists():
        print(f"[update-vox-home] ERRO: CONTENT_DIR não existe: {CONTENT_DIR}", file=sys.stderr)
        sys.exit(1)
    if not INDEX_MD.exists():
        print(f"[update-vox-home] ERRO: index.md não encontrado em {INDEX_MD}", file=sys.stderr)
        sys.exit(1)

    posts, tag_counter, excluded_tags = collect_posts()

    if not posts:
        print("[update-vox-home] Nenhum post publicado encontrado — abortando.", file=sys.stderr)
        sys.exit(1)

    recent_posts = posts[:N_RECENT]
    top_tags = [
        tag for tag, _ in tag_counter.most_common(N_TOP_TAGS * 3)
        if tag not in excluded_tags
    ][:N_TOP_TAGS]

    print(f"[update-vox-home] {len(posts)} posts, {len(tag_counter)} tags únicas")
    print(f"[update-vox-home] Recentes: {[p['link'] for p in recent_posts]}")
    print(f"[update-vox-home] Top tags: {top_tags}")

    update_index(recent_posts, top_tags)


if __name__ == "__main__":
    main()
