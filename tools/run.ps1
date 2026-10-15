# Builds and runs the Reseal server, like the npm scripts of Reseal-js:
#   zig build local        ->  run.ps1 -Mode local       (this machine, Reseal-js/.env.local, in this window)
#   zig build staging      ->  run.ps1 -Mode staging     (reseal.wreseal.com, Reseal-js/.env.staging, in this window;
#                                                       -Background starts it hidden instead)
#   zig build production   ->  run.ps1 -Mode production  (the Linux server and pages for Proxmox, in zig-out/production)
# Settings, including PORT, come from Reseal-js's .env file for that mode. Roll back staging to Node:
# stop reseal-server.exe, then `npm run staging` in C:\MProjects\Reseal-js.

param(
    [ValidateSet('local', 'staging', 'production')][string]$Mode = 'staging',
    [string]$Zig = 'C:\Tools\zig-0.17.0\zig.exe',
    # Start staging hidden in the background instead of in this window.
    [switch]$Background
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$js = Join-Path (Split-Path -Parent $repo) 'Reseal-js'
$dir = Join-Path $repo "zig-out\$Mode"
$web = Join-Path $dir 'web'
$exe = Join-Path $dir 'reseal-server.exe'

Push-Location $repo
try {
    $server = if ($Mode -eq 'production') { 'server-linux' } else { 'server' }
    & $Zig build $server -Doptimize=safe; if ($LASTEXITCODE) { throw 'server build failed' }
    & $Zig build web -Doptimize=small; if ($LASTEXITCODE) { throw 'web build failed' }
} finally { Pop-Location }

# The running copy must stop before it can be replaced.
Get-Process reseal-server -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
Start-Sleep -Milliseconds 500

# The pages: the zui web app (also at /embed and /developers, which it draws itself), plus the
# files other sites load as they are: the widget library Taazur embeds (/sdk/reseal.js), the
# notification-permission window (/push) and "Coming soon".
New-Item -ItemType Directory -Force $dir | Out-Null
if (Test-Path $web) { Remove-Item -Recurse -Force $web }
Copy-Item -Recurse (Join-Path $repo 'zig-out\web') $web
Copy-Item (Join-Path $web 'index.html') (Join-Path $web 'embed.html')
Copy-Item (Join-Path $web 'index.html') (Join-Path $web 'developers.html')
Copy-Item -Recurse (Join-Path $js 'public\sdk') (Join-Path $web 'sdk')
Copy-Item (Join-Path $js 'public\push.html') $web
Copy-Item (Join-Path $js 'public\coming-soon.html') $web

if ($Mode -eq 'production') {
    Copy-Item (Join-Path $repo 'zig-out\linux\reseal-server') $dir -Force
    Write-Output @"
Ready in $dir. On the Proxmox server:
  1. copy reseal-server and web/ to one folder;
  2. put Reseal-js's .env.production next to them, with RESEAL_PUBLIC_DIR=web and, for push to
     phones, FCM_SERVICE_ACCOUNT_FILE=<path to the Firebase service account json>;
  3. run ./reseal-server from that folder (behind Cloudflare Tunnel, plain HTTP).
"@
    return
}
Copy-Item (Join-Path $repo 'zig-out\bin\reseal-server.exe') $dir -Force

# Settings: Reseal-js's .env file for this mode, plus the pages and push.
$vars = [ordered]@{}
foreach ($line in Get-Content (Join-Path $js ".env.$Mode")) {
    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') { $vars[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
$vars['RESEAL_PUBLIC_DIR'] = $web
# Push to phones: the Firebase service account, kept outside the repositories.
$fcm = Join-Path (Split-Path -Parent $repo) 'secrets\firebase-service-account.json'
if (Test-Path $fcm) { $vars['FCM_SERVICE_ACCOUNT_FILE'] = $fcm }

# In this window, like npm run dev / npm run staging: the log shows here and Ctrl+C stops it.
if (-not $Background) {
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
    Write-Output "Reseal ($Mode) running in this window (Ctrl+C stops it)"
    Push-Location $dir
    try { & $exe } finally { Pop-Location }
    return
}

# Staging runs on by itself: started by Windows' process service, so it shares no handles with
# this script (a `zig build` would otherwise wait for it), with its settings in .env next to it
# (zig-out is never committed).
$vars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content -Encoding ascii (Join-Path $dir '.env')
$cmd = "cmd /c `"`"$exe`" 1>server.log 2>server.err.log`""
# No window (ShowWindow 0): closing a console window would stop the server.
$hidden = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $dir; ProcessStartupInformation = $hidden } | Out-Null
Write-Output "Reseal staging started (logs in $dir)"
