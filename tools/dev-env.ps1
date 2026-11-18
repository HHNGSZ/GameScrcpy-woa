<#
.SYNOPSIS
    Imports the MSVC developer environment for x64 or for the x64-to-ARM64 cross toolset, and the Qt
    kit location, into the current PowerShell session.

.DESCRIPTION
    The environment is laid out from the install folders instead of running vcvars: vcvarsall reads
    the SDK and toolset locations from the registry through reg.exe, which some machines do not allow
    to run, and it starts cmd.exe, which some machines do not have on PATH.

.EXAMPLE
    $env:GS_QT_DIR = 'C:\Qt\6.10.1\msvc2022_64'
    . .\tools\dev-env.ps1
    cmake --workflow --preset msvc-debug

.EXAMPLE
    $env:GS_QT_DIR = 'C:\Qt\6.10.1\msvc2022_arm64'
    $env:GS_QT_HOST_DIR = 'C:\Qt\6.10.1\msvc2022_64'
    . .\tools\dev-env.ps1 -Arch arm64
    cmake --workflow --preset arm64-release
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',
    [string]$QtDir = $env:GS_QT_DIR,
    [string]$QtHostDir = $env:GS_QT_HOST_DIR
)

$ErrorActionPreference = 'Stop'

function Find-MsvcTools([string]$TargetArch) {
    $roots = @("$env:ProgramFiles\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio")
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $candidate = Get-ChildItem -Path "$root\*\*\VC\Tools\MSVC\*\bin\Hostx64\$TargetArch\cl.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($candidate) {
            return (Split-Path (Split-Path (Split-Path (Split-Path $candidate.FullName -Parent) -Parent) -Parent) -Parent)
        }
    }
    if ($TargetArch -eq 'arm64') {
        throw "no ARM64 compiler under VC\Tools\MSVC: install the MSVC ARM64 build tools " +
              "(Microsoft.VisualStudio.Component.VC.Tools.ARM64)."
    }
    throw 'no x64 compiler under VC\Tools\MSVC: install Visual Studio 2022 or newer with the "Desktop development with C++" workload.'
}

function Find-WindowsSdk([string]$TargetArch) {
    $kits = "${env:ProgramFiles(x86)}\Windows Kits\10"
    if (-not (Test-Path "$kits\Lib")) { throw "Windows SDK not found under $kits" }
    $candidate = Get-ChildItem -Path "$kits\Lib\*" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "um\$TargetArch") } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $candidate) { throw "the Windows SDK under $kits has no $TargetArch libraries" }
    return @{ Root = $kits; Version = $candidate.Name }
}

function Import-MsvcEnvironment([string]$TargetArch, [string]$BasePath) {
    $tools = Find-MsvcTools $TargetArch
    $sdk = Find-WindowsSdk $TargetArch
    $include = @(
        "$tools\include",
        "$($sdk.Root)\Include\$($sdk.Version)\ucrt",
        "$($sdk.Root)\Include\$($sdk.Version)\um",
        "$($sdk.Root)\Include\$($sdk.Version)\shared",
        "$($sdk.Root)\Include\$($sdk.Version)\winrt",
        "$($sdk.Root)\Include\$($sdk.Version)\cppwinrt"
    ) | Where-Object { Test-Path $_ }
    $lib = @(
        "$tools\lib\$TargetArch",
        "$($sdk.Root)\Lib\$($sdk.Version)\ucrt\$TargetArch",
        "$($sdk.Root)\Lib\$($sdk.Version)\um\$TargetArch"
    ) | Where-Object { Test-Path $_ }
    $env:VCToolsInstallDir = "$tools\"
    $env:VCToolsVersion = Split-Path $tools -Leaf
    $env:VCINSTALLDIR = "$(Split-Path (Split-Path $tools -Parent) -Parent)\"
    $env:WindowsSdkDir = "$($sdk.Root)\"
    $env:WindowsSDKVersion = "$($sdk.Version)\"
    $env:UniversalCRTSdkDir = "$($sdk.Root)\"
    $env:UCRTVersion = $sdk.Version
    $env:Platform = $(if ($TargetArch -eq 'arm64') { 'ARM64' } else { 'x64' })
    $env:VSCMD_ARG_HOST_ARCH = 'x64'
    $env:VSCMD_ARG_TGT_ARCH = $TargetArch
    $env:INCLUDE = $include -join ';'
    $env:LIB = $lib -join ';'
    $env:LIBPATH = "$($sdk.Root)\UnionMetadata\$($sdk.Version);$($sdk.Root)\References\$($sdk.Version)"
    # The SDK tools on PATH have to be the host ones: what sits under bin\<version>\<target> is a
    # program for the target processor, which cannot run on the x64 host doing the build.
    $env:PATH = (@("$tools\bin\Hostx64\$TargetArch", "$($sdk.Root)\bin\$($sdk.Version)\x64") +
        ($BasePath -split ';' | Where-Object { $_ })) -join ';'
    $vsRoot = Split-Path (Split-Path (Split-Path (Split-Path $tools -Parent) -Parent) -Parent) -Parent
    foreach ($folder in (Join-Path $vsRoot 'MSBuild\Current\Bin')) {
        if (Test-Path $folder) { $env:PATH = "$folder;$env:PATH" }
    }
}

# The environment of one toolset cannot be stacked onto the other: start from a clean slate so
# switching between x64 and arm64 in the same window does not keep the first toolset's paths.
if ($env:GS_DEV_ENV_LOADED -ne '1' -or $env:GS_DEV_ENV_ARCH -ne $Arch) {
    $inheritedPath = $env:PATH
    $drop = '^(Path|INCLUDE|LIB|LIBPATH|VSINSTALLDIR|VCToolsInstallDir|VCToolsVersion|VisualStudioVersion|'
    $drop += 'VCINSTALLDIR|WindowsSdkDir|WindowsSDKVersion|WindowsSdkBinPath|WindowsSdkVerBinPath|UCRTVersion|'
    $drop += 'UniversalCRTSdkDir|Platform|VSCMD_ARG_.*|VSCMD_VER|NETFXSDKDir|ExtensionSdkDir|'
    $drop += 'FrameworkDir|FrameworkVersion|FrameworkSDKRoot|VCIDEInstallDir|DevEnvDir)$'
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if ($name -match $drop -and (Test-Path "Env:$name")) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    Import-MsvcEnvironment $Arch $inheritedPath
    $env:GS_DEV_ENV_LOADED = '1'
    $env:GS_DEV_ENV_ARCH = $Arch
}

if ($QtDir) {
    if (-not (Test-Path (Join-Path $QtDir 'lib\cmake\Qt6'))) {
        throw "GS_QT_DIR does not point to a Qt 6 kit: $QtDir"
    }
    $env:GS_QT_DIR = $QtDir
    $qtBin = Join-Path $QtDir 'bin'
    if (-not (($env:PATH -split ';') -contains $qtBin)) { $env:PATH = "$qtBin;$env:PATH" }
} else {
    Write-Warning 'GS_QT_DIR is not set: only the core-only preset can be configured.'
}

if ($Arch -eq 'arm64') {
    if (-not $QtHostDir) {
        $sibling = $QtDir -replace 'msvc2022_arm64$', 'msvc2022_64'
        if ($sibling -ne $QtDir -and (Test-Path (Join-Path $sibling 'lib\cmake\Qt6'))) { $QtHostDir = $sibling }
    }
    if ($QtHostDir) {
        $env:GS_QT_HOST_DIR = $QtHostDir
    } else {
        Write-Warning 'GS_QT_HOST_DIR is not set: cross-building needs the x64 Qt kit for moc, rcc and qmlcachegen.'
    }
}

if (-not $env:JAVA_HOME) {
    $jdk = Get-ChildItem -Path "$env:ProgramFiles\Java", "$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Microsoft" `
            -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($jdk) { $env:JAVA_HOME = $jdk.FullName }
}
if (-not $env:ANDROID_HOME) {
    Write-Warning 'ANDROID_HOME is not set: the android/ Gradle build will not find the SDK.'
}

$ninja = (Get-Command ninja -ErrorAction SilentlyContinue).Source
Write-Host "Target       : $Arch"
Write-Host "MSVC toolset : $env:VCToolsVersion"
Write-Host "Qt kit       : $env:GS_QT_DIR"
if ($Arch -eq 'arm64') { Write-Host "Qt host kit  : $env:GS_QT_HOST_DIR" }
Write-Host "Ninja        : $ninja"
Write-Host "JDK          : $env:JAVA_HOME"
Write-Host "Android SDK  : $env:ANDROID_HOME"
