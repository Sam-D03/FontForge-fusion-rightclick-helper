[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $PSCommandPath
$repairScript = Join-Path $scriptDirectory 'Repair-FusionFont.ps1'
if (-not (Test-Path -LiteralPath $repairScript)) {
    throw "Missing repair script: $repairScript"
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$command = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$repairScript`" `"%1`" -ShowMessage"
$extensions = @('.ttf', '.otf')

foreach ($extension in $extensions) {
    $menuKey = "HKCU:\Software\Classes\SystemFileAssociations\$extension\shell\MakeFusionFont"
    $commandKey = Join-Path $menuKey 'command'

    if ($PSCmdlet.ShouldProcess($extension, 'Install Make Fusion Font context menu item')) {
        New-Item -Path $menuKey -Force | Out-Null
        Set-Item -LiteralPath $menuKey -Value 'Make Fusion Font'
        New-ItemProperty -LiteralPath $menuKey -Name 'Icon' -Value "$env:SystemRoot\System32\shell32.dll,174" -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $menuKey -Name 'NoWorkingDirectory' -Value '' -PropertyType String -Force | Out-Null

        New-Item -Path $commandKey -Force | Out-Null
        Set-Item -LiteralPath $commandKey -Value $command
    }
}

if ($WhatIfPreference) {
    Write-Host 'WhatIf complete. No context-menu registry entries were changed.'
}
else {
    Write-Host 'Installed the Make Fusion Font right-click item for .ttf and .otf files.'
    Write-Host 'On Windows 11 it may appear under "Show more options" depending on Explorer settings.'
}
