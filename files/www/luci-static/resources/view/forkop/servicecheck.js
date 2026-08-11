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
var POLL_INTERVAL_MS = 1500;
var JOB_TIMEOUT_MS = 10 * 60 * 1000;

var STATE_LABEL = {
  success: "работает",
  warning: "замечания",
  error: "не работает",
  skipped: "пропущено",
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
    ".fkpsc { --ok:#2f9e44; --warn:#e8a33d; --err:#e03131; --skip:#868e96; --accent:#4a90d9; }",
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

    /* --- сводка --- */
    ".fkpsc-summary { display: flex; flex-wrap: wrap; gap: .5em; margin: 0 0 1em; }",
    ".fkpsc-sum { display: inline-flex; align-items: baseline; gap: .4em; padding: .35em .75em; border-radius: 8px; background: rgba(127,127,127,.1); font-size: .92em; }",
    ".fkpsc-sum b { font-size: 1.15em; }",
    ".fkpsc-sum.ok b { color: var(--ok); }",
    ".fkpsc-sum.warn b { color: var(--warn); }",
    ".fkpsc-sum.err b { color: var(--err); }",

    /* --- сетка плиток --- */
    ".fkpsc-tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(255px, 1fr)); gap: .75em; align-items: start; }",
    ".fkpsc-tile { border: 1px solid rgba(127,127,127,.3); border-radius: 10px; background: rgba(127,127,127,.05); overflow: hidden; cursor: pointer; transition: transform .12s ease, box-shadow .12s ease, border-color .12s ease; position: relative; }",
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
    ".fkpsc-row { border-left: 3px solid var(--skip); border-radius: 0 6px 6px 0; background: rgba(127,127,127,.07); padding: .6em .8em; margin-bottom: .5em; }",
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

  if (item.kind === "tcp" || item.kind === "udp") {
    stages.push({
      name: item.kind === "udp" ? "UDP" : "TCP",
      state: !dnsOk ? "skip" : (tcpFailed ? "fail" : (item.state === "skipped" ? "skip" : "ok")),
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
    ]);
  },

  render: function (data) {
    injectStyles();

    var capabilities = data[0];
    var catalogue = data[1];

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

    var runButton = E("button", { class: "cbi-button cbi-button-action important" }, "Проверить сервис");
    var xhttpButton = E("button", {
      class: "cbi-button",
      click: function () {
        xhttpButton.disabled = true;
        xhttpButton.textContent = "Патчим…";
        callBin(["xhttp_patch"]).then(function (result) {
          ui.addNotification(null, E("p", {}, result.output || "xHTTP hotfix установлен"), result.success ? "info" : "warning");
        }).catch(function (error) {
          ui.addNotification(null, E("p", {}, error.message || "Не удалось установить xHTTP hotfix"), "error");
        }).finally(function () {
          xhttpButton.disabled = false;
          xhttpButton.textContent = "Починить импорт xHTTP";
        });
      },
    }, "Починить импорт xHTTP");
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

    return E("div", { class: "cbi-map fkpsc" }, [
      E("h2", {}, "Проверка сервисов Forkop"),
      E("div", { class: "fkpsc-intro" }, [
        E("p", {}, "Проверка идёт тем же путём, что и трафик клиента: имя резолвится через dnsmasq и sing-box, " +
          "а соединение попадает в цепочку mangle_output и уходит в tproxy. Нажмите на плитку сервиса, " +
          "чтобы увидеть, на каком этапе всё сломалось — DNS, TCP, TLS или HTTP."),
      ]),
      notes.length ? E("div", { class: "fkpsc-note" }, notes.map(function (note) {
        return E("div", {}, note);
      })) : "",
      E("div", { class: "fkpsc-mode" }, [
        E("label", {}, [modeRouter, E("span", {}, " С роутера (быстро, рекомендуется)")]),
        E("label", {}, [
          modeNetns,
          E("span", {}, " От имени клиента в LAN"),
          clientIpInput,
        ]),
      ]),
      E("h3", {}, "Сервисы"),
      picker,
      E("div", { class: "fkpsc-actions" }, [
        runButton,
        xhttpButton,
        stopButton,
        E("button", {
          class: "cbi-button",
          click: function () {
            setAll(true);
          },
        }, "Выбрать все"),
        E("button", {
          class: "cbi-button",
          click: function () {
            setAll(false);
          },
        }, "Снять все"),
        progressWrap,
        progressText,
      ]),
      summaryNode,
      metaNode,
      tilesNode,
    ]);
  },
});
