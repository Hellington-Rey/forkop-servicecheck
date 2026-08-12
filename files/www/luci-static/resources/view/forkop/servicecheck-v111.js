"use strict";
"require view";
"require fs";
"require ui";

/*
 * Forkop Service Check - страница проверки доступности сервисов.
 *
 * Страница намеренно не встраивается в SPA forkop: та собрана в один бандл
 * main.js, патчить который нельзя без пересборки. Здесь обычная LuCI-вьюха,
 * которая общается с /usr/bin/forkop-servicecheck.
 *
 * Результаты показываются плитками: свёрнутая плитка отвечает на вопрос
 * "работает ли", развёрнутая - "что именно и на каком этапе сломалось".
 * Всё оформление - свой CSS без внешних ресурсов, чтобы страница работала
 * на любой теме LuCI и не тянула ни шрифтов, ни картинок.
 */

var BIN = "/usr/bin/forkop-servicecheck";
var UI_VERSION = "1.2.0"; // Filename stays v111 for compatibility with existing LuCI menu entries.
var POLL_INTERVAL_MS = 1500;
var JOB_TIMEOUT_MS = 10 * 60 * 1000;

var STATE_LABEL = {
  success: "работает",
  warning: "замечания",
  error: "не работает",
  skipped: "пропущено",
  udp_unconfirmed: "UDP не подтверждён",
  loading: "проверяем",
};

var VERDICT_LABEL = {
  ok: "OK",
  slow: "медленно",
  dns_fail: "DNS не отдал адрес",
  timeout: "таймаут",
  tcp_refused: "соединение отклонено",
  tls_error: "ошибка TLS",
  tls_handshake: "TLS оборван",
  tls_cert_rejected: "сертификат отклонён",
  tls_cert_untrusted: "часы или CA",
  tls_reset: "соединение сброшено",
  redirect_loop: "круг редиректов",
  geo_blocked: "блокировка по IP/региону",
  http_server_error: "ошибка на стороне сервиса",
  http_unexpected: "неожиданный ответ",
  failed: "ошибка",
  skipped: "пропущено",
};

var runState = {
  running: false,
  jobId: "",
  timer: null,
  cancelled: false,
};

var openTiles = {};

function callBin(args) {
  return fs.exec(BIN, args).then(function (result) {
    if ((result.code || 0) !== 0 && !result.stdout) {
      throw new Error(result.stderr || "команда завершилась с ошибкой");
    }

    try {
      return JSON.parse(result.stdout);
    } catch (e) {
      throw new Error("не удалось разобрать ответ: " + (result.stdout || result.stderr || ""));
    }
  });
}

function injectStyles() {
  if (document.getElementById("fkpsc-styles")) {
    return;
  }

  var css = [
    /* Цвета статусов держим в одном месте: они одинаково читаются */
    /* и на светлой, и на тёмной теме LuCI. */
    ".fkpsc { --ok:#2f9e44; --warn:#e8a33d; --err:#e03131; --skip:#868e96; --accent:#4a90d9; --surface:#fff; --surface-soft:#f1f3f5; --surface-raised:#fff; box-sizing:border-box; padding:1em; border-radius:14px; background:#fff; background:var(--surface); color:#202124; }",
    ".fkpsc-hero { padding:1.1em 1.25em; margin-bottom:1em; border-radius:14px; background:linear-gradient(135deg,rgba(74,144,217,.20),rgba(92,52,168,.12)),var(--surface-raised); border:1px solid rgba(74,144,217,.35); box-shadow:0 5px 18px rgba(0,0,0,.08); }",
    ".fkpsc-hero h2 { margin:.05em 0 .35em; font-size:1.55em; }",
    ".fkpsc-badges { display:flex; flex-wrap:wrap; gap:.45em; margin-top:.75em; }",
    ".fkpsc-badge { padding:.25em .65em; border-radius:999px; background:rgba(127,127,127,.16); font-size:.84em; }",
    ".fkpsc-card { padding:1em 1.1em; margin:0 0 1em; border-radius:12px; border:1px solid rgba(127,127,127,.32); background:var(--surface-raised); box-shadow:0 5px 18px rgba(0,0,0,.10); }",
    ".fkpsc-card h3 { margin:.05em 0 .75em; }",
    ".fkpsc-tabs { display:flex; gap:.35em; margin:0 0 1em; padding:.25em; border-radius:11px; background:var(--surface-soft); border:1px solid rgba(127,127,127,.24); }",
    ".fkpsc-tab { flex:0 1 auto; padding:.55em .9em; border:0; border-radius:8px; background:transparent; color:inherit; cursor:pointer; font-weight:600; }",
    ".fkpsc-tab.active { color:#fff; background:var(--accent); box-shadow:0 2px 8px rgba(0,0,0,.18); }",
    ".fkpsc-page { display:none; } .fkpsc-page.active { display:block; }",
    ".fkpsc-editor { box-sizing:border-box; width:100%; min-height:32em; resize:vertical; font:12px/1.45 monospace; white-space:pre; tab-size:2; color:inherit; background:var(--surface-soft); border:1px solid rgba(127,127,127,.4); }",
    ".fkpsc-fix { padding:.75em; border:1px solid rgba(127,127,127,.25); border-radius:9px; background:var(--surface-soft); margin-bottom:.55em; }",
    ".fkpsc-fix-title { font-weight:600; margin-bottom:.25em; }",
    ".fkpsc-intro { margin-bottom: 1em; line-height: 1.55; max-width: 60em; }",
    ".fkpsc-note { background: rgba(232,163,61,.12); border-left: 3px solid var(--warn); padding: .65em .9em; margin: .9em 0; border-radius: 0 6px 6px 0; line-height: 1.5; }",

    /* --- выбор сервисов: чипы вместо частокола чекбоксов --- */
    ".fkpsc-chips-pick { display: flex; flex-wrap: wrap; gap: .45em; margin: .7em 0 1.1em; }",
    ".fkpsc-pick { display: inline-flex; align-items: center; gap: .4em; padding: .38em .8em; border-radius: 999px; border: 1px solid rgba(127,127,127,.4); cursor: pointer; user-select: none; font-size: .93em; line-height: 1.2; transition: all .15s ease; background: transparent; }",
    ".fkpsc-pick:hover { border-color: var(--accent); }",
    ".fkpsc-pick .tick { width: 1em; height: 1em; border-radius: 50%; border: 1px solid rgba(127,127,127,.55); display: inline-block; position: relative; flex: none; }",
    ".fkpsc-pick.on { border-color: var(--accent); background: rgba(74,144,217,.14); }",
    ".fkpsc-pick.on .tick { background: var(--accent); border-color: var(--accent); }",
    ".fkpsc-pick.on .tick::after { content: ''; position: absolute; left: .3em; top: .12em; width: .22em; height: .45em; border: solid #fff; border-width: 0 2px 2px 0; transform: rotate(45deg); }",
    ".fkpsc-pick .num { opacity: .55; font-size: .88em; }",

    /* --- панель управления --- */
    ".fkpsc-mode label { display: block; margin-bottom: .35em; cursor: pointer; }",
    ".fkpsc-actions { display: flex; gap: .6em; flex-wrap: wrap; align-items: center; margin: 0 0 1.2em; }",
    ".fkpsc-progress { flex: 1 1 200px; min-width: 150px; height: 6px; background: rgba(127,127,127,.22); border-radius: 3px; overflow: hidden; }",
    ".fkpsc-progress > div { height: 100%; width: 0; background: var(--accent); transition: width .35s ease; }",
    ".fkpsc-custom-form { display:flex; flex-wrap:wrap; gap:.55em; align-items:center; margin:.55em 0 .75em; }",
    ".fkpsc-custom-target { flex:1 1 260px; min-width:180px; }",
    ".fkpsc-custom-port { width:7em; }",
    ".fkpsc-custom-port-label { display:flex; gap:.35em; align-items:center; }",
    ".fkpsc-custom-result { margin:.7em 0 1.15em; padding:.8em .9em; border-radius:9px; border-left:4px solid var(--skip); background:var(--surface-soft); }",
    ".fkpsc-custom-result.state-success { border-left-color:var(--ok); }",
    ".fkpsc-custom-result.state-warning { border-left-color:var(--warn); }",
    ".fkpsc-custom-result.state-error { border-left-color:var(--err); }",
    ".fkpsc-custom-head { display:flex; flex-wrap:wrap; gap:.45em; align-items:center; margin-bottom:.35em; }",
    ".fkpsc-custom-title { font-weight:700; margin-right:auto; }",
    ".fkpsc-custom-pill { padding:.18em .6em; border-radius:999px; background:rgba(127,127,127,.16); font-size:.84em; font-weight:600; }",
    ".fkpsc-custom-pill.ok { color:var(--ok); background:rgba(47,158,68,.13); }",
    ".fkpsc-custom-pill.warn { color:#9a6500; background:rgba(232,163,61,.16); }",
    ".fkpsc-custom-pill.err { color:var(--err); background:rgba(224,49,49,.13); }",

    /* --- сводка --- */
    ".fkpsc-summary { display: flex; flex-wrap: wrap; gap: .5em; margin: 0 0 1em; }",
    ".fkpsc-sum { display: inline-flex; align-items: baseline; gap: .4em; padding: .35em .75em; border:1px solid rgba(127,127,127,.25); border-radius: 8px; background:var(--surface-raised); font-size: .92em; }",
    ".fkpsc-sum b { font-size: 1.15em; }",
    ".fkpsc-sum.ok b { color: var(--ok); }",
    ".fkpsc-sum.warn b { color: var(--warn); }",
    ".fkpsc-sum.err b { color: var(--err); }",

    /* --- сетка плиток --- */
    ".fkpsc-tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(255px, 1fr)); gap: .75em; align-items: start; }",
    ".fkpsc-tile { border: 1px solid rgba(127,127,127,.35); border-radius: 10px; background:var(--surface-raised); box-shadow:0 3px 12px rgba(0,0,0,.10); overflow: hidden; cursor: pointer; transition: transform .12s ease, box-shadow .12s ease, border-color .12s ease; position: relative; }",
    ".fkpsc-tile::before { content: ''; position: absolute; inset: 0 0 auto 0; height: 3px; background: var(--skip); }",
    ".fkpsc-tile.state-success::before { background: var(--ok); }",
    ".fkpsc-tile.state-warning::before { background: var(--warn); }",
    ".fkpsc-tile.state-error::before { background: var(--err); }",
    ".fkpsc-tile:hover { transform: translateY(-2px); box-shadow: 0 4px 14px rgba(0,0,0,.16); border-color: rgba(127,127,127,.5); }",
    ".fkpsc-tile:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }",
    ".fkpsc-tile.open { grid-column: 1 / -1; cursor: default; transform: none; box-shadow: 0 4px 18px rgba(0,0,0,.14); }",
    ".fkpsc-tile-head { display: flex; align-items: center; gap: .5em; padding: .8em .9em .1em; }",
    ".fkpsc-dot { width: .7em; height: .7em; border-radius: 50%; flex: none; background: var(--skip); }",
    ".state-success .fkpsc-dot { background: var(--ok); box-shadow: 0 0 0 3px rgba(47,158,68,.18); }",
    ".state-warning .fkpsc-dot { background: var(--warn); box-shadow: 0 0 0 3px rgba(232,163,61,.18); }",
    ".state-error .fkpsc-dot { background: var(--err); box-shadow: 0 0 0 3px rgba(224,49,49,.18); }",
    ".fkpsc-tile-title { font-weight: 600; font-size: 1.02em; flex: 1 1 auto; }",
    ".fkpsc-chev { opacity: .45; font-size: .8em; transition: transform .18s ease; flex: none; }",
    ".fkpsc-tile.open .fkpsc-chev { transform: rotate(180deg); }",
    ".fkpsc-tile-status { padding: 0 .9em .1em 2.1em; opacity: .75; font-size: .9em; }",
    ".fkpsc-tile-foot { padding: .5em .9em .8em 2.1em; display: flex; align-items: center; gap: .5em; }",
    ".fkpsc-bar { display: flex; gap: 2px; flex: 1 1 auto; height: 5px; }",
    ".fkpsc-bar > i { flex: 1 1 auto; border-radius: 2px; background: var(--skip); opacity: .85; }",
    ".fkpsc-bar > i.success { background: var(--ok); }",
    ".fkpsc-bar > i.warning { background: var(--warn); }",
    ".fkpsc-bar > i.error { background: var(--err); }",
    ".fkpsc-count { font-size: .85em; opacity: .6; white-space: nowrap; }",
    ".fkpsc-tile.loading .fkpsc-dot { animation: fkpsc-pulse 1.1s ease-in-out infinite; }",
    "@keyframes fkpsc-pulse { 0%,100% { opacity: .35; } 50% { opacity: 1; } }",

    /* --- раскрытая часть --- */
    ".fkpsc-detail { display: none; padding: .3em .9em 1em; border-top: 1px solid rgba(127,127,127,.22); margin-top: .5em; animation: fkpsc-fade .2s ease; }",
    ".fkpsc-tile.open .fkpsc-detail { display: block; }",
    "@keyframes fkpsc-fade { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: none; } }",
    ".fkpsc-detail-note { opacity: .7; font-size: .9em; margin: .7em 0 .3em; }",
    ".fkpsc-sect { font-size: .82em; text-transform: uppercase; letter-spacing: .06em; opacity: .55; margin: 1em 0 .5em; }",
    ".fkpsc-row { border:1px solid rgba(127,127,127,.22); border-left: 3px solid var(--skip); border-radius: 0 6px 6px 0; background:var(--surface-soft); padding: .6em .8em; margin-bottom: .5em; }",
    ".fkpsc-row.state-success { border-left-color: var(--ok); }",
    ".fkpsc-row.state-warning { border-left-color: var(--warn); }",
    ".fkpsc-row.state-error { border-left-color: var(--err); }",
    ".fkpsc-row-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: .5em; }",
    ".fkpsc-row-name { font-weight: 600; }",
    ".fkpsc-row-url { font-family: monospace; font-size: .85em; opacity: .55; word-break: break-all; }",
    ".fkpsc-verdict { margin-left: auto; padding: .1em .55em; border-radius: 999px; font-size: .8em; font-weight: 600; color: #fff; background: var(--skip); white-space: nowrap; }",
    /* Правила привязаны к самой строке, а не к предку: у плитки свой класс */
    /* состояния, и через потомка он перекрашивал текст до нечитаемого. */
    ".fkpsc-row.state-success .fkpsc-verdict { background: var(--ok); color: #fff; }",
    ".fkpsc-row.state-warning .fkpsc-verdict { background: var(--warn); color: #2b2410; }",
    ".fkpsc-row.state-error .fkpsc-verdict { background: var(--err); color: #fff; }",
    ".fkpsc-row.state-skipped .fkpsc-verdict { background: var(--skip); color: #fff; }",
    ".fkpsc-row-msg { margin-top: .35em; font-size: .93em; }",

    /* --- этапы: DNS -> TCP -> TLS -> HTTP --- */
    ".fkpsc-stages { display: flex; flex-wrap: wrap; align-items: center; gap: .3em; margin-top: .55em; }",
    ".fkpsc-stage { display: inline-flex; align-items: center; gap: .3em; padding: .15em .5em; border-radius: 5px; font-size: .8em; background: rgba(127,127,127,.15); }",
    ".fkpsc-stage.ok { color: var(--ok); }",
    ".fkpsc-stage.fail { background: rgba(224,49,49,.16); color: var(--err); font-weight: 600; }",
    ".fkpsc-stage.skip { opacity: .4; }",
    ".fkpsc-arrow { opacity: .3; font-size: .75em; }",
    ".fkpsc-facts { display: flex; flex-wrap: wrap; gap: .3em; margin-top: .5em; }",
    ".fkpsc-fact { font-size: .8em; padding: .12em .5em; border-radius: 5px; background: rgba(127,127,127,.13); font-family: monospace; }",
    ".fkpsc-fact.hl { background: rgba(74,144,217,.18); }",
    ".fkpsc-okline { display: flex; flex-wrap: wrap; align-items: baseline; gap: .5em; padding: .3em .1em; font-size: .9em; border-bottom: 1px solid rgba(127,127,127,.14); }",
    ".fkpsc-okline .nm { flex: 1 1 12em; }",
    ".fkpsc-okline .tm { opacity: .5; font-family: monospace; font-size: .88em; }",
    ".fkpsc-meta { margin: .3em 0 1.1em; opacity: .7; line-height: 1.6; font-size: .92em; }",
    ".fkpsc-dim { opacity: .65; }",
    ".fkpsc-empty { opacity: .6; padding: 2em 1em; text-align: center; }",
    ".fkpsc-service-tools { display:flex; flex-wrap:wrap; gap:.45em; align-items:center; margin:.45em 0; }",
    ".fkpsc-search { flex:1 1 190px; min-width:150px; }",
    "@media (prefers-color-scheme:dark) {",
    "  .fkpsc { --surface:#18191b; --surface-soft:#242629; --surface-raised:#202225; background:#18191b; color:#e7e9ec; }",
    "}",
    "@media (max-width:600px) {",
    "  .fkpsc { padding:.55em; border-radius:10px; }",
    "  .fkpsc-hero { padding:.85em .9em; border-radius:10px; }",
    "  .fkpsc-hero h2 { font-size:1.3em; }",
    "  .fkpsc-tabs { position:sticky; top:0; z-index:20; }",
    "  .fkpsc-tab { flex:1 1 30%; padding:.65em .35em; }",
    "  .fkpsc-card { padding:.8em; border-radius:9px; }",
    "  .fkpsc-actions .cbi-button { flex:1 1 45%; min-height:2.6em; }",
    "  .fkpsc-chips-pick { gap:.35em; }",
    "  .fkpsc-pick { padding:.42em .65em; }",
    "  .fkpsc-tiles { grid-template-columns:1fr; }",
    "}",
  ].join("\n");

  document.head.appendChild(E("style", { id: "fkpsc-styles" }, css));
}

function formatMs(value) {
  value = parseInt(value, 10) || 0;
  return value > 0 ? value + " мс" : "—";
}

/*
 * Этапы соединения. Главная ценность раскрытой плитки: видно не только
 * "не работает", но и на каком именно шаге всё встало.
 */
function stagesFor(item) {
  var verdict = item.verdict || "";
  var dnsOk = !!item.dns_ok;
  var tcpFailed = verdict === "timeout" || verdict === "tcp_refused";
  var tlsFailed = verdict === "tls_error" || verdict === "tls_reset" ||
    verdict === "tls_handshake" || verdict === "tls_cert_rejected" || verdict === "tls_cert_untrusted";
  var stages = [];

  stages.push({ name: "DNS", state: dnsOk ? "ok" : (verdict === "dns_fail" ? "fail" : "skip") });

  if (item.kind === "tcp" || item.kind === "udp" || item.kind === "udp_dns") {
    stages.push({
      name: item.kind === "udp" || item.kind === "udp_dns" ? "UDP" : "TCP",
      state: !dnsOk ? "skip" : (tcpFailed ? "fail" : (item.state === "skipped" || verdict === "udp_unconfirmed" ? "skip" : "ok")),
    });
    return stages;
  }

  stages.push({ name: "TCP", state: !dnsOk ? "skip" : (tcpFailed ? "fail" : "ok") });
  stages.push({ name: "TLS", state: (!dnsOk || tcpFailed) ? "skip" : (tlsFailed ? "fail" : "ok") });
  stages.push({ name: "HTTP", state: item.http_code > 0 ? "ok" : "skip" });

  return stages;
}

function renderStages(item) {
  var nodes = [];

  stagesFor(item).forEach(function (stage, index) {
    if (index > 0) {
      nodes.push(E("span", { class: "fkpsc-arrow" }, "→"));
    }

    var mark = stage.state === "ok" ? "✓" : (stage.state === "fail" ? "✕" : "·");
    nodes.push(E("span", { class: "fkpsc-stage " + stage.state }, [
      E("span", {}, mark),
      E("span", {}, stage.name),
    ]));
  });

  return E("div", { class: "fkpsc-stages" }, nodes);
}

function renderFacts(item) {
  var facts = [];

  if (item.dns_ip) {
    facts.push({ text: item.dns_ip + (item.dns_fakeip ? " · fakeip" : ""), hl: !!item.dns_fakeip });
  }

  if (item.http_code > 0) {
    facts.push({ text: "HTTP " + item.http_code });
  }

  if (item.tcp_ms > 0) {
    facts.push({ text: "TCP " + formatMs(item.tcp_ms) });
  }

  if (item.tls_ms > 0) {
    facts.push({ text: "TLS " + formatMs(item.tls_ms) });
  }

  if (item.total_ms > 0) {
    facts.push({ text: "всего " + formatMs(item.total_ms) });
  }

  if (item.remote_ip && item.remote_ip !== item.dns_ip) {
    facts.push({ text: "→ " + item.remote_ip });
  }

  if (item.outbound) {
    facts.push({ text: "через " + item.outbound, hl: true });
  }

  if (!facts.length) {
    return "";
  }

  return E("div", { class: "fkpsc-facts" }, facts.map(function (fact) {
    return E("span", { class: "fkpsc-fact" + (fact.hl ? " hl" : "") }, fact.text);
  }));
}

function renderProblemRow(item) {
  var head = [
    E("span", { class: "fkpsc-row-name" }, item.label),
  ];

  if (item.url) {
    head.push(E("span", { class: "fkpsc-row-url" }, item.url));
  }

  head.push(E("span", { class: "fkpsc-verdict" }, VERDICT_LABEL[item.verdict] || item.verdict || STATE_LABEL[item.state]));

  var body = [E("div", { class: "fkpsc-row-head" }, head)];

  if (item.message) {
    body.push(E("div", { class: "fkpsc-row-msg" }, item.message));
  }

  if (item.optional) {
    body.push(E("div", { class: "fkpsc-dim", style: "font-size:.85em;margin-top:.2em" },
      "необязательная цель — на общий вердикт не влияет"));
  }

  body.push(renderStages(item));

  var facts = renderFacts(item);
  if (facts) {
    body.push(facts);
  }

  return E("div", { class: "fkpsc-row state-" + item.state }, body);
}

function renderOkLine(item) {
  var timing = item.total_ms > 0 ? formatMs(item.total_ms) : (item.tcp_ms > 0 ? formatMs(item.tcp_ms) : "");

  return E("div", { class: "fkpsc-okline" }, [
    E("span", { class: "nm" }, item.label),
    item.dns_fakeip ? E("span", { class: "fkpsc-fact hl" }, "через прокси") : "",
    item.http_code > 0 ? E("span", { class: "tm" }, "HTTP " + item.http_code) : "",
    E("span", { class: "tm" }, timing),
  ]);
}

function renderDetail(service) {
  var items = service.items || [];
  var problems = items.filter(function (item) {
    return item.state === "error" || item.state === "warning";
  });
  var fine = items.filter(function (item) {
    return item.state !== "error" && item.state !== "warning";
  });

  var nodes = [];

  if (service.description) {
    nodes.push(E("div", { class: "fkpsc-detail-note" }, service.description));
  }

  if (problems.length) {
    nodes.push(E("div", { class: "fkpsc-sect" }, "Что не работает"));
    problems.forEach(function (item) {
      nodes.push(renderProblemRow(item));
    });
  }

  if (fine.length) {
    nodes.push(E("div", { class: "fkpsc-sect" },
      problems.length ? "Остальное в порядке" : "Все цели в порядке"));
    fine.forEach(function (item) {
      nodes.push(renderOkLine(item));
    });
  }

  return E("div", { class: "fkpsc-detail" }, nodes);
}

function renderTile(service) {
  var items = service.items || [];
  var okCount = items.filter(function (item) {
    return item.state === "success";
  }).length;

  var tile = E("div", {
    class: "fkpsc-tile state-" + service.state + (openTiles[service.id] ? " open" : ""),
    tabindex: "0",
    role: "button",
    "aria-expanded": openTiles[service.id] ? "true" : "false",
  }, [
    E("div", { class: "fkpsc-tile-head" }, [
      E("span", { class: "fkpsc-dot" }),
      E("span", { class: "fkpsc-tile-title" }, service.title),
      E("span", { class: "fkpsc-chev" }, "▼"),
    ]),
    E("div", { class: "fkpsc-tile-status" }, service.description_result || STATE_LABEL[service.state] || ""),
    E("div", { class: "fkpsc-tile-foot" }, [
      E("div", { class: "fkpsc-bar" }, items.map(function (item) {
        return E("i", { class: item.state, title: item.label + ": " + (item.message || STATE_LABEL[item.state] || "") });
      })),
      E("span", { class: "fkpsc-count" }, okCount + "/" + items.length),
    ]),
    renderDetail(service),
  ]);

  function toggle() {
    var isOpen = tile.classList.toggle("open");
    openTiles[service.id] = isOpen;
    tile.setAttribute("aria-expanded", isOpen ? "true" : "false");
  }

  tile.addEventListener("click", toggle);
  tile.addEventListener("keydown", function (event) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      toggle();
    }
  });

  return tile;
}

function renderSummary(services) {
  if (!services.length) {
    return "";
  }

  var counts = { success: 0, warning: 0, error: 0 };

  services.forEach(function (service) {
    if (counts[service.state] !== undefined) {
      counts[service.state]++;
    }
  });

  var cells = [
    E("span", { class: "fkpsc-sum ok" }, [E("b", {}, String(counts.success)), E("span", {}, "работают")]),
  ];

  if (counts.warning) {
    cells.push(E("span", { class: "fkpsc-sum warn" }, [E("b", {}, String(counts.warning)), E("span", {}, "с замечаниями")]));
  }

  if (counts.error) {
    cells.push(E("span", { class: "fkpsc-sum err" }, [E("b", {}, String(counts.error)), E("span", {}, "не работают")]));
  }

  return E("div", { class: "fkpsc-summary" }, cells);
}

function renderRunMeta(state) {
  var lines = [];

  if (state.mode === "netns") {
    lines.push("Режим: от имени клиента в LAN" + (state.client_ip ? " (" + state.client_ip + ")" : ""));
  } else {
    lines.push("Режим: с роутера через tproxy — тот же путь, что у трафика клиента");
  }

  if (state.netns_error) {
    lines.push("Режим клиента не запустился (" + state.netns_error + "), проверка выполнена с роутера.");
  }

  if (state.forkop_running === false) {
    lines.push("Внимание: forkop не запущен, соединения шли напрямую.");
  }

  if (state.resolver) {
    lines.push("DNS-резолвер проверки: " + state.resolver);
  }

  if (state.tools && !state.tools.curl) {
    lines.push("curl не установлен — тайминги и коды ответов определяются приблизительно через uclient-fetch.");
  }

  return E("div", { class: "fkpsc-meta" }, lines.map(function (line) {
    return E("div", {}, line);
  }));
}

function renderCustomResult(result) {
  var item = result.item || {};
  var route = result.route || {};
  var reachable = item.state === "success" || item.state === "warning";
  var through = route.through_sing_box;
  var routeText = through === true ? "через sing-box" :
    (through === false ? "мимо sing-box" : "маршрут не определён");
  var routeClass = through === true ? "ok" : (through === false ? "err" : "warn");
  var stateClass = through === null || through === undefined ? "warning" :
    (reachable ? "success" : "error");
  var nodes = [
    E("div", { class: "fkpsc-custom-head" }, [
      E("span", { class: "fkpsc-custom-title" }, result.target + ":" + result.port),
      E("span", { class: "fkpsc-custom-pill " + (reachable ? "ok" : "err") },
        reachable ? "доступен" : "не доступен"),
      E("span", { class: "fkpsc-custom-pill " + routeClass }, routeText),
    ]),
    E("div", {}, route.message || ""),
  ];

  if (item.message) {
    nodes.push(E("div", { class: "fkpsc-row-msg" }, item.message));
  }

  nodes.push(renderStages(item));
  var facts = renderFacts(item);
  if (facts) {
    nodes.push(facts);
  }
  if (result.netns_error) {
    nodes.push(E("div", { class: "fkpsc-dim", style: "margin-top:.4em" },
      "Режим клиента не запустился: " + result.netns_error + ". Проверено с роутера."));
  }

  return E("div", { class: "fkpsc-custom-result state-" + stateClass }, nodes);
}

return view.extend({
  handleSaveApply: null,
  handleSave: null,
  handleReset: null,

  load: function () {
    return Promise.all([
      callBin(["capabilities"]).catch(function () {
        return null;
      }),
      callBin(["list"]).catch(function () {
        return null;
      }),
      callBin(["fixes"]).catch(function () {
        return { fixes: [] };
      }),
      callBin(["profiles-get"]).catch(function () {
        return null;
      }),
    ]);
  },

  render: function (data) {
    injectStyles();

    var capabilities = data[0];
    var catalogue = data[1];
    var fixes = (data[2] && data[2].fixes) || [];
    var profilesData = data[3];

    if (!capabilities || !catalogue) {
      return E("div", { class: "cbi-map fkpsc" }, [
        E("h2", {}, "Проверка сервисов Forkop"),
        E("div", { class: "alert-message error" },
          "Не удалось обратиться к " + BIN + ". Проверьте, что модуль установлен и у пользователя есть права на его запуск."),
      ]);
    }

    var profiles = catalogue.profiles || [];
    var selected = {};

    profiles.forEach(function (profile) {
      selected[profile.id] = profile.id === "baseline" || profile.group !== "system";
    });

    var tilesNode = E("div", { class: "fkpsc-tiles" });
    var summaryNode = E("div", {});
    var progressBar = E("div", {});
    var progressWrap = E("div", { class: "fkpsc-progress", style: "display:none" }, [progressBar]);
    var progressText = E("span", { class: "fkpsc-dim" }, "");
    var metaNode = E("div", {});
    var customResultNode = E("div", {});

    var modeRouter = E("input", { type: "radio", name: "fkpsc-mode", value: "router", checked: "" });
    var modeNetns = E("input", {
      type: "radio",
      name: "fkpsc-mode",
      value: "netns",
      disabled: capabilities.netns ? null : "",
    });
    var clientIpInput = E("input", {
      type: "text",
      class: "cbi-input-text",
      placeholder: "авто",
      style: "width: 9em; margin-left: .4em;",
      disabled: "",
    });

    modeRouter.addEventListener("change", function () {
      clientIpInput.disabled = true;
    });
    modeNetns.addEventListener("change", function () {
      clientIpInput.disabled = false;
    });

    var customTargetInput = E("input", {
      type: "text",
      class: "cbi-input-text fkpsc-custom-target",
      placeholder: "example.com или 1.1.1.1",
      autocomplete: "off",
      spellcheck: "false",
    });
    var customPortInput = E("input", {
      type: "number",
      class: "cbi-input-text fkpsc-custom-port",
      min: "1",
      max: "65535",
      value: "443",
      title: "TCP-порт",
    });
    var customCheckButton = E("button", {
      class: "cbi-button cbi-button-action important",
      type: "button",
    }, "Проверить IP/домен");

    function runCustomCheck() {
      if (customCheckButton.disabled) {
        return;
      }
      var target = customTargetInput.value.trim();
      var port = parseInt(customPortInput.value, 10) || 443;
      if (!target) {
        ui.addNotification(null, E("p", {}, "Введите IP-адрес или домен."), "warning");
        customTargetInput.focus();
        return;
      }

      var mode = modeNetns.checked ? "netns" : "router";
      var clientIp = mode === "netns" ? clientIpInput.value.trim() : "";
      customCheckButton.disabled = true;
      customCheckButton.textContent = "Проверяем…";
      customResultNode.replaceChildren(E("div", { class: "fkpsc-custom-result state-warning" },
        "Устанавливаем соединение и смотрим маршрут в sing-box…"));

      callBin(["custom", target, String(port), mode, clientIp]).then(function (result) {
        if (!result.success) {
          customResultNode.replaceChildren(E("div", { class: "fkpsc-custom-result state-error" },
            result.message || "Не удалось выполнить проверку."));
          return;
        }
        customResultNode.replaceChildren(renderCustomResult(result));
      }).catch(function (error) {
        customResultNode.replaceChildren(E("div", { class: "fkpsc-custom-result state-error" },
          "Ошибка проверки: " + error.message));
      }).finally(function () {
        customCheckButton.disabled = false;
        customCheckButton.textContent = "Проверить IP/домен";
      });
    }

    customCheckButton.addEventListener("click", runCustomCheck);
    customTargetInput.addEventListener("keydown", function (event) {
      if (event.key === "Enter") {
        event.preventDefault();
        runCustomCheck();
      }
    });

    var pickNodes = {};
    var picker = E("div", { class: "fkpsc-chips-pick" }, profiles.map(function (profile) {
      var chip = E("span", {
        class: "fkpsc-pick" + (selected[profile.id] ? " on" : ""),
        title: profile.description || "",
        tabindex: "0",
        role: "checkbox",
        "aria-checked": selected[profile.id] ? "true" : "false",
      }, [
        E("span", { class: "tick" }),
        E("span", {}, profile.title),
        E("span", { class: "num" }, String(profile.targets)),
      ]);

      function toggle() {
        selected[profile.id] = !selected[profile.id];
        chip.classList.toggle("on", selected[profile.id]);
        chip.setAttribute("aria-checked", selected[profile.id] ? "true" : "false");
      }

      chip.addEventListener("click", toggle);
      chip.addEventListener("keydown", function (event) {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          toggle();
        }
      });

      pickNodes[profile.id] = chip;
      return chip;
    }));

    function setAll(value) {
      profiles.forEach(function (profile) {
        selected[profile.id] = value;
        pickNodes[profile.id].classList.toggle("on", value);
        pickNodes[profile.id].setAttribute("aria-checked", value ? "true" : "false");
      });
    }

    function selectOnly(ids) {
      var wanted = {};
      ids.forEach(function (id) { wanted[id] = true; });
      profiles.forEach(function (profile) {
        selected[profile.id] = !!wanted[profile.id];
        pickNodes[profile.id].classList.toggle("on", selected[profile.id]);
        pickNodes[profile.id].setAttribute("aria-checked", selected[profile.id] ? "true" : "false");
      });
    }

    var serviceSearch = E("input", { type: "search", class: "cbi-input-text fkpsc-search", placeholder: "Найти сервис…" });
    serviceSearch.addEventListener("input", function () {
      var query = serviceSearch.value.trim().toLowerCase();
      profiles.forEach(function (profile) {
        var haystack = (profile.title + " " + (profile.description || "")).toLowerCase();
        pickNodes[profile.id].style.display = !query || haystack.indexOf(query) >= 0 ? "" : "none";
      });
    });

    var quickPreset = E("button", { class: "cbi-button", type: "button" }, "Быстрая");
    quickPreset.addEventListener("click", function () {
      selectOnly(["baseline", "telegram", "youtube", "discord", "udp_common"]);
    });
    var udpPreset = E("button", { class: "cbi-button", type: "button" }, "Только UDP");
    udpPreset.addEventListener("click", function () { selectOnly(["udp_common"]); });

    var runButton = E("button", { class: "cbi-button cbi-button-action important" }, "Проверить сервис");
    var retryButton = E("button", { class: "cbi-button", style: "display:none" }, "Повторить ошибки");
    var lastProblemIds = [];
    var maintenancePanel = E("div", { class: "fkpsc-card" });

    var fixesNodes = fixes.map(function (fix) {
      var applyButton = E("button", { class: "cbi-button cbi-button-action" }, "Применить");
      applyButton.addEventListener("click", function () {
        applyButton.disabled = true;
        applyButton.textContent = "Выполняю…";
        callBin(["fix", fix.id]).then(function (result) {
          ui.addNotification(null, E("p", {}, result.output || result.message || "Фикс применён"), result.success ? "info" : "warning");
        }).catch(function (error) {
          ui.addNotification(null, E("p", {}, error.message || "Не удалось применить фикс"), "error");
        }).finally(function () {
          applyButton.disabled = false;
          applyButton.textContent = "Применить";
        });
      });
      return E("div", { class: "fkpsc-fix" }, [
        E("div", { class: "fkpsc-fix-title" }, fix.title),
        E("div", { class: "fkpsc-dim" }, fix.description || ""),
        E("div", { class: "fkpsc-dim", style: "margin:.35em 0" }, fix.risk || ""),
        applyButton,
      ]);
    });

    var maintenanceChildren = [
      E("h3", {}, "Безопасные исправления Forkop"),
      E("p", { class: "fkpsc-dim" },
        "Здесь доступны только встроенные исправления из белого списка backend. Произвольные команды из браузера не выполняются."),
    ];
    if (fixesNodes.length) {
      fixesNodes.forEach(function (node) { maintenanceChildren.push(node); });
    } else {
      maintenanceChildren.push(E("div", { class: "fkpsc-dim" }, "Фикс недоступен."));
    }
    maintenancePanel.appendChild(E("div", {}, maintenanceChildren));
    var stopButton = E("button", { class: "cbi-button", style: "display:none" }, "Остановить");

    function setRunning(running) {
      runState.running = running;
      runButton.disabled = running;
      runButton.textContent = running ? "Проверяем…" : "Проверить сервис";
      stopButton.style.display = running ? "" : "none";
      progressWrap.style.display = running ? "" : "none";
    }

    function updateProgress(progress) {
      var done = (progress && progress.done) || 0;
      var total = (progress && progress.total) || 0;
      var percent = total > 0 ? Math.round((done / total) * 100) : 0;

      progressBar.style.width = percent + "%";
      progressText.textContent = total > 0 ? done + " из " + total + " проверок" : "";
    }

    function renderResults(state) {
      var services = state.services || [];

      metaNode.replaceChildren(state.running ? E("div", {}) : renderRunMeta(state));
      summaryNode.replaceChildren(state.running ? E("div", {}) : renderSummary(services));
      tilesNode.replaceChildren.apply(tilesNode, services.map(renderTile));
      if (!state.running) {
        lastProblemIds = services.filter(function (service) {
          return service.state === "error";
        }).map(function (service) {
          return service.id;
        });
        retryButton.style.display = lastProblemIds.length ? "" : "none";
      }
    }

    function pollJob(jobId, startedAt) {
      runState.timer = window.setTimeout(function () {
        if (runState.cancelled) {
          return;
        }

        callBin(["status", jobId]).then(function (state) {
          if (runState.cancelled) {
            return;
          }

          updateProgress(state.progress);
          renderResults(state);

          if (state.running) {
            if (Date.now() - startedAt > JOB_TIMEOUT_MS) {
              setRunning(false);
              ui.addNotification(null, E("p", {}, "Проверка не завершилась за отведённое время."), "warning");
              return;
            }

            pollJob(jobId, startedAt);
            return;
          }

          setRunning(false);
        }).catch(function (error) {
          setRunning(false);
          ui.addNotification(null, E("p", {}, "Ошибка чтения состояния: " + error.message), "error");
        });
      }, POLL_INTERVAL_MS);
    }

    runButton.addEventListener("click", function () {
      var ids = profiles.filter(function (profile) {
        return selected[profile.id];
      }).map(function (profile) {
        return profile.id;
      });

      if (!ids.length) {
        ui.addNotification(null, E("p", {}, "Выберите хотя бы один сервис."), "warning");
        return;
      }

      var mode = modeNetns.checked ? "netns" : "router";
      var clientIp = mode === "netns" ? clientIpInput.value.trim() : "";

      runState.cancelled = false;
      setRunning(true);
      updateProgress({ done: 0, total: 0 });
      tilesNode.replaceChildren();
      summaryNode.replaceChildren();
      metaNode.replaceChildren();

      callBin(["start", ids.join(","), mode, clientIp]).then(function (response) {
        if (!response.success) {
          setRunning(false);
          ui.addNotification(null, E("p", {}, "Не удалось запустить проверку: " + (response.message || "")), "error");
          return;
        }

        runState.jobId = response.job_id;
        updateProgress(response.progress);
        pollJob(response.job_id, Date.now());
      }).catch(function (error) {
        setRunning(false);
        ui.addNotification(null, E("p", {}, "Не удалось запустить проверку: " + error.message), "error");
      });
    });

    stopButton.addEventListener("click", function () {
      runState.cancelled = true;
      if (runState.timer) {
        window.clearTimeout(runState.timer);
        runState.timer = null;
      }
      setRunning(false);
    });

    retryButton.addEventListener("click", function () {
      if (!lastProblemIds.length) {
        return;
      }
      selectOnly(lastProblemIds);
      runButton.click();
    });

    var notes = [];

    if (!capabilities.forkop_running) {
      notes.push("Forkop сейчас не запущен — проверка покажет доступность без обхода.");
    }

    if (!capabilities.curl) {
      notes.push("На роутере нет curl: тайминги TCP/TLS и коды ответов будут приблизительными. Поставьте пакет curl для точной диагностики.");
    }

    if (!capabilities.netns) {
      notes.push("Режим «от имени клиента» недоступен: ip netns не поддерживается этой прошивкой.");
    }

    var checkTab = E("button", { class: "fkpsc-tab active", type: "button", role: "tab", "aria-selected": "true" }, "Проверка сервисов");
    var fixTab = E("button", { class: "fkpsc-tab", type: "button", role: "tab", "aria-selected": "false" }, "Фикс Forkop");
    var listsTab = E("button", { class: "fkpsc-tab", type: "button", role: "tab", "aria-selected": "false" }, "Списки");
    var checkPage = E("div", { class: "fkpsc-page active" }, [
      notes.length ? E("div", { class: "fkpsc-note" }, notes.map(function (note) {
        return E("div", {}, note);
      })) : "",
      E("div", { class: "fkpsc-card" }, [
        E("h3", {}, "Параметры проверки"),
        E("div", { class: "fkpsc-mode" }, [
          E("label", {}, [modeRouter, E("span", {}, " С роутера (быстро)")]),
          E("label", {}, [
            modeNetns,
            E("span", {}, " От имени клиента в LAN"),
            clientIpInput,
          ]),
        ]),
        E("h3", { style: "margin-top:1em" }, "Проверить свой IP или домен"),
        E("p", { class: "fkpsc-dim" },
          "Введите любую цель и TCP-порт. Проверка покажет доступность и подтвердит, попало ли соединение в sing-box. Используется выбранный выше режим."),
        E("div", { class: "fkpsc-custom-form" }, [
          customTargetInput,
          E("label", { class: "fkpsc-custom-port-label" }, ["Порт", customPortInput]),
          customCheckButton,
        ]),
        customResultNode,
        E("h3", {}, "Сервисы"),
        E("div", { class: "fkpsc-service-tools" }, [serviceSearch, quickPreset, udpPreset]),
        picker,
        E("div", { class: "fkpsc-actions" }, [
          runButton,
          retryButton,
          stopButton,
          E("button", {
            class: "cbi-button",
            click: function () { setAll(true); },
          }, "Выбрать все"),
          E("button", {
            class: "cbi-button",
            click: function () { setAll(false); },
          }, "Снять все"),
          progressWrap,
          progressText,
        ]),
      ]),
      summaryNode,
      metaNode,
      tilesNode,
    ]);
    var fixPage = E("div", { class: "fkpsc-page" }, [maintenancePanel]);
    var profilesEditor = E("textarea", {
      class: "cbi-input-textarea fkpsc-editor",
      spellcheck: "false",
      wrap: "off",
    }, profilesData && profilesData.config ? JSON.stringify(profilesData.config, null, 2) : "");
    var saveProfilesButton = E("button", { class: "cbi-button cbi-button-action important", type: "button" }, "Сохранить список");
    var resetProfilesButton = E("button", { class: "cbi-button cbi-button-negative", type: "button" }, "Вернуть встроенный");

    saveProfilesButton.addEventListener("click", function () {
      var parsed;
      try {
        parsed = JSON.parse(profilesEditor.value);
      } catch (error) {
        ui.addNotification(null, E("p", {}, "Ошибка JSON: " + error.message), "error");
        return;
      }
      saveProfilesButton.disabled = true;
      saveProfilesButton.textContent = "Сохраняю…";
      callBin(["profiles-save", JSON.stringify(parsed)]).then(function (result) {
        if (!result.success) {
          throw new Error(result.message || "не удалось сохранить список");
        }
        ui.addNotification(null, E("p", {}, result.message + ". Страница будет обновлена."), "info");
        window.setTimeout(function () { window.location.reload(); }, 700);
      }).catch(function (error) {
        ui.addNotification(null, E("p", {}, error.message || "Не удалось сохранить список"), "error");
        saveProfilesButton.disabled = false;
        saveProfilesButton.textContent = "Сохранить список";
      });
    });

    resetProfilesButton.addEventListener("click", function () {
      if (!window.confirm("Удалить пользовательский список и вернуть встроенный?")) {
        return;
      }
      resetProfilesButton.disabled = true;
      callBin(["profiles-reset"]).then(function (result) {
        if (!result.success) {
          throw new Error(result.message || "не удалось восстановить список");
        }
        window.location.reload();
      }).catch(function (error) {
        ui.addNotification(null, E("p", {}, error.message || "Не удалось восстановить список"), "error");
        resetProfilesButton.disabled = false;
      });
    });

    var listsPage = E("div", { class: "fkpsc-page" }, [
      E("div", { class: "fkpsc-card" }, [
        E("h3", {}, "Списки проверок"),
        E("p", { class: "fkpsc-dim" }, "Редактируйте профили и цели в JSON. Поддерживаются kind: https, http, tcp, udp и udp_dns. Пользовательский список хранится в /etc/forkop-servicecheck/profiles.json и сохраняется при обновлении модуля."),
        E("p", { class: "fkpsc-dim" }, "Сейчас используется: " + (profilesData && profilesData.source === "custom" ? "пользовательский список" : "встроенный список")),
        profilesData ? profilesEditor : E("div", { class: "alert-message error" }, "Backend не отдал список проверок."),
        E("div", { class: "fkpsc-actions", style: "margin-top:1em" }, [saveProfilesButton, resetProfilesButton]),
      ]),
    ]);

    function showPage(name) {
      var showFix = name === "fix";
      var showLists = name === "lists";
      var showCheck = !showFix && !showLists;
      checkTab.classList.toggle("active", showCheck);
      fixTab.classList.toggle("active", showFix);
      listsTab.classList.toggle("active", showLists);
      checkTab.setAttribute("aria-selected", showCheck ? "true" : "false");
      fixTab.setAttribute("aria-selected", showFix ? "true" : "false");
      listsTab.setAttribute("aria-selected", showLists ? "true" : "false");
      checkPage.classList.toggle("active", showCheck);
      fixPage.classList.toggle("active", showFix);
      listsPage.classList.toggle("active", showLists);
    }

    checkTab.addEventListener("click", function () { showPage("check"); });
    fixTab.addEventListener("click", function () { showPage("fix"); });
    listsTab.addEventListener("click", function () { showPage("lists"); });

    return E("div", { class: "cbi-map fkpsc" }, [
      E("div", { class: "fkpsc-hero" }, [
        E("h2", {}, "Forkop Service Check"),
        E("p", {}, "Проверка идёт тем же путём, что и трафик клиента: имя резолвится через dnsmasq и sing-box, " +
          "а соединение попадает в цепочку mangle_output и уходит в tproxy. Нажмите на плитку сервиса, " +
          "чтобы увидеть, на каком этапе всё сломалось — DNS, TCP, TLS или HTTP."),
        E("div", { class: "fkpsc-badges" }, [
          E("span", { class: "fkpsc-badge" }, "интерфейс v" + UI_VERSION),
          E("span", { class: "fkpsc-badge" }, capabilities.forkop_running ? "● Forkop запущен" : "○ Forkop остановлен"),
          E("span", { class: "fkpsc-badge" }, capabilities.curl ? "HTTPS: точный" : "HTTPS: упрощённый"),
          E("span", { class: "fkpsc-badge" }, capabilities.netns ? "netns доступен" : "только роутер"),
        ]),
      ]),
      E("div", { class: "fkpsc-tabs", role: "tablist" }, [checkTab, fixTab, listsTab]),
      checkPage,
      fixPage,
      listsPage,
    ]);
  },
});
