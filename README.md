# Vox

Infrastructure for my personal digital garden — a public, interconnected collection of notes,
ideas, and podcast annotations built with [Quartz v4](https://quartz.jzhao.xyz/).

## What is a Digital Garden?

A digital garden is a continuously growing and evolving collection of notes — somewhere between
a blog and a wiki. Unlike a blog, posts are not finished articles published at a specific time;
they are living notes that get updated, linked to other notes, and refined over time.

This garden follows loosely the [Zettelkasten](https://zettelkasten.de/) method: each note is
atomic (focused on a single idea), linked to related notes through [[wikilinks]], and tagged to
enable lateral discovery. The result is a network of ideas rather than a linear archive.

## What's in this repo

This repository contains the **publishing infrastructure** for the garden:

| File | Purpose |
|------|---------|
| `quartz.config.ts` | Quartz site configuration (title, plugins, graph, backlinks) |
| `quartz.layout.ts` | Page layout components |
| `custom.scss` | Custom styles |
| `install-vox.sh` | One-time setup: clones Quartz, creates symlinks, registers `vox-publish` in PATH |
| `vox-publish.sh` | Build + deploy pipeline (Quartz build → Azure Static Web Apps) |
| `patches/` | Quartz monkey-patches applied at build time (see below) |
| `.env.example` | Environment variable template (copy to `.env`, fill with real values) |

The content (actual notes) lives in a separate repository: [vox-content](https://github.com/thluiz/vox-content).

## Quartz patches

Quartz is used as-is from upstream — we don't maintain a fork. Instead, small adjustments
live as `.patch` files in `patches/` and are applied automatically by `vox-publish.sh`
before each build.

**Why patches instead of a fork?**

- The changes are cosmetic and site-specific (OG image format, meta tags, layout tweaks) —
  not things that would be accepted as upstream PRs.
- Maintaining a fork requires regular rebasing against upstream, which is disproportionate
  overhead for a handful of one-line changes.
- `git apply` is atomic: a patch either applies cleanly or fails entirely, so a Quartz
  update will never produce a silently broken build. If upstream changes the same lines,
  the build aborts and the patch can be regenerated in minutes.
- Patches are self-documenting (readable diffs) and trivially reproducible.

| Patch | What it does |
|-------|-------------|
| `ogImage.patch` | OG images as PNG instead of WebP (WhatsApp/Meta compatibility), adds `og:image:secure_url`, fixes mime type detection, reorders meta tags per OG spec |
| `Head.patch` | Adds `fb:app_id` meta tag and `noindex, nofollow` for staging control |
| `ContentMeta.patch` | Language flags (BR/US) in post metadata based on frontmatter `lang` field |
| `contentMeta-scss.patch` | Styling for the language flag badges (alignment, border, spacing) |

The publish script applies patches before building and cleans up after, so the local
Quartz checkout stays in sync with upstream and can be updated with a simple `git pull`.


## Setup

```bash
# 1. Clone this repo on your build machine
git clone https://github.com/thluiz/vox.git ~/vox

# 2. Copy and fill the environment file (never commit .env)
cp ~/vox/.env.example ~/vox/.env
nano ~/vox/.env

# 3. Run the installer
bash ~/vox/install-vox.sh

# 4. Publish
vox-publish
```

## Requirements

- Node.js 22+ and npm
- `swa` CLI: `npm install -g @azure/static-web-apps-cli`
- Azure Static Web Apps resource + deployment token
- Git

> **Note on authentication**: HermesTools only reads from GitHub (public repos via HTTPS).
> No SSH key or GitHub token needed on the build machine for `vox`. Content (`vox-content`)
> uses a deploy key for push access.

## License

Content is © the author. Infrastructure scripts are MIT.
