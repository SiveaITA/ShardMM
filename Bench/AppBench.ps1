<#
.SYNOPSIS
    Builds and runs AppBench: application-shaped Delphi code under several Win64 memory managers.

.DESCRIPTION
    The same program is built with dcc64 in several variants:
      ShardMM   ShardMM from ..\Source;
      mimalloc  mimalloc.dll from a release of microsoft/mimalloc (-MimallocVersion), built here with
                CMake, Ninja and MSVC from Visual Studio as a plain DLL that does not override malloc
                of the process; or a ready DLL given by -MimallocDll;
      FastMM5   FastMM5 from the source directory given by -FastMM5
                (https://github.com/pleriche/FastMM5);
      RTL       the memory manager of the Delphi RTL.
    Every scenario at every thread count runs as a separate process, -Runs times per variant with
    the variants interleaved, and the run with the median time goes into the table. The checksums of
    a scenario and thread count are compared across the variants: a difference means that a manager
    corrupted memory, and the row is marked. The result is a markdown table on stdout. Nothing else
    should run on the machine meanwhile; for a steady clock set the Windows power mode to
    "Best performance". Everything is built in -OutDir.

.PARAMETER Managers
    A subset of ShardMM, mimalloc, FastMM5, RTL. By default all of them, FastMM5 only with -FastMM5.
.PARAMETER Threads
    Thread counts. 1, 4 and 16 by default.
.PARAMETER Scenarios
    Scenarios; all by default.
.PARAMETER Scale
    Multiplier of the work per thread.
.PARAMETER Runs
    How many times to run every combination; the median by time goes into the table.
.PARAMETER Cores
    P, E or LPE: every process runs only on the cores of this class, with the workers pinned to the
    cores (option -cores of the program). Without it the same N threads land on performance or
    efficiency cores of a hybrid processor from run to run. A thread count above the number of cores
    of the class measures preemption rather than scaling.
.PARAMETER FastMM5
    The directory with FastMM5.pas.
.PARAMETER MimallocDll
    A ready mimalloc.dll (built without MI_OVERRIDE) instead of building one.
.PARAMETER MimallocVersion
    The mimalloc release to build, without the v prefix; the source is the tag archive from GitHub.
.PARAMETER OutDir
    The directory for builds and downloads; in the temporary directory by default.
.PARAMETER NoBuild
    Take the executables (and mimalloc.dll) built earlier in -OutDir: the runs then need neither
    Delphi nor Visual Studio, only a copy of that directory and this script.
.PARAMETER Delphi
    The root of the Delphi installation; by default the newest one registered that has dcc64.exe.

.EXAMPLE
    .\AppBench.ps1 -Runs 3 -FastMM5 C:\src\FastMM5 > results.md
    .\AppBench.ps1 -Managers ShardMM,mimalloc -Threads 8 -Scenarios objects,mixed -Cores E
#>
[CmdletBinding()]
param(
    [ValidateSet('ShardMM', 'mimalloc', 'FastMM5', 'RTL')]
    [string[]]$Managers,
    [int[]]$Threads = @(1, 4, 16),
    [ValidateSet('objects', 'pack', 'json', 'strings', 'maps', 'interfaces', 'pipeline', 'mixed', 'threads')]
    [string[]]$Scenarios = @('objects', 'pack', 'json', 'strings', 'maps', 'interfaces', 'pipeline', 'mixed', 'threads'),
    [double]$Scale = 1,
    [ValidateRange(1, 99)]
    [int]$Runs = 1,
    [ValidateSet('', 'P', 'E', 'LPE')]
    [string]$Cores = '',
    [string]$FastMM5,
    [string]$MimallocDll,
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$MimallocVersion = '3.6.0',
    [string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'AppBench'),
    [switch]$NoBuild,
    [string]$Delphi
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Project = Join-Path $Root 'AppBench.dpr'
$ScaleText = $Scale.ToString([Globalization.CultureInfo]::InvariantCulture)

if (-not $Managers) {
    $Managers = @('ShardMM', 'mimalloc')
    if ($FastMM5) { $Managers += 'FastMM5' }
    $Managers += 'RTL'
}
if (($Managers -contains 'FastMM5') -and -not $NoBuild) {
    if (-not $FastMM5 -or -not (Test-Path (Join-Path $FastMM5 'FastMM5.pas'))) {
        throw 'The FastMM5 variant needs -FastMM5 <directory with FastMM5.pas>'
    }
    $FastMM5 = (Resolve-Path $FastMM5).Path
}

# The 8.3 name: dcc64 does not take every path with spaces in a unit path from PowerShell. On a
# volume without short names the path comes back as is.
function Get-ShortPath([string]$Path) {
    try { return (New-Object -ComObject Scripting.FileSystemObject).GetFolder($Path).ShortPath }
    catch { return $Path }
}

function Find-Delphi([string]$Dir) {
    if ($Dir) {
        if (-not (Test-Path (Join-Path $Dir 'bin\dcc64.exe'))) { throw "No bin\dcc64.exe in $Dir" }
        return (Resolve-Path $Dir).Path
    }
    $found = @()
    foreach ($key in 'HKCU:\Software\Embarcadero\BDS', 'HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS',
                     'HKLM:\SOFTWARE\Embarcadero\BDS') {
        if (-not (Test-Path $key)) { continue }
        foreach ($sub in Get-ChildItem $key) {
            $rootDir = (Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue).RootDir
            $version = $null
            if ($rootDir -and [version]::TryParse($sub.PSChildName, [ref]$version) -and
                (Test-Path (Join-Path $rootDir 'bin\dcc64.exe'))) {
                $found += [pscustomobject]@{ Version = $version; Root = $rootDir.TrimEnd('\') }
            }
        }
    }
    if (-not $found) { throw 'No Delphi installation with bin\dcc64.exe is registered; pass -Delphi <root>' }
    return ($found | Sort-Object Version -Descending | Select-Object -First 1).Root
}

if (-not $NoBuild) {
    $DelphiRoot = Find-Delphi $Delphi
    $Dcc = Join-Path $DelphiRoot 'bin\dcc64.exe'
    $Lib = Join-Path (Get-ShortPath $DelphiRoot) 'lib\win64\release'
    $ShardSource = (Resolve-Path (Join-Path $Root '..\Source')).Path
    Write-Host "Delphi: $DelphiRoot" -ForegroundColor Gray
}

# Variant: compiler defines and extra unit directories
$Variants = [ordered]@{
    'ShardMM'  = @{ Defines = @('MM_SHARDMM'); Units = @() }
    'mimalloc' = @{ Defines = @('MM_MIMALLOC'); Units = @() }
    'FastMM5'  = @{ Defines = @('MM_FASTMM5'); Units = @($FastMM5) }
    'RTL'      = @{ Defines = @(); Units = @() }
}

function Build-Mimalloc([string]$Version) {
    $dir = Join-Path $OutDir "mimalloc-$Version"
    $dll = Join-Path $dir 'build\mimalloc.dll'
    if (Test-Path $dll) { return $dll }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'Building mimalloc needs Visual Studio with C++ (vswhere.exe not found); or pass -MimallocDll' }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'No Visual Studio with the x64 C++ tools found; or pass -MimallocDll' }
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'

    New-Item -ItemType Directory -Force $dir | Out-Null
    $zip = Join-Path $dir 'source.zip'
    $url = "https://github.com/microsoft/mimalloc/archive/refs/tags/v$Version.zip"
    Write-Host "  downloading $url" -ForegroundColor Gray
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    $source = Join-Path $dir "mimalloc-$Version"
    $build = Join-Path $dir 'build'

    # A DLL only: no override of malloc of the process and no mimalloc-redirect.dll; statistics and
    # sampling as in the default release build
    $cmake = "cmake -S `"$source`" -B `"$build`" -G Ninja -DCMAKE_BUILD_TYPE=Release -DMI_BUILD_SHARED=ON " +
             '-DMI_BUILD_STATIC=OFF -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF -DMI_OVERRIDE=OFF -DMI_WIN_REDIRECT=OFF'
    # vcvars64.bat writes to stderr even on success; Windows PowerShell 5.1 would take that for an
    # error under Stop, so only the exit code decides
    $ErrorActionPreference = 'Continue'
    $log = & cmd.exe /c "call `"$vcvars`" >nul 2>&1 && $cmake && cmake --build `"$build`"" 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0 -or -not (Test-Path $dll)) { throw "Building mimalloc failed`n$($log -join "`n")" }
    return $dll
}

function Build-Variant([string]$Name) {
    $dir = Join-Path $OutDir "Win64-$Name"
    $exe = Join-Path $dir 'AppBench.exe'
    if ($NoBuild) {
        if (-not (Test-Path $exe)) { throw "No ${exe}: -NoBuild takes the executables of an earlier build" }
        return $exe
    }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $units = @($Lib, $ShardSource) + $Variants[$Name].Units
    $argList = @('-B', '-Q', '-$O+', '-$D-', "-E$dir", "-N0$dir", '-NSSystem;Winapi;System.Win',
                 ('-U' + ($units -join ';'))) + ($Variants[$Name].Defines | ForEach-Object { "-D$_" }) + @($Project)
    $ErrorActionPreference = 'Continue'
    $out = & $Dcc @argList 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "dcc64 ($Name) exited with code $code`n$($out -join "`n")" }
    $out | Where-Object { "$_" -match 'Hint|Warning' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    return $exe
}

# One run: the table row and its time; stderr of the program (FastMM5 counters) goes to the screen
function Invoke-Bench([string]$Exe, [string]$Scenario, [int]$Count) {
    $argList = @('-only', $Scenario, '-threads', $Count, '-scale', $ScaleText)
    if ($Cores) { $argList += @('-cores', $Cores) }
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @argList 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $row = $out | Where-Object { $_ -is [string] -and $_.StartsWith('|') } | Select-Object -First 1
    # The program prints the chosen cores on every run; the screen gets them once
    foreach ($line in ($out | Where-Object { $_ -is [Management.Automation.ErrorRecord] })) {
        $text = "$line"
        if ($text.StartsWith('cores ')) {
            if ($script:CoresShown) { continue }
            $script:CoresShown = $true
        }
        Write-Host "  $text" -ForegroundColor Gray
    }
    if ($code -ne 0 -or -not $row) { throw "$Exe -only $Scenario -threads $Count exited with code $code" }
    $cells = $row.Split('|') | ForEach-Object { $_.Trim() }
    return [pscustomobject]@{ Row = $row; Seconds = [double]::Parse($cells[4], [Globalization.CultureInfo]::InvariantCulture);
                              Check = $cells[8] }
}

$exes = [ordered]@{}
foreach ($name in $Variants.Keys) {
    if ($Managers -notcontains $name) { continue }
    Write-Host "== building $name" -ForegroundColor Cyan
    $exe = Build-Variant $name
    if ($name -eq 'mimalloc' -and -not $NoBuild) {
        $dll = $MimallocDll
        if (-not $dll) { $dll = Build-Mimalloc $MimallocVersion }
        Copy-Item $dll (Split-Path $exe) -Force
    }
    $exes[$name] = $exe
}

# The program writes UTF-8 to stdout
$consoleEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
try {
    '| manager | scenario | threads | time, s | k ops/s | memory held, MB | peak, MB | checksum |'
    '|---|---|---:|---:|---:|---:|---:|---|'
    foreach ($scenario in $Scenarios) {
        foreach ($count in $Threads) {
            $checks = @{}
            # Runs alternate between the variants (A, B, A, B...): a clock drift during the runs falls
            # on all of them alike rather than on the one whose turn came during warm-up
            $results = @{}
            foreach ($name in $exes.Keys) { $results[$name] = New-Object System.Collections.Generic.List[object] }
            for ($i = 0; $i -lt $Runs; $i++) {
                foreach ($name in $exes.Keys) {
                    Write-Host "== $scenario, $count threads, $name, run $($i + 1)" -ForegroundColor Gray
                    $results[$name].Add((Invoke-Bench $exes[$name] $scenario $count))
                }
            }
            foreach ($name in $exes.Keys) {
                $median = ($results[$name] | Sort-Object Seconds)[[int][Math]::Floor(($results[$name].Count - 1) / 2)]
                $checks[$name] = $median.Check
                $row = $median.Row
                if (@($checks.Values | Select-Object -Unique).Count -gt 1) {
                    Write-Warning "$scenario, $count threads: the checksum of $name differs from the others"
                    $row = $row.TrimEnd(' ', '|') + ' **mismatch** |'
                }
                $row
            }
        }
    }
}
finally {
    [Console]::OutputEncoding = $consoleEncoding
}
Write-Host 'Done.' -ForegroundColor Green
