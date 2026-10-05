# Vox — Onboarding para sessões futuras

Este é o **repo de infraestrutura** do site `vox.thluiz.com` — um digital garden /
arquivo de transcrições e anotações de podcasts. **O conteúdo (.md + .json)
vive em outro repo** (`E:/vox-content/`) e é montado via Hugo module mounts.

---

## Layout

| Caminho | O que é |
|---|---|
| `E:/vox/` (este repo) | Layouts, CSS, JS, scripts, config Hugo |
| `E:/vox-content/` (repo separado) | Conteúdo: `YYYY/MM/Wnn/<slug>.md` + `<slug>.json` por episódio |
| `E:/hextra/` | Tema Hextra (NÃO modificar — usado como upstream) |
| `content-home/` | Páginas próprias do Vox que sobrepõem `content/` (ex: `_index.md` da home, `transcript/`) |
| `layouts/` | Overrides de templates do Hextra. Os principais: `_partials/custom/episode-footer.html`, `transcript/list.html`, `_partials/scripts/search.html` |
| `assets/css/custom.css` | Estilos custom (concatenado pelo Hextra) |
| `static/` | Assets servidos as-is (`/js/transcript.js`, `robots.txt`) |
| `vox-publish-windows.ps1` | Pipeline build + deploy (S3 + CloudFront) |
| `tests/` | Suite Playwright (regressão dos features + quirks) |

`hugo.toml` define os mounts e o menu `[menu.main]`. **Cada ano novo precisa ser
adicionado manualmente** ao bloco `[[menu.main]]` com `parent = "archive"` para
aparecer no dropdown "Arquivo" (mobile e desktop).

---

## Dev local

```bash
hugo server -p 1313 --disableFastRender
```

> **Gotcha:** Hugo às vezes não detecta arquivos novos em subdiretórios novos
> de `layouts/_partials/`. Se ver erro `partial X not found` depois de criar
> uma subpasta nova, **reinicia o server**.

---

## Build e publish

```bash
pwsh -NoProfile -File vox-publish-windows.ps1                 # incremental (default)
pwsh -NoProfile -File vox-publish-windows.ps1 -ForceFullSync  # hash de todo o public/
pwsh -NoProfile -File vox-publish-windows.ps1 -S3Sync         # s3 sync --delete (drift)
```

O upload é **sempre por diferença**: SHA256 de cada arquivo do `public/`
comparado com `public-manifest.json`, e só o que mudou sobe via `aws s3 cp`
(paralelo). Nunca `s3 sync` por padrão — ele compara mtime, e o Hugo reescreve
o mtime de todo o `public/` a cada build, então reenviava ~4.5 GiB por publish.

**Modo incremental** (padrão) hasheia:
1. Arquivos derivados de mudanças em `vox-content` (via git diff)
2. Whitelist de assets estáticos: `css`, `js`, `images`, `scripts`, `transcript` + alguns root files (`index.html`, `sitemap.xml`, favicons…)

**Mudança de apresentação é detectada sozinha:** o script guarda um fingerprint
de `hugo.toml`, `layouts/`, `assets/`, `static/`, `content-home/`, `patches/`,
commit do Hextra e versão do Hugo (`last-published-presentation.txt`). Se mudou,
hasheia o `public/` inteiro e sobe só o que diferir — não precisa lembrar do
`-ForceFullSync` depois de mexer em layout/CSS/config.

**Quando usar `-ForceFullSync`:** `last-published-commit.txt` obsoleto, ou
suspeita de que o diff de conteúdo não pegou alguma página (ex: página de tag).
Continua sendo upload por diferença, só que hasheando tudo.

**Quando usar `-S3Sync`:** o S3 divergiu do manifest (alguém mexeu no bucket à
mão, upload interrompido antes de gravar o manifest). Reenvia o site inteiro.
Quirk: `aws s3 sync` pode retornar **exit 1 com Unicode em paths**
(ex: `tags/ética/`) — os arquivos sobem, mas o script aborta antes do
CloudFront invalidation; rerun ou invalidation manual.

---

## Testes

```bash
npm install
npx playwright install chromium  # uma vez
hugo server -p 1313 &            # outro terminal (ou Claude rodando em background)
npm test
```

Para rodar contra produção em vez de local:
```bash
VOX_TEST_BASE_URL=https://vox.thluiz.com npm test
```

3 specs em `tests/`:
- **`transcript.spec.ts`** — `/transcript/?json=...`: TOC montada do `timeline[]`, lazy render por `<details>` toggle, link no footer do episódio, erro se faltar `?json=`
- **`i18n.spec.ts`** — labels em PT (ep `lang: "pt"`) vs EN (ep `lang: "en"`)
- **`console.spec.ts`** — zero erros JS no console (cobre os quirks do Hextra abaixo — se algum reaparecer, este teste falha)

`fullyParallel: true`, ~3.4s no host. Não usar o MCP `mcp__plugin_autoimplement_playwright-test__*` — ele tem expectativas próprias de seed/projeto que não casam com este config; usar `npx playwright test` direto.

---

## Quirks do Hextra que tive que contornar

Quando atualizar o tema (`E:/hextra/`), **rodar `npm test` antes e depois** —
se os quirks abaixo voltarem, os overrides em `layouts/` são a primeira pista.

### 1. `flexsearch.js` crasha em página sem `.hextra-search-wrapper`

**Sintoma:** `TypeError: Cannot destructure property 'inputElement' of 'getActiveSearchElement(...)' as it is undefined`.
**Causa:** `getActiveSearchElement()` retorna `undefined` se 0 ou >1 wrappers
visíveis; chamadores fazem destructure sem null-check.
**Workaround:** `layouts/_partials/scripts/search.html` (override) pula o
bootstrap quando `.Params.excludeSearch == true`.

### 2. `menu.js` crasha em página sem `.hextra-sidebar-container`

**Sintoma:** `TypeError: Cannot read properties of null (reading 'removeAttribute')`.
**Causa:** `syncAriaHidden()` em `core/menu.js:13` faz `sidebarContainer.setAttribute(...)`
sem checar se existe.
**Workaround:** páginas custom (ex: `layouts/transcript/list.html`) precisam
chamar `partial "sidebar.html" (dict "context" . "disableSidebar" true)` para
renderizar o `<aside>` (vazio) que o JS espera.

### 3. Sidebar mobile do Hextra mostra só `site.Menus.main`, não a árvore de conteúdo

**Sintoma:** No mobile, hamburger abre quase vazio (só "Tags").
**Causa:** `_partials/sidebar.html:33` chama `sidebar-main` com `toc: true`,
o que ativa a branch `$useMainMenu` em `sidebar-tree`, iterando só
`site.Menus.main`. Desktop usa branch sem `toc`, iterando `RegularPages` + `Sections`.
**Workaround:** definir entradas explícitas em `[menu.main]` do `hugo.toml`
(grupo "Arquivo" + filho por ano, com `parent = "archive"`).
Custo: 1 entrada nova por ano.

---

## Toscanini (renderer dos episódios)

Os `.md` em `vox-content/` são **gerados pelo Toscanini** (Elixir,
HermesTools, `vox_pocketcast_json_renderer.ex`) a partir do JSON sidecar.
Mudanças visuais no episódio podem precisar pareamento: ajusta o renderer
*e* o layout do Hugo. Não editar `.md` direto — sobrescrito no próximo render.

JSON sidecar tem: `title, description, summary, transcript (string [HH:MM:SS]),
timeline[{time,topic,summary}], tags, participants, recommendations, metadata,
lang, aliases`. A página `/transcript/` consome `transcript` + `timeline` + `lang`.

---

## Política de commit

- **Nunca** adicionar `Co-Authored-By` (memory: `feedback_no_coauthored.md`)
- Não commitar `last-published-commit.txt` ou `public-manifest.json` —
  o publish script é dono deles. Se aparecerem modificados, é porque o
  publish anterior rodou
- URLs **sempre lowercase** no S3; CloudFront normaliza (memory: `feedback_url_case.md`)
