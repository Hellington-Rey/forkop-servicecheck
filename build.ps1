# Собирает самодостаточный установщик install-forkop-servicecheck.sh
# из содержимого каталога files\ и шаблона installer-template.sh.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$filesDir = Join-Path $root 'files'
$template = Join-Path $root 'installer-template.sh'
$output = Join-Path $root 'install-forkop-servicecheck.sh'
$archive = Join-Path $env:TEMP 'forkop-servicecheck-payload.tar.gz'
$staging = Join-Path $env:TEMP ("forkop-servicecheck-payload-" + [Guid]::NewGuid().ToString('N'))

$version = '1.3.1'
$builtAt = (Get-Date).ToString('yyyy-MM-dd')

if (Test-Path $archive) { Remove-Item $archive -Force }
New-Item -ItemType Directory -Path $staging | Out-Null

try {
    Copy-Item -Recurse -Force (Join-Path $filesDir 'usr') $staging
    Copy-Item -Recurse -Force (Join-Path $filesDir 'www') $staging

    # Git can check the repository out with CRLF on Windows. BusyBox ash then
    # reads "set -eu\r" as an illegal option, so executable shell payloads are
    # normalized again at build time regardless of checkout settings.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    Get-ChildItem -Recurse -File $staging | Where-Object {
        $_.Extension -in @('.sh', '.uc', '.json', '.js') -or
        $_.FullName -like '*\usr\bin\forkop-servicecheck' -or
        $_.FullName -like '*\usr\share\forkop-servicecheck\version'
    } | ForEach-Object {
        $text = [System.IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n").Replace("`r", "`n")
        [System.IO.File]::WriteAllText($_.FullName, $text, $utf8NoBom)
    }

    # ustar, а не pax по умолчанию: busybox tar на роутере разбирает его без сюрпризов.
    & tar --format=ustar -czf $archive -C $staging usr www
    if ($LASTEXITCODE -ne 0) { throw "tar завершился с кодом $LASTEXITCODE" }
} finally {
    if (Test-Path $staging) { Remove-Item -Recurse -Force -LiteralPath $staging }
}

$bytes = [System.IO.File]::ReadAllBytes($archive)
$base64 = [Convert]::ToBase64String($bytes)

$wrapped = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $base64.Length; $i += 76) {
    $length = [Math]::Min(76, $base64.Length - $i)
    [void]$wrapped.Append($base64.Substring($i, $length))
    [void]$wrapped.Append("`n")
}

$script = [System.IO.File]::ReadAllText($template)
$script = $script.Replace('@@VERSION@@', $version)
$script = $script.Replace('@@BUILT_AT@@', $builtAt)
$script = $script.Replace("@@PAYLOAD@@`n", $wrapped.ToString())
$script = $script.Replace('@@PAYLOAD@@', $wrapped.ToString())
$script = $script.Replace("`r`n", "`n")

[System.IO.File]::WriteAllText($output, $script, $utf8NoBom)

Remove-Item $archive -Force

$size = [Math]::Round((Get-Item $output).Length / 1KB, 1)
Write-Output "Собрано: $output ($size КБ, payload $([Math]::Round($bytes.Length / 1KB, 1)) КБ)"

# Пакеты для opkg и apk - в dist\
& python (Join-Path $root 'build_packages.py')
if ($LASTEXITCODE -ne 0) { throw "build_packages.py завершился с кодом $LASTEXITCODE" }
