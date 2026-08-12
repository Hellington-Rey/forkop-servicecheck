"""Сборка пакетов forkop-servicecheck.

Делает .ipk (формат opkg, OpenWrt <= 24.10) прямо здесь, на любой ОС: это
обычный gzip-tar из debian-binary + control.tar.gz + data.tar.gz, и Python
собирает его детерминированно, с нужными правами и владельцем root.

.apk (формат APKv3/ADB, OpenWrt >= 25.12) так собрать нельзя: это бинарный
формат, который умеет писать только apk-tools v3. Поэтому здесь генерируется
самодостаточный make-apk.sh, который вызывает `apk mkpkg` уже на машине с apk -
например, прямо на роутере с OpenWrt 25.12.

Пакет архитектурно-независим (arch: all): внутри только скрипты на ucode,
JavaScript и JSON, ничего скомпилированного.
"""

import gzip
import io
import tarfile
from pathlib import Path

ROOT = Path(__file__).parent
FILES_DIR = ROOT / "files"
OUT_DIR = ROOT / "dist"

PACKAGE = "luci-app-forkop-servicecheck"
VERSION = "1.1.2"
RELEASE = "r1"
ARCH = "all"
LICENSE = "MIT"
MAINTAINER = "forkop-servicecheck"
URL = "https://github.com/ushan0v/forkop"
DEPENDS = ["forkop", "luci-base"]
DESCRIPTION = (
    "Проверка доступности сервисов для Forkop. Добавляет в LuCI страницу с "
    "кнопкой проверки: Telegram, YouTube, Instagram и другие сервисы проверяются "
    "тем же путём, которым идёт трафик клиента сети - через dnsmasq, sing-box и "
    "tproxy. Показывает DNS, TCP, TLS, код ответа и выбранный outbound."
)

# Фиксированное время: пакет должен собираться байт в байт одинаково.
MTIME = 1735689600  # 2025-01-01 00:00:00 UTC

# (путь в пакете, путь в files/, режим)
PAYLOAD = [
    ("./usr/bin/forkop-servicecheck", "usr/bin/forkop-servicecheck", 0o755),
    ("./usr/lib/forkop-servicecheck/probe.uc", "usr/lib/forkop-servicecheck/probe.uc", 0o644),
    ("./usr/lib/forkop-servicecheck/xhttp_hotfix.sh", "usr/lib/forkop-servicecheck/xhttp_hotfix.sh", 0o755),
    ("./usr/lib/forkop-servicecheck/icmp_tproxy_hotfix.sh", "usr/lib/forkop-servicecheck/icmp_tproxy_hotfix.sh", 0o755),
    ("./usr/share/forkop-servicecheck/profiles.json", "usr/share/forkop-servicecheck/profiles.json", 0o644),
    ("./usr/share/forkop-servicecheck/version", "usr/share/forkop-servicecheck/version", 0o644),
    ("./www/luci-static/resources/view/forkop/servicecheck-v111.js", "www/luci-static/resources/view/forkop/servicecheck-v111.js", 0o644),
    ("./usr/share/luci/menu.d/luci-app-forkop-servicecheck.json", "usr/share/luci/menu.d/luci-app-forkop-servicecheck.json", 0o644),
    ("./usr/share/rpcd/acl.d/luci-app-forkop-servicecheck.json", "usr/share/rpcd/acl.d/luci-app-forkop-servicecheck.json", 0o644),
]

# Каталоги, которые пакет заводит сам. Общие (/usr/bin, /www/...) не трогаем:
# они принадлежат другим пакетам, и удалять их при деинсталляции нельзя.
OWNED_DIRS = [
    "./usr/lib/forkop-servicecheck",
    "./usr/share/forkop-servicecheck",
]

POSTINST = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0

# Кеш диспетчера LuCI держит список пунктов меню - без сброса новая страница
# не появится до перезагрузки.
rm -rf /tmp/luci-modulecache 2>/dev/null
rm -f /tmp/luci-indexcache* 2>/dev/null

# rpcd читает acl.d только при старте.
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1

exit 0
"""

PRERM = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0

# Убираем временный network namespace, если проверка оборвалась на полпути.
[ -x /usr/bin/forkop-servicecheck ] && /usr/bin/forkop-servicecheck netns_teardown >/dev/null 2>&1
rm -rf /var/run/forkop-servicecheck 2>/dev/null

exit 0
"""

POSTRM = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0

rm -rf /tmp/luci-modulecache 2>/dev/null
rm -f /tmp/luci-indexcache* 2>/dev/null
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1

exit 0
"""


def tar_info(name, size, mode, is_dir=False):
    info = tarfile.TarInfo(name)
    info.size = size
    info.mode = mode
    info.mtime = MTIME
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.type = tarfile.DIRTYPE if is_dir else tarfile.REGTYPE
    return info


def make_tar_gz(entries):
    """entries: список (имя, данные|None, режим, каталог?) -> bytes tar.gz"""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for name, data, mode, is_dir in entries:
            if is_dir:
                tar.addfile(tar_info(name, 0, mode, is_dir=True))
            else:
                tar.addfile(tar_info(name, len(data), mode), io.BytesIO(data))

    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", mtime=MTIME) as gz:
        gz.write(raw.getvalue())
    return compressed.getvalue()


def build_data_tar():
    entries = []
    installed_size = 0

    for owned in OWNED_DIRS:
        entries.append((owned, None, 0o755, True))

    for package_path, source_path, mode in PAYLOAD:
        data = (FILES_DIR / source_path).read_bytes()
        installed_size += len(data)
        entries.append((package_path, data, mode, False))

    return make_tar_gz(entries), installed_size


def build_control_tar(installed_size):
    control = (
        f"Package: {PACKAGE}\n"
        f"Version: {VERSION}-{RELEASE}\n"
        f"Depends: {', '.join(DEPENDS)}\n"
        f"Source: feeds/forkop-servicecheck\n"
        f"SourceName: {PACKAGE}\n"
        f"License: {LICENSE}\n"
        f"Section: net\n"
        f"SourceDateEpoch: {MTIME}\n"
        f"Maintainer: {MAINTAINER}\n"
        f"Architecture: {ARCH}\n"
        f"Installed-Size: {installed_size}\n"
        f"Description: {DESCRIPTION}\n"
    ).encode("utf-8")

    entries = [
        ("./control", control, 0o644, False),
        ("./postinst", POSTINST.encode("utf-8"), 0o755, False),
        ("./prerm", PRERM.encode("utf-8"), 0o755, False),
        ("./postrm", POSTRM.encode("utf-8"), 0o755, False),
    ]
    return make_tar_gz(entries)


def build_ipk():
    data_tar, installed_size = build_data_tar()
    control_tar = build_control_tar(installed_size)

    entries = [
        ("./debian-binary", b"2.0\n", 0o644, False),
        ("./data.tar.gz", data_tar, 0o644, False),
        ("./control.tar.gz", control_tar, 0o644, False),
    ]

    OUT_DIR.mkdir(exist_ok=True)
    output = OUT_DIR / f"{PACKAGE}_{VERSION}-{RELEASE}_{ARCH}.ipk"
    output.write_bytes(make_tar_gz(entries))
    return output, installed_size


def build_feed(ipk_path):
    """Каталог фида для opkg: сам пакет плюс индекс Packages/Packages.gz.

    Формат повторяет scripts/ipkg-make-index.sh из OpenWrt: поля Filename, Size и
    SHA256sum вставляются прямо перед Description, а из индекса вычищаются поля,
    которые OpenWrt в Packages не публикует. Подпись (Packages.sig) добавляется
    отдельным шагом - sign-feed.sh, там, где есть usign.
    """
    import hashlib
    import shutil

    feed_dir = OUT_DIR / "feed"
    feed_dir.mkdir(parents=True, exist_ok=True)

    for stale in feed_dir.glob("*"):
        if stale.is_file():
            stale.unlink()

    shutil.copy2(ipk_path, feed_dir / ipk_path.name)

    raw = ipk_path.read_bytes()
    outer = tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz")
    control_tar = tarfile.open(
        fileobj=io.BytesIO(outer.extractfile("./control.tar.gz").read()), mode="r:gz"
    )
    control = control_tar.extractfile("./control").read().decode("utf-8")

    extra = (
        f"Filename: {ipk_path.name}\n"
        f"Size: {len(raw)}\n"
        f"SHA256sum: {hashlib.sha256(raw).hexdigest()}\n"
    )
    manifest = control.replace("Description:", extra + "Description:", 1)

    # OpenWrt не публикует эти поля в Packages (см. package/Makefile).
    dropped = ("Maintainer:", "LicenseFiles:", "Source:", "SourceName:", "Require:", "SourceDateEpoch:")
    packages = "".join(
        line + "\n"
        for line in manifest.splitlines()
        if not line.startswith(dropped)
    ) + "\n"

    (feed_dir / "Packages").write_text(packages, encoding="utf-8", newline="\n")

    with gzip.GzipFile(filename="", fileobj=open(feed_dir / "Packages.gz", "wb"),
                       mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(packages.encode("utf-8"))

    return feed_dir


def build_apk_maker():
    """Самодостаточный сборщик .apk: разворачивает файлы и зовёт apk mkpkg."""
    import base64

    entries = []
    for package_path, source_path, mode in PAYLOAD:
        data = (FILES_DIR / source_path).read_bytes()
        entries.append((package_path, data, mode, False))
    for owned in OWNED_DIRS:
        entries.append((owned, None, 0o755, True))

    payload = base64.b64encode(make_tar_gz(entries)).decode("ascii")
    wrapped = "\n".join(payload[i:i + 76] for i in range(0, len(payload), 76))

    template = (ROOT / "make-apk-template.sh").read_text(encoding="utf-8")
    script = (
        template.replace("@@PACKAGE@@", PACKAGE)
        .replace("@@VERSION@@", f"{VERSION}-{RELEASE}")
        .replace("@@ARCH@@", "noarch" if ARCH == "all" else ARCH)
        .replace("@@LICENSE@@", LICENSE)
        .replace("@@URL@@", URL)
        .replace("@@MAINTAINER@@", MAINTAINER)
        .replace("@@DEPENDS@@", " ".join(DEPENDS))
        .replace("@@DESCRIPTION@@", " ".join(DESCRIPTION.split()))
        .replace("@@POSTINST@@", POSTINST)
        .replace("@@PRERM@@", PRERM)
        .replace("@@PAYLOAD@@", wrapped)
    )

    OUT_DIR.mkdir(exist_ok=True)
    output = OUT_DIR / "make-apk.sh"
    output.write_text(script.replace("\r\n", "\n"), encoding="utf-8", newline="\n")
    return output


def main():
    ipk, installed_size = build_ipk()
    print(f"собран {ipk.name}: {ipk.stat().st_size} байт "
          f"(содержимое {installed_size} байт, arch={ARCH})")

    feed = build_feed(ipk)
    print(f"собран фид {feed}: {', '.join(sorted(p.name for p in feed.iterdir()))}")
    print("  подписать: sh sign-feed.sh -d <каталог фида> (нужен usign)")

    maker = build_apk_maker()
    print(f"собран {maker.name}: {maker.stat().st_size} байт "
          f"- запустить на машине с apk-tools v3, чтобы получить .apk")


if __name__ == "__main__":
    main()
