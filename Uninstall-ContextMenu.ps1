[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$extensions = @('.ttf', '.otf')

foreach ($extension in $extensions) {
    $menuKey = "HKCU:\Software\Classes\SystemFileAssociations\$extension\shell\MakeFusionFont"
    if (Test-Path -LiteralPath $menuKey) {
        if ($PSCmdlet.ShouldProcess($extension, 'Remove Make Fusion Font context menu item')) {
            Remove-Item -LiteralPath $menuKey -Recurse -Force
        }
    }
}

if ($WhatIfPreference) {
    Write-Host 'WhatIf complete. No context-menu registry entries were changed.'
}
else {
    Write-Host 'Removed the Make Fusion Font right-click item for .ttf and .otf files.'
}
