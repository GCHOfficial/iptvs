[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $PackagePath,

  [Parameter(Mandatory = $true)]
  [string] $ExpectedVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($ExpectedVersion -notmatch '^\d+\.\d+\.\d+\.0$') {
  throw "ExpectedVersion must have four numeric components and end in .0: $ExpectedVersion"
}

function Find-WindowsSdkTool([string] $Name) {
  $Command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -ne $Command) {
    return $Command.Source
  }
  $SdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $Candidates = @(Get-ChildItem $SdkBin -Filter $Name -File -Recurse |
    Where-Object { $_.DirectoryName -match '[\\/]x64$' } |
    Sort-Object { [version] $_.Directory.Parent.Name } -Descending)
  if ($Candidates.Count -eq 0) {
    throw "$Name was not found in PATH or the Windows 10 SDK."
  }
  return $Candidates[0].FullName
}

$MakeAppx = Find-WindowsSdkTool 'makeappx.exe'
$ResolvedPackagePath = (Resolve-Path $PackagePath).Path
$UnpackDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "iptvs-msix-verify-$([guid]::NewGuid().ToString('N'))"

try {
  & $MakeAppx unpack /o /p $ResolvedPackagePath /d $UnpackDirectory
  if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx unpack failed with exit code $LASTEXITCODE."
  }

  [xml] $Manifest = Get-Content (Join-Path $UnpackDirectory 'AppxManifest.xml') -Raw
  $Namespace = New-Object System.Xml.XmlNamespaceManager($Manifest.NameTable)
  $Namespace.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
  $Namespace.AddNamespace('rescap', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities')

  $Identity = $Manifest.SelectSingleNode('/f:Package/f:Identity', $Namespace)
  $ExpectedIdentity = @{
    Name = 'George-CosminHanta.IPTVSPlayer'
    Publisher = 'CN=7DA809EF-3303-40F1-B760-21A6BCA24B17'
    Version = $ExpectedVersion
    ProcessorArchitecture = 'x64'
  }
  foreach ($Entry in $ExpectedIdentity.GetEnumerator()) {
    if ($Identity.GetAttribute($Entry.Key) -cne $Entry.Value) {
      throw "Unexpected MSIX identity $($Entry.Key): $($Identity.GetAttribute($Entry.Key))"
    }
  }

  $Application = $Manifest.SelectSingleNode('/f:Package/f:Applications/f:Application', $Namespace)
  if ($Application.GetAttribute('Executable') -cne 'iptvs.exe' -or
      $Application.GetAttribute('EntryPoint') -cne 'Windows.FullTrustApplication') {
    throw 'MSIX application entry point is not the expected iptvs.exe full-trust process.'
  }

  $Capabilities = @($Manifest.SelectNodes('/f:Package/f:Capabilities/*', $Namespace))
  if ($Capabilities.Count -ne 1 -or
      $Capabilities[0].NamespaceURI -cne 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities' -or
      $Capabilities[0].GetAttribute('Name') -cne 'runFullTrust') {
    throw 'MSIX must declare only the runFullTrust capability.'
  }

  $RequiredPayload = @(
    'iptvs.exe',
    'flutter_windows.dll',
    'libmpv-2.dll',
    'data\flutter_assets\AssetManifest.bin',
    'Assets\StoreLogo.png',
    'Assets\Square44x44Logo.png',
    'Assets\Square150x150Logo.png'
  )
  foreach ($RelativePath in $RequiredPayload) {
    if (-not (Test-Path (Join-Path $UnpackDirectory $RelativePath) -PathType Leaf)) {
      throw "MSIX is missing required payload: $RelativePath"
    }
  }

  Write-Host "Verified Microsoft Store MSIX identity, version, capabilities, and runtime payload: $ResolvedPackagePath"
} finally {
  if (Test-Path $UnpackDirectory) {
    Remove-Item $UnpackDirectory -Recurse -Force
  }
}
