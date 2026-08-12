"""Static checks for the generated self-contained installer."""

import base64
import io
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "install-forkop-servicecheck.sh"
PACKAGE = ROOT / "dist" / "luci-app-forkop-servicecheck_1.2.0-r1_all.ipk"
MARKER = "__FORKOP_SC_PAYLOAD__"


def assert_shell(name, shell_script):
    assert shell_script.startswith(b"#!/bin/sh\n"), f"{name} has an invalid shebang"
    assert b"\r" not in shell_script, f"{name} contains CRLF/CR line endings"


def main():
    script = INSTALLER.read_text(encoding="utf-8")
    assert 'VERSION="1.2.0"' in script
    assert "detect_installed_version()" in script
    assert 'INSTALLED_VERSION="$(detect_installed_version || true)"' in script
    assert "sed -n '/^__PAYLOAD_BELOW__$/,$p' \"$0\"" not in script

    chunks = script.split(MARKER)
    assert len(chunks) >= 3, "payload heredoc is missing"
    payload = chunks[1].split("\n", 1)[1].rsplit("\n", 1)[0]
    archive = base64.b64decode("".join(payload.split()), validate=True)

    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        names = set(tar.getnames())
        cli_raw = tar.extractfile("usr/bin/forkop-servicecheck").read()
        xhttp_fix = tar.extractfile("usr/lib/forkop-servicecheck/xhttp_hotfix.sh").read()
        icmp_fix = tar.extractfile("usr/lib/forkop-servicecheck/icmp_tproxy_hotfix.sh").read()
        cli = cli_raw.decode("utf-8")
        engine = tar.extractfile("usr/lib/forkop-servicecheck/probe.uc").read().decode("utf-8")
        view = tar.extractfile("www/luci-static/resources/view/forkop/servicecheck-v111.js").read().decode("utf-8")
        profiles = tar.extractfile("usr/share/forkop-servicecheck/profiles.json").read().decode("utf-8")

    required = {
        "usr/bin/forkop-servicecheck",
        "usr/lib/forkop-servicecheck/probe.uc",
        "usr/lib/forkop-servicecheck/xhttp_hotfix.sh",
        "usr/lib/forkop-servicecheck/icmp_tproxy_hotfix.sh",
        "usr/share/forkop-servicecheck/profiles.json",
        "usr/share/forkop-servicecheck/version",
        "www/luci-static/resources/view/forkop/servicecheck-v111.js",
    }
    missing = required - names
    assert not missing, f"missing payload files: {sorted(missing)}"
    assert_shell("installer CLI", cli_raw)
    assert_shell("installer xHTTP fix", xhttp_fix)
    assert_shell("installer ICMP fix", icmp_fix)
    assert "#!/usr/bin/ucode" not in cli
    assert "command -v ucode" in cli
    assert "    custom)" in cli
    assert 'else if (mode == "custom")' in engine
    assert 'status == 28 && connect_ms <= 0 && remote_ip == ""' in engine
    assert 'else if (mode == "profiles-save")' in engine
    assert 'callBin(["profiles-save", JSON.stringify(parsed)])' in view
    assert '--surface-raised:#fff' in view
    assert 'background:var(--surface-raised)' in view
    assert 'MTProto DC' not in profiles
    assert 'UDP / QUIC / Discord' not in profiles
    assert '"Проверить IP/домен"' in view
    with tarfile.open(PACKAGE, mode="r:gz") as outer:
        data_archive = outer.extractfile("./data.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(data_archive), mode="r:gz") as data_tar:
        assert_shell("IPK CLI", data_tar.extractfile("./usr/bin/forkop-servicecheck").read())
        assert_shell("IPK xHTTP fix", data_tar.extractfile("./usr/lib/forkop-servicecheck/xhttp_hotfix.sh").read())
        assert_shell("IPK ICMP fix", data_tar.extractfile("./usr/lib/forkop-servicecheck/icmp_tproxy_hotfix.sh").read())

    print(f"installer/IPK OK: {len(archive)} bytes, {len(names)} entries")


if __name__ == "__main__":
    main()
