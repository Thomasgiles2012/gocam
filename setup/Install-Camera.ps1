param([Parameter(Mandatory=$true)][string]$SourceDll, [Parameter(Mandatory=$true)][string]$ExpectedSha256, [switch]$InspectOnly)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell so the camera class is registered in the correct registry view.' }
$componentClsid = '{389E9F71-7914-4ED1-A60C-25D50FDF0A84}'
$componentOwner = 'GoProOriginalCamera-389E9F71-v1'
$componentKey = 'HKLM:\SOFTWARE\Classes\CLSID\' + $componentClsid
$componentInproc = $componentKey + '\InprocServer32'
$componentRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'GoPro Low Latency Camera'
$componentSource = (Resolve-Path -LiteralPath $SourceDll).Path
if ([IO.Path]::GetExtension($componentSource) -ne '.dll') { throw 'The source must be our built DLL.' }
if ($ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'An exact SHA256 identity is required.' }
$componentHash = (Get-FileHash -LiteralPath $componentSource -Algorithm SHA256).Hash
if ($componentHash -ne $ExpectedSha256) { throw 'Built source identity changed. Nothing was installed.' }
$componentTargetDir = [IO.Path]::GetFullPath((Join-Path $componentRoot $componentHash.Substring(0,24)))
if (-not $componentTargetDir.StartsWith($componentRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Installation target escaped its owned directory.' }
$componentTarget = Join-Path $componentTargetDir 'GoProDevice1080Source.dll'
foreach ($checkedInstallPath in (Split-Path -Parent $componentRoot), $componentRoot, $componentTargetDir, $componentTarget) {
    if ((Test-Path -LiteralPath $checkedInstallPath) -and ((Get-Item -LiteralPath $checkedInstallPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'An installation target is a reparse point; refusing redirected writes.' }
}
$componentExisting = Test-Path -LiteralPath $componentKey
if ($componentExisting) {
    $existingOwner = (Get-ItemProperty -LiteralPath $componentKey -Name GoProLowLatencyOwner -ErrorAction SilentlyContinue).GoProLowLatencyOwner
    if ($existingOwner -ne $componentOwner) { throw 'The CLSID already exists without our ownership marker. Refusing to overwrite it.' }
    if (-not (Test-Path -LiteralPath $componentInproc) -or -not (Get-Item -LiteralPath $componentInproc).GetValue('')) { throw 'Our existing registration is incomplete; refusing to overwrite it.' }
}
if ($InspectOnly) {
    Write-Output ('Would install only our source DLL at: ' + $componentTarget)
    Write-Output ('Would register only our COM class: ' + $componentClsid)
    Write-Output 'No drivers, certificates, firewall, firmware, audio, or existing camera registration changes.'
    return
}
$componentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$componentPrincipal = New-Object Security.Principal.WindowsPrincipal($componentIdentity)
if (-not $componentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'One-time installation needs an administrator-approved PowerShell process.' }
$componentPriorPath = $null
$componentPriorThreading = $null
$componentPriorHash = $null
if ($componentExisting) {
    $componentPriorHash = (Get-Item -LiteralPath $componentKey).GetValue('GoProLowLatencySourceSha256')
    if (Test-Path -LiteralPath $componentInproc) {
        $componentPriorPath = (Get-Item -LiteralPath $componentInproc).GetValue('')
        $componentPriorThreading = (Get-Item -LiteralPath $componentInproc).GetValue('ThreadingModel')
    }
}
$componentCreated = $false
try {
    New-Item -ItemType Directory -Path $componentTargetDir -Force | Out-Null
    if (Test-Path -LiteralPath $componentTarget) {
        if ((Get-FileHash -LiteralPath $componentTarget -Algorithm SHA256).Hash -ne $componentHash) { throw 'The target file exists with different bytes; refusing to overwrite it.' }
    } else { Copy-Item -LiteralPath $componentSource -Destination $componentTarget }
    if ((Get-FileHash -LiteralPath $componentTarget -Algorithm SHA256).Hash -ne $componentHash) { throw 'Installed source verification failed.' }
    if (-not $componentExisting) {
        New-Item -Path $componentKey | Out-Null; $componentCreated = $true
        New-ItemProperty -LiteralPath $componentKey -Name GoProLowLatencyOwner -Value $componentOwner -PropertyType String | Out-Null
    }
    New-Item -Path $componentInproc -Force | Out-Null
    Set-Item -LiteralPath $componentInproc -Value $componentTarget
    New-ItemProperty -LiteralPath $componentInproc -Name ThreadingModel -Value Both -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $componentKey -Name GoProLowLatencyOwner -Value $componentOwner -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $componentKey -Name GoProLowLatencySourceSha256 -Value $componentHash -PropertyType String -Force | Out-Null
    if ((Get-Item -LiteralPath $componentInproc).GetValue('') -ne $componentTarget) { throw 'COM registration verification failed.' }
    Write-Output 'Installed our camera-only component. No selectable endpoint is created until the app starts.'
} catch {
    # Roll back only the exact class owned by this installer. Never delete files
    # or an existing class belonging to another application.
    if ($componentCreated -and (Test-Path -LiteralPath $componentKey)) {
        $rollbackInproc = Get-Item -LiteralPath $componentInproc -ErrorAction SilentlyContinue
        $rollbackClass = Get-Item -LiteralPath $componentKey
        $rollbackMarker = $rollbackClass.GetValue('GoProLowLatencyOwner')
        $rollbackExpectedSubkeys = @($rollbackClass.GetSubKeyNames() | Where-Object { $_ -ne 'InprocServer32' }).Count -eq 0
        if ($rollbackExpectedSubkeys -and ($null -eq $rollbackMarker -or $rollbackMarker -eq $componentOwner) -and ($null -eq $rollbackInproc -or -not $rollbackInproc.GetValue('') -or $rollbackInproc.GetValue('') -eq $componentTarget)) { Remove-Item -LiteralPath $componentKey -Recurse }
    } elseif ($componentPriorPath) {
        Set-Item -LiteralPath $componentInproc -Value $componentPriorPath
        if ($null -eq $componentPriorThreading) { Remove-ItemProperty -LiteralPath $componentInproc -Name ThreadingModel -ErrorAction SilentlyContinue }
        else { New-ItemProperty -LiteralPath $componentInproc -Name ThreadingModel -Value $componentPriorThreading -PropertyType String -Force | Out-Null }
        if ($null -eq $componentPriorHash) { Remove-ItemProperty -LiteralPath $componentKey -Name GoProLowLatencySourceSha256 -ErrorAction SilentlyContinue }
        else { New-ItemProperty -LiteralPath $componentKey -Name GoProLowLatencySourceSha256 -Value $componentPriorHash -PropertyType String -Force | Out-Null }
    }
    throw
}
