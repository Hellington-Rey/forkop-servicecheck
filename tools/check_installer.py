"""Static checks for the generated self-contained installer."""

import base64
import io
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "install-forkop-servicecheck.sh"
MARKER = "__FORKOP_SC_PAYLOAD__"


def main():
    script = INSTALLER.read_text(encoding="utf-8")
    assert 'VERSION="1.1.2"' in script
    assert "detect_installed_version()" in script
    assert 'INSTALLED_VERSION="$(detect_installed_version || true)"' in script
    assert "sed -n '/^__PAYLOAD_BELOW__$/,$p' \"$0\"" not in script

    chunks = script.split(MARKER)
    assert len(chunks) >= 3, "payload heredoc is missing"
    payload = chunks[1].split("\n", 1)[1].rsplit("\n", 1)[0]
    archive = base64.b64decode("".join(payload.split()), validate=True)

    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        names = set(tar.getnames())
        cli = tar.extractfile("usr/bin/forkop-servicecheck").read().decode("utf-8")
        engine = tar.extractfile("usr/lib/forkop-servicecheck/probe.uc").read().decode("utf-8")
        view = tar.extractfile("www/luci-static/resources/view/forkop/servicecheck-v111.js").read().decode("utf-8")

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
    assert cli.startswith("#!/bin/sh\n")
    assert "\r\n" not in cli
    assert "#!/usr/bin/ucode" not in cli
    assert "command -v ucode" in cli
    assert "    custom)" in cli
    assert 'else if (mode == "custom")' in engine
    assert '"Проверить IP/домен"' in view
    print(f"installer OK: {len(archive)} bytes, {len(names)} entries")


if __name__ == "__main__":
    main()
