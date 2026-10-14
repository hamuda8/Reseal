# Runs the Zig Reseal server as staging (reseal.wreseal.com through the Cloudflare tunnel).
# Settings, including PORT, come from Reseal-js/.env.staging (the same database and keys the Node
# staging server used). Run:  powershell -File C:\MProjects\Reseal\tools\staging.ps1
# Roll back to Node: stop reseal-server.exe, then `npm run staging` in C:\MProjects\Reseal-js.
# Build first:  zig build server -Doptimize=safe   and   zig build web -Doptimize=small

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$js = Join-Path (Split-Path -Parent $repo) 'Reseal-js'
$dir = Join-Path $repo 'zig-out\staging'
$web = Join-Path $dir 'web'

# A copy of the server and the pages, so rebuilding does not touch the running one.
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item (Join-Path $repo 'zig-out\bin\reseal-server.exe') $dir -Force

# The pages: the zui web app (also at /embed and /developers, which it draws itself), plus the
# files other sites load as they are: the widget library Taazur embeds (/sdk/reseal.js), the
# notification-permission window (/push) and "Coming soon".
if (Test-Path $web) { Remove-Item -Recurse -Force $web }
Copy-Item -Recurse (Join-Path $repo 'zig-out\web') $web
Copy-Item (Join-Path $web 'index.html') (Join-Path $web 'embed.html')
Copy-Item (Join-Path $web 'index.html') (Join-Path $web 'developers.html')
Copy-Item -Recurse (Join-Path $js 'public\sdk') (Join-Path $web 'sdk')
Copy-Item (Join-Path $js 'public\push.html') $web
Copy-Item (Join-Path $js 'public\coming-soon.html') $web

foreach ($line in Get-Content (Join-Path $js '.env.staging')) {
    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim().Trim('"'), 'Process')
    }
}
$env:RESEAL_PUBLIC_DIR = $web
# Push to phones: the Firebase service account, kept outside the repositories.
$fcm = Join-Path (Split-Path -Parent $repo) 'secrets\firebase-service-account.json'
if (Test-Path $fcm) { $env:FCM_SERVICE_ACCOUNT_FILE = $fcm }

Start-Process -FilePath (Join-Path $dir 'reseal-server.exe') -WorkingDirectory $dir -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $dir 'server.log') -RedirectStandardError (Join-Path $dir 'server.err.log')
Write-Output "Zig Reseal staging started (logs in $dir)"
