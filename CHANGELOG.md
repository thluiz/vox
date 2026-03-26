# Changelog

All notable changes to the **Vox** project are documented in this file.

Vox is a digital garden built on [Quartz v4](https://quartz.jzhao.xyz/) for
publishing podcast transcriptions and annotations. It was created to give
listeners a searchable, browsable archive of episode content with automatic
tag clouds, OG images, and an explorer sidebar organised by year/week.

---

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
