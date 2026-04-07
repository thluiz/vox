# Changelog

All notable changes to the **Vox** project are documented in this file.

Vox is a digital garden for publishing podcast transcriptions and annotations.
It provides a searchable, browsable archive of episode content with tag clouds,
and an explorer sidebar organised by year/week.

---

## v2.0.2 — 2026-04-07 — WebP OG images

- OG images switched from PNG to WebP — 63% smaller (~30KB vs ~80KB)
- `vox-publish-windows.ps1`: incremental path detection now looks for `og.webp`
  instead of `og.png` (the stale `og.png` check caused 70 newly-generated OG
  images to be skipped during incremental publishes; all backfilled to S3)
- `hugo.toml`: `disablePathToLower = true` to preserve case in generated URLs

## v2.0.1 — 2026-04-05 — OG image tuning

- OG image description font increased to 36px, up to 350 chars
- OG image title font increased to 50px, full title (truncate at 120 chars)
- OG image footer font increased to 26px

## v2.0.0 — 2026-04-05 — Hugo + Hextra Migration

### Engine migration: Quartz v4 → Hugo + Hextra

**Why**: Quartz v4 rebuilt the entire site on every build (1681 episodes). Hugo has
native incremental builds and is orders of magnitude faster (~25s full build vs minutes).

**Theme**: [Hextra](https://github.com/imfing/hextra) (Tailwind CSS, FlexSearch, dark mode).

### What changed

- **`hugo.toml`**: Full Hugo config with module mounts (content from `E:\vox-content`,
  excludes Obsidian `index.md`), `disableAliases = true` for Obsidian alias compatibility
- **Content symlink replaced by module mounts**: `content-home/_index.md` provides the
  Hugo-compatible home page; vox-content mounted as secondary content source
- **Custom sidebar** (`layouts/_partials/sidebar.html`): Year → week navigation with
  episode counts, skipping month level, weeks link to year page `#anchors`
- **Typography** (`assets/css/custom.css`): Source Sans Pro (body), Schibsted Grotesk
  (headers), IBM Plex Mono (code), Quartz color palette (`#4e4e4e` darkgray text),
  Tailwind CSS variable overrides for compact density
- **Episode layout** (`layouts/docs/single.html`): Flag (BR/US), date, reading time,
  word count, tag badges, then title and content
- **Render hooks**: `render-heading.html` suppresses duplicate H1 (frontmatter title
  vs markdown `# Title`); `render-link.html` fixes relative JSON data links
- **Section list pages** (`layouts/docs/list.html`): Episodes grouped by week with
  metadata (flag, date, reading time); home page shows curated top 10 tags +
  recent publications + about text
- **Tag taxonomy** (`layouts/docs/taxonomy.html`, `term.html`): Tag cloud sorted by
  count; individual tag pages with episode metadata
- **`serve-local.ps1`**: Adapted for Hugo (applies/reverts patches to Hextra theme)

### Compatibility

- **Zero changes to vox-content**: All modifications are in the Hugo project
  (worktree `E:\Vox-Hugo`, branch `vox-hugo`). Quartz continues to work from `main`.
- **Obsidian aliases**: `disableAliases = true` prevents Hugo from creating redirect
  pages for Obsidian wikilink aliases in frontmatter
- **`lang` frontmatter**: Deprecated in Hugo v0.144 but still accessible as
  `.Params.lang` — used for BR/US flag display

### Not yet migrated (future phases)

- Graph view + backlinks (D3.js/AntV G6)
- OG images, `fb:app_id`, `noindex` meta tags
- Custom tag filtering (`hideTags`, `minEntries`)
- Wikilinks `[[...]]` rendering

---

## 2026-04-05

### Scripts e infra

- **`vox-publish-windows.ps1`**: fix fnm PATH para scheduled tasks + fix deleções só em full scan (incremental não tem visão completa do `public/`)
- **`vox-suggest-annotations.ps1`**: migrado para pool explícito via `need-annotation.json` (em vez de scan global); cleanup automático de episódios já anotados; notificação Telegram do pool restante
- **`serve-local.ps1`**: novo script para servir Quartz localmente com patches aplicados (porta 8085)
- **`.gitignore`**: adicionado `vox-suggest-annotations.log`

### Conteúdo

- **`render-from-json.py`** (HermesTools): transcript removido do MD; link "Dados adicionais e transcrição" no rodapé apontando para o JSON
- Re-render de todos os 1681 episódios (MDs sem transcript, -4.4M linhas)
- Fix alias com `/` no episódio Part 2 An Elegant Puzzle (causava ENOENT no Windows)

## 2026-04-04

### Patches — auditoria e alterações

| Patch | Ficheiro alvo | Antes | Agora |
|---|---|---|---|
| **ContentMeta.patch** | `ContentMeta.tsx` + `contentMeta.scss` | Bandeiras BR/US ao lado da data conforme `lang` no frontmatter | Sem alteração |
| **contentMeta-scss.patch** | `contentMeta.scss` | Estilos para bandeiras (`.lang-flag-wrap`, `.lang-flag`) | Sem alteração |
| **FolderContent.patch** | `FolderContent.tsx` | Páginas de ano/mês listam artigos recursivamente (não só filhos directos) | Sem alteração |
| **Head.patch** | `Head.tsx` | `noindex`/`nofollow`, `og:site_name` como `property`, `fb:app_id` | Sem alteração |
| **ogImage.patch** | `ogImage.tsx` | OG images em PNG (não WebP), ordem correcta dos meta tags, fix `getFileExtension` | Sem alteração |
| **tagPage.patch** | `tagPage.tsx` | Passa `hideTags`/`minEntries` para `TagContent`, filtra tags com < N entries no emitter | Sem alteração |
| **TagContent.patch** | `TagContent.tsx` | `hideTags` + `minEntries` filtro; página index mostrava `<h2>` + `<PageList>` (10 posts por tag) | **Index compacto**: só nome da tag + contagem com link, sem listar posts (reduziu `/tags/index.html` de 31MB para ~poucos KB) |
| **graph.patch** | `graph.inline.ts` | `excludedSlugs` via `removeTags` (filtra nós do graph por tag) | **+ Skip graph no mobile/tablet** (`window.innerWidth < 1024` → return imediato, zero processamento d3/pixi/fetch) |

### Outras alterações

- **`render-from-json.py`** (HermesTools): transcript removido do MD renderizado — reduz peso das páginas de episódio
- **Skill `slice-podcast`** criada: corte de trechos de áudio de episódios com ffmpeg

## 2026-03-26

- Flatten explorer hierarchy: weeks are promoted directly under year nodes
  (removing the intermediate month level) and display an episode count
- Hide collapse arrow and empty container on leaf folders via CSS
- Add `vox-suggest-annotations.ps1` script for AI-assisted annotation suggestions
- Gitignore `.claude/settings.local.json`

## 2026-03-18

- Miscellaneous fixes

## 2026-03-08

- Migrate deploy pipeline from Azure Blob Storage to **AWS S3 + CloudFront**
- Remove tag-page entry limits; re-enable OG image generation (no longer
  constrained by Azure SWA 250 MB limit)
- Add Azure Blob Storage deploy pipeline (superseded by AWS migration)

## 2026-03-05 – 2026-03-06

- Add `FolderContent.patch` for recursive year/month listing in the explorer
- Filter tag pages to only show tags with 2+ entries (reduce deploy size)
- Exclude specific tags (`developer-tea`) from tag cloud, tag index, and graph
- Exclude tagged content nodes from graph when `removeTags` is set
- Disable `CustomOgImages` temporarily to fit Azure SWA 250 MB limit
- Fix: revert patches before re-applying to handle partial-run recovery
- Fix: always push `vox-content` submodule after deploy

## 2026-02-25

- Fix `og:site_name` meta tag: use `property` attribute instead of `name`
- Remove and then revert `noindex` meta tag change (needed for Telegram/Facebook
  link previews)

## 2026-02-23 – 2026-02-24

- Enable dynamic OG images via `CustomOgImages` plugin (dark mode)
- Introduce Quartz patch system for maintainable source modifications
- Improve explorer sidebar readability and UX (styling, indentation)
- Ignore `README.md` in Quartz build (was leaking into RSS feed)
- Open external links in new tab with `noopener noreferrer`; later removed in
  favour of browser defaults
- Fix wikilink parser: sanitise pipe (`|`) and hash (`#`) in display text

## 2026-02-22 — Initial release

- Quartz v4 configuration, layout, and custom SCSS for the Vox digital garden
- Deploy and build scripts
- `fix-transcription.py`: insert blank lines between timestamp segments
- Fix `fnm` PATH for non-interactive shells
- Fix `esbuild` symlink issue: copy config files instead of symlinking
- Restore `@use base.scss` import in `custom.scss` (was missing layout CSS)
- Show Explorer on mobile (remove `DesktopOnly` wrapper)
