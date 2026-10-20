@echo off
rem ==========================================================================
rem  PCL Patcher (drag & drop friendly)
rem  ------------------------------------------------------------------------
rem  Usage:
rem    1) Drag "Plain Craft Launcher 2.exe" (or its folder) onto this file.
rem    2) Or just double-click it - it will search for PCL automatically.
rem
rem  NOTE: the batch part below MUST stay pure ASCII. All Chinese messages
rem  live in the PowerShell payload after the marker line, which is decoded
rem  as UTF-8 and executed from a temp .ps1 file.
rem ==========================================================================
setlocal EnableExtensions DisableDelayedExpansion

set "BATFILE=%~f0"
set "PSFILE=%TEMP%\pcl_patch_%RANDOM%%RANDOM%.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$b=[IO.File]::ReadAllBytes($env:BATFILE);$u=New-Object Text.UTF8Encoding($false,$true);try{$t=$u.GetString($b)}catch{$t=[Text.Encoding]::GetEncoding(936).GetString($b)};$m='#@@PCL_PATCH_PS@@#';$i=$t.LastIndexOf($m);if($i -lt 0){exit 9};$c=$t.Substring($i+$m.Length).TrimStart([char[]](13,10));[IO.File]::WriteAllText($env:PSFILE,$c,(New-Object Text.UTF8Encoding($true)))"

if errorlevel 1 (
    echo.
    echo  [ERROR] Cannot prepare the patch script.
    echo          Windows PowerShell 5.0 or newer is required.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%" -BatDir "%~dp0." -CurrentDir "%CD%" %*
set "RC=%ERRORLEVEL%"
del /f /q "%PSFILE%" >nul 2>&1
exit /b %RC%

#@@PCL_PATCH_PS@@#
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Targets,
    [string]$BatDir = '',
    [string]$CurrentDir = ''
)

$ErrorActionPreference = 'Stop'

# 归一化：$null / 空白参数直接丢掉（注意 @($null).Count 是 1，不能用它判断有无参数）
$Targets = @($Targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

$script:ExeName = 'Plain Craft Launcher 2.exe'
$script:Flags   = [Reflection.BindingFlags]'Public,NonPublic,Instance,Static,DeclaredOnly'
$script:Steps   = 5
$script:Done    = New-Object System.Collections.ArrayList

try { $Host.UI.RawUI.WindowTitle = 'PCL 一键补丁 - 把 exe 拖进来即可' } catch { }
try {
    if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) }
} catch { }

$script:Interactive = $true
try { if ([Console]::IsInputRedirected) { $script:Interactive = $false } } catch { }

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host ''
    Write-Host '  需要 Windows PowerShell 5.0 及以上版本（Windows 10/11 自带 5.1）。' -ForegroundColor Red
    Write-Host ('  当前版本：' + $PSVersionTable.PSVersion)
    if ($script:Interactive) { try { [void](Read-Host '  按回车键退出') } catch { } }
    exit 1
}

# ---------------------------------------------------------------- 输出helpers
function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkCyan
}

function Write-Step {
    param([int]$Number, [string]$Text)
    Write-Host ('  [{0}/{1}] {2}' -f $Number, $script:Steps, $Text) -ForegroundColor Yellow
}

function Write-Detail {
    param([string]$Text)
    Write-Host ('        ' + $Text)
}

function Write-Ok {
    param([string]$Text)
    Write-Host ('  [成功] ' + $Text) -ForegroundColor Green
}

function Write-Bad {
    param([string]$Text)
    Write-Host ''
    Write-Host ('  [失败] ' + $Text) -ForegroundColor Red
}

function Ask-Yes {
    param([string]$Question, [bool]$Default = $true)
    if (-not $script:Interactive) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $answer = Read-Host ('  ' + $Question + ' [' + $hint + ']')
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return ($answer.Trim() -match '^(y|yes|Y|是|好|确定)')
}

function Exit-WithPause {
    param([int]$Code = 0)
    if ($script:Interactive) {
        Write-Host ''
        try { [void](Read-Host '  按回车键退出') } catch { }
    }
    exit $Code
}

trap {
    Write-Host ''
    Write-Host ('  [异常] ' + $_.Exception.Message) -ForegroundColor Red
    if ($script:Interactive) { try { [void](Read-Host '  按回车键退出') } catch { } }
    exit 1
}

# ------------------------------------------------------------- 定位 exe / 分析
function Get-Candidates {
    param([string[]]$Roots)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $list = New-Object System.Collections.ArrayList
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $items = @()
        try {
            $items = Get-ChildItem -LiteralPath $root -Filter 'Plain Craft Launcher*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue
        } catch { }
        foreach ($it in $items) {
            if ($seen.Add($it.FullName)) { [void]$list.Add($it.FullName) }
        }
    }
    return , $list
}

function Expand-Target {
    param([string]$Path)
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Path)) { return , $out }

    $p = $Path.Trim()
    if ($p.Length -ge 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) { $p = $p.Substring(1, $p.Length - 2) }
    $p = $p.Trim()
    if (-not $p) { return , $out }

    # 备份文件（*.bak_时间戳）拖进来 = 还原
    if ($p -match '\.bak_\d{8}_\d{6}(_\d+)?$') {
        if (Test-Path -LiteralPath $p -PathType Leaf) { [void]$out.Add([IO.Path]::GetFullPath($p)) }
        else { Write-Bad ('备份文件不存在：' + $p) }
        return , $out
    }

    if (-not [IO.Path]::IsPathRooted($p)) {
        $joined = Join-Path (Get-Location).Path $p
        if (Test-Path -LiteralPath $joined) { $p = $joined }
    }

    if (Test-Path -LiteralPath $p -PathType Container) {
        $inner = Get-Candidates -Roots @($p)
        if ($inner.Count -eq 0) {
            Write-Bad ('这个文件夹里没找到 PCL 主程序：' + $p)
            return , $out
        }
        foreach ($i in $inner) { [void]$out.Add($i) }
        return , $out
    }

    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Write-Bad ('路径不存在：' + $p)
        return , $out
    }

    $ext = [IO.Path]::GetExtension($p)
    if ($ext -ieq '.exe') { [void]$out.Add([IO.Path]::GetFullPath($p)); return , $out }
    if ($ext -ieq '.zip' -or $ext -ieq '.7z' -or $ext -ieq '.rar') {
        Write-Bad '这是压缩包，请先解压出 exe 再拖进来。'
        return , $out
    }
    Write-Bad ('不支持的文件类型：' + $ext)
    return , $out
}

function Get-PclInfo {
    param([byte[]]$Bytes)

    $asm = [Reflection.Assembly]::Load($Bytes)
    $type = $asm.GetType('PCL.PageDownloadInstall', $false)
    if ($null -eq $type) { throw '找不到 PCL.PageDownloadInstall 类型，这可能不是 PCL 主程序。' }

    $method = $type.GetMethod('LoaderInit', $script:Flags)
    if ($null -eq $method) { throw '找不到 LoaderInit 方法，exe 版本不受支持。' }

    $modDownload = $asm.GetType('PCL.ModDownload', $false)
    if ($null -eq $modDownload) { throw '找不到 PCL.ModDownload 类型，exe 版本不受支持。' }

    $field = $modDownload.GetField('DlClientListLoader', [Reflection.BindingFlags]'Public,Static')
    if ($null -eq $field) { throw '找不到 DlClientListLoader 字段，exe 版本不受支持。' }

    return [pscustomobject]@{
        Assembly = $asm
        Version  = $asm.GetName().Version
        Type     = $type
        Method   = $method
        IL       = $method.GetMethodBody().GetILAsByteArray()
        Token    = $field.MetadataToken
    }
}

function Test-RestrictedIL {
    param([byte[]]$IL)
    return (
        $IL.Length -eq 94 -and
        $IL[0x19] -eq 0x14 -and
        $IL[0x1A] -eq 0x72 -and
        $IL[0x1F] -eq 0x7E -and
        $IL[0x4A] -eq 0x02 -and
        $IL[93] -eq 0x2A
    )
}

function Test-UnlockedIL {
    param([byte[]]$IL, [int]$Token)
    if ($IL.Length -lt 0x20) { return $false }
    if ($IL[0x1A] -ne 0x7E) { return $false }
    return ([BitConverter]::ToInt32($IL, 0x1B) -eq $Token)
}

# ------------------------------------------------------------------ 备份/还原
function New-Backup {
    param([string]$Path)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bak = '{0}.bak_{1}' -f $Path, $stamp
    $n = 1
    while (Test-Path -LiteralPath $bak) {
        $bak = '{0}.bak_{1}_{2}' -f $Path, $stamp, $n
        $n++
    }
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    return $bak
}

function Copy-Overwrite {
    param([string]$Source, [string]$Destination)
    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    $wasReadOnly = $false
    if ($item -and $item.IsReadOnly) { $wasReadOnly = $true; $item.IsReadOnly = $false }
    try {
        [IO.File]::Copy($Source, $Destination, $true)
    } finally {
        if ($wasReadOnly) { try { (Get-Item -LiteralPath $Destination -Force).IsReadOnly = $true } catch { } }
    }
}

function Get-ExeFromBackup {
    param([string]$BackupPath)
    return ($BackupPath -replace '\.bak_\d{8}_\d{6}(_\d+)?$', '')
}

# ------------------------------------------------------------------ 进程处理
function Stop-PclProcess {
    param([string]$ExePath)
    $name = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $true }

    Write-Host ('  检测到 PCL 正在运行（进程：' + $name + '）。') -ForegroundColor Yellow
    if (-not (Ask-Yes '是否自动关闭它，以便写入补丁？' $true)) { return $false }

    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
    Start-Sleep -Milliseconds 900
    foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 400
    return (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -eq 0)
}

# ---------------------------------------------------------------------- 还原
function Invoke-Restore {
    param([string]$BackupPath)

    $exe = Get-ExeFromBackup -BackupPath $BackupPath
    Write-Host ''
    Write-Host ('  >> 还原：' + $exe)

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        Write-Bad ('备份文件不存在：' + $BackupPath)
        return $false
    }

    $name = [IO.Path]::GetFileNameWithoutExtension($exe)
    if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) {
        if (-not (Stop-PclProcess -ExePath $exe)) {
            Write-Bad 'PCL 仍在运行，已跳过。请先退出 PCL 再重试。'
            return $false
        }
    }

    try {
        Copy-Overwrite -Source $BackupPath -Destination $exe
    } catch {
        Write-Bad ('还原失败：' + $_.Exception.Message)
        return $false
    }

    try {
        $info = Get-PclInfo -Bytes ([IO.File]::ReadAllBytes($exe))
        if (Test-UnlockedIL -IL $info.IL -Token $info.Token) {
            Write-Host '  还原完成，但该 exe 仍是已打补丁状态（备份本身可能已被修改）。' -ForegroundColor Yellow
        } else {
            Write-Ok ('已还原为原版程序：' + $exe)
        }
    } catch {
        Write-Ok ('已用备份覆盖：' + $exe)
    }
    return $true
}

# ---------------------------------------------------------------------- 打补丁
function Invoke-Patch {
    param([string]$ExePath)

    Write-Host ''
    Write-Host ('  >> ' + $ExePath)

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        Write-Bad '文件不存在。'
        return $false
    }

    $procName = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    if (@(Get-Process -Name $procName -ErrorAction SilentlyContinue).Count -gt 0) {
        if (-not (Stop-PclProcess -ExePath $ExePath)) {
            Write-Bad 'PCL 仍在运行，已跳过。请手动退出 PCL（含托盘图标）后重试。'
            return $false
        }
    }

    # ---- 1. 分析 ----
    Write-Step 1 '正在分析程序版本 ...'
    $bytes = [IO.File]::ReadAllBytes($ExePath)
    try {
        $info = Get-PclInfo -Bytes $bytes
    } catch {
        Write-Bad $_.Exception.Message
        Write-Detail '本工具只支持 PCL 2.x 的 .NET 版 Plain Craft Launcher 2.exe。'
        Write-Detail '（PCL CE / 其他启动器不适用）'
        return $false
    }
    Write-Detail ('版本 ' + $info.Version + '，文件大小 ' + $bytes.Length + ' 字节')

    if (Test-UnlockedIL -IL $info.IL -Token $info.Token) {
        Write-Host '  这个 exe 已经解除过下载限制，无需重复修改。' -ForegroundColor Green
        Write-Detail '如需还原：把同目录下的 *.bak_* 备份拖回本工具即可。'
        return $true
    }

    if (-not (Test-RestrictedIL -IL $info.IL)) {
        Write-Bad '没有找到预期的“关闭下载”代码，这个 exe 版本暂不支持。'
        Write-Detail ('LoaderInit 长度：' + $info.IL.Length + ' 字节（预期 94）')
        return $false
    }

    # ---- 2. 备份 ----
    Write-Step 2 '正在备份原程序 ...'
    try {
        $backupPath = New-Backup -Path $ExePath
    } catch {
        Write-Bad ('备份失败，已放弃修改：' + $_.Exception.Message)
        return $false
    }
    Write-Detail ('备份：' + $backupPath)

    # ---- 3. 定位代码 ----
    Write-Step 3 '正在定位待修改的代码 ...'
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $haystack = $latin1.GetString($bytes)
    $needle = $latin1.GetString($info.IL)
    $ilOffset = $haystack.IndexOf($needle, [StringComparison]::Ordinal)
    if ($ilOffset -lt 0) {
        Write-Bad '在 exe 文件里找不到 LoaderInit 的代码，已放弃修改。'
        return $false
    }
    if ($haystack.IndexOf($needle, $ilOffset + 1, [StringComparison]::Ordinal) -ge 0) {
        Write-Bad '文件中匹配到多处相同代码，为避免误改已停止。'
        return $false
    }

    # ---- 4. 写入 ----
    Write-Step 4 '正在写入补丁 ...'
    Write-Detail 'LoaderInit：限制加载器 -> DlClientListLoader'

    $patchedIL = [byte[]]$info.IL.Clone()
    $patchedIL[0x1A] = 0x7E
    [Array]::Copy([BitConverter]::GetBytes($info.Token), 0, $patchedIL, 0x1B, 4)
    for ($i = 0x1F; $i -lt 0x4A; $i++) { $patchedIL[$i] = 0x00 }

    $patchOffset = $ilOffset + 0x1A
    for ($i = 0; $i -lt 48; $i++) { $bytes[$patchOffset + $i] = $patchedIL[0x1A + $i] }

    # 直接覆盖写（保留只读属性状态）
    $item = Get-Item -LiteralPath $ExePath -Force
    $wasReadOnly = $item.IsReadOnly
    if ($wasReadOnly) { $item.IsReadOnly = $false }
    try {
        [IO.File]::WriteAllBytes($ExePath, $bytes)
    } catch {
        if ($wasReadOnly) { try { (Get-Item -LiteralPath $ExePath -Force).IsReadOnly = $true } catch { } }
        try { Copy-Overwrite -Source $backupPath -Destination $ExePath } catch { }
        Write-Bad '写入失败，已尝试还原原程序。请完全退出 PCL（包括托盘图标）后重试。'
        Write-Detail $_.Exception.Message
        return $false
    } finally {
        if ($wasReadOnly) { try { (Get-Item -LiteralPath $ExePath -Force).IsReadOnly = $true } catch { } }
    }

    # ---- 5. 校验 ----
    Write-Step 5 '正在校验修改结果 ...'
    try {
        $verify = Get-PclInfo -Bytes ([IO.File]::ReadAllBytes($ExePath))
    } catch {
        try { Copy-Overwrite -Source $backupPath -Destination $ExePath } catch { }
        Write-Bad '写入后无法重新解析程序，已自动还原。'
        return $false
    }
    if (-not (Test-UnlockedIL -IL $verify.IL -Token $verify.Token)) {
        try { Copy-Overwrite -Source $backupPath -Destination $ExePath } catch { }
        Write-Bad '写入后的校验没有通过，已自动还原为原程序。'
        return $false
    }
    try {
        [Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($verify.Method.MethodHandle)
    } catch {
        try { Copy-Overwrite -Source $backupPath -Destination $ExePath } catch { }
        Write-Bad '补丁后的代码无法通过编译，已自动还原为原程序。'
        Write-Detail $_.Exception.Message
        return $false
    }

    Write-Detail '校验通过：代码可正常编译，下载加载器已修复。'
    Write-Ok '解除限制成功！'
    [void]$script:Done.Add([pscustomobject]@{ Exe = $ExePath; Backup = $backupPath })
    return $true
}

# ================================================================== 主流程 ===
Write-Host ''
Write-Host '  ================================================================' -ForegroundColor Cyan
Write-Host '    PCL 下载限制解除工具' -ForegroundColor Cyan
Write-Host '    把 Plain Craft Launcher 2.exe 拖到本窗口 / 本文件上即可' -ForegroundColor Cyan
Write-Host '  ================================================================' -ForegroundColor Cyan

$queue = New-Object System.Collections.ArrayList
foreach ($t in @($Targets)) {
    foreach ($x in (Expand-Target -Path $t)) { [void]$queue.Add($x) }
}

# 拖进来了东西但一个都没识别出来 -> 直接停，不要偷偷去改别的文件
if ($queue.Count -eq 0 -and $Targets.Count -gt 0) {
    Write-Host ''
    Write-Host '  拖入的内容无法识别，已停止。' -ForegroundColor Yellow
    Exit-WithPause 1
}

# 没有拖入任何东西 -> 提示拖入 -> 再不行就自动查找
if ($queue.Count -eq 0 -and $script:Interactive) {
    Write-Host ''
    Write-Host '  没有收到拖入的文件。' -ForegroundColor Yellow
    Write-Host '  提示：把 "Plain Craft Launcher 2.exe" 直接拖到这个窗口里，路径会自动填进来。'
    for ($i = 0; $i -lt 3 -and $queue.Count -eq 0; $i++) {
        $line = Read-Host '  拖入后按回车（直接回车 = 自动查找）'
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        foreach ($x in (Expand-Target -Path $line)) { [void]$queue.Add($x) }
    }
}

if ($queue.Count -eq 0) {
    Write-Head '正在自动查找 PCL 主程序（就近优先）...'

    $tiers = @(
        @{ Label = '本文件所在目录'; Roots = @($BatDir, $CurrentDir) },
        @{ Label = '上一级目录';     Roots = @((Split-Path -Path $BatDir -Parent)) },
        @{ Label = '桌面 / 下载';    Roots = @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:USERPROFILE 'Downloads')) }
    )

    $cands = $null
    $scope = ''
    foreach ($tier in $tiers) {
        $found = Get-Candidates -Roots $tier.Roots
        if ($found.Count -gt 0) {
            $cands = @($found | Sort-Object -Unique)
            $scope = $tier.Label
            break
        }
    }

    if ($null -eq $cands -or $cands.Count -eq 0) {
        Write-Bad '没有找到 Plain Craft Launcher 2.exe。'
        Write-Host '  请把本文件放到 PCL 所在文件夹里，或把 exe / 文件夹拖到本文件上。'
        Exit-WithPause 1
    }

    if ($cands.Count -eq 1) {
        Write-Host ('  在' + $scope + '找到：' + $cands[0]) -ForegroundColor Green
        [void]$queue.Add($cands[0])
    } elseif (-not $script:Interactive) {
        Write-Bad ('在' + $scope + '找到 ' + $cands.Count + ' 个候选程序，非交互模式下无法选择。')
        exit 1
    } else {
        Write-Host ''
        Write-Host ('  在' + $scope + '找到 ' + $cands.Count + ' 个候选程序：') -ForegroundColor Yellow
        $show = [Math]::Min($cands.Count, 20)
        for ($i = 0; $i -lt $show; $i++) {
            Write-Host ('    [' + ($i + 1) + '] ' + $cands[$i])
        }
        if ($cands.Count -gt $show) { Write-Host ('    ... 还有 ' + ($cands.Count - $show) + ' 个未显示') }
        $sel = Read-Host '  输入序号（直接回车选 1）'
        $idx = 0
        if (-not [string]::IsNullOrWhiteSpace($sel)) { [void][int]::TryParse($sel.Trim(), [ref]$idx) }
        if ($idx -lt 1 -or $idx -gt $cands.Count) { $idx = 1 }
        [void]$queue.Add($cands[$idx - 1])
    }
}

# ---------------------------------------------------------------- 逐个处理 ---
$okCount = 0
$badCount = 0
foreach ($item in $queue) {
    try {
        if ($item -match '\.bak_\d{8}_\d{6}(_\d+)?$') {
            if (Invoke-Restore -BackupPath $item) { $okCount++ } else { $badCount++ }
        } else {
            if (Invoke-Patch -ExePath $item) { $okCount++ } else { $badCount++ }
        }
    } catch {
        Write-Bad $_.Exception.Message
        $badCount++
    }
}

# -------------------------------------------------------------------- 收尾 ---
Write-Host ''
Write-Host '  ----------------------------------------------------------------' -ForegroundColor DarkCyan
if ($badCount -eq 0) {
    Write-Host ('  全部完成：成功 ' + $okCount + ' 项。') -ForegroundColor Green
} else {
    Write-Host ('  完成：成功 ' + $okCount + ' 项，失败 ' + $badCount + ' 项。') -ForegroundColor Yellow
}
Write-Host '  ----------------------------------------------------------------' -ForegroundColor DarkCyan

if ($script:Done.Count -gt 0 -and $script:Interactive) {
    Write-Host '  本次备份：'
    foreach ($d in $script:Done) { Write-Host ('    ' + (Split-Path -Path $d.Backup -Leaf)) }
    Write-Host ''
    $key = Read-Host '  输入 R 还原备份 / L 启动 PCL / 直接回车退出'
    $key = if ($null -eq $key) { '' } else { $key.Trim().ToLower() }

    if ($key -eq 'r') {
        foreach ($d in $script:Done) { [void](Invoke-Restore -BackupPath $d.Backup) }
        Write-Host ''
        Write-Host '  已还原为原版 PCL。' -ForegroundColor Green
        Exit-WithPause 0
    } elseif ($key -eq 'l') {
        $d = $script:Done[$script:Done.Count - 1]
        try {
            Start-Process -FilePath $d.Exe -WorkingDirectory (Split-Path -Path $d.Exe -Parent)
            Write-Host '  已启动 PCL。' -ForegroundColor Green
        } catch {
            Write-Bad ('启动失败：' + $_.Exception.Message)
        }
    }
    if ($badCount -gt 0) { exit 1 }
    exit 0
}

if ($badCount -gt 0) { Exit-WithPause 1 }
Exit-WithPause 0
