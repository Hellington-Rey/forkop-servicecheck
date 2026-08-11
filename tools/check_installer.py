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
    assert 'VERSION="1.1.0"' in script
    assert "detect_installed_version()" in script
    assert 'INSTALLED_VERSION="$(detect_installed_version || true)"' in script
    assert "sed -n '/^__PAYLOAD_BELOW__$/,$p' \"$0\"" not in script

    chunks = script.split(MARKER)
    assert len(chunks) >= 3, "payload heredoc is missing"
    payload = chunks[1].split("\n", 1)[1].rsplit("\n", 1)[0]
    archive = base64.b64decode("".join(payload.split()), validate=True)

    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        names = set(tar.getnames())

    required = {
        "usr/bin/forkop-servicecheck",
        "usr/lib/forkop-servicecheck/probe.uc",
        "usr/lib/forkop-servicecheck/xhttp_hotfix.sh",
        "usr/lib/forkop-servicecheck/icmp_tproxy_hotfix.sh",
        "usr/share/forkop-servicecheck/profiles.json",
        "usr/share/forkop-servicecheck/version",
        "www/luci-static/resources/view/forkop/servicecheck-v110.js",
    }
    missing = required - names
    assert not missing, f"missing payload files: {sorted(missing)}"
    print(f"installer OK: {len(archive)} bytes, {len(names)} entries")


if __name__ == "__main__":
    main()
