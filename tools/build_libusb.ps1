[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$Libusb = @{
    Name   = 'libusb-1.0.30'
    Url    = 'https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2'
    Sha256 = 'fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf'
}

$Platform = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }
$MsbuildFlags = @(
    '/p:Configuration=Release', "/p:Platform=$Platform", '/p:PlatformToolset=v143',
    '/p:EnableWindowsHotplug=false', '/nologo', '/verbosity:minimal'
)

$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root 'deps\libusb'
$downloads = Join-Path $work 'downloads'
$sources = Join-Path $work 'src'
$output = Join-Path $root "third_party\libusb\$Arch"

function Assert-ExitCode([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

function Reset-Directory([string]$Path) {
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path }
    New-Item -ItemType Directory -Force $Path | Out-Null
}

function Test-Intact([string]$File, [string]$Sha256) {
    return (Test-Path $File) -and (Get-FileHash $File -Algorithm SHA256).Hash -eq $Sha256
}

function Assert-Intact([string]$File, [string]$Sha256, [string]$Source) {
    if (-not (Test-Intact $File $Sha256)) {
        Remove-Item $File -ErrorAction SilentlyContinue
        throw "$Source did not arrive intact (SHA-256 differs); the partial file was removed, run again"
    }
}

function Get-Source([hashtable]$Spec) {
    $file = Join-Path $downloads (Split-Path $Spec.Url -Leaf)
    New-Item -ItemType Directory -Force $downloads | Out-Null
    if (-not (Test-Intact $file $Spec.Sha256)) {
        Write-Host "Downloading $($Spec.Url)"
        & curl.exe -L --fail --silent --show-error -C - --retry 5 --retry-all-errors -o $file $Spec.Url
    }
    Assert-Intact $file $Spec.Sha256 $Spec.Url
    return $file
}

function Invoke-SelfTest {
    if ($Libusb.Sha256 -notmatch '^[0-9a-f]{64}$') { throw 'the pinned SHA-256 is not 64 lowercase hex digits' }
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("gs-libusb-selftest-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $scratch | Out-Null
    try {
        $file = Join-Path $scratch 'sample.bin'
        $abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        [IO.File]::WriteAllBytes($file, [byte[]](0x61, 0x62, 0x63))
        Assert-Intact $file $abc 'sample'
        if (-not (Test-Path $file)) { throw 'a file with the expected hash was removed' }
        $refused = $false
        try { Assert-Intact $file $Libusb.Sha256 'sample' } catch { $refused = $true }
        if (-not $refused) { throw 'a file with another hash was accepted' }
        if (Test-Path $file) { throw 'a file with another hash was kept' }
        $refused = $false
        try { Assert-Intact $file $abc 'sample' } catch { $refused = $true }
        if (-not $refused) { throw 'a missing file was accepted' }
    } finally {
        Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
    }
    Write-Host 'build_libusb self-test passed'
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

foreach ($tool in 'cl.exe', 'tar.exe') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is not on PATH: run . .\tools\dev-env.ps1 first"
    }
}
if ($Arch -eq 'x64' -and -not (Get-Command msbuild.exe -ErrorAction SilentlyContinue)) {
    throw 'msbuild.exe is not on PATH: run . .\tools\dev-env.ps1 first'
}

$archive = Get-Source $Libusb
Reset-Directory $sources
& tar.exe -xjf $archive -C $sources
Assert-ExitCode 'tar (libusb)'
$source = Join-Path $sources $Libusb.Name

if ($Arch -eq 'arm64') {
    # `msvc/libusb_dll.vcxproj` has no ARM64 configuration, and MSBuild cannot start a tool on a
    # machine whose environment block repeats a variable name (HTTPS_PROXY and https_proxy, for
    # instance). ARM64 therefore compiles the same sources the project lists, with the same
    # definitions, straight from cl, and links the shipped .def file.
    $build = Join-Path $work 'build'
    Reset-Directory $build
    $sources = @(
        'libusb\core.c', 'libusb\descriptor.c', 'libusb\hotplug.c', 'libusb\io.c', 'libusb\strerror.c',
        'libusb\sync.c', 'libusb\os\events_windows.c', 'libusb\os\threads_windows.c',
        'libusb\os\windows_common.c', 'libusb\os\windows_usbdk.c', 'libusb\os\windows_winusb.c'
    ) | ForEach-Object { Join-Path $source $_ }
    Push-Location $build
    try {
        & cl.exe /nologo /LD /O2 /MD /D_WIN32_WINNT=_WIN32_WINNT_VISTA /D_CRT_SECURE_NO_WARNINGS /DNDEBUG `
            "/I$(Join-Path $source 'msvc')" "/I$(Join-Path $source 'libusb')" @sources `
            /link "/DEF:$(Join-Path $source 'libusb\libusb-1.0.def')" /OUT:libusb-1.0.dll /IMPLIB:libusb-1.0.lib
        Assert-ExitCode 'cl (libusb)'
    } finally {
        Pop-Location
    }
    $built = $build
    $builtLib = $build
} else {
    & msbuild.exe (Join-Path $source 'msvc\libusb_dll.vcxproj') @MsbuildFlags
    Assert-ExitCode 'msbuild (libusb)'
    $built = Join-Path $source "build\v143\$Platform\Release\dll"
    $builtLib = $built
}

$shared = Split-Path $output -Parent
Reset-Directory $output
foreach ($dir in 'lib', 'bin') { New-Item -ItemType Directory -Force (Join-Path $output $dir) | Out-Null }
Copy-Item -Force (Join-Path $source 'libusb\libusb.h') (Join-Path $shared 'include')
Copy-Item (Join-Path $builtLib 'libusb-1.0.lib') (Join-Path $output 'lib')
Copy-Item (Join-Path $built 'libusb-1.0.dll') (Join-Path $output 'bin')
Copy-Item -Force (Join-Path $source 'COPYING') (Join-Path $shared 'licenses\libusb-COPYING')
Copy-Item -Force (Join-Path $source 'AUTHORS') (Join-Path $shared 'licenses\libusb-AUTHORS')

$toolLines = @(
    '| Input | Version | SHA-256 |'
    '|---|---|---|'
    "| libusb | $($Libusb.Name) | ``$($Libusb.Sha256.ToLowerInvariant())`` |"
    "| MSVC | $env:VCToolsVersion | |"
)
$howTo = @()
if ($Arch -eq 'arm64') {
    $toolLines += "| CMake | not used | |"
    $howTo += 'Built with cl from the sources `msvc/libusb_dll.vcxproj` lists (that project has no ARM64 ' +
              'configuration), linking `libusb/libusb-1.0.def` for the exports:'
    $howTo += ''
    $howTo += '```'
    $howTo += 'cl /LD /O2 /MD /D_WIN32_WINNT=_WIN32_WINNT_VISTA /D_CRT_SECURE_NO_WARNINGS /DNDEBUG ' +
              '/I msvc /I libusb <sources> /link /DEF:libusb/libusb-1.0.def'
    $howTo += '```'
} else {
    $toolLines += "| MSBuild | $(((& msbuild.exe -version -nologo) | Select-Object -Last 1)) | |"
    $howTo += 'Built from `msvc/libusb_dll.vcxproj` with:'
    $howTo += ''
    $howTo += '```'
    $howTo += ($MsbuildFlags -join "`n")
    $howTo += '```'
}
$files = Get-ChildItem -Path (Join-Path $output 'bin'), (Join-Path $output 'lib') -File | Sort-Object FullName
$info = @(
    '# libusb build (ADR-0009, AOA)'
    ''
    'Generated by `tools/build_libusb.ps1`; do not edit. Change the script and rebuild instead.'
    ''
    "Processor: ``$Arch``"
    ''
) + $toolLines + @(
    ''
    'The release signature was checked against the release key `C68187379B23DE9EFC46651E2C80FF56C6830A0E`.'
) + $howTo + @(
    ''
    '| File | Bytes | SHA-256 |'
    '|---|---|---|'
)
foreach ($file in $files) {
    $relative = $file.FullName.Substring($output.Length + 1).Replace('\', '/')
    $info += "| $relative | $($file.Length) | ``$((Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())`` |"
}
[IO.File]::WriteAllText((Join-Path $output 'BUILDINFO.md'), (($info -join "`n") + "`n"))

Write-Host "libusb installed into $output"
$files | ForEach-Object { Write-Host ("  {0,-16} {1,12:N0} bytes" -f $_.Name, $_.Length) }
