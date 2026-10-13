# Runs the Zig Reseal server as staging (reseal.wreseal.com through the Cloudflare tunnel).
# Settings, including PORT, come from Reseal-js/.env.staging (the same database and keys the Node
# staging server used). Run:  powershell -File C:\MProjects\Reseal\tools\staging.ps1
# Roll back to Node: stop reseal-server.exe, then `npm run staging` in C:\MProjects\Reseal-js.
# Build first:  zig build server -Doptimize=safe

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$js = Join-Path (Split-Path -Parent $repo) 'Reseal-js'
$dir = Join-Path $repo 'zig-out\staging'

# A copy of the server, so rebuilding does not touch the running one.
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item (Join-Path $repo 'zig-out\bin\reseal-server.exe') $dir -Force

foreach ($line in Get-Content (Join-Path $js '.env.staging')) {
    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim().Trim('"'), 'Process')
    }
}
# The web app: Reseal-js's public folder for now (the zui client is still being finished).
$env:RESEAL_PUBLIC_DIR = Join-Path $js 'public'

Start-Process -FilePath (Join-Path $dir 'reseal-server.exe') -WorkingDirectory $dir -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $dir 'server.log') -RedirectStandardError (Join-Path $dir 'server.err.log')
Write-Output "Zig Reseal staging started (logs in $dir)"
