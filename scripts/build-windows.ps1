$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    dotnet run --project apps/windows/ModelChecks/ModelChecks.csproj --configuration Release
    if ($LASTEXITCODE -ne 0) { throw 'Windows model checks failed.' }
    cargo build --locked --release -p multi-sync-bridge
    if ($LASTEXITCODE -ne 0) { throw 'Rust bridge build failed.' }
    dotnet publish apps/windows/MultiSync.Windows.csproj --configuration Release --runtime win-x64 -p:Platform=x64 --output dist/windows
    if ($LASTEXITCODE -ne 0) { throw 'WinUI application build failed.' }
    if (-not (Test-Path 'dist/windows/multi_sync_bridge.dll')) { throw 'Native engine is missing from publish output.' }
    if (-not (Test-Path 'dist/windows/MultiSync.Windows.exe')) { throw 'Application executable is missing from publish output.' }
    Compress-Archive -Path dist/windows/* -DestinationPath dist/MultiSync-Windows-x64.zip -Force
    Write-Output 'Built dist/MultiSync-Windows-x64.zip'
} finally { Pop-Location }
