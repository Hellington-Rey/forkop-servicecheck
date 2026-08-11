#!/usr/bin/env ucode

// Forkop Service Check - probe engine.
//
// Проверяет доступность сервисов так, как это делает клиент сети: имя резолвится
// через тот же dnsmasq -> sing-box, а соединение уходит из роутера и попадает в
// цепочку mangle_output -> tproxy, то есть тем же путём, что трафик из LAN.
// В режиме netns трафик реально входит через br-lan из отдельного namespace,
// что дополнительно воспроизводит правила секций, привязанные к source IP.

let fs = require("fs");

const LIB_DIR = getenv("FORKOP_SC_LIB") || "/usr/lib/forkop-servicecheck";
const ENGINE = LIB_DIR + "/probe.uc";
// Пользовательские профили в /etc имеют приоритет: пакет обновляет только свою
// копию в /usr/share, поэтому правки переживают переустановку.
const PROFILES_OVERRIDE = "/etc/forkop-servicecheck/profiles.json";
const PROFILES_DEFAULT = "/usr/share/forkop-servicecheck/profiles.json";
const STATE_DIR = getenv("FORKOP_SC_STATE_DIR") || "/var/run/forkop-servicecheck";
const FORKOP_BIN = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const SING_BOX_CONFIG = getenv("FORKOP_SC_SING_BOX_CONFIG") || "/etc/sing-box/config.json";
const NETNS_NAME = getenv("FORKOP_SC_NETNS") || "fkpsc";
const NETNS_VETH_HOST = "fkpsc0";
const NETNS_VETH_PEER = "fkpsc1";
const XHTTP_PATCH = "/usr/lib/forkop-servicecheck/xhttp_hotfix.sh";

const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const DNS_TIMEOUT = 3;
const CONNECT_TIMEOUT = 7;
const TOTAL_TIMEOUT = 15;
const SLOW_THRESHOLD_MS = 5000;
const JOB_MAX_AGE = 1800;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    if (status < 0)
        return 1;
    return status > 255 ? int(status / 256) : status;
}

function now_ms() {
    let value = null;
    try {
        value = clock(true);
    }
    catch (e) {
        value = null;
    }
    if (type(value) != "array")
        value = clock();
    if (type(value) != "array")
        return 0;
    return value[0] * 1000 + int(value[1] / 1000000);
}

function now_seconds() {
    let value = clock();
    return type(value) == "array" ? int(value[0]) : 0;
}

function capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { status, output: data == null ? "" : as_string(data) };
}

function capture_args(args, merge_stderr) {
    return capture(command_from_args(args) + (merge_stderr ? " 2>&1" : " 2>/dev/null"));
}

function run_quiet(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function command_exists(name) {
    return run_quiet([ "command", "-v", as_string(name) ]);
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function xhttp_patch() {
    if (fs.stat(XHTTP_PATCH) == null) {
        write_json({ success: false, message: "xHTTP-патч не установлен в пакет" });
        return 1;
    }
    let result = capture_args([ "sh", XHTTP_PATCH ], true);
    write_json({ success: result.status == 0, code: result.status, output: trim(as_string(result.output)) });
    return result.status;
}

function available_fixes() {
    return [
        {
            id: "xhttp_import",
            title: "Фикс xHTTP импорта подписок",
            description: "Исправляет импорт дополнительных полей xHTTP из подписок в parser.uc Forkop.",
            risk: "Создаётся резервная копия parser.uc; патч проверяется через ucode до замены."
        }
    ];
}

function list_fixes() {
    write_json({ success: true, fixes: available_fixes() });
    return 0;
}

function run_fix(id) {
    if (as_string(id) == "xhttp_import")
        return xhttp_patch();
    write_json({ success: false, message: "неизвестный фикс Forkop" });
    return 1;
}

function parse_json(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function read_json_file(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? null : parse_json(data);
}

function trim_newlines(value) {
    return replace(as_string(value), /[\r\n]+$/g, "");
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

// curl отдаёт тайминги как "0.123". Собирать число по частям нельзя: деление двух
// целых в ucode целочисленное, и дробная часть схлопывается в ноль. Умножение же
// приводит числовую строку к double, поэтому проверяем формат и умножаем.
function number_value(value) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+(\.[0-9]+)?$/) == null)
        return 0;
    return value * 1;
}

function temp_path(suffix) {
    return sprintf("/tmp/.forkop-sc-%d-%d.%s", now_seconds(), int(now_ms() % 1000000), as_string(suffix));
}

function ensure_state_dir() {
    run_quiet([ "mkdir", "-p", STATE_DIR ]);
}

function profiles_file() {
    let override = getenv("FORKOP_SC_PROFILES");
    if (as_string(override) != "")
        return as_string(override);
    if (fs.stat(PROFILES_OVERRIDE) != null)
        return PROFILES_OVERRIDE;
    return PROFILES_DEFAULT;
}

// ---------------------------------------------------------------------------
// Сеть: разбор адресов
// ---------------------------------------------------------------------------

function valid_ipv4(value) {
    value = trim(as_string(value));
    let matched = match(value, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
    if (matched == null)
        return false;
    for (let i = 1; i <= 4; i++)
        if (int(matched[i]) > 255)
            return false;
    return true;
}

function ipv4_to_int(value) {
    let parts = split(trim(as_string(value)), ".");
    if (length(parts) != 4)
        return -1;
    return int(parts[0]) * 16777216 + int(parts[1]) * 65536 + int(parts[2]) * 256 + int(parts[3]);
}

function int_to_ipv4(value) {
    value = int(value);
    let a = int(value / 16777216) % 256;
    let b = int(value / 65536) % 256;
    let c = int(value / 256) % 256;
    let d = value % 256;
    return sprintf("%d.%d.%d.%d", a, b, c, d);
}

function prefix_mask(prefix) {
    prefix = int(prefix);
    if (prefix <= 0)
        return 0;
    if (prefix >= 32)
        return 4294967295;
    return (4294967295 << (32 - prefix)) & 4294967295;
}

function ipv4_in_cidr(ip, cidr) {
    let parts = split(as_string(cidr), "/");
    if (length(parts) != 2 || !valid_ipv4(ip) || !valid_ipv4(parts[0]))
        return false;
    let mask = prefix_mask(parts[1]);
    return (ipv4_to_int(ip) & mask) == (ipv4_to_int(parts[0]) & mask);
}

function ipv4_in_any_cidr(ip, cidrs) {
    for (let cidr in array_or_empty(cidrs))
        if (ipv4_in_cidr(ip, cidr))
            return true;
    return false;
}

// ---------------------------------------------------------------------------
// Окружение роутера
// ---------------------------------------------------------------------------

function uci_get(path) {
    let result = capture_args([ "uci", "-q", "get", as_string(path) ]);
    return result.status == 0 ? trim_newlines(result.output) : "";
}

function lan_interface() {
    let configured = words(uci_get("forkop.settings.source_network_interfaces"));
    if (length(configured) > 0)
        return configured[0];
    return "br-lan";
}

function interface_ipv4(interface) {
    let output = capture_args([ "ip", "-4", "-o", "addr", "show", "dev", as_string(interface) ], false).output;
    for (let line in split(output, "\n")) {
        let matched = match(trim(as_string(line)), /inet[ \t]+([0-9.]+)\/([0-9]+)/);
        if (matched != null)
            return { address: matched[1], prefix: int(matched[2]) };
    }
    return null;
}

function fakeip_ranges() {
    let ranges = [];
    let config = read_json_file(SING_BOX_CONFIG);
    let dns = object_or_empty(object_or_empty(config).dns);

    for (let server in array_or_empty(dns.servers)) {
        server = object_or_empty(server);
        if (as_string(server.type) == "fakeip") {
            if (as_string(server.inet4_range) != "")
                push(ranges, as_string(server.inet4_range));
        }
    }

    let legacy = object_or_empty(dns.fakeip);
    if (as_string(legacy.inet4_range) != "")
        push(ranges, as_string(legacy.inet4_range));

    if (length(ranges) == 0)
        push(ranges, "198.18.0.0/15");

    return ranges;
}

function forkop_running() {
    let result = capture_args([ FORKOP_BIN, "get_status" ], false);
    if (result.status != 0)
        return false;
    let status = object_or_empty(parse_json(result.output));
    return int(status.running) == 1;
}

// Сборки busybox сильно разнятся: где-то nc умеет -z и -w, где-то это
// "Usage: nc [IPADDR PORT]" вообще без флагов. Пробуем от лучшего к худшему.
function nc_option_rejected(command) {
    let output = lc(as_string(capture(command).output));
    return index(output, "invalid option") >= 0 || index(output, "unrecognized option") >= 0 ||
        index(output, "usage:") >= 0 || index(output, "bad port") >= 0;
}

function detect_nc_mode() {
    if (!command_exists("nc"))
        return "none";
    if (!nc_option_rejected("nc -z -w 1 127.0.0.1 1 2>&1"))
        return "zero";
    if (!nc_option_rejected("nc -w 1 127.0.0.1 1 2>&1"))
        return "wait";
    return "plain";
}

function capabilities() {
    let interface = lan_interface();
    let address = interface_ipv4(interface);
    let nc_mode = detect_nc_mode();

    return {
        curl: command_exists("curl"),
        uclient_fetch: command_exists("uclient-fetch") || command_exists("wget"),
        dig: command_exists("dig"),
        nslookup: command_exists("nslookup"),
        nc: nc_mode != "none",
        nc_mode,
        timeout_cmd: command_exists("timeout"),
        netns: run_quiet([ "ip", "netns", "list" ]) && command_exists("ip"),
        lan_interface: interface,
        lan_address: address == null ? "" : address.address,
        lan_prefix: address == null ? 0 : address.prefix,
        fakeip_ranges: fakeip_ranges(),
        forkop_running: forkop_running(),
        profiles_version: int(object_or_empty(read_json_file(profiles_file())).version || 0)
    };
}

// ---------------------------------------------------------------------------
// Профили
// ---------------------------------------------------------------------------

function load_profiles() {
    let data = object_or_empty(read_json_file(profiles_file()));
    return array_or_empty(data.profiles);
}

function target_label(target) {
    target = object_or_empty(target);
    if (as_string(target.label) != "")
        return as_string(target.label);
    if (as_string(target.kind) == "tcp" || as_string(target.kind) == "udp" || as_string(target.kind) == "udp_dns")
        return sprintf("%s:%d", as_string(target.host), int(target.port || 443));
    return as_string(target.host) + as_string(target.path || "/");
}

function target_url(target) {
    target = object_or_empty(target);
    let scheme = as_string(target.kind) == "http" ? "http" : "https";
    let port = int(target.port || 0);
    let host = as_string(target.host);
    let authority = port > 0 && port != 443 && port != 80 ? host + ":" + as_string(port) : host;
    let path = as_string(target.path || "/");
    if (substr(path, 0, 1) != "/")
        path = "/" + path;
    return scheme + "://" + authority + path;
}

// ---------------------------------------------------------------------------
// Пробы
// ---------------------------------------------------------------------------

function prefixed_args(ctx, args) {
    let full = [];
    for (let arg in array_or_empty(ctx.exec_prefix))
        push(full, arg);
    for (let arg in args)
        push(full, arg);
    return full;
}

function probe_dns(ctx, host) {
    if (valid_ipv4(host))
        return { ok: true, ip: host, fakeip: false, ms: 0, error: "", skipped: true };

    let started = now_ms();
    let addresses = [];

    if (ctx.tools.dig) {
        let result = capture_args(prefixed_args(ctx, [
            "dig", "@" + ctx.resolver, as_string(host), "A", "+short",
            "+timeout=" + as_string(DNS_TIMEOUT), "+tries=1"
        ]), false);
        for (let line in split(result.output, "\n")) {
            line = trim(as_string(line));
            if (valid_ipv4(line))
                push(addresses, line);
        }
    }
    else if (ctx.tools.nslookup) {
        let result = capture_args(prefixed_args(ctx, [ "nslookup", as_string(host), ctx.resolver ]), true);
        // busybox печатает "Address 1: 1.2.3.4 host.example", хвост после адреса игнорируем.
        for (let line in split(result.output, "\n")) {
            let matched = match(trim(as_string(line)), /^Address[ \t0-9]*:[ \t]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
            if (matched != null && valid_ipv4(matched[1]) && matched[1] != ctx.resolver)
                push(addresses, matched[1]);
        }
    }

    let elapsed = now_ms() - started;

    if (length(addresses) == 0)
        return { ok: false, ip: "", fakeip: false, ms: elapsed, error: "нет A-записи" };

    return {
        ok: true,
        ip: addresses[0],
        all: addresses,
        fakeip: ipv4_in_any_cidr(addresses[0], ctx.fakeip_ranges),
        ms: elapsed,
        error: ""
    };
}

function curl_failure_verdict(status, output) {
    output = lc(as_string(output));

    if (status == 6)
        return { verdict: "dns_fail", message: "имя не резолвится" };
    if (status == 7)
        return { verdict: "tcp_refused", message: "не удалось установить TCP-соединение" };
    if (status == 28)
        return { verdict: "timeout", message: "таймаут соединения" };
    // Три "ошибки TLS" у curl имеют совершенно разные причины, и валить их в одну
    // строку - значит прятать диагноз. 35 - хендшейк оборвали (типовая подпись DPI),
    // 51 - сертификат отклонён, 60 - сертификат не удалось проверить, а это почти
    // всегда сбитые часы роутера (нет RTC) или отсутствующий ca-bundle.
    if (status == 35)
        return { verdict: "tls_handshake", message: "TLS-хендшейк оборван — похоже на DPI или несовместимый TLS" };
    if (status == 51)
        return { verdict: "tls_cert_rejected", message: "сертификат сервера отклонён" };
    if (status == 60)
        return { verdict: "tls_cert_untrusted", message: "сертификат не проверен — проверьте часы роутера и наличие ca-bundle" };
    if (status == 52)
        return { verdict: "tls_reset", message: "сервер закрыл соединение без ответа" };
    if (status == 56)
        return { verdict: "tls_reset", message: "соединение сброшено при передаче данных" };
    if (status == 47)
        return { verdict: "redirect_loop", message: "сервис отвечает, но перенаправляет по кругу" };
    if (index(output, "connection reset") >= 0)
        return { verdict: "tls_reset", message: "соединение сброшено" };

    return { verdict: "failed", message: trim(as_string(output)) != "" ? trim(as_string(output)) : sprintf("curl завершился с кодом %d", status) };
}

function http_probe_curl(ctx, target) {
    let url = target_url(target);
    let format = "%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{remote_ip}";
    let args = prefixed_args(ctx, [
        "curl", "-sS", "-o", "/dev/null", "-L", "--max-redirs", "5",
        "--connect-timeout", as_string(CONNECT_TIMEOUT),
        "--max-time", as_string(TOTAL_TIMEOUT),
        "-A", USER_AGENT,
        "-w", format,
        url
    ]);
    let error_file = temp_path("curl-err");
    let result = capture(command_from_args(args) + " 2>" + shell_quote(error_file));
    let stderr = as_string(fs.readfile(error_file) || "");
    fs.unlink(error_file);

    if (result.status != 0) {
        let failure = curl_failure_verdict(result.status, stderr);
        return {
            reached: false,
            code: 0,
            remote_ip: "",
            tcp_ms: 0,
            tls_ms: 0,
            total_ms: 0,
            verdict: failure.verdict,
            message: failure.message
        };
    }

    let fields = split(trim(as_string(result.output)), "|");
    if (length(fields) < 7)
        return { reached: false, code: 0, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: 0, verdict: "failed", message: "не удалось разобрать ответ curl" };

    let namelookup = number_value(fields[1]) * 1000;
    let connect = number_value(fields[2]) * 1000;
    let appconnect = number_value(fields[3]) * 1000;
    let total = number_value(fields[5]) * 1000;

    return {
        reached: true,
        code: int(fields[0]),
        remote_ip: as_string(fields[6]),
        dns_ms: int(namelookup),
        tcp_ms: int(connect > namelookup ? connect - namelookup : connect),
        tls_ms: int(appconnect > connect ? appconnect - connect : 0),
        total_ms: int(total),
        verdict: "",
        message: ""
    };
}

function uclient_failure_verdict(output) {
    output = lc(as_string(output));

    if (index(output, "download completed") >= 0)
        return null;
    if (index(output, "failed to resolve") >= 0 || index(output, "name or service not known") >= 0)
        return { verdict: "dns_fail", message: "имя не резолвится" };
    if (index(output, "connection refused") >= 0)
        return { verdict: "tcp_refused", message: "соединение отклонено" };
    if (index(output, "timed out") >= 0 || index(output, "timeout") >= 0)
        return { verdict: "timeout", message: "таймаут соединения" };
    if (index(output, "connection reset") >= 0)
        return { verdict: "tls_reset", message: "соединение сброшено" };
    if (index(output, "ssl") >= 0 || index(output, "tls") >= 0)
        return { verdict: "tls_error", message: "ошибка TLS" };
    if (index(output, "failed to establish connection") >= 0)
        return { verdict: "timeout", message: "не удалось установить соединение" };

    return { verdict: "failed", message: trim(as_string(output)) };
}

function http_probe_uclient(ctx, target) {
    let url = target_url(target);
    let binary = command_exists("uclient-fetch") ? "uclient-fetch" : "wget";
    let started = now_ms();
    // Без -q: именно в stderr uclient-fetch и busybox wget пишут причину отказа,
    // а -T понимают обе реализации, в отличие от --timeout=.
    let result = capture_args(prefixed_args(ctx, [
        binary, "-T", as_string(CONNECT_TIMEOUT), "-O", "/dev/null", url
    ]), true);
    let elapsed = now_ms() - started;
    let output = as_string(result.output);

    let code_match = match(output, /HTTP error ([0-9]{3})/);
    if (code_match != null)
        return {
            reached: true,
            code: int(code_match[1]),
            remote_ip: "",
            tcp_ms: 0,
            tls_ms: 0,
            total_ms: elapsed,
            verdict: "",
            message: ""
        };

    if (result.status == 0)
        return {
            reached: true,
            code: 200,
            remote_ip: "",
            tcp_ms: 0,
            tls_ms: 0,
            total_ms: elapsed,
            verdict: "",
            message: "код ответа определён приблизительно (нет curl)"
        };

    let failure = uclient_failure_verdict(output);
    if (failure == null)
        return { reached: true, code: 200, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: elapsed, verdict: "", message: "" };

    return {
        reached: false,
        code: 0,
        remote_ip: "",
        tcp_ms: 0,
        tls_ms: 0,
        total_ms: elapsed,
        verdict: failure.verdict,
        message: failure.message
    };
}

// Проверка чистого TCP через curl. Протокол на порту нам безразличен: важно лишь,
// дошло ли дело до установленного соединения. curl это и говорит кодом выхода -
// 7 и 28 означают, что соединиться не удалось, а ошибки TLS уровнем выше (35, 52,
// 56) означают, что TCP как раз поднялся. Так обходимся без nc, флаги которого
// в busybox-сборках непредсказуемы.
function tcp_probe_curl(ctx, target) {
    let host = as_string(target.host);
    let port = int(target.port || 443);
    let url = "https://" + host + ":" + as_string(port) + "/";
    let args = prefixed_args(ctx, [
        "curl", "-sS", "-o", "/dev/null",
        "--connect-timeout", as_string(CONNECT_TIMEOUT),
        "--max-time", as_string(CONNECT_TIMEOUT + 2),
        "-w", "%{time_connect}|%{remote_ip}",
        url
    ]);
    let started = now_ms();
    let result = capture(command_from_args(args) + " 2>/dev/null");
    let elapsed = now_ms() - started;
    let status = result.status;

    let fields = split(trim(as_string(result.output)), "|");
    let connect_ms = length(fields) > 0 ? int(number_value(fields[0]) * 1000) : 0;
    let remote_ip = length(fields) > 1 ? as_string(fields[1]) : "";

    if (status == 6)
        return { reached: false, code: 0, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: elapsed, verdict: "dns_fail", message: "имя не резолвится" };

    if (status == 7)
        return { reached: false, code: 0, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: elapsed, verdict: "tcp_refused", message: "не удалось установить TCP-соединение" };

    if (status == 28)
        return { reached: false, code: 0, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: elapsed, verdict: "timeout", message: "таймаут TCP-соединения" };

    let measured = connect_ms > 0 ? connect_ms : elapsed;
    return { reached: true, code: 0, remote_ip, tcp_ms: measured, tls_ms: 0, total_ms: measured, verdict: "", message: "" };
}

function tcp_probe_nc(ctx, target) {
    let host = as_string(target.host);
    let port = as_string(int(target.port || 443));
    let mode = as_string(ctx.tools.nc_mode);
    let args = [];

    if (mode == "zero")
        args = [ "nc", "-z", "-w", as_string(CONNECT_TIMEOUT), host, port ];
    else if (mode == "wait")
        args = [ "nc", "-w", as_string(CONNECT_TIMEOUT), host, port ];
    else if (ctx.tools.timeout_cmd)
        args = [ "timeout", as_string(CONNECT_TIMEOUT), "nc", host, port ];
    else
        return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "nc без поддержки таймаута, а curl не установлен" };

    let started = now_ms();
    let status = normalize_status(system(command_from_args(prefixed_args(ctx, args)) + " </dev/null >/dev/null 2>&1"));
    let elapsed = now_ms() - started;

    if (status == 0)
        return { reached: true, code: 0, remote_ip: "", tcp_ms: elapsed, tls_ms: 0, total_ms: elapsed, verdict: "", message: "" };

    let timed_out = elapsed >= CONNECT_TIMEOUT * 1000 - 500;
    return {
        reached: false,
        code: 0,
        remote_ip: "",
        tcp_ms: 0,
        tls_ms: 0,
        total_ms: elapsed,
        verdict: timed_out ? "timeout" : "tcp_refused",
        message: timed_out ? "таймаут TCP-соединения" : "TCP-соединение отклонено"
    };
}

function tcp_probe(ctx, target) {
    if (ctx.tools.curl)
        return tcp_probe_curl(ctx, target);
    return tcp_probe_nc(ctx, target);
}

function udp_probe(ctx, target) {
    if (!ctx.tools.nc)
        return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "нет nc для UDP-проверки" };

    let started = now_ms();
    let args = [ "nc", "-u" ];
    if (ctx.tools.nc_mode == "zero")
        push(args, "-z");
    if (ctx.tools.nc_mode != "plain")
        push(args, "-w", "2");
    push(args, as_string(target.host), as_string(int(target.port || 0)));
    let status = normalize_status(system(command_from_args(prefixed_args(ctx, args)) + " </dev/null >/dev/null 2>&1"));
    let elapsed = now_ms() - started;

    // UDP не подтверждает доставку без ответа приложения. Это best-effort:
    // успешная отправка означает, что маршрут и локальный сокет доступны.
    if (status == 0)
        return { reached: true, code: 0, remote_ip: "", tcp_ms: elapsed, tls_ms: 0, total_ms: elapsed, verdict: "udp_unconfirmed", message: "UDP-пакет отправлен, но протокол не подтвердил доставку" };
    return { reached: true, code: 0, remote_ip: "", tcp_ms: elapsed, tls_ms: 0, total_ms: elapsed, verdict: "udp_unconfirmed", message: "UDP-ответ не получен; это не доказывает блокировку трафика" };
}

function udp_dns_probe(ctx, target) {
    if (!ctx.tools.nslookup)
        return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "нет nslookup для двусторонней UDP-проверки" };

    let query = as_string(target.query || "discord.com");
    let started = now_ms();
    let result = capture_args(prefixed_args(ctx, [ "nslookup", query, as_string(target.host) ]), true);
    let elapsed = now_ms() - started;
    let output = lc(as_string(result.output));
    let ok = result.status == 0 && index(output, "address") >= 0;
    return {
        reached: ok,
        code: 0,
        remote_ip: as_string(target.host),
        tcp_ms: elapsed,
        tls_ms: 0,
        total_ms: elapsed,
        verdict: ok ? "" : "timeout",
        message: ok ? "получен ответ DNS по UDP" : "нет ответа DNS по UDP"
    };
}

function connection_probe(ctx, target) {
    if (as_string(target.kind) == "udp_dns")
        return udp_dns_probe(ctx, target);
    if (as_string(target.kind) == "udp")
        return udp_probe(ctx, target);
    if (as_string(target.kind) == "tcp") {
        if (!ctx.tools.curl && !ctx.tools.nc)
            return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "нет ни curl, ни nc" };
        return tcp_probe(ctx, target);
    }

    if (ctx.tools.curl)
        return http_probe_curl(ctx, target);
    if (ctx.tools.uclient_fetch)
        return http_probe_uclient(ctx, target);

    return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "нет ни curl, ни uclient-fetch" };
}

// ---------------------------------------------------------------------------
// Определение маршрута через Clash API
// ---------------------------------------------------------------------------

function clash_connections() {
    let result = capture_args([ FORKOP_BIN, "clash_api", "get_connections" ], false);
    if (result.status != 0)
        return [];

    let parsed = parse_json(result.output);
    if (type(parsed) == "array")
        return parsed;

    return array_or_empty(object_or_empty(parsed).connections);
}

function outbound_for(connections, host, remote_ip) {
    host = lc(as_string(host));
    remote_ip = as_string(remote_ip);

    for (let connection in connections) {
        connection = object_or_empty(connection);
        let metadata = object_or_empty(connection.metadata);
        let connection_host = lc(as_string(metadata.host));
        let destination = as_string(metadata.destinationIP);

        if ((connection_host != "" && connection_host == host) ||
            (remote_ip != "" && destination == remote_ip)) {
            let chains = array_or_empty(connection.chains);
            if (length(chains) > 0)
                return join(" ← ", chains);
        }
    }

    return "";
}

// ---------------------------------------------------------------------------
// Вердикты
// ---------------------------------------------------------------------------

function expected_codes(target) {
    let expect = array_or_empty(object_or_empty(target).expect);
    return length(expect) > 0 ? expect : [ 200 ];
}

function code_expected(code, target) {
    code = int(code);
    for (let value in expected_codes(target))
        if (int(value) == code)
            return true;
    return false;
}

function target_verdict(target, dns, connection) {
    if (as_string(connection.verdict) == "skipped")
        return { state: "skipped", verdict: "skipped", message: as_string(connection.message) };

    if (as_string(connection.verdict) == "udp_unconfirmed")
        return { state: "warning", verdict: "udp_unconfirmed", message: as_string(connection.message) };

    if (!dns.ok && !valid_ipv4(as_string(target.host)))
        return { state: "error", verdict: "dns_fail", message: "DNS не отдал адрес: " + as_string(dns.error) };

    if (!connection.reached) {
        let verdict = as_string(connection.verdict);
        // Круг редиректов означает, что сервис отвечает: сеть до него рабочая,
        // поэтому это замечание, а не отказ.
        if (verdict == "redirect_loop")
            return { state: "warning", verdict, message: as_string(connection.message) };
        return { state: "error", verdict: verdict != "" ? verdict : "failed", message: as_string(connection.message) };
    }

    if (as_string(target.kind) == "tcp" || as_string(target.kind) == "udp" || as_string(target.kind) == "udp_dns")
        return int(connection.total_ms) > SLOW_THRESHOLD_MS
            ? { state: "warning", verdict: "slow", message: "соединение установлено, но медленно" }
            : { state: "success", verdict: "ok", message: "" };

    let code = int(connection.code);
    let expected = code_expected(code, target);

    // Мы проверяем достижимость, а не семантику API: раз пришёл любой HTTP-ответ,
    // значит DNS, TCP, TLS и HTTP отработали и путь до сервиса живой. Коды вроде
    // 404 на голом корне CDN - это норма, а не проблема сети. Особые случаи ниже.
    if (code >= 500)
        return { state: "warning", verdict: "http_server_error", message: sprintf("сервис отвечает ошибкой %d", code) };

    if (!expected && (code == 403 || code == 451))
        return { state: "warning", verdict: "geo_blocked", message: sprintf("ответ %d — похоже на блокировку по IP или региону", code) };

    if (int(connection.total_ms) > SLOW_THRESHOLD_MS)
        return { state: "warning", verdict: "slow", message: sprintf("работает, но медленно: %d мс", int(connection.total_ms)) };

    if (!expected)
        return { state: "success", verdict: "ok", message: sprintf("ответ %d — нетипичный, но соединение проходит", code) };

    return { state: "success", verdict: "ok", message: "" };
}

function service_state(items) {
    let required_total = 0;
    let required_ok = 0;
    let has_warning = false;

    for (let item in items) {
        if (item.optional || item.state == "skipped")
            continue;

        required_total++;
        if (item.state == "success")
            required_ok++;
        else if (item.state == "warning") {
            required_ok++;
            has_warning = true;
        }
    }

    if (required_total == 0)
        return { state: "warning", description: "проверить не удалось" };
    if (required_ok == 0)
        return { state: "error", description: "не работает" };
    if (required_ok < required_total)
        return { state: "warning", description: sprintf("работает частично (%d из %d)", required_ok, required_total) };
    if (has_warning)
        return { state: "warning", description: "работает с замечаниями" };

    return { state: "success", description: "работает" };
}

// ---------------------------------------------------------------------------
// Запуск проверки
// ---------------------------------------------------------------------------

// ВАЖНО: в ucode нет подъёма объявлений - функция, объявленная ниже по файлу,
// не видна объявленной выше (вызов компилируется как обращение к глобали и падает
// в рантайме). Поэтому порядок объявлений здесь значим: сначала зависимости.

function netns_teardown() {
    run_quiet([ "ip", "netns", "del", NETNS_NAME ]);
    run_quiet([ "ip", "link", "del", NETNS_VETH_HOST ]);
    run_quiet([ "rm", "-rf", "/etc/netns/" + NETNS_NAME ]);
}

function leased_addresses() {
    let leases = {};
    let data = fs.readfile("/tmp/dhcp.leases");
    if (data == null)
        return leases;

    for (let line in split(as_string(data), "\n")) {
        let fields = words(line);
        if (length(fields) >= 3 && valid_ipv4(fields[2]))
            leases[fields[2]] = true;
    }

    return leases;
}

function address_free(candidate, leases) {
    if (leases[candidate])
        return false;
    // Не используем ICMP: некоторые провайдеры и сетевые фильтры реагируют на
    // массовые echo-запросы. Проверяем только ARP/маршрут через HTTPS.
    if (command_exists("curl")) {
        let result = capture_args([ "curl", "-k", "-sS", "-o", "/dev/null",
            "--connect-timeout", "1", "--max-time", "2", "https://" + candidate + "/" ], false);
        // Любой ответ HTTPS означает занятый адрес; ошибки маршрута/таймаута
        // оставляют возможность использовать кандидат.
        return result.status == 6 || result.status == 7 || result.status == 28;
    }
    return true;
}

function pick_client_ip(caps, requested) {
    requested = as_string(requested);
    if (valid_ipv4(requested))
        return requested;

    let prefix = int(caps.lan_prefix);
    if (!valid_ipv4(caps.lan_address) || prefix < 16 || prefix > 30)
        return "";

    let mask = prefix_mask(prefix);
    let router_value = ipv4_to_int(caps.lan_address);
    let network = router_value & mask;
    let size = 1 << (32 - prefix);
    let broadcast = network + size - 1;
    let leases = leased_addresses();

    // Берём адреса с верхнего края подсети - там DHCP-пул OpenWrt заканчивается раньше.
    for (let offset = 1; offset <= 8; offset++) {
        let candidate_value = broadcast - offset;
        if (candidate_value <= network || candidate_value == router_value)
            continue;
        let candidate = int_to_ipv4(candidate_value);
        if (address_free(candidate, leases))
            return candidate;
    }

    return "";
}

function netns_setup(caps, requested_ip) {
    if (!caps.netns)
        return { ok: false, error: "режим клиента недоступен: нет поддержки ip netns" };

    netns_teardown();

    let client_ip = pick_client_ip(caps, requested_ip);
    if (client_ip == "")
        return { ok: false, error: "не удалось подобрать свободный IP в LAN" };

    let prefix = as_string(int(caps.lan_prefix));
    let steps = [
        [ "ip", "netns", "add", NETNS_NAME ],
        [ "ip", "link", "add", NETNS_VETH_HOST, "type", "veth", "peer", "name", NETNS_VETH_PEER ],
        [ "ip", "link", "set", NETNS_VETH_PEER, "netns", NETNS_NAME ],
        [ "ip", "link", "set", NETNS_VETH_HOST, "master", caps.lan_interface ],
        [ "ip", "link", "set", NETNS_VETH_HOST, "up" ],
        [ "ip", "netns", "exec", NETNS_NAME, "ip", "link", "set", "lo", "up" ],
        [ "ip", "netns", "exec", NETNS_NAME, "ip", "addr", "add", client_ip + "/" + prefix, "dev", NETNS_VETH_PEER ],
        [ "ip", "netns", "exec", NETNS_NAME, "ip", "link", "set", NETNS_VETH_PEER, "up" ],
        [ "ip", "netns", "exec", NETNS_NAME, "ip", "route", "add", "default", "via", caps.lan_address ]
    ];

    for (let step in steps) {
        if (!run_quiet(step)) {
            netns_teardown();
            return { ok: false, error: "не удалось выполнить: " + join(" ", step) };
        }
    }

    run_quiet([ "mkdir", "-p", "/etc/netns/" + NETNS_NAME ]);
    if (fs.writefile("/etc/netns/" + NETNS_NAME + "/resolv.conf", "nameserver " + caps.lan_address + "\n") == null) {
        netns_teardown();
        return { ok: false, error: "не удалось записать resolv.conf для namespace" };
    }

    return { ok: true, client_ip, error: "" };
}

function build_context(mode, client_ip) {
    let caps = capabilities();
    let ctx = {
        tools: {
            curl: caps.curl,
            uclient_fetch: caps.uclient_fetch,
            dig: caps.dig,
            nslookup: caps.nslookup,
            nc: caps.nc,
            nc_mode: caps.nc_mode,
            timeout_cmd: caps.timeout_cmd
        },
        fakeip_ranges: caps.fakeip_ranges,
        resolver: "127.0.0.1",
        exec_prefix: [],
        mode: as_string(mode) == "netns" ? "netns" : "router",
        lan_interface: caps.lan_interface,
        lan_address: caps.lan_address,
        forkop_running: caps.forkop_running,
        client_ip: "",
        netns_error: ""
    };

    if (ctx.mode != "netns")
        return ctx;

    let netns = netns_setup(caps, client_ip);
    if (!netns.ok) {
        ctx.mode = "router";
        ctx.netns_error = netns.error;
        return ctx;
    }

    ctx.exec_prefix = [ "ip", "netns", "exec", NETNS_NAME ];
    ctx.resolver = caps.lan_address != "" ? caps.lan_address : "127.0.0.1";
    ctx.client_ip = netns.client_ip;
    ctx.netns_active = true;
    return ctx;
}

function probe_target(ctx, target) {
    target = object_or_empty(target);
    let host = as_string(target.host);
    let dns = probe_dns(ctx, host);
    let connection = { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "", message: "" };

    if (dns.ok)
        connection = connection_probe(ctx, target);
    else
        connection.verdict = "dns_fail";

    let verdict = target_verdict(target, dns, connection);

    return {
        label: target_label(target),
        kind: as_string(target.kind || "https"),
        host,
        port: int(target.port || (as_string(target.kind) == "http" ? 80 : 443)),
        url: as_string(target.kind) == "tcp" ? "" : target_url(target),
        optional: target.optional === true,
        dns_ok: dns.ok,
        dns_ip: as_string(dns.ip),
        dns_fakeip: dns.fakeip === true,
        dns_ms: int(dns.ms),
        remote_ip: as_string(connection.remote_ip),
        http_code: int(connection.code),
        tcp_ms: int(connection.tcp_ms),
        tls_ms: int(connection.tls_ms),
        total_ms: int(connection.total_ms),
        outbound: "",
        state: verdict.state,
        verdict: verdict.verdict,
        message: verdict.message
    };
}

function probe_service(ctx, profile) {
    profile = object_or_empty(profile);
    let items = [];

    for (let target in array_or_empty(profile.targets))
        push(items, probe_target(ctx, target));

    // Атрибуция маршрута - best effort: Clash API отдаёт только живые соединения,
    // а короткие HTTP-запросы к моменту опроса часто уже закрыты. Поэтому один
    // запрос на сервис, а не на каждую цель, и пустой результат не считается ошибкой.
    if (ctx.forkop_running) {
        let connections = clash_connections();
        if (length(connections) > 0) {
            for (let item in items) {
                if (!item.state || item.state == "skipped")
                    continue;
                item.outbound = outbound_for(connections, item.host, item.remote_ip);
            }
        }
    }

    let summary = service_state(items);

    return {
        id: as_string(profile.id),
        title: as_string(profile.title),
        group: as_string(profile.group),
        description: as_string(profile.description),
        state: summary.state,
        description_result: summary.description,
        items
    };
}

function selected_profiles(ids) {
    ids = trim(as_string(ids));
    let all = load_profiles();

    if (ids == "" || ids == "all")
        return all;

    let wanted = {};
    for (let id in split(ids, ","))
        wanted[trim(as_string(id))] = true;

    let result = [];
    for (let profile in all)
        if (wanted[as_string(object_or_empty(profile).id)])
            push(result, profile);

    return result;
}

// Состояние фоновых заданий. Объявлено до run_check, потому что тот пишет в него
// прогресс по ходу проверки, а forward-ссылок ucode не прощает.

function job_id_valid(value) {
    value = as_string(value);
    return value != "" && match(value, /^[A-Za-z0-9_-]+$/) != null;
}

function job_path(job_id) {
    return job_id_valid(job_id) ? STATE_DIR + "/" + as_string(job_id) + ".json" : "";
}

function write_state(path, value) {
    ensure_state_dir();
    return fs.writefile(as_string(path), sprintf("%J", value) + "\n") != null;
}

function update_progress(path, done, total, services) {
    let state = object_or_empty(read_json_file(path));
    if (!state.running)
        return;
    state.progress = { done: int(done), total: int(total) };
    state.services = services;
    write_state(path, state);
}

function run_check(ids, mode, client_ip, progress_path) {
    let profiles = selected_profiles(ids);
    let ctx = build_context(mode, client_ip);
    let services = [];
    let total = 0;

    for (let profile in profiles)
        total += length(array_or_empty(object_or_empty(profile).targets));

    let done = 0;

    for (let profile in profiles) {
        let result = probe_service(ctx, profile);
        push(services, result);
        done += length(result.items);
        if (as_string(progress_path) != "")
            update_progress(progress_path, done, total, services);
    }

    if (ctx.netns_active)
        netns_teardown();

    return {
        generated_at: now_seconds(),
        mode: ctx.mode,
        requested_mode: as_string(mode) == "netns" ? "netns" : "router",
        netns_error: as_string(ctx.netns_error),
        client_ip: as_string(ctx.client_ip),
        resolver: ctx.resolver,
        forkop_running: ctx.forkop_running,
        tools: ctx.tools,
        fakeip_ranges: ctx.fakeip_ranges,
        progress: { done, total },
        services
    };
}

// ---------------------------------------------------------------------------
// Фоновые задания
// ---------------------------------------------------------------------------

function cleanup_jobs() {
    ensure_state_dir();
    let now = now_seconds();
    for (let path in fs.glob(STATE_DIR + "/*.json")) {
        let state = object_or_empty(read_json_file(path));
        let started = int(state.started_at || 0);
        if (started > 0 && now - started > JOB_MAX_AGE)
            fs.unlink(path);
    }
}

function start_job(ids, mode, client_ip) {
    ensure_state_dir();
    cleanup_jobs();

    let job_id = sprintf("sc-%d-%d", now_seconds(), int(now_ms() % 100000));
    let path = job_path(job_id);
    if (path == "") {
        write_json({ success: false, message: "не удалось создать задание" });
        return 1;
    }

    let profiles = selected_profiles(ids);
    let total = 0;
    for (let profile in profiles)
        total += length(array_or_empty(object_or_empty(profile).targets));

    if (length(profiles) == 0) {
        write_json({ success: false, message: "не выбран ни один сервис" });
        return 1;
    }

    let state = {
        kind: "service_check",
        job_id,
        running: true,
        success: false,
        started_at: now_seconds(),
        finished_at: 0,
        mode: as_string(mode) == "netns" ? "netns" : "router",
        ids: as_string(ids),
        progress: { done: 0, total },
        services: []
    };

    if (!write_state(path, state)) {
        write_json({ success: false, message: "не удалось записать состояние задания" });
        return 1;
    }

    let worker = command_from_args([
        "ucode", "-L", LIB_DIR, ENGINE, "worker", path, as_string(ids), as_string(mode), as_string(client_ip)
    ]);
    system("(" + worker + " >/dev/null 2>&1 &)");

    write_json({ success: true, job_id, progress: state.progress });
    return 0;
}

function worker(path, ids, mode, client_ip) {
    let result = run_check(ids, mode, client_ip, path);
    let state = object_or_empty(read_json_file(path));

    state.running = false;
    state.success = true;
    state.finished_at = now_seconds();
    state.services = result.services;
    state.resolver = result.resolver;
    state.tools = result.tools;
    state.fakeip_ranges = result.fakeip_ranges;
    state.progress = result.progress;
    state.mode = result.mode;
    state.netns_error = result.netns_error;
    state.client_ip = result.client_ip;
    state.forkop_running = result.forkop_running;

    write_state(path, state);
    return 0;
}

function job_status(job_id) {
    let path = job_path(job_id);
    if (path == "" || fs.stat(path) == null) {
        write_json({ success: false, running: false, message: "задание не найдено" });
        return 1;
    }

    let state = object_or_empty(read_json_file(path));
    if (length(keys(state)) == 0) {
        write_json({ success: false, running: false, message: "не удалось прочитать состояние задания" });
        return 1;
    }

    write_json(state);
    return 0;
}

function list_profiles() {
    let data = object_or_empty(read_json_file(profiles_file()));
    let profiles = [];

    for (let profile in array_or_empty(data.profiles)) {
        profile = object_or_empty(profile);
        push(profiles, {
            id: as_string(profile.id),
            title: as_string(profile.title),
            group: as_string(profile.group),
            description: as_string(profile.description),
            targets: length(array_or_empty(profile.targets))
        });
    }

    write_json({ version: int(data.version || 0), updated: as_string(data.updated), profiles });
    return 0;
}

// ---------------------------------------------------------------------------

let mode = as_string(ARGV[0]);

if (mode == "list")
    exit(list_profiles());
else if (mode == "capabilities") {
    write_json(capabilities());
    exit(0);
}
else if (mode == "fixes")
    exit(list_fixes());
else if (mode == "fix")
    exit(run_fix(ARGV[1]));
else if (mode == "run") {
    write_json(run_check(ARGV[1], ARGV[2], ARGV[3], ""));
    exit(0);
}
else if (mode == "start")
    exit(start_job(ARGV[1], ARGV[2], ARGV[3]));
else if (mode == "status")
    exit(job_status(ARGV[1]));
else if (mode == "worker")
    exit(worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4]));
else if (mode == "cleanup") {
    cleanup_jobs();
    exit(0);
}
else if (mode == "netns-teardown") {
    netns_teardown();
    exit(0);
}
else if (mode == "xhttp-patch")
    exit(run_fix("xhttp_import"));
else {
    warn("Unknown mode: ", mode, "\n");
    exit(1);
}
