(function () {
  'use strict';

  var params = new URLSearchParams(location.search);
  var jsonUrl = params.get('json');

  var $title = document.getElementById('tr-title');
  var $podcast = document.getElementById('tr-podcast');
  var $back = document.getElementById('tr-episode-link');
  var $loader = document.getElementById('tr-loader');
  var $tocNav = document.getElementById('tr-toc-nav');
  var $toc = document.getElementById('tr-toc');
  var $sections = document.getElementById('tr-sections');
  var $help = document.getElementById('tr-help');

  if (!jsonUrl) {
    showError('Parâmetro ?json= ausente na URL.');
    return;
  }

  fetch(jsonUrl, { credentials: 'omit' })
    .then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    })
    .then(render)
    .catch(function (err) {
      showError('Erro ao carregar a transcrição: ' + err.message);
    });

  function showError(msg) {
    $loader.textContent = msg;
  }

  function timeToSec(t) {
    var parts = t.split(':').map(Number);
    if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length === 2) return parts[0] * 60 + parts[1];
    return 0;
  }

  var LINE_RE = /^\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s?(.*)$/;

  function parseTranscript(text) {
    var lines = [];
    var raws = text.split('\n');
    for (var i = 0; i < raws.length; i++) {
      var m = raws[i].match(LINE_RE);
      if (m) {
        lines.push({ time: m[1], sec: timeToSec(m[1]), text: m[2] });
      } else if (lines.length && raws[i].trim()) {
        lines[lines.length - 1].text += ' ' + raws[i].trim();
      }
    }
    return lines;
  }

  function buildSections(timeline, lines) {
    if (!lines.length) return [];

    if (!timeline || !timeline.length) {
      // Fallback: blocos de 5 minutos
      var out = [];
      var i = 0;
      while (i < lines.length) {
        var start = lines[i].sec;
        var endSec = start + 300;
        var chunk = [];
        while (i < lines.length && lines[i].sec < endSec) chunk.push(lines[i++]);
        out.push({
          time: chunk[0].time,
          topic: chunk[0].time + ' – ' + chunk[chunk.length - 1].time,
          summary: '',
          lines: chunk
        });
      }
      return out;
    }

    var sections = [];

    // Intro (linhas antes do primeiro tópico)
    var firstSec = timeToSec(timeline[0].time);
    var intro = [];
    for (var k = 0; k < lines.length && lines[k].sec < firstSec; k++) intro.push(lines[k]);
    if (intro.length) {
      sections.push({
        time: intro[0].time,
        topic: 'Introdução',
        summary: '',
        lines: intro
      });
    }

    for (var j = 0; j < timeline.length; j++) {
      var entry = timeline[j];
      var s = timeToSec(entry.time);
      var e = j + 1 < timeline.length ? timeToSec(timeline[j + 1].time) : Infinity;
      var secLines = [];
      for (var n = 0; n < lines.length; n++) {
        if (lines[n].sec >= s && lines[n].sec < e) secLines.push(lines[n]);
      }
      sections.push({
        time: entry.time,
        topic: entry.topic || '(sem título)',
        summary: entry.summary || '',
        lines: secLines
      });
    }

    return sections;
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  function renderLines(sectionLines) {
    var html = '';
    for (var i = 0; i < sectionLines.length; i++) {
      var l = sectionLines[i];
      html +=
        '<p class="vox-tr-line">' +
        '<span class="vox-tr-time">' + l.time + '</span> ' +
        escapeHtml(l.text) +
        '</p>';
    }
    return html;
  }

  function deriveEpisodeHref(u) {
    // "/2026/04/W14/303-jamil-chade.json" -> "/2026/04/W14/303-jamil-chade/"
    try {
      var parsed = new URL(u, location.href);
      var p = parsed.pathname.replace(/\.json$/i, '/');
      return p;
    } catch (_) {
      return '/';
    }
  }

  function render(data) {
    document.title = (data.title || 'Transcrição') + ' — Vox';
    $title.textContent = 'Transcrição — ' + (data.title || '');

    var meta = data.metadata || {};
    var parts = [];
    if (meta.podcast) parts.push(meta.podcast);
    if (meta.author) parts.push(meta.author);
    $podcast.textContent = parts.join(' — ');

    $back.href = deriveEpisodeHref(jsonUrl);

    if (!data.transcript) {
      showError('Este episódio não tem transcrição disponível.');
      return;
    }

    var lines = parseTranscript(data.transcript);
    var sections = buildSections(data.timeline, lines);

    if (!sections.length) {
      showError('Transcrição vazia ou em formato não reconhecido.');
      return;
    }

    // TOC
    var tocHtml = '';
    for (var i = 0; i < sections.length; i++) {
      var s = sections[i];
      tocHtml +=
        '<li><a href="#s' + i + '">' +
        '<span class="vox-tr-time">' + s.time + '</span> ' +
        escapeHtml(s.topic) +
        '</a></li>';
    }
    $toc.innerHTML = tocHtml;
    $tocNav.hidden = false;

    // Sections — leves até o usuário abrir
    var frag = document.createDocumentFragment();
    for (var x = 0; x < sections.length; x++) {
      var sec = sections[x];
      var det = document.createElement('details');
      det.className = 'vox-tr-section';
      det.id = 's' + x;

      var sum = document.createElement('summary');
      sum.innerHTML =
        '<span class="vox-tr-time">' + sec.time + '</span> ' +
        '<span class="vox-tr-topic">' + escapeHtml(sec.topic) + '</span>';
      det.appendChild(sum);

      if (sec.summary) {
        var p = document.createElement('p');
        p.className = 'vox-tr-summary';
        p.textContent = sec.summary;
        det.appendChild(p);
      }

      var body = document.createElement('div');
      body.className = 'vox-tr-lines';
      det.appendChild(body);

      (function (detEl, bodyEl, secData) {
        detEl.addEventListener('toggle', function () {
          if (detEl.open && !bodyEl.dataset.rendered) {
            bodyEl.innerHTML = renderLines(secData.lines);
            bodyEl.dataset.rendered = '1';
          }
        });
      })(det, body, sec);

      frag.appendChild(det);
    }
    $sections.appendChild(frag);

    $loader.hidden = true;
    $help.hidden = false;

    // Se houver hash, abra a seção correspondente
    if (location.hash) {
      var target = document.querySelector(location.hash);
      if (target && target.tagName === 'DETAILS') {
        target.open = true;
        setTimeout(function () {
          target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }, 50);
      }
    }
  }
})();
