$running = Get-WmiObject Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'HakimiWidget.ps1' }
if (!$running) {
    $scriptDir = Split-Path $PSScriptRoot -Parent
    $vbs = Join-Path $scriptDir "scripts\Launch-Hakimi.vbs"
    if (Test-Path $vbs) {
        Start-Process "wscript.exe" -ArgumentList "`"$vbs`"" -WindowStyle Hidden
    }
}
Write-Output "{}"
