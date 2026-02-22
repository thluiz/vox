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
| `.env.example` | Environment variable template (copy to `.env`, fill with real values) |

The content (actual notes) lives in a separate repository: [vox-content](https://github.com/thluiz/vox-content).

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
