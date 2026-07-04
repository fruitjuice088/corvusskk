# Build CorvusSKK (x64, release-flavored) natively on Windows using clang-cl + lld-link,
# with the MSVC CRT/ATL/Windows SDK obtained via xwin (no Visual Studio install).
#
# Prerequisites (all installable without admin rights / without Visual Studio):
#   - clang-cl, lld-link, llvm-rc, llvm-lib  (e.g. `scoop install llvm`)
#   - xwin.exe (prebuilt binary from https://github.com/Jake-Shadle/xwin/releases;
#     building xwin itself via `cargo install xwin` requires an MSVC link.exe, which
#     is exactly what we don't have)
#   - MSVC/ATL/SDK splatted with:
#       build\tools\xwin.exe --accept-license --include-atl --arch x86_64 `
#           --cache-dir build\xwin-cache splat --output build\xwin-msvc
#
# Debug (_DEBUG) CRT libs aren't redistributable and xwin can't fetch them, so this
# build uses NDEBUG + statically-linked release CRT instead. Config files are
# therefore read from %APPDATA%\CorvusSKK\ (same as a normal release install), not
# %APPDATA%\CorvusSKK_DEBUG\.
param(
    [string]$XwinMsvc,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $XwinMsvc) { $XwinMsvc = Join-Path $Repo 'build\xwin-msvc' }
if (-not (Test-Path (Join-Path $XwinMsvc 'crt\include'))) {
    throw "MSVC/SDK not found under $XwinMsvc (run xwin splat first)"
}
$XwinMsvc = (Resolve-Path $XwinMsvc).Path

if (-not $Out) { $Out = Join-Path $Repo 'build\win-xwin' }
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
Set-Location $Out

function Invoke-Native {
    param([string]$Exe, [string[]]$ExeArgs)
    & $Exe @ExeArgs
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE): $($ExeArgs -join ' ')" }
}

function Invoke-Rc {
    param([string]$RcDir, [string]$RcFile, [string]$OutRes)
    Push-Location $RcDir
    try {
        Invoke-Native llvm-rc @(
            '-I.', "-I$Repo\common",
            "-I$XwinMsvc\crt\include", "-I$XwinMsvc\sdk\include\um",
            "-I$XwinMsvc\sdk\include\shared", "-I$XwinMsvc\sdk\include\ucrt",
            '-C', '65001', '-DNDEBUG', '-FO', $OutRes, $RcFile
        )
    } finally { Pop-Location }
}

$SysInc = @(
    '-imsvc', "$XwinMsvc\crt\include",
    '-imsvc', "$XwinMsvc\sdk\include\um",
    '-imsvc', "$XwinMsvc\sdk\include\ucrt",
    '-imsvc', "$XwinMsvc\sdk\include\shared",
    '-imsvc', "$XwinMsvc\sdk\include\winrt"
)
$LibDirs = @(
    "-libpath:$XwinMsvc\crt\lib\x86_64",
    "-libpath:$XwinMsvc\sdk\lib\ucrt\x86_64",
    "-libpath:$XwinMsvc\sdk\lib\um\x86_64",
    "-libpath:$Out"
)
# Debug ucrt/libcpmt/libvcruntime are not redistributable and unavailable via xwin;
# force the release (NDEBUG) static CRT instead and silence the auto-selected debug libs.
$CrtNoDefault = @('-nodefaultlib:libcpmtd.lib', '-nodefaultlib:libucrtd.lib', '-nodefaultlib:libvcruntimed.lib', '-nodefaultlib:libcmtd.lib')
$CrtLibs = @('libcmt.lib', 'libcpmt.lib', 'libvcruntime.lib', 'libucrt.lib')
$CxxFlags = @('-m64', '-fms-compatibility-version=19.44', '-EHsc', '-Zc:__cplusplus', '-MT') + $SysInc

Write-Host "=== libinput (dummy input.dll; link-time only, do NOT ship to a real machine) ==="
Invoke-Native clang-cl (@('-c') + $CxxFlags + @('-DWIN32', '-DNDEBUG', '-D_WINDOWS', '-D_USRDLL', '-DUNICODE', '-D_UNICODE', "-I$Repo\libinput", '-Foinput.obj', "$Repo\libinput\input.cpp"))
Invoke-Native lld-link (@('-dll', '-machine:x64', "-def:$Repo\libinput\input.def", '-out:input.dll', '-implib:input.lib') + $LibDirs + $CrtNoDefault + @('input.obj') + $CrtLibs + @('kernel32.lib', 'user32.lib'))

Write-Host "=== liblua (lua55.dll) ==="
$LibluaSrc = @('lapi', 'lauxlib', 'lbaselib', 'lcode', 'lcorolib', 'lctype', 'ldblib', 'ldebug', 'ldo', 'ldump', 'lfunc', 'lgc',
    'linit', 'liolib', 'llex', 'lmathlib', 'lmem', 'loadlib', 'lobject', 'lopcodes', 'loslib', 'lparser', 'lstate', 'lstring',
    'lstrlib', 'ltable', 'ltablib', 'ltm', 'lu8w', 'lundump', 'lutf8lib', 'lvm', 'lzio')
foreach ($f in $LibluaSrc) {
    Invoke-Native clang-cl (@('-c') + $CxxFlags + @('-DLUA_BUILD_AS_DLL', '-DWIN32', '-DNDEBUG', '-D_WINDOWS', '-D_USRDLL', '-DUNICODE', '-D_UNICODE',
            "-FI$Repo\liblua\pch.h", "-I$Repo\liblua", "-Fo${f}.obj", "$Repo\liblua\$f.c"))
}
Invoke-Rc "$Repo\liblua" 'liblua.rc' "$Out\liblua.res"
Invoke-Native lld-link (@('-dll', '-machine:x64', '-out:lua55.dll', '-implib:lua55.lib') + $LibDirs + $CrtNoDefault +
    ($LibluaSrc | ForEach-Object { "$_.obj" }) + @('liblua.res') + $CrtLibs + @('kernel32.lib', 'user32.lib', 'advapi32.lib'))

Write-Host "=== libz (zlib1.dll) ==="
$LibzSrc = @('adler32', 'compress', 'crc32', 'deflate', 'gzclose', 'gzlib', 'gzread', 'gzwrite', 'infback', 'inffast',
    'inflate', 'inftrees', 'trees', 'uncompr', 'zutil')
foreach ($f in $LibzSrc) {
    Invoke-Native clang-cl (@('-c') + $CxxFlags + @('-DWIN32', '-DNDEBUG', '-D_WINDOWS', '-D_USRDLL', '-D_CRT_SECURE_NO_WARNINGS', '-D_CRT_NONSTDC_NO_DEPRECATE', '-DUNICODE', '-D_UNICODE',
            "-FI$Repo\libz\pch.h", "-I$Repo\libz", "-Fo${f}.obj", "$Repo\libz\$f.c"))
}
Invoke-Rc "$Repo\libz" 'zlib1.rc' "$Out\zlib1.res"
Invoke-Native lld-link (@('-dll', '-machine:x64', "-def:$Repo\libz\zlib.def", '-out:zlib1.dll', '-implib:zlib1.lib') + $LibDirs + $CrtNoDefault +
    ($LibzSrc | ForEach-Object { "$_.obj" }) + @('zlib1.res') + $CrtLibs + @('kernel32.lib'))

Write-Host "=== common.lib (static, used by imcrvmgr/imcrvcnf) ==="
$CommonLibSrc = @('common', 'configxml', 'eucjis2004', 'eucjis2004table', 'eucjp', 'eucjptable', 'parseskkdic', 'utf8')
foreach ($f in $CommonLibSrc) {
    Invoke-Native clang-cl (@('-c') + $CxxFlags + @('-DWIN32', '-DNDEBUG', '-D_LIB', '-DUNICODE', '-D_UNICODE',
            "-FI$Repo\common\pch.h", "-I$Repo\common", "-Focommon_lib_${f}.obj", "$Repo\common\$f.cpp"))
}
Invoke-Native llvm-lib (@('-machine:x64', '-out:common.lib') + ($CommonLibSrc | ForEach-Object { "common_lib_$_.obj" }))

Write-Host "=== common.obj (compiled directly into imcrvtip, per upstream layout) ==="
$ImcrvtipCommonSrc = @('common', 'configxml', 'utf8')
foreach ($f in $ImcrvtipCommonSrc) {
    Invoke-Native clang-cl (@('-c') + $CxxFlags + @('-DWIN32', '-DNDEBUG', '-D_WINDOWS', '-D_USRDLL', '-DUNICODE', '-D_UNICODE',
            "-FI$Repo\imcrvtip\pch.h", "-I$Repo\imcrvtip", "-I$Repo\common", "-I$Repo\libinput", "-Fo${f}.obj", "$Repo\common\$f.cpp"))
}

Write-Host "=== imcrvtip.dll ==="
$ImcrvtipSrc = @(
    'CandidateKeyHandler', 'CandidateList', 'CandidatePaint', 'CandidateUIElement', 'CandidateWindow',
    'Compartment', 'CompartmentEventSink', 'Composition', 'ConfigTip', 'DisplayAttributeProvider',
    'DllMain', 'FunctionProvider', 'Globals', 'InputModeWindow', 'KeyEventSink', 'KeyHandler',
    'KeyHandlerCharacter', 'KeyHandlerComposition', 'KeyHandlerControl', 'KeyHandlerConversion',
    'KeyHandlerDictionary', 'LanguageBar', 'Property', 'Register', 'Server', 'TextEditSink', 'TextService',
    'ThreadFocusSink', 'ThreadMgrEventSink'
)
foreach ($f in $ImcrvtipSrc) {
    Invoke-Native clang-cl (@('-c') + $CxxFlags + @('-DWIN32', '-DNDEBUG', '-D_WINDOWS', '-D_USRDLL', '-DUNICODE', '-D_UNICODE',
            "-FI$Repo\imcrvtip\pch.h", "-I$Repo\imcrvtip", "-I$Repo\common", "-I$Repo\libinput", "-Fo${f}.obj", "$Repo\imcrvtip\$f.cpp"))
}
Invoke-Rc "$Repo\imcrvtip" 'imcrvtip.rc' "$Out\imcrvtip.res"
$ImcrvtipObjs = @('common.obj', 'configxml.obj', 'utf8.obj') + ($ImcrvtipSrc | ForEach-Object { "$_.obj" })
Invoke-Native lld-link (@('-dll', '-machine:x64', "-def:$Repo\imcrvtip\imcrvtip.def", '-out:imcrvtip.dll') + $LibDirs + $CrtNoDefault +
    @('-delayload:input.dll', '-delayload:d2d1.dll', '-delayload:dwrite.dll') + $ImcrvtipObjs + @('imcrvtip.res') +
    @('input.lib', 'd2d1.lib', 'dwrite.lib', 'delayimp.lib') + $CrtLibs +
    @('kernel32.lib', 'user32.lib', 'gdi32.lib', 'advapi32.lib', 'ole32.lib', 'oleaut32.lib',
        'shell32.lib', 'shlwapi.lib', 'xmllite.lib', 'bcrypt.lib', 'comctl32.lib', 'comdlg32.lib'))

Write-Host "=== imcrvmgr.exe (dictionary manager) ==="
$ImcrvmgrSrc = @('ConfigMgr', 'imcrvmgr', 'lcrvmgr', 'SearchCharacter', 'SearchDictionary', 'SearchSKKServer', 'SearchUserDictionary', 'Server')
foreach ($f in $ImcrvmgrSrc) {
    Invoke-Native clang-cl (@('-c') + $CxxFlags + @('-DWIN32', '-DNDEBUG', '-D_WINDOWS', '-DUNICODE', '-D_UNICODE',
            "-FI$Repo\imcrvmgr\pch.h", "-I$Repo\imcrvmgr", "-I$Repo\common", "-I$Repo\liblua", "-Fomgr_${f}.obj", "$Repo\imcrvmgr\$f.cpp"))
}
Invoke-Rc "$Repo\imcrvmgr" 'imcrvmgr.rc' "$Out\imcrvmgr.res"
Invoke-Native lld-link (@('-machine:x64', '-out:imcrvmgr.exe', '-subsystem:windows') + $LibDirs + $CrtNoDefault +
    ($ImcrvmgrSrc | ForEach-Object { "mgr_$_.obj" }) + @('imcrvmgr.res', 'lua55.lib', 'common.lib', 'ws2_32.lib') + $CrtLibs +
    @('kernel32.lib', 'user32.lib', 'gdi32.lib', 'advapi32.lib', 'ole32.lib', 'oleaut32.lib', 'shell32.lib', 'shlwapi.lib', 'xmllite.lib'))

Write-Host "=== imcrvcnf.exe (config dialog) ==="
$ImcrvcnfSrc = @('ConfigCnf', 'convtable', 'DlgDicAddUrl', 'DlgDicMake', 'DlgProcBehavior1', 'DlgProcBehavior2',
    'DlgProcConvPoint', 'DlgProcDictionary1', 'DlgProcDictionary2', 'DlgProcDisplay1', 'DlgProcDisplay2',
    'DlgProcDisplayAttr', 'DlgProcJLatin', 'DlgProcKana', 'DlgProcKeyMap', 'DlgProcPreservedKey', 'DlgProcSelKey', 'imcrvcnf')
foreach ($f in $ImcrvcnfSrc) {
    Invoke-Native clang-cl (@('-c') + $CxxFlags + @('-DWIN32', '-DNDEBUG', '-D_WINDOWS', '-DUNICODE', '-D_UNICODE',
            "-FI$Repo\imcrvcnf\pch.h", "-I$Repo\imcrvcnf", "-I$Repo\common", "-I$Repo\libz", "-Focnf_${f}.obj", "$Repo\imcrvcnf\$f.cpp"))
}
Invoke-Rc "$Repo\imcrvcnf" 'imcrvcnf.rc' "$Out\imcrvcnf.res"
Invoke-Native lld-link (@('-machine:x64', '-out:imcrvcnf.exe', '-subsystem:windows') + $LibDirs + $CrtNoDefault +
    ($ImcrvcnfSrc | ForEach-Object { "cnf_$_.obj" }) + @('imcrvcnf.res', 'zlib1.lib', 'common.lib', 'comctl32.lib', 'comdlg32.lib', 'wininet.lib', 'shcore.lib') + $CrtLibs +
    @('kernel32.lib', 'user32.lib', 'gdi32.lib', 'advapi32.lib', 'ole32.lib', 'oleaut32.lib', 'shell32.lib', 'shlwapi.lib', 'xmllite.lib'))

Write-Host "=== done: $Out ==="
Get-ChildItem "$Out\*" -Include *.dll, *.exe | Format-Table Name, Length, LastWriteTime
