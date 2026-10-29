[CmdletBinding()]
param([switch]$Sign)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if ($Sign) {
    $signingThumbprint = ($env:MULTISYNC_WINDOWS_CERTIFICATE_THUMBPRINT -replace '\s', '')
    if ($signingThumbprint -notmatch '^[a-fA-F0-9]{40}$') {
        throw '-Sign requires MULTISYNC_WINDOWS_CERTIFICATE_THUMBPRINT for an installed certificate in CurrentUser\My.'
    }
    $signingCertificate = Get-Item "Cert:\CurrentUser\My\$signingThumbprint" -ErrorAction Stop
    if (-not $signingCertificate.HasPrivateKey -or $signingCertificate.NotAfter -le (Get-Date) -or $signingCertificate.NotBefore -gt (Get-Date)) {
        throw 'The selected signing certificate is expired, not yet valid, or has no private key.'
    }
    if (-not ($signingCertificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) {
        throw 'The selected certificate does not have the Code Signing extended key usage.'
    }
    $signTool = $env:MULTISYNC_SIGNTOOL_PATH
    if ([string]::IsNullOrWhiteSpace($signTool)) {
        $signTool = (Get-Command signtool.exe -ErrorAction Stop).Source
    }
    if (-not (Test-Path -LiteralPath $signTool -PathType Leaf)) { throw 'SignTool was not found.' }
    $timestampUrl = $env:MULTISYNC_WINDOWS_TIMESTAMP_URL
    if ([string]::IsNullOrWhiteSpace($timestampUrl)) { $timestampUrl = 'http://timestamp.digicert.com' }
    $timestampUri = [uri]$timestampUrl
    if (-not $timestampUri.IsAbsoluteUri -or $timestampUri.Scheme -notin @('http', 'https') -or $timestampUri.UserInfo) {
        throw 'The timestamp URL must be an absolute HTTP(S) URL without embedded credentials.'
    }
}
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
    $packagePath = 'dist/MultiSync-Windows-x64.zip'
    if ($Sign) {
        # Sign only project-owned code; keep vendor runtime signatures unchanged.
        foreach ($name in @('MultiSync.Windows.exe', 'MultiSync.Windows.dll', 'multi_sync_bridge.dll')) {
            $file = Join-Path $projectRoot "dist/windows/$name"
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing application code: $name" }
            & $signTool sign /sha1 $signingThumbprint /s My /fd SHA256 /tr $timestampUrl /td SHA256 $file
            if ($LASTEXITCODE -ne 0) { throw "Signing failed: $name" }
            & $signTool verify /pa /all /tw $file
            if ($LASTEXITCODE -ne 0) { throw "Signature verification failed: $name" }
            $signature = Get-AuthenticodeSignature -LiteralPath $file
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $signingThumbprint -or -not $signature.TimeStamperCertificate) {
                throw "The expected trusted, timestamped signature was not found: $name"
            }
        }
        $packagePath = 'dist/MultiSync-Windows-x64-signed.zip'
    }
    Compress-Archive -Path dist/windows/* -DestinationPath $packagePath -Force
    Write-Output "Built $packagePath"
} finally { Pop-Location }
