"""Читает JSON результата forkop-servicecheck из stdin и печатает его таблицей."""

import json
import sys

MARK = {"success": "[ OK ]", "warning": "[ ~~ ]", "error": "[FAIL]", "skipped": "[skip]"}

raw = sys.stdin.read().strip()
start = raw.find("{")
if start < 0:
    print("нет JSON в выводе:\n" + raw[:2000])
    sys.exit(1)

data = json.loads(raw[start:])

if "services" not in data:
    print(json.dumps(data, ensure_ascii=False, indent=2)[:3000])
    sys.exit(0)

mode = data.get("mode", "?")
print(f"режим: {mode}   резолвер: {data.get('resolver', '?')}   forkop: "
      f"{'запущен' if data.get('forkop_running') else 'НЕ запущен'}   "
      f"client_ip: {data.get('client_ip') or '-'}")
if data.get("netns_error"):
    print(f"netns не поднялся: {data['netns_error']}")
print(f"fakeip: {', '.join(data.get('fakeip_ranges', []))}")
print()

for service in data["services"]:
    print(f"{MARK.get(service['state'], '?')} {service['title']}: {service['description_result']}")

    for item in service["items"]:
        dns = item["dns_ip"] or "-"
        if item["dns_fakeip"]:
            dns += " (fakeip)"

        timing = []
        if item["tcp_ms"]:
            timing.append(f"tcp {item['tcp_ms']}ms")
        if item["tls_ms"]:
            timing.append(f"tls {item['tls_ms']}ms")
        if item["total_ms"]:
            timing.append(f"итого {item['total_ms']}ms")
        if item["http_code"]:
            timing.insert(0, f"HTTP {item['http_code']}")

        extra = ""
        if item.get("outbound"):
            extra += f"  через {item['outbound']}"
        if item["message"]:
            extra += f"  <- {item['message']}"
        if item["optional"]:
            extra += "  (необяз.)"

        label = item["label"][:44]
        print(f"    {MARK.get(item['state'], '?')} {label:<44} dns {dns:<24} {' '.join(timing):<40}{extra}")

    print()

states = [s["state"] for s in data["services"]]
print(f"итог: ok={states.count('success')} warn={states.count('warning')} fail={states.count('error')} "
      f"проверок={data.get('progress', {}).get('done', '?')}")
