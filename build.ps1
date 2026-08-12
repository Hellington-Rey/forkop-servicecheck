# Собирает самодостаточный установщик install-forkop-servicecheck.sh
# из содержимого каталога files\ и шаблона installer-template.sh.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$filesDir = Join-Path $root 'files'
$template = Join-Path $root 'installer-template.sh'
$output = Join-Path $root 'install-forkop-servicecheck.sh'
$archive = Join-Path $env:TEMP 'forkop-servicecheck-payload.tar.gz'

$version = '1.1.2'
$builtAt = (Get-Date).ToString('yyyy-MM-dd')

if (Test-Path $archive) { Remove-Item $archive -Force }

# ustar, а не pax по умолчанию: busybox tar на роутере разбирает его без сюрпризов.
& tar --format=ustar -czf $archive -C $filesDir usr www
if ($LASTEXITCODE -ne 0) { throw "tar завершился с кодом $LASTEXITCODE" }

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

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($output, $script, $utf8NoBom)

Remove-Item $archive -Force

$size = [Math]::Round((Get-Item $output).Length / 1KB, 1)
Write-Output "Собрано: $output ($size КБ, payload $([Math]::Round($bytes.Length / 1KB, 1)) КБ)"

# Пакеты для opkg и apk - в dist\
& python (Join-Path $root 'build_packages.py')
if ($LASTEXITCODE -ne 0) { throw "build_packages.py завершился с кодом $LASTEXITCODE" }
