<#
.SYNOPSIS
    Builds the minimal LGPL FFmpeg of ADR-0046 with MSVC and places it in third_party/ffmpeg.

.DESCRIPTION
    Run it in a shell prepared by tools/dev-env.ps1 (MSVC and Ninja on PATH). It also needs
    Python 3 and MSYS2 with make, diffutils, pkgconf and nasm:
        pacman -S --needed make diffutils pkgconf nasm
    Sources are downloaded once into deps/ffmpeg/downloads and must match the hashes below. dav1d
    and FFmpeg are built under deps/ffmpeg, which also keeps the PDBs. third_party/ffmpeg receives
    the headers, import libraries, DLLs, licenses and BUILDINFO.md, and is committed.

    Upgrading: change a version and its hash, run this script, run the tests, commit
    third_party/ffmpeg.

.EXAMPLE
    . .\tools\dev-env.ps1
    .\tools\build_ffmpeg.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',
    [string]$Msys2Root = $env:GS_MSYS2_ROOT,
    [int]$Jobs = [Environment]::ProcessorCount
)

$ErrorActionPreference = 'Stop'

$FFmpeg = @{
    Name   = 'ffmpeg-9.0.2'
    Url    = 'https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz'
    Sha256 = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
}
$Dav1d = @{
    Name   = 'dav1d-1.5.4'
    Url    = 'https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz'
    Sha256 = '686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5'
}

$CommonFlags = @(
    '--toolchain=msvc', '--target-os=win64',
    '--enable-shared', '--disable-static', '--extra-cflags=-MD',
    '--disable-autodetect', '--disable-everything',
    '--disable-programs', '--disable-doc', '--disable-network',
    '--disable-avdevice', '--disable-avfilter', '--disable-swscale',
    '--enable-d3d11va',
    '--enable-decoder=h264,hevc,av1',
    '--enable-parser=h264,hevc,av1,opus,aac',
    '--enable-hwaccel=h264_d3d11va,h264_d3d11va2,hevc_d3d11va,hevc_d3d11va2,av1_d3d11va,av1_d3d11va2',
    '--enable-muxer=mp4', '--enable-protocol=file'
)
$AudioFlags = '--enable-decoder=opus,aac'

# x86_64 gets NASM assembly and dav1d; ARM64 builds without assembly (armasm needs the ARM64
# assembler wired through gas-preprocessor) and decodes AV1 with FFmpeg's own decoder. Hardware
# D3D11VA decoding is what the client uses on both processors anyway.
if ($Arch -eq 'arm64') {
    # configure links a test program and runs it, which an ARM64 binary cannot do on the x64 host, so
    # the build is a cross build and needs a host compiler for the tools it builds while compiling:
    # MSYS2's gcc, which does run here.
    # configure probes whether it can create symlinks; on a Windows account without the symlink
    # privilege that probe fails and, under `set -e`, takes the whole configure with it. Copying
    # instead of linking is enough for everything the build does with a link.
    $ConfigureFlags = @('--arch=aarch64', '--enable-cross-compile', '--host-cc=gcc', '--disable-asm',
                        '--ln_s=cp -R', "--enable-w32threads") + $CommonFlags +
        @($AudioFlags, "--enable-decoder=av1", "--disable-encoders")
    $UseDav1d = $false
} else {
    $ConfigureFlags = @('--arch=x86_64', "--enable-w32threads", '--enable-libdav1d') + $CommonFlags +
        @($AudioFlags, '--enable-decoder=libdav1d')
    $UseDav1d = $true
}
$Libraries = 'avcodec', 'avformat', 'avutil', 'swresample'

$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root "deps\ffmpeg\$Arch"
$downloads = Join-Path $root 'deps\ffmpeg\downloads'
$sources = Join-Path $root 'deps\ffmpeg\src'
$prefix = Join-Path $work 'prefix'
$output = Join-Path $root "third_party\ffmpeg\$Arch"

function ConvertTo-MsysPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    return '/' + $full.Substring(0, 1).ToLowerInvariant() + $full.Substring(2).Replace('\', '/')
}

function Assert-ExitCode([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

function Reset-Directory([string]$Path) {
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path }
    New-Item -ItemType Directory -Force $Path | Out-Null
}

function Invoke-Msys([string]$Name, [string]$Script) {
    $file = Join-Path $work "$Name.sh"
    [IO.File]::WriteAllText($file, ("set -e`n" + $Script + "`n").Replace("`r`n", "`n"))
    $saved = $env:MSYSTEM, $env:MSYS2_PATH_TYPE, $env:CHERE_INVOKING
    try {
        $env:MSYSTEM = 'MSYS'
        $env:MSYS2_PATH_TYPE = 'inherit'
        $env:CHERE_INVOKING = '1'
        & $bash -l (ConvertTo-MsysPath $file)
        Assert-ExitCode "MSYS2 step $Name"
    } finally {
        $env:MSYSTEM, $env:MSYS2_PATH_TYPE, $env:CHERE_INVOKING = $saved
    }
}

function Get-Source([hashtable]$Spec) {
    $file = Join-Path $downloads (Split-Path $Spec.Url -Leaf)
    New-Item -ItemType Directory -Force $downloads | Out-Null
    if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $Spec.Sha256) {
        Write-Host "Downloading $($Spec.Url)"
        & curl.exe -L --fail --silent --show-error -C - --retry 5 --retry-all-errors -o $file $Spec.Url
    }
    if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $Spec.Sha256) {
        Remove-Item $file -ErrorAction SilentlyContinue
        throw "$($Spec.Url) did not arrive intact (SHA-256 differs); the partial file was removed, run again"
    }
    return $file
}

function Expand-Source([string]$Archive, [string]$Name) {
    $target = Join-Path $sources $Name
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    New-Item -ItemType Directory -Force $sources | Out-Null
    Invoke-Msys "extract-$Name" "tar -xJf '$(ConvertTo-MsysPath $Archive)' -C '$(ConvertTo-MsysPath $sources)'"
    return $target
}

function Find-Single([string[]]$Patterns) {
    $found = @(Get-ChildItem -Path $Patterns -File -ErrorAction SilentlyContinue)
    if ($found.Count -ne 1) { throw "expected one file for $($Patterns -join ', '), found $($found.Count)" }
    return $found[0]
}

$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if (-not $cl -or -not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    throw 'MSVC or Ninja is not on PATH: run . .\tools\dev-env.ps1 first'
}
$msys = @($Msys2Root, 'C:\msys64') | Where-Object { $_ -and (Test-Path (Join-Path $_ 'usr\bin\bash.exe')) } |
    Select-Object -First 1
if (-not $msys) { throw 'MSYS2 not found: install it from https://www.msys2.org or set GS_MSYS2_ROOT' }
$bash = Join-Path $msys 'usr\bin\bash.exe'
$nasm = Join-Path $msys 'usr\bin\nasm.exe'
$needed = @('make', 'pkgconf', 'cmp')
if ($UseDav1d) { $needed += 'nasm' }
foreach ($tool in $needed) {
    if (-not (Test-Path (Join-Path $msys "usr\bin\$tool.exe"))) {
        throw "MSYS2 lacks $tool.exe: pacman -S --needed make diffutils pkgconf nasm"
    }
}

New-Item -ItemType Directory -Force $work | Out-Null
$ffmpegSource = Expand-Source (Get-Source $FFmpeg) $FFmpeg.Name
Reset-Directory $prefix

$configure = Join-Path $ffmpegSource 'configure'
$configureText = [IO.File]::ReadAllText($configure)
$relaxedText = $configureText.Replace('grep -q ^Microsoft', 'grep -q Microsoft')
if ($relaxedText -eq $configureText) { throw 'configure no longer has the MSVC banner check this script relaxes' }
[IO.File]::WriteAllText($configure, $relaxedText)

if ($UseDav1d) {
    $dav1dSource = Expand-Source (Get-Source $Dav1d) $Dav1d.Name
    $venv = Join-Path $work 'venv'
    $python = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path $python)) {
        & python -m venv $venv
        Assert-ExitCode 'python -m venv'
    }
    & $python -m pip install --quiet --disable-pip-version-check --require-hashes -r (Join-Path $PSScriptRoot 'ffmpeg-build-requirements.txt')
    Assert-ExitCode 'pip install (meson)'
    $meson = Join-Path $venv 'Scripts\meson.exe'
    $dav1dBuild = Join-Path $work 'build-dav1d'
    if (Test-Path $dav1dBuild) { Remove-Item -Recurse -Force $dav1dBuild }
    $nativeFile = Join-Path $work 'meson-native.ini'
    Set-Content -Path $nativeFile -Encoding ascii -Value "[binaries]`nnasm = '$($nasm.Replace('\', '/'))'"
    & $meson setup $dav1dBuild $dav1dSource --native-file $nativeFile --buildtype=release --default-library=static `
        "--prefix=$prefix" --libdir=lib -Denable_tools=false -Denable_tests=false -Db_vscrt=md
    Assert-ExitCode 'meson setup (dav1d)'
    & $meson install -C $dav1dBuild --quiet
    Assert-ExitCode 'meson install (dav1d)'
    $dav1dLib = Join-Path $prefix 'lib\dav1d.lib'
    if (-not (Test-Path $dav1dLib)) {
        Copy-Item (Find-Single @((Join-Path $prefix 'lib\libdav1d.a'))).FullName $dav1dLib
    }
}

$ffmpegBuild = Join-Path $work 'build-ffmpeg'
Reset-Directory $ffmpegBuild
$flags = $ConfigureFlags + "--prefix=$(ConvertTo-MsysPath $prefix)" + '--pkg-config=pkgconf' + '--pkg-config-flags=--static'
# The flags go into a shell command line, so one that carries a space (`--ln_s=cp -R`) has to be
# quoted or configure reads its second word as an option of its own.
$quotedFlags = ($flags | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
Invoke-Msys 'build-ffmpeg' @"
# MSVC first: MSYS2's coreutils has a link.exe of its own.
export PATH="$(ConvertTo-MsysPath (Split-Path $cl.Source -Parent)):`$PATH"
export PKG_CONFIG_PATH='$(ConvertTo-MsysPath (Join-Path $prefix 'lib\pkgconfig'))'
cd '$(ConvertTo-MsysPath $ffmpegBuild)'
'$(ConvertTo-MsysPath $ffmpegSource)/configure' $quotedFlags
make -j$Jobs
make install
"@
$pdbs = Join-Path $work 'pdb'
Reset-Directory $pdbs
Get-ChildItem -Path $ffmpegBuild -Recurse -Filter '*.pdb' | Where-Object { $_.Name -notlike 'vc*.pdb' } |
    Copy-Item -Destination $pdbs

$shared = Split-Path $output -Parent
Reset-Directory $output
foreach ($dir in 'include', 'lib', 'bin') { New-Item -ItemType Directory -Force (Join-Path $output $dir) | Out-Null }
foreach ($library in $Libraries) {
    # The headers are per processor: configure writes avutil/avconfig.h, and the value of
    # AV_HAVE_FAST_UNALIGNED differs between x64 and ARM64.
    Copy-Item -Recurse -Force (Join-Path $prefix "include\lib$library") (Join-Path $output 'include')
    $importLib = Find-Single @((Join-Path $prefix "lib\$library.lib"), (Join-Path $prefix "bin\$library.lib"))
    Copy-Item $importLib.FullName (Join-Path $output 'lib')
    Copy-Item (Find-Single @((Join-Path $prefix "bin\$library-*.dll"))).FullName (Join-Path $output 'bin')
}
Copy-Item -Force (Join-Path $ffmpegSource 'COPYING.LGPLv2.1') (Join-Path $shared 'licenses\FFmpeg-COPYING.LGPLv2.1')
Copy-Item -Force (Join-Path $ffmpegSource 'LICENSE.md') (Join-Path $shared 'licenses\FFmpeg-LICENSE.md')
if ($UseDav1d) {
    Copy-Item -Force (Join-Path $dav1dSource 'COPYING') (Join-Path $shared 'licenses\dav1d-COPYING')
}

$files = Get-ChildItem -Path (Join-Path $output 'bin'), (Join-Path $output 'lib') -File | Sort-Object FullName
$inputs = @(
    "| FFmpeg | $($FFmpeg.Name) | ``$($FFmpeg.Sha256.ToLowerInvariant())`` |"
)
if ($UseDav1d) {
    $inputs += "| dav1d | $($Dav1d.Name) | ``$($Dav1d.Sha256.ToLowerInvariant())`` |"
} else {
    $inputs += "| dav1d | $($Dav1d.Name) not built for $Arch; AV1 decodes with FFmpeg's own decoder | |"
}
$inputs += "| MSVC | $env:VCToolsVersion | |"
if ($UseDav1d) {
    $inputs += "| nasm | $((& $nasm -v) -join ' ') | |"
    $inputs += "| meson | $((& $meson --version) -join ' ') | |"
}
$info = @(
    '# FFmpeg build (ADR-0046)'
    ''
    'Generated by `tools/build_ffmpeg.ps1`; do not edit. Change the script and rebuild instead.'
    ''
    "Processor: ``$Arch``"
    ''
    '| Input | Version | SHA-256 |'
    '|---|---|---|'
) + $inputs + @(
    ''
    'FFmpeg configure flags (plus `--prefix`, `--pkg-config=pkgconf --pkg-config-flags=--static`):'
    ''
    '```'
    ($ConfigureFlags -join "`n")
    '```'
    ''
    '| File | Bytes | SHA-256 |'
    '|---|---|---|'
)
foreach ($file in $files) {
    $relative = $file.FullName.Substring($output.Length + 1).Replace('\', '/')
    $info += "| $relative | $($file.Length) | ``$((Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())`` |"
}
[IO.File]::WriteAllText((Join-Path $output 'BUILDINFO.md'), (($info -join "`n") + "`n"))

Write-Host "FFmpeg installed into $output"
$files | ForEach-Object { Write-Host ("  {0,-24} {1,12:N0} bytes" -f $_.Name, $_.Length) }
