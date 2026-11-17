// Vox search: Pagefind behind Hextra's navbar search box (.hextra-search-*).
// Replaces Hextra's flexsearch.js. The index is produced by `pagefind --site`
// after the Hugo build (see vox-publish-*.ps1); this script loads it lazily on
// first focus and only downloads the chunks each query needs.
(function () {
  const base = document.currentScript.dataset.pagefindBase;
  const NO_RESULTS = '{{ (T "noResultsFound") | default "No results found." }}';
  const FOUND_TEMPLATE = '{{ (T "resultsFound") | default "%d results found" }}';
  const MAX_RESULTS = 20;
  const DEBOUNCE_MS = 150;

  const inputs = document.querySelectorAll('.hextra-search-input');
  const shortcuts = document.querySelectorAll('.hextra-search-wrapper kbd');

  if (/iPad|iPhone|Macintosh/.test(navigator.userAgent)) {
    shortcuts.forEach((k) => { k.innerHTML = '<span class="hx:text-xs">⌘</span>K'; });
  }

  let pagefind = null;
  let loading = null;
  let seq = 0;
  let timer = null;

  // The index has one language per <html lang> (Portuguese episodes are "pt",
  // everything else "en"), each with its own stemmer. Pagefind picks the language
  // from the page it runs on, so to search the whole archive from any page we
  // create one instance per language, setting <html lang> just long enough for
  // createInstance to read it.
  function load() {
    if (!loading) {
      loading = (async () => {
        const pf = await import(base + 'pagefind.js');
        const entry = await (await fetch(base + 'pagefind-entry.json')).json();
        const langs = Object.keys(entry.languages || {});
        const own = document.documentElement.lang;
        const instances = [];
        for (const lang of langs.length ? langs : [own]) {
          document.documentElement.lang = lang;
          try {
            const inst = await pf.createInstance();  // derives its base path from the pagefind.js URL
            await inst.options({ baseUrl: base.replace(/pagefind\/$/, '') });
            instances.push(inst);
          } finally {
            document.documentElement.lang = own;
          }
        }
        pagefind = instances;
        return instances;
      })();
      loading.catch((err) => { console.warn('[vox] pagefind unavailable', err); loading = null; });
    }
    return loading;
  }

  // Navbar and sidebar can each render a wrapper; only one is visible at a time.
  function active() {
    const w = Array.from(document.querySelectorAll('.hextra-search-wrapper')).filter((el) => el.clientHeight > 0);
    if (w.length !== 1) return null;
    return {
      wrapper: w[0],
      input: w[0].querySelector('.hextra-search-input'),
      results: w[0].querySelector('.hextra-search-results'),
      status: w[0].querySelector('.hextra-search-status'),
    };
  }

  function setShortcutOpacity(v) { shortcuts.forEach((k) => { k.style.opacity = v; }); }
  function hide() { const a = active(); if (a) a.results.classList.add('hx:hidden'); }

  function finish() {
    const a = active();
    if (!a) return;
    hide();
    a.input.value = '';
    a.input.blur();
    setShortcutOpacity(100);
  }

  function activeIndex() {
    const a = active();
    const el = a && a.results.querySelector('.hextra-search-active');
    return el ? parseInt(el.dataset.index, 10) : -1;
  }

  function setActive(i) {
    const a = active();
    if (!a) return;
    const cur = a.results.querySelector('.hextra-search-active');
    if (cur) cur.classList.remove('hextra-search-active');
    const next = a.results.querySelector('[data-index="' + i + '"]');
    if (next) { next.classList.add('hextra-search-active'); next.focus(); }
  }

  function onKeyDown(e) {
    const a = active();
    if (!a) return;
    const count = parseInt(a.results.dataset.count || '0', 10);
    const idx = activeIndex();
    if (e.key === 'ArrowUp') { e.preventDefault(); if (idx > 0) setActive(idx - 1); }
    else if (e.key === 'ArrowDown') { e.preventDefault(); if (idx + 1 < count) setActive(idx + 1); }
    else if (e.key === 'Enter') {
      e.preventDefault();
      const cur = a.results.querySelector('.hextra-search-active');
      if (cur) cur.click();
      finish();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      seq++; // drop in-flight searches
      a.input.value = '';
      hide();
      a.input.blur();
      setShortcutOpacity(100);
    }
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  function render(a, items) {
    a.results.innerHTML = '';
    a.results.classList.remove('hx:hidden');
    if (!items.length) {
      a.results.innerHTML = '<span class="hextra-search-no-result">' + esc(NO_RESULTS) + '</span>';
      a.results.dataset.count = '0';
      if (a.status) a.status.textContent = NO_RESULTS;
      return;
    }
    const frag = document.createDocumentFragment();
    items.forEach((d, i) => {
      const li = document.createElement('li');
      const link = document.createElement('a');
      link.dataset.index = i;
      link.href = d.url;
      if (i === 0) link.classList.add('hextra-search-active');
      const title = document.createElement('div');
      title.className = 'hextra-search-title';
      title.textContent = (d.meta && d.meta.title) || d.url;
      link.appendChild(title);
      if (d.excerpt) {
        const ex = document.createElement('div');
        ex.className = 'hextra-search-excerpt';
        // Pagefind escapes the page text; only its own <mark> tags are markup.
        ex.innerHTML = d.excerpt;
        link.appendChild(ex);
      }
      li.appendChild(link);
      li.addEventListener('mousemove', () => {
        const cur = a.results.querySelector('.hextra-search-active');
        if (cur) cur.classList.remove('hextra-search-active');
        link.classList.add('hextra-search-active');
      });
      li.addEventListener('keydown', onKeyDown);
      link.addEventListener('click', finish);
      frag.appendChild(li);
    });
    a.results.appendChild(frag);
    a.results.dataset.count = String(items.length);
    if (a.status) a.status.textContent = FOUND_TEMPLATE.replace('%d', String(items.length));
  }

  async function run(query) {
    const mine = ++seq;
    const a = active();
    if (!a) return;
    if (!query.trim()) { hide(); return; }
    let pf;
    try { pf = pagefind || await load(); } catch (_) { return; }
    const found = await Promise.all(pf.map((inst) => inst.search(query)));
    if (mine !== seq) return; // a newer keystroke superseded this query
    const top = found.flatMap((r) => r.results).sort((x, y) => y.score - x.score).slice(0, MAX_RESULTS);
    const data = await Promise.all(top.map((r) => r.data()));
    if (mine !== seq) return;
    render(a, data);
  }

  for (const el of inputs) {
    el.addEventListener('focus', load, { once: true });
    el.addEventListener('keydown', onKeyDown);
    el.addEventListener('input', (e) => {
      setShortcutOpacity(e.target.value.length > 0 ? 0 : 100);
      clearTimeout(timer);
      timer = setTimeout(() => run(e.target.value), DEBOUNCE_MS);
    });
  }

  const FORM = ['input', 'select', 'button', 'textarea'];
  document.addEventListener('keydown', (e) => {
    const a = active();
    if (!a) return;
    const el = document.activeElement;
    const tag = el && el.tagName && el.tagName.toLowerCase();
    if (a.input === el || !tag || FORM.includes(tag) || (el && el.isContentEditable)) return;
    if (e.key === '/' || (e.key === 'k' && (e.metaKey || e.ctrlKey))) {
      e.preventDefault();
      a.input.focus();
    }
  });

  document.addEventListener('mousedown', (e) => {
    const a = active();
    if (!a) return;
    if (e.target !== a.input && !a.results.contains(e.target)) {
      setShortcutOpacity(100);
      hide();
    }
  });
})();
