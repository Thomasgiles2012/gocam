param([switch]$Remove)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell to unregister the correct COM class.' }
$ownedKey = 'HKLM:\SOFTWARE\Classes\CLSID\{389E9F71-7914-4ED1-A60C-25D50FDF0A84}'
if (-not (Test-Path -LiteralPath $ownedKey)) { Write-Output 'Our camera component is not registered.'; return }
$ownedMarker = (Get-ItemProperty -LiteralPath $ownedKey -Name GoProLowLatencyOwner -ErrorAction SilentlyContinue).GoProLowLatencyOwner
if ($ownedMarker -ne 'GoProOriginalCamera-389E9F71-v1') { throw 'Ownership marker does not match; nothing will be removed.' }
if (-not $Remove) { Write-Output 'Close our camera app, then run this script as administrator with -Remove to unregister only our COM class. Installed source files are retained.'; return }
$removePrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $removePrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Unregistration requires administrator approval.' }
Remove-Item -LiteralPath $ownedKey -Recurse
Write-Output 'Unregistered only our camera component. Its files remain recoverable in Program Files; other cameras and audio are untouched.'
