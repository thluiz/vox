# Changelog

All notable changes to the **Vox** project are documented in this file.

Vox is a digital garden for publishing podcast transcriptions and annotations.
It provides a searchable, browsable archive of episode content with tag clouds,
and an explorer sidebar organised by year/week.

---

## v2.2.0 — 2026-04-25 — Playwright test suite & onboarding doc

### What changed

A regression suite covering the transcript feature, the i18n label
swap, and a console-error gate against the Hextra integration quirks
that surfaced during v2.1.0. The suite is the safety net for future
Hextra theme upgrades — if any of the patched quirks regress, the
console spec fails immediately.

- **`tests/`** (3 specs, 8 cases, ~3.4 s parallel)
  - `transcript.spec.ts` — TOC built from `timeline[]`, lazy
    `<details>` render (lines absent before click, present after,
    no duplication on close+reopen), footer "Ler transcrição" link,
    error message when `?json=` missing
  - `i18n.spec.ts` — PT episode keeps Portuguese labels; EN episode
    swaps to English (`Topics`, `back to episode`, `Tap a topic`);
    `<html lang>` updated to match `data.lang`
  - `console.spec.ts` — zero `console.error`, `pageerror`, or HTTP
    4xx/5xx on `/transcript/?json=...` and on a normal episode page
- **`package.json` + `playwright.config.ts`** — `npm test`,
  `baseURL` parameterized via `VOX_TEST_BASE_URL` (default
  `http://localhost:1313`, override to hit prod)
- **`CLAUDE.md`** at repo root — project layout, dev/build/publish/
  test workflows, and the catalog of Hextra quirks needing
  overrides (`flexsearch.js` destructure crash, `menu.js` sidebar
  null-check, mobile-sidebar limitation). Auto-loaded by future
  Claude Code sessions so the discoveries don't have to be redone.

### Why a custom config instead of the Playwright MCP

The `mcp__plugin_autoimplement_playwright-test__*` tools enforce
their own seed/project shape and don't read a project's local
`playwright.config.ts` — "Project chromium not found" / "seed test
not found" even with valid local definitions. `npx playwright test`
against the local config worked first try.

### Operating notes

- `node_modules/`, `test-results/`, `playwright-report/` ignored;
  `package-lock.json` and the config tracked
- Tests need an HTTP target — either a local `hugo server` on
  `1313` or `VOX_TEST_BASE_URL` pointing at production. They do
  not start a server themselves
- The console spec is intentionally strict (`expect(errs).toEqual([])`)
  — any new noise fails loudly, including 404s on missing assets,
  which is the canary that caught the v2.0.4 CSS-hash bug pattern

## v2.1.0 — 2026-04-25 — Reader-friendly transcript page

### What changed

A new standalone reader at `/transcript/?json=<sidecar-path>` so
visitors (especially on older mobile devices that struggled to
render the full transcript inline on the episode page) can read
episode transcripts paginated by topic, with lazy DOM insertion.

- **`/transcript/` page** — single Hugo branch bundle
  (`content-home/transcript/_index.md` + `layouts/transcript/list.html`)
  rendered through Hextra's `baseof` so it shares the site chrome.
  Frontmatter:
  - `type: transcript` — escapes Hextra's `docs` cascade so the
    custom layout is picked up
  - `_build.list: never` — keeps "Transcrição (0)" out of every
    other page's sidebar tree
  - `sidebar.hide: true` — renders an empty `<aside>` so Hextra's
    `menu.js` doesn't crash (see "Console-error fixes" below)
- **`static/js/transcript.js`** — vanilla JS (no framework, no
  build step). Reads `?json=` from `location.search`, fetches the
  episode JSON sidecar, parses transcript lines (`[HH:MM:SS] text`
  format), and segments them by `timeline[]` (one `<details>` per
  topic, with the timeline `summary` as a topic blurb). Lines are
  rendered into the DOM only when the user opens the topic; reopen
  is idempotent. Handles a synthetic "Introdução" section for
  pre-timeline lines and falls back to 5-minute blocks if a
  transcript has no timeline. `<html lang>` and all UI labels
  (back, topics heading, help, intro section name, errors) swap
  between PT/EN based on the JSON's `lang` field
- **`layouts/_partials/custom/episode-footer.html`** — added a
  conditional "Ler transcrição" / "Read transcript" link next to
  the existing "Dados adicionais e transcrição (JSON)" technical
  link, only when the sidecar has a non-empty `transcript` field
- **`assets/css/custom.css`** — mobile-first styles for the
  transcript page (collapsed `<details>` with timestamp + topic
  title, italic summary, monospaced inline timestamps that drop
  to a separate line below 560 px viewports)

### "Arquivo" navigation menu

The Hextra mobile sidebar (`_partials/sidebar.html:31`) renders
`site.Menus.main` only — not the `RegularPages`/`Sections` tree
the desktop sidebar uses. With Vox's main menu being just "Tags",
the year/week navigation present on desktop was completely
unreachable on mobile.

- **`hugo.toml`** — added a top-level `Arquivo` menu entry
  (`identifier = "archive"`) plus one child per year (2010-2026)
  with `parent = "archive"`. Renders as a navbar dropdown on
  desktop and as an expanded list inside the mobile hamburger.
  Maintenance: one new entry per year going forward

### Console-error fixes (Hextra integration)

While testing the new page, two pre-existing Hextra crashes
surfaced because the page legitimately doesn't render every
DOM scaffold the theme's bundled JS assumes:

- **`flexsearch.js`** destructures
  `getActiveSearchElement(...)` without a null-check;
  `getActiveSearchElement` returns `undefined` when 0 or >1
  `.hextra-search-wrapper` elements are visible.
  **Fix:** `layouts/_partials/scripts/search.html` overrides the
  theme partial and skips loading `flexsearch.js` when the page
  has `excludeSearch: true` in frontmatter
- **`core/menu.js:13`** (`syncAriaHidden`) calls
  `sidebarContainer.removeAttribute(...)` without checking if the
  element exists.
  **Fix:** the transcript layout calls
  `partial "sidebar.html" (dict "context" . "disableSidebar" true)`
  to render the `<aside>` (empty) the JS expects

Both are upstream bugs; the workarounds are scoped to opted-out
pages so the rest of the site is untouched.

### Publish script change

- **`vox-publish-windows.ps1`** — added `transcript` to the
  incremental-mode asset whitelist (joining `css`, `js`, `images`,
  `scripts` from v2.0.4) so the standalone `/transcript/index.html`
  is hashed and re-uploaded on layout edits without needing
  `-ForceFullSync`

## v2.0.4 — 2026-04-08 — Publish script: static asset re-check

### The bug

`vox-publish-windows.ps1`'s incremental mode builds its upload list
exclusively from `Get-HtmlPathsToCheck`, which walks the `vox-content`
git diff and maps each changed `.md`/`.json` to its derived HTML
outputs (episode page, parent year/month/week indexes, tag pages, OG
image, sibling JSON sidecar). This is great for content churn but
completely ignores anything in `public/` that is **not** derived from
a content file — in particular Hugo's compiled assets under
`public/css/`, `public/js/`, theme images, favicons, and root-level
generated files (`index.html`, `sitemap.xml`, `site.webmanifest`,
`404.html`).

The v2.0.3 footer partial added new rules to `assets/css/custom.css`,
which changed the compiled CSS hash from
`main.min.fbf9cea32b9a4737e078baf68235e08723d14e9aee3220628540e2ad32847183.css`
to
`main.min.78adf0a14183bab58a60d985d4d9454b520c08128783e09f8aba2b675ebee14a.css`.
The regenerated episode HTMLs referenced the new hash and were
uploaded correctly (11 869 files), but the CSS file itself was never
hashed, never compared against the manifest, and never uploaded.
Every episode page on the live site 404'd on the stylesheet until the
CSS was pushed manually.

### The fix

- **`vox-publish-windows.ps1`** — after the episode-derived upload
  list is built, the incremental path now walks a small whitelist of
  static-asset directories (`css`, `js`, `images`, `scripts`) plus a
  fixed list of root files (`robots.txt`, `404.html`, `index.html`,
  `index.xml`, `sitemap.xml`, `site.webmanifest`, all the favicons
  and touch icons) and hashes them in parallel. Hashes are compared
  against the manifest exactly like the content files, so unchanged
  assets are skipped, but any file with a different hash (or an
  entirely new content-hashed filename, as with the Hextra-compiled
  CSS/JS) is added to `$toUpload`. The additional scan is <300 KB
  of data and completes in well under a second.
- The fix applies **only** to incremental mode. Full-scan mode already
  covers these files because it hashes everything under `public/`.

### Why not just force a full sync?

Full scan re-hashes ~16 000 files and re-checks every one against
S3, which is significantly slower and uploads the full delta even
when nothing changed. The incremental approach is worth preserving
for its speed — the whitelist fix patches the one class of files it
was missing, without sacrificing incrementality.

## v2.0.3 — 2026-04-07 — Episode footer & metadata migration

### What changed

- **New partial `layouts/_partials/custom/episode-footer.html`** — rendered
  on every episode page (`{{ if .IsPage }}` guard in
  `layouts/docs/single.html` and `layouts/_default/single.html`). Reads
  the sibling `<slug>.json` sidecar at build time via `os.ReadFile` +
  `transform.Unmarshal` (wrapped in `try` for non-episode pages) and
  surfaces:
  - **Episode identity**: podcast (linked to `metadata.podcast_site`
    when present, larger `1rem` font), author, podcast categories
    (linked to their respective `/tags/{slug}/` pages, joined with `›`),
    podcast type (`episodic` / `serial`)
  - **Aliases** (`Also known as` / `Também conhecido como`)
  - **Participants**: each name linked to its `/tags/{slug}/` page,
    followed by an italic bilingual disclaimer noting the names were
    obtained from audio (with a 🙈 emoji because spelling may be off)
  - **Technical line**: JSON sidecar link (URL reconstructed from the
    page `.RelPermalink`, no resource lookup or path hack needed),
    UUID code chip
  - **Publication line**: `Publicado em <date>` followed by
    `PocketCasts — <full source URL>` on a second line, both linked
  - **Legal disclaimer** (PT/EN, 4 paragraphs separated by a divider):
    content belongs to original creators, Vox is a non-profit aggregator,
    Vox compilation layer (annotations / metadata / curation) released
    under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/),
    contact via GitHub issues for takedown
  - **Back to top** anchor pointing at `#content` (the existing main
    wrapper id, no new anchor needed)
- **`assets/css/custom.css`** — `.vox-episode-footer` styles + dark mode
  variants (~30 lines), bordered separator before legal block, dashed
  separator before tech line, `word-break: break-all` on the source URL
  to keep long PocketCasts URLs from overflowing narrow viewports
- **`layouts/_markup/render-link.html`** — removed the year-pattern hack
  (`findRE \^\d{4}/`) that prepended `/` to relative content paths.
  This existed solely to coerce the legacy hardcoded
  `[Dados adicionais e transcrição](slug.json)` link to resolve correctly,
  and is no longer needed now that the link is gone from content (see
  Toscanini v0.2.2 + the bulk MD cleanup below). The render hook now
  has no special-case path manipulation.

### Companion changes (other repos)

This release is paired with two coordinated commits in sibling repos:

- **`hermes-tools/services/toscanini` v0.2.2** (commit `0e83c59`) —
  removed `render_metadata/3` and `render_json_footer/2` from
  `VoxPocketcastJsonRenderer`, plus the now-unused `add/2` helper. New
  episodes are emitted clean from this point onward. Includes 20 ExUnit
  tests covering the renderer (PT + EN fixtures, transcript stripped)
  and a fix to `config/test.exs` (`pool: Ecto.Adapters.SQL.Sandbox`)
  that unblocks the entire test suite.
- **`vox-content`** (commit `b8268db`) — one-shot historical cleanup of
  1860 episode markdown files. Removes `## Dados do Episódio`,
  `## Dados do Podcast`, `## Episode Info`, `## Podcast Info` blocks +
  the standalone `[Dados adicionais e transcrição](*.json)` /
  `[Additional data and transcript](*.json)` line. 54 859 deletions, 0
  insertions. Editorial sections under `## Indicações` /
  `## Recommendations` are preserved, including the editorial
  `### Referencias-Culturais` / `### Referencias` subsections that exist
  in 3 outlier episodes (verified during phase planning). Generated by
  `E:\vox\phase2-strip-metadata-sections.py --apply`, log at
  `E:\vox\logs\phase2-strip-2026-04-07T222904.log`.

### Why

The four metadata h2 blocks were emitted into every episode markdown by
the Toscanini renderer. That meant (a) every published episode carried
the same boilerplate metadata in content form, (b) any change to the
presentation required bulk-rewriting thousands of markdown files, and
(c) the JSON pointer link relied on a path-resolution workaround in
`render-link.html` because Hugo's link rendering couldn't natively
resolve `[x](slug.json)` from inside an episode page bundle's mounted
year directory. Moving metadata to a Hugo template:

- eliminates content/template duplication across the archive,
- centralises presentation tweaks in one partial,
- reads the JSON sidecar resource at build time (single source of truth),
- removes the need for the `^\d{4}/` path coercion in
  `render-link.html`,
- keeps content files purely editorial.

The renderer change had to land *before* the bulk cleanup, otherwise
new episodes would have continued regenerating the removed sections
forever — see the project memory note about Toscanini's
`render-from-json` lifecycle for the rationale.

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
