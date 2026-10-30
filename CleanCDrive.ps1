<#
.SYNOPSIS
    C盘清理助手 - 扫描并可视化清理 C 盘可释放空间

.DESCRIPTION
    双击"启动.bat"或运行本脚本后：
      1. 后台 Runspace 线程扫描内置 + clean-targets.json 中的自定义清理目标；
      2. 启动本地 HTTP 服务(默认 127.0.0.1:8765)并自动打开浏览器；
      3. 页面实时展示扫描进度、磁盘用量、各目标大小/用途说明；
      4. 勾选目标后一键清理，逐项反馈释放量与失败原因。

.PARAMETER StartPort
    本地服务起始端口，被占用时自动向后尝试 10 个端口，默认 8765。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File CleanCDrive.ps1

.NOTES
    零依赖：仅使用 Windows 自带 PowerShell 与浏览器。清理动作仅按 id 白名单执行。
#>
[CmdletBinding()]
param(
    [int]$StartPort = 8765,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'

# 应用版本与发布仓库(更新检测/一键升级用;发布时打 v* tag 触发 CI 发版)
$script:Version = '1.0.1'
$script:Repo    = 'jcbowen/cdrive-cleaner'

#region ---------------- 全局配置 ----------------

$script:ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'clean-targets.json'
$script:DriveName  = 'C'

# 判断当前是否以管理员身份运行
# 返回值：$true=管理员；$false=普通权限
$principal  = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

#endregion

#region ---------------- 清理目标定义 ----------------

<#
.SYNOPSIS
    获取内置的清理目标清单
.DESCRIPTION
    每个目标包含 id、name、paths(支持通配符)、description、risk、action 字段。
    action: deleteContents=删除目录内容(保留目录本身)；recyclebin=清空回收站
    risk  : safe=安全；caution=谨慎；admin=需要管理员权限
.PARAMETER  无
.EXAMPLE
    $targets = Get-BuiltinTargets
#>
function Get-BuiltinTargets {
    $envU    = $env:USERPROFILE
    $envL    = $env:LOCALAPPDATA
    $envR    = $env:APPDATA

    return @(
        @{ id='user_temp';          name='用户临时文件';       paths=@("$envL\Temp");                                      risk='safe';    action='deleteContents'
            description='各类程序运行时产生的临时文件，清理后一般无影响，个别正在运行的程序会自动重建。' }
        @{ id='windows_temp';       name='系统临时文件';       paths=@('C:\Windows\Temp');                                 risk='safe';    action='deleteContents'
            description='Windows 系统级临时文件，部分文件需要管理员权限才能删除。' }
        @{ id='go_build';           name='Go 编译缓存';        paths=@("$envL\go-build");                                  risk='safe';    action='deleteContents'
            description='Go 工具链的编译产物缓存，删除后下次编译 Go 项目时自动重建，首次编译会变慢。' }
        @{ id='npm_cache_local';    name='npm 缓存(用户级)';   paths=@("$envL\npm-cache");                                 risk='safe';    action='deleteContents'
            description='npm 下载包的本地缓存，删除不影响已安装的项目依赖，后续安装包时会重新下载。' }
        @{ id='npm_cache_roaming';  name='npm 缓存(漫游)';     paths=@("$envR\npm-cache");                                 risk='safe';    action='deleteContents'
            description='npm 在 Roaming 目录下的缓存副本，删除不影响已安装的依赖。' }
        @{ id='pnpm_cache';         name='pnpm 缓存';          paths=@("$envL\pnpm-cache", "$envL\pnpm\store");            risk='safe';    action='deleteContents'
            description='pnpm 包管理器缓存与内容寻址存储，删除后已装项目不受影响，新安装会重新下载。' }
        @{ id='pip_cache';          name='pip 缓存';           paths=@("$envL\pip\Cache");                                 risk='safe';    action='deleteContents'
            description='Python pip 下载包缓存，删除后已安装的包不受影响。' }
        @{ id='yarn_cache';         name='Yarn 缓存';          paths=@("$envL\Yarn\Cache");                                risk='safe';    action='deleteContents'
            description='Yarn 包管理器下载缓存，删除不影响已有项目。' }
        @{ id='npminstall_tarball'; name='cnpm 下载缓存';      paths=@("$envU\.npminstall_tarball");                       risk='safe';    action='deleteContents'
            description='cnpm 安装时下载的 tgz 包缓存，可安全删除。' }
        @{ id='workbuddy_logs';     name='WorkBuddy 日志';     paths=@("$envU\.workbuddy\logs");                           risk='safe';    action='deleteContents'
            description='WorkBuddy 运行日志，纯记录用途，删除不影响功能。' }
        @{ id='workbuddy_traces';   name='WorkBuddy 追踪数据'; paths=@("$envU\.workbuddy\traces");                         risk='safe';    action='deleteContents'
            description='WorkBuddy 链路追踪/调试数据，可安全删除。' }
        @{ id='codeium_db';         name='Codeium 索引数据库'; paths=@("$envU\.codeium\database");                         risk='caution'; action='deleteContents'
            description='Codeium/Windsurf 插件的代码索引数据库。不再使用该插件可放心删；仍在使用则删除后插件会重建索引(耗时)。' }
        @{ id='edge_cache';         name='Edge 浏览器缓存';    paths=@("$envL\Microsoft\Edge\User Data\*\Cache", "$envL\Microsoft\Edge\User Data\*\Code Cache"); risk='safe'; action='deleteContents'
            description='Edge 浏览器网页缓存，删除后首次打开网页稍慢。浏览器运行时部分文件会被占用而跳过。' }
        @{ id='chrome_cache';       name='Chrome 浏览器缓存';  paths=@("$envL\Google\Chrome\User Data\*\Cache", "$envL\Google\Chrome\User Data\*\Code Cache"); risk='safe'; action='deleteContents'
            description='Chrome 浏览器网页缓存，删除后首次打开网页稍慢。浏览器运行时部分文件会被占用而跳过。' }
        @{ id='crash_dumps';        name='崩溃转储文件';       paths=@("$envL\CrashDumps");                                risk='safe';    action='deleteContents'
            description='程序崩溃时生成的转储文件，仅用于排查故障，可安全删除。' }
        @{ id='thumbnails';         name='缩略图缓存';         paths=@("$envL\Microsoft\Windows\Explorer\thumbcache_*.db"); risk='safe';   action='deleteContents'
            description='资源管理器缩略图缓存数据库，删除后打开图片文件夹时缩略图需重新生成。' }
        @{ id='windows_update_cache'; name='Windows 更新缓存'; paths=@('C:\Windows\SoftwareDistribution\Download');        risk='admin';   action='deleteContents'
            description='Windows 更新已下载的安装包缓存，删除后系统按需重新下载。需要管理员权限，且建议先停止 wuauserv 服务。' }
        @{ id='recyclebin';         name='回收站';             paths=@('RecycleBin');                                      risk='safe';    action='recyclebin'
            description='回收站中的已删除文件，清空后不可恢复。' }
    )
}

<#
.SYNOPSIS
    读取 clean-targets.json 中的自定义清理目标
.DESCRIPTION
    文件不存在或格式错误时返回空数组；enabled 为 false 的项跳过；缺失字段给默认值。
    返回值：目标对象数组(与 Get-BuiltinTargets 结构一致)，出错返回 @()
.EXAMPLE
    $custom = Get-CustomTargets
#>
function Get-CustomTargets {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return @() }
    try {
        $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "配置文件 clean-targets.json 解析失败：$($_.Exception.Message)"
        return @()
    }
    $list = @()
    foreach ($t in @($cfg.customTargets)) {
        if (-not $t) { continue }
        if ($t.enabled -eq $false) { continue }
        if (-not $t.paths -or @($t.paths).Count -eq 0) { continue }
        $list += @{
            id          = if ($t.id) { [string]$t.id } else { 'custom-' + [guid]::NewGuid().ToString('N').Substring(0,8) }
            name        = if ($t.name) { [string]$t.name } else { '自定义目录' }
            paths       = @($t.paths | ForEach-Object { [string]$_ })
            description = if ($t.description) { [string]$t.description } else { '用途待补充：可把该路径发给 AI 帮你完善说明。' }
            risk        = if ($t.risk) { [string]$t.risk } else { 'safe' }
            action      = if ($t.action) { [string]$t.action } else { 'deleteContents' }
        }
    }
    return $list
}

<#
.SYNOPSIS
    合并内置与自定义清理目标
.DESCRIPTION
    内置项在前、自定义项在后；按 id 去重(自定义项覆盖同 id 内置项)。
    返回值：目标数组
.EXAMPLE
    $all = Merge-Targets
#>
function Merge-Targets {
    $builtin = Get-BuiltinTargets
    $custom  = Get-CustomTargets
    $map = @{}
    foreach ($t in $builtin) { $map[$t.id] = $t }
    foreach ($t in $custom)  { $map[$t.id] = $t }
    return @($map.Values)
}

#endregion

#region ---------------- 文件系统测量(注入后台 Runspace 使用) ----------------

# 该源码字符串会被注入到扫描/清理 Runspace 中执行，包含三个工具函数
$script:FSSource = @'
function Measure-PathFs {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return @{ Bytes = [long]0; Files = [long]0 } }
    if (-not $item.PSIsContainer) { return @{ Bytes = [long]$item.Length; Files = [long]1 } }
    $bytes = [long]0
    $files = [long]0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($item.FullName)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                try {
                    $fi = New-Object System.IO.FileInfo($f)
                    if (($fi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $bytes += $fi.Length; $files++ }
                } catch { }
            }
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $di = New-Object System.IO.DirectoryInfo($d)
                    if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($d) }
                } catch { }
            }
        } catch { }
    }
    return @{ Bytes = $bytes; Files = $files }
}

function Expand-TargetRealPath {
    param([string[]]$Patterns)
    $out = @()
    foreach ($p in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p -eq 'RecycleBin') { continue }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($p)
        $items = @(Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue)
        foreach ($i in $items) { if ($i) { $out += $i.FullName } }
    }
    return @($out | Select-Object -Unique)
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}
'@

#endregion

#region ---------------- 后台扫描 ----------------

# 扫描线程主体：逐个目标测量大小，实时把进度与结果写入同步哈希表
$script:ScanBody = {
    param($sync, $targets, $fsSource)
    . ([scriptblock]::Create($fsSource))

    $sync.State   = 'scanning'
    $sync.Done    = 0
    $sync.Total   = @($targets).Count
    $sync.Current = ''
    $sync.Results = @()

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($targets)) {
        $sync.Current = $t.name
        $reals = Expand-TargetRealPath -Patterns @($t.paths)
        $size  = [long]0
        $files = [long]0
        foreach ($r in $reals) {
            $m = Measure-PathFs -Path $r
            $size  += $m.Bytes
            $files += $m.Files
        }
        $obj = [pscustomobject]@{
            id          = $t.id
            name        = $t.name
            paths       = @($t.paths)
            real        = @($reals)
            description = $t.description
            risk        = $t.risk
            action      = $t.action
            size        = $size
            files       = $files
            status      = ''
            message     = ''
        }
        $list.Add($obj)
        $sync.Done++
        $sync.Results = $list.ToArray()
    }

    $sync.State   = 'done'
    $sync.Current = ''
    $sync.Results = $list.ToArray()

    $d = Get-PSDrive -Name 'C'
    $sync.Disk = @{ used = [double]$d.Used; free = [double]$d.Free; total = ([double]$d.Used + [double]$d.Free) }
}

<#
.SYNOPSIS
    启动(或重启)后台扫描线程
.DESCRIPTION
    若上一次扫描尚未结束则先停止；扫描结果实时写入 $script:Sync.Results。
.PARAMETER  无
.EXAMPLE
    Start-Scan
#>
# 版本检测线程主体:查询 GitHub 最新 Release,与本地版本比对后写入 Sync.Update
$script:UpdateCheckBody = {
    param($sync, $repo, $cur)
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -TimeoutSec 8
        $latest = ('' + $rel.tag_name).TrimStart('v')
        $asset = @($rel.assets) | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        $newer = $false
        try { $newer = [version]$latest -gt [version]$cur } catch { }
        $sync.Update = @{
            available  = $newer
            current    = [string]$cur
            version    = [string]$rel.tag_name
            assetUrl   = if ($asset) { [string]$asset.browser_download_url } else { '' }
            zipballUrl = [string]$rel.zipball_url
        }
    } catch {
        $sync.Update = @{ available = $false; current = [string]$cur; version = ''; assetUrl = ''; zipballUrl = '' }
    }
}

# 异步启动一次版本检测(独立 runspace,不阻塞扫描与页面)
function Start-UpdateCheck {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:UpdateCheckBody).AddArgument($script:Sync).AddArgument($script:Repo).AddArgument($script:Version)
    [void]$ps.BeginInvoke()
}

function Start-Scan {
    if ($script:ScanPS -and -not $script:ScanHandle.IsCompleted) { $script:ScanPS.Stop(); $script:ScanPS.Dispose() }
    $targets = Merge-Targets
    $script:Sync.State   = 'scanning'
    $script:Sync.Done    = 0
    $script:Sync.Total   = @($targets).Count
    $script:Sync.Current = ''
    $script:Sync.Results = @()
    $script:Sync.Clean   = @{ state = 'idle'; done = 0; total = 0; current = '' }
    $script:ScanPS = [powershell]::Create()
    $script:ScanPS.AddScript($script:ScanBody).AddArgument($script:Sync).AddArgument($targets).AddArgument($script:FSSource) | Out-Null
    $script:ScanHandle = $script:ScanPS.BeginInvoke()

    # 顺带异步检查 GitHub 上的新版本
    Start-UpdateCheck
}

#endregion

#region ---------------- 后台清理 ----------------

# 清理线程主体：按 id 白名单逐项清理，回报释放量与被占用跳过数
$script:CleanBody = {
    param($sync, $ids, $fsSource)
    . ([scriptblock]::Create($fsSource))

    $clean = $sync.Clean
    $clean.state   = 'running'
    $clean.total   = @($ids).Count
    $clean.done    = 0
    $clean.current = ''

    $all = @($sync.Results)
    $releasedTotal = [double]0

    foreach ($id in @($ids)) {
        $t = $all | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $t) { continue }

        $clean.current = $t.name
        $t.status = 'cleaning'
        $before = [long]$t.size

        $reals = @()
        foreach ($r in @($t.real)) { if ($r) { $reals += $r } }
        $failed = 0

        if ($t.action -eq 'recyclebin') {
            try { Clear-RecycleBin -Force -ErrorAction Stop } catch { $failed++ }
        } else {
            foreach ($r in $reals) {
                $item = Get-Item -LiteralPath $r -Force -ErrorAction SilentlyContinue
                if (-not $item) { continue }
                if ($item.PSIsContainer) {
                    $children = @(Get-ChildItem -LiteralPath $r -Force -ErrorAction SilentlyContinue)
                    foreach ($c in $children) {
                        Remove-Item -LiteralPath $c.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $c.FullName) { $failed++ }
                    }
                } else {
                    Remove-Item -LiteralPath $r -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $r) { $failed++ }
                }
            }
        }

        $after = [long]0
        foreach ($r in $reals) {
            $m = Measure-PathFs -Path $r
            $after += $m.Bytes
        }
        $released = $before - $after
        if ($released -lt 0) { $released = 0 }
        $releasedTotal += $released
        $t.size = $after

        if ($t.action -eq 'recyclebin') {
            if ($failed -gt 0) { $t.status = 'partial'; $t.message = '部分项目被占用，未能完全清空' }
            else               { $t.status = 'done';    $t.message = "已清空回收站，释放 $(Format-Bytes -Bytes $released)" }
        }
        elseif ($failed -gt 0 -and $after -gt 0) {
            $t.status = 'partial'; $t.message = "已释放 $(Format-Bytes -Bytes $released)，部分文件被占用跳过"
        }
        elseif ($failed -gt 0) {
            $t.status = 'partial'; $t.message = "文件被占用，未能释放(建议关闭相关程序或以管理员运行)"
        }
        else {
            $t.status = 'done'; $t.message = "已释放 $(Format-Bytes -Bytes $released)"
        }
        $clean.done++
    }

    $clean.state   = 'done'
    $clean.current = ''
    $sync.LastReleased = $releasedTotal

    $d = Get-PSDrive -Name 'C'
    $sync.Disk = @{ used = [double]$d.Used; free = [double]$d.Free; total = ([double]$d.Used + [double]$d.Free) }
}

<#
.SYNOPSIS
    启动后台清理线程
.DESCRIPTION
    仅接受传入的 id 列表(在线程内按 id 匹配已扫描结果执行)，返回是否成功启动。
    清理进行中时拒绝重复启动。
.PARAMETER Ids
    要清理的目标 id 字符串数组
.PARAMETER Sync
    同步哈希表(由调用方传入)
.EXAMPLE
    Start-Clean -Ids @('user_temp','pip_cache') -Sync $sync
#>
function Start-Clean {
    param([string[]]$Ids, [hashtable]$Sync)
    if ($script:CleanPS -and -not $script:CleanHandle.IsCompleted) { return $false }
    if ($Sync.Clean.state -eq 'running') { return $false }
    $Sync.Clean = @{ state = 'running'; done = 0; total = @($Ids).Count; current = '' }
    $script:CleanPS = [powershell]::Create()
    $script:CleanPS.AddScript($script:CleanBody).AddArgument($Sync).AddArgument(@($Ids)).AddArgument($script:FSSource) | Out-Null
    $script:CleanHandle = $script:CleanPS.BeginInvoke()
    return $true
}

#endregion

#region ---------------- 页面资源 ----------------

<#
.SYNOPSIS
    返回内嵌的可视化单页 HTML
.DESCRIPTION
    深色主题，原生 JS 轮询 /api/status 刷新，无外部依赖。
    返回值：HTML 字符串
.EXAMPLE
    $html = Get-PageHtml
#>
function Get-PageHtml {
    return @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>C盘清理助手</title>
<style>
:root{
  --bg:#0f172a; --card:#1e293b; --card2:#243349; --line:#334155;
  --tx:#e2e8f0; --tx2:#94a3b8; --acc:#38bdf8; --green:#22c55e; --orange:#f59e0b; --red:#ef4444; --blue:#3b82f6;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--tx);font-family:"Segoe UI","Microsoft YaHei",system-ui,sans-serif;padding-bottom:96px}
header{display:flex;justify-content:space-between;align-items:center;padding:18px 28px;border-bottom:1px solid var(--line);flex-wrap:wrap;gap:16px}
h1{font-size:22px}
.sub{color:var(--tx2);font-size:12px;margin-left:8px}
.disk{display:flex;align-items:center;gap:14px}
.ring{width:84px;height:84px;transform:rotate(-90deg)}
.ring circle{fill:none;stroke-width:9;stroke-linecap:round}
.ring .bgc{stroke:#243349}
.ring .fgc{stroke:var(--acc);transition:stroke-dashoffset .6s}
.disk-info{font-size:13px;color:var(--tx2);line-height:1.7}
.disk-info b{color:var(--tx);font-size:16px}
#progress{padding:12px 28px;font-size:13px;color:var(--tx2);display:none;align-items:center;gap:12px}
.pbar{flex:1;max-width:460px;height:6px;background:#243349;border-radius:3px;overflow:hidden}
.pbar i{display:block;height:100%;background:linear-gradient(90deg,#38bdf8,#818cf8);width:0%;transition:width .4s;border-radius:3px}
#progress.cleaning .pbar i{background:linear-gradient(90deg,#f59e0b,#ef4444)}
#progress.cleaning #ptext{color:var(--orange)}
main{padding:8px 28px 20px}
.thead,.row{display:grid;grid-template-columns:34px minmax(170px,1.1fr) minmax(110px,.9fr) 92px minmax(0,2.2fr) 96px;gap:12px;align-items:center}
.thead{padding:8px 12px;color:var(--tx2);font-size:12px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:5}
.row{padding:10px 12px;border-bottom:1px solid #1b2537}
.row:hover{background:rgba(56,189,248,.045)}
.row input{width:16px;height:16px;accent-color:var(--acc);cursor:pointer}
.locking .row input{pointer-events:none;opacity:.45}
.nm{font-weight:600;font-size:14px}
.badges{display:flex;gap:6px;flex-wrap:wrap;margin-top:3px}
.badge{font-size:11px;padding:2px 8px;border-radius:999px;white-space:nowrap}
.b-safe{background:rgba(34,197,94,.15);color:var(--green)}
.b-caution{background:rgba(245,158,11,.15);color:var(--orange)}
.b-admin{background:rgba(59,130,246,.15);color:var(--blue)}
.b-cleaning{background:rgba(56,189,248,.18);color:var(--acc)}
.b-done{background:rgba(34,197,94,.15);color:var(--green)}
.b-partial{background:rgba(245,158,11,.15);color:var(--orange)}
.b-error{background:rgba(239,68,68,.15);color:var(--red)}
.b-cleaning::before{content:'';display:inline-block;width:9px;height:9px;border:2px solid rgba(56,189,248,.3);border-top-color:var(--acc);border-radius:50%;margin-right:5px;vertical-align:-1px;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.cellsize .sz{font-size:15px;font-weight:600;color:var(--acc);font-variant-numeric:tabular-nums}
.bar{height:4px;margin-top:4px;background:#243349;border-radius:2px;overflow:hidden}
.bar i{display:block;height:100%;border-radius:2px;background:linear-gradient(90deg,#38bdf8,#818cf8);transition:width .5s}
.ct{font-size:12.5px;color:var(--tx2);font-variant-numeric:tabular-nums}
.path{font-family:Consolas,monospace;font-size:11px;color:var(--tx2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.desc{font-size:12px;color:var(--tx2);opacity:.85;margin-top:2px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.msg{font-size:11.5px;margin-top:2px}
.m-done{color:var(--green)} .m-partial{color:var(--orange)} .m-error{color:var(--red)}
.warnline{font-size:11.5px;color:var(--orange);margin-top:2px}
.mini{background:var(--card2);border:1px solid var(--line);color:var(--tx2);font-size:12px;padding:5px 12px;border-radius:8px;cursor:pointer;white-space:nowrap}
.mini:hover{color:var(--tx);border-color:#64748b}
.mini:disabled{opacity:.4;cursor:not-allowed}
footer{position:fixed;left:0;right:0;bottom:0;background:rgba(15,23,42,.92);backdrop-filter:blur(8px);border-top:1px solid var(--line);display:flex;justify-content:space-between;align-items:center;padding:14px 28px;gap:14px;flex-wrap:wrap}
.selinfo{font-size:13px;color:var(--tx2)}
.selinfo b{color:var(--tx)}
.btns{display:flex;gap:8px;flex-wrap:wrap}
.btn{padding:9px 18px;border-radius:9px;border:1px solid var(--line);background:var(--card2);color:var(--tx);font-size:13px;cursor:pointer}
.btn:hover{border-color:#64748b}
.btn.primary{background:linear-gradient(90deg,#0ea5e9,#6366f1);border:none;font-weight:600}
.btn.primary:hover{filter:brightness(1.1)}
.btn.danger{background:transparent;border-color:#7f1d1d;color:#fca5a5}
.btn:disabled{opacity:.45;cursor:not-allowed}
#toast{position:fixed;top:20px;left:50%;transform:translateX(-50%);background:#334155;color:var(--tx);padding:10px 22px;border-radius:10px;font-size:13px;opacity:0;pointer-events:none;transition:opacity .3s;box-shadow:0 8px 24px rgba(0,0,0,.4);z-index:99;max-width:70vw}
.empty{grid-column:1/-1;text-align:center;color:var(--tx2);padding:60px 0;font-size:14px}
#updbanner{display:none;align-items:center;gap:12px;padding:10px 28px;background:rgba(245,158,11,.12);border-bottom:1px solid rgba(245,158,11,.4);font-size:13px;color:#fbbf24}
#updbanner.show{display:flex}
#updbanner b{color:#fbbf24}
#updmask{position:fixed;inset:0;background:rgba(15,23,42,.88);display:flex;align-items:center;justify-content:center;z-index:999}
#updmask .mbox{text-align:center;font-size:15px;color:var(--tx)}
#updmask .spin{width:42px;height:42px;border:4px solid rgba(56,189,248,.25);border-top-color:var(--acc);border-radius:50%;margin:0 auto 16px;animation:spin 1s linear infinite}
</style>
</head>
<body>
<header>
  <div><h1>C盘清理助手<span class="sub" id="port"></span></h1></div>
  <div class="disk">
    <svg class="ring" viewBox="0 0 100 100">
      <circle class="bgc" cx="50" cy="50" r="42"></circle>
      <circle class="fgc" id="ringfg" cx="50" cy="50" r="42" stroke-dasharray="263.9" stroke-dashoffset="263.9"></circle>
    </svg>
    <div class="disk-info" id="diskinfo">等待扫描…</div>
  </div>
</header>
<div id="updbanner"><span>发现新版本 <b id="updver"></b>(当前 <span id="updcur"></span>)</span><button class="btn primary" onclick="doUpgrade()">立即升级</button><button class="mini" onclick="hideUpd()">忽略</button></div>
<div id="updmask" style="display:none"><div class="mbox"><div class="spin"></div><div id="updmsg">正在升级…</div></div></div>
<div id="progress"><span id="ptext"></span><div class="pbar"><i id="pfill"></i></div></div>
<main id="main"><div class="empty">正在启动扫描…</div></main>
<footer>
  <div class="selinfo">已选 <b id="selc">0</b> 项 · 预计释放 <b id="selsz">0 B</b></div>
  <div class="btns">
    <button class="btn lockable" onclick="selSafe()">全选安全项</button>
    <button class="btn lockable" onclick="selNone()">清空选择</button>
    <button class="btn primary lockable" id="cleanbtn" onclick="doClean()">开始清理</button>
    <button class="btn lockable" onclick="addDir()">添加自定义目录</button>
    <button class="btn lockable" onclick="rescan()">重新扫描</button>
    <button class="btn danger" onclick="stopSrv()">退出服务</button>
  </div>
</footer>
<div id="toast"></div>
<script>
var st = {state:'init', results:[], disk:null, clean:{state:'idle'}, isadmin:false, total:0, done:0, current:''};
var sel = {};
var upgrading = false, disconnected = false, upgHidden = false;
var TITLE = 'C盘清理助手';

function fmt(b){
  if (b == null) return '0 B';
  if (b >= 1073741824) return (b/1073741824).toFixed(2) + ' GB';
  if (b >= 1048576) return (b/1048576).toFixed(1) + ' MB';
  if (b >= 1024) return (b/1024).toFixed(1) + ' KB';
  return b + ' B';
}
function esc(s){ return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;'); }

function toast(msg){
  var t = document.getElementById('toast');
  t.textContent = msg; t.style.opacity = 1;
  clearTimeout(t._h); t._h = setTimeout(function(){ t.style.opacity = 0; }, 3200);
}

function visibleRows(){
  return (st.results || []).filter(function(t){ return t.size > 0; });
}

function render(){
  var main = document.getElementById('main');
  var u = st.update, bn = document.getElementById('updbanner');
  if (u && u.available && !upgHidden) {
    bn.className = 'show';
    document.getElementById('updver').textContent = u.version;
    document.getElementById('updcur').textContent = 'v' + u.current;
  } else { bn.className = ''; }
  var cleaning = st.clean && st.clean.state === 'running';
  var pr = document.getElementById('progress');
  var pt = document.getElementById('ptext');
  var pf = document.getElementById('pfill');

  if (st.state === 'scanning') {
    pr.className = ''; pr.style.display = 'flex';
    var p = st.total > 0 ? Math.round(st.done / st.total * 100) : 0;
    pf.style.width = p + '%';
    pt.textContent = '扫描中 ' + st.done + '/' + st.total + (st.current ? ' · ' + st.current : '…');
    document.title = '扫描中 ' + st.done + '/' + st.total + ' - ' + TITLE;
  } else if (cleaning) {
    pr.className = 'cleaning'; pr.style.display = 'flex';
    var p2 = st.clean.total > 0 ? Math.round(st.clean.done / st.clean.total * 100) : 0;
    pf.style.width = p2 + '%';
    pt.textContent = '清理中 ' + st.clean.done + '/' + st.clean.total + (st.clean.current ? ' · ' + st.clean.current : '…');
    document.title = '清理中 ' + st.clean.done + '/' + st.clean.total + ' - ' + TITLE;
  } else {
    pr.style.display = 'none';
    document.title = TITLE;
  }

  if (st.disk) {
    var u = st.disk.used, f = st.disk.free, tt = st.disk.total;
    var C = 263.9;
    document.getElementById('ringfg').setAttribute('stroke-dashoffset', (C * (1 - u / tt)).toFixed(1));
    document.getElementById('diskinfo').innerHTML = '<b>' + fmt(u) + '</b> 已用 / ' + fmt(tt) + '<br>剩余 <b style="color:' + (f < 5368709120 ? '#f87171' : '#4ade80') + '">' + fmt(f) + '</b>';
  }

  var vis = visibleRows();
  if (st.state !== 'scanning') {
    var ids = vis.map(function(t){ return t.id; });
    Object.keys(sel).forEach(function(k){ if (ids.indexOf(k) < 0) delete sel[k]; });
  }
  applyLock(cleaning);

  if (!vis.length) {
    main.innerHTML = '<div class="empty">' + (st.state === 'scanning' ? '正在扫描,发现可清理项后将显示…' : '未发现可清理的内容(目标目录不存在或为空)') + '</div>';
    updateSel(); return;
  }
  var mx = 0;
  vis.forEach(function(t){ if (t.size > mx) mx = t.size; });
  var html = '<div class="thead"><div></div><div>名称</div><div>大小</div><div>文件数</div><div>路径与用途</div><div>操作</div></div>';
  vis.forEach(function(t){ html += rowHtml(t, mx); });
  main.innerHTML = html;
  updateSel();
}

function rowHtml(t, mx){
  var rb = t.risk === 'caution' ? '<span class="badge b-caution">谨慎</span>'
         : t.risk === 'admin' ? '<span class="badge b-admin">需管理员</span>'
         : '<span class="badge b-safe">安全</span>';
  var sb = t.status === 'cleaning' ? '<span class="badge b-cleaning">清理中</span>'
         : t.status === 'done' ? '<span class="badge b-done">已清理</span>'
         : t.status === 'partial' ? '<span class="badge b-partial">部分清理</span>'
         : t.status === 'error' ? '<span class="badge b-error">失败</span>' : '';
  var pct = mx > 0 ? (t.size / mx * 100) : 0;
  var paths = (t.real && t.real.length ? t.real : t.paths).join('   ');
  var canopen = t.real && t.real.length;
  return '<div class="row">'
    + '<div><input type="checkbox" ' + (sel[t.id] ? 'checked' : '') + ' onchange="toggleSel(\'' + t.id + '\', this.checked)"></div>'
    + '<div><div class="nm">' + esc(t.name) + '</div><div class="badges">' + rb + sb + '</div></div>'
    + '<div class="cellsize"><div class="sz">' + fmt(t.size) + '</div><div class="bar"><i style="width:' + pct + '%"></i></div></div>'
    + '<div class="ct">' + Number(t.files).toLocaleString() + '</div>'
    + '<div><div class="path" title="' + esc(paths) + '">' + esc(paths) + '</div>'
    + '<div class="desc" title="' + esc(t.description) + '">' + esc(t.description) + '</div>'
    + (t.risk === 'admin' && !st.isadmin ? '<div class="warnline">当前未以管理员身份运行，清理可能不完整</div>' : '')
    + (t.message ? '<div class="msg m-' + t.status + '">' + esc(t.message) + '</div>' : '')
    + '</div>'
    + '<div><button class="mini" ' + (canopen ? '' : 'disabled') + ' onclick="openDir(\'' + t.id + '\')">打开</button></div>'
    + '</div>';
}

function applyLock(on){
  document.getElementById('main').classList.toggle('locking', on);
  document.querySelectorAll('.lockable').forEach(function(b){ b.disabled = on; });
}

function updateSel(){
  var n = 0, s = 0;
  visibleRows().forEach(function(t){ if (sel[t.id]) { n++; s += t.size; } });
  document.getElementById('selc').textContent = n;
  document.getElementById('selsz').textContent = fmt(s);
}
function toggleSel(id, on){ sel[id] = on; updateSel(); }
function selSafe(){ visibleRows().forEach(function(t){ if (t.risk === 'safe') sel[t.id] = true; }); render(); }
function selNone(){ sel = {}; render(); }

function api(url, body){
  return fetch(url, body ? {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)} : {}).then(function(r){ return r.json(); });
}

function doClean(){
  var ids = Object.keys(sel).filter(function(k){ return sel[k]; });
  if (!ids.length) { toast('请先勾选要清理的项目'); return; }
  if (!confirm('确认清理选中的 ' + ids.length + ' 项吗？清理的文件不可恢复。')) return;
  api('/api/clean', {ids: ids}).then(function(r){
    if (r.ok) toast('清理任务已开始…');
    else toast(r.error || '启动失败');
  });
}
function addDir(){
  var p = prompt('请输入要加入清理清单的目录完整路径，例如 C:\\Some\\Cache');
  if (!p) return;
  api('/api/add', {path: p}).then(function(r){
    if (r.ok) toast('已添加并重新扫描');
    else toast(r.error || '添加失败');
  });
}
function rescan(){ api('/api/rescan', {}).then(function(){ toast('重新扫描已开始'); }); }
function openDir(id){ api('/api/open', {id: id}).then(function(r){ if (!r.ok) toast(r.error || '打开失败'); }); }
function stopSrv(){
  if (!confirm('确定退出清理助手吗？')) return;
  st.exiting = true;
  api('/api/stop', {}).then(function(){ document.body.innerHTML = '<div class="empty" style="padding-top:30vh">服务已停止，可以关闭此页面。</div>'; });
}
function hideUpd(){ upgHidden = true; document.getElementById('updbanner').className = ''; }
function doUpgrade(){
  var u = st.update;
  if (!u || !u.available) { toast('没有可用更新'); return; }
  if (!confirm('升级到 ' + u.version + '？升级期间服务会短暂重启，完成后页面自动恢复。')) return;
  var mask = document.getElementById('updmask');
  mask.style.display = 'flex';
  document.getElementById('updmsg').textContent = '正在下载新版本 ' + u.version + '…';
  api('/api/upgrade', {}).then(function(r){
    if (r.ok) {
      upgrading = true;
      document.getElementById('updmsg').textContent = '升级完成，服务重启中，页面将自动恢复…';
      return fetch('/api/stop', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'});
    }
    mask.style.display = 'none';
    toast(r.error || '升级失败');
  }).catch(function(){ mask.style.display = 'none'; toast('升级请求失败'); });
}

window.addEventListener('beforeunload', function(e){
  if (st.clean && st.clean.state === 'running' && !st.exiting) {
    e.preventDefault(); e.returnValue = '';
    return '';
  }
});

function poll(){
  fetch('/api/status').then(function(r){ return r.json(); }).then(function(d){
    if (upgrading && disconnected) { location.reload(); return; }
    var prevClean = st.clean ? st.clean.state : 'idle';
    st = d;
    if (prevClean === 'running' && st.clean.state === 'done') {
      var rel = st.lastReleased;
      toast('清理完成' + (rel ? '，共释放 ' + fmt(rel) : ''));
    }
    render();
  }).catch(function(){ disconnected = true; });
  setTimeout(poll, 800);
}
fetch('/api/status').then(function(r){ return r.json(); }).then(function(d){
  st = d;
  document.getElementById('port').textContent = ' · 127.0.0.1:' + d.port;
  render(); poll();
});
</script>
</body>
</html>
'@
}

#endregion

#region ---------------- HTTP 服务 ----------------

<#
.SYNOPSIS
    输出 JSON 响应
.DESCRIPTION
    序列化对象为 JSON 并以 UTF-8 写回响应流，随后关闭输出流。
.PARAMETER Ctx
    HttpListenerContext 上下文对象
.PARAMETER Obj
    要序列化的对象
.EXAMPLE
    Send-Json -Ctx $ctx -Obj @{ ok = $true }
#>
function Send-Json {
    param($Ctx, $Obj)
    $json = $Obj | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Ctx.Response.ContentType = 'application/json; charset=utf-8'
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.OutputStream.Close()
}

<#
.SYNOPSIS
    输出 HTML 响应
.DESCRIPTION
    以 UTF-8 写回 HTML 页面并关闭输出流。
.PARAMETER Ctx
    HttpListenerContext 上下文对象
.PARAMETER Html
    HTML 字符串
.EXAMPLE
    Send-Html -Ctx $ctx -Html (Get-PageHtml)
#>
function Send-Html {
    param($Ctx, [string]$Html)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Ctx.Response.ContentType = 'text/html; charset=utf-8'
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.OutputStream.Close()
}

<#
.SYNOPSIS
    读取 POST 请求的 JSON 请求体
.DESCRIPTION
    以 UTF-8 读取请求体并解析为 PSCustomObject；解析失败或空体返回 $null。
.PARAMETER Ctx
    HttpListenerContext 上下文对象
.EXAMPLE
    $body = Read-JsonBody -Ctx $ctx
#>
function Read-JsonBody {
    param($Ctx)
    try {
        $reader = New-Object System.IO.StreamReader($Ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

<#
.SYNOPSIS
    组装 /api/status 状态载荷
.DESCRIPTION
    汇总扫描状态、结果列表、磁盘用量、清理状态、管理员标记与服务端口。
    返回值：状态哈希表
.EXAMPLE
    $payload = Get-StatusPayload
#>
function Get-StatusPayload {
    $r = @($script:Sync.Results)
    $clean = $script:Sync.Clean
    if ($clean -isnot [hashtable] -and $clean) {
        $clean = @{ state = [string]$clean.state; done = $clean.done; total = $clean.total; current = [string]$clean.current }
    }
    return @{
        ok           = $true
        state        = [string]$script:Sync.State
        done         = $script:Sync.Done
        total        = $script:Sync.Total
        current      = [string]$script:Sync.Current
        results      = $r
        disk         = $script:Sync.Disk
        clean        = $clean
        lastReleased = [double]$script:Sync.LastReleased
        isadmin      = $script:IsAdmin
        port         = $script:Port
        update       = $script:Sync.Update
    }
}

<#
.SYNOPSIS
    执行一键升级:下载新版本包并部署升级器
.DESCRIPTION
    优先从 GitHub Release 资产下载 zip,否则回退 zipball;解压后生成 upgrade.ps1
    (等待当前进程退出、覆盖主脚本与启动 bat、保留用户配置 clean-targets.json、
    清理临时目录并以 -NoBrowser 重启服务),随后启动升级器进程并返回。
    实际文件覆盖由升级器在本服务退出后完成,页面经轮询自动刷新恢复。
.EXAMPLE
    $r = Start-Upgrade
#>
function Start-Upgrade {
    $u = $script:Sync.Update
    if (-not $u -or -not $u.available) { return @{ ok = $false; error = '没有可用更新' } }
    $dest = $PSScriptRoot
    $tmp  = Join-Path $dest '.update_tmp'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $url = if ($u.assetUrl) { $u.assetUrl } else { $u.zipballUrl }
        $zip = Join-Path $tmp 'update.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 180 -UseBasicParsing
        $extract = Join-Path $tmp 'new'
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        # 兼容两种包结构:Release zip(CDriveCleaner/...)与 zipball(仓库名-tag/...)
        $src = Get-ChildItem -Path $extract -Recurse -Filter 'CleanCDrive.ps1' | Select-Object -First 1
        if (-not $src) { return @{ ok = $false; error = '下载内容中未找到主脚本' } }
        $srcDir  = $src.DirectoryName
        $batName = if (Test-Path (Join-Path $srcDir 'start.bat')) { 'start.bat' } else { '启动.bat' }
        $up = Join-Path $tmp 'upgrade.ps1'
        $content = @"
`$null = Wait-Process -Id $PID -Timeout 30 -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Copy-Item -Path '$srcDir\CleanCDrive.ps1' -Destination '$dest' -Force
Copy-Item -Path '$srcDir\$batName' -Destination '$dest\启动.bat' -Force
Start-Sleep -Milliseconds 300
Remove-Item -Path '$tmp' -Recurse -Force -ErrorAction SilentlyContinue
Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"'$dest\CleanCDrive.ps1'"
"@
        Set-Content -Path $up -Value $content -Encoding UTF8
        Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$up`"" -WindowStyle Hidden
        return @{ ok = $true }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

<#
.SYNOPSIS
    处理添加自定义目录请求
.DESCRIPTION
    校验目录存在与重复后追加到 clean-targets.json，并触发重新扫描。
    返回值：@{ ok = $true } 或 @{ ok = $false; error = '原因' }
.PARAMETER PathText
    用户输入的目录路径
.EXAMPLE
    $r = Add-CustomTarget -PathText 'C:\Some\Cache'
#>
function Add-CustomTarget {
    param([string]$PathText)
    if ($script:Sync.Clean.state -eq 'running') { return @{ ok = $false; error = '清理正在进行中，请稍候' } }
    if ([string]::IsNullOrWhiteSpace($PathText)) { return @{ ok = $false; error = '路径为空' } }
    $p = [System.Environment]::ExpandEnvironmentVariables($PathText.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $p)) { return @{ ok = $false; error = "路径不存在：$p" } }
    $item = Get-Item -LiteralPath $p -Force
    if (-not $item.PSIsContainer) { return @{ ok = $false; error = '请输入目录路径而非文件' } }

    # 归一化后查重(配置文件与内置清单都查)
    $norm = $item.FullName.TrimEnd('\').ToLower()
    foreach ($t in (Merge-Targets)) {
        foreach ($pt in @($t.paths)) {
            $exp = [System.Environment]::ExpandEnvironmentVariables([string]$pt).TrimEnd('\').ToLower()
            if ($exp -eq $norm) { return @{ ok = $false; error = '该目录已在清理清单中' } }
        }
    }

    try {
        $cfg = $null
        if (Test-Path -LiteralPath $script:ConfigPath) {
            $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if (-not $cfg) { $cfg = New-Object psobject }
        $arr = @()
        if ($cfg.customTargets) { $arr = @($cfg.customTargets) }
        $newTarget = New-Object psobject -Property @{
            id          = 'custom-' + (Get-Date -Format 'yyyyMMddHHmmss')
            name        = Split-Path -Path $item.FullName -Leaf
            paths       = @($item.FullName)
            description = '用途待补充：可把该路径发给 AI 帮你完善说明。'
            action      = 'deleteContents'
            risk        = 'caution'
            enabled     = $true
        }
        $arr = @($arr) + @($newTarget)
        $cfg | Add-Member -NotePropertyName customTargets -NotePropertyValue $arr -Force
        $json = $cfg | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        return @{ ok = $false; error = "写入配置失败：$($_.Exception.Message)" }
    }

    Start-Scan
    return @{ ok = $true }
}

<#
.SYNOPSIS
    处理打开文件夹请求
.DESCRIPTION
    按 id 在已扫描结果中查找目标，取其第一个实际存在的路径用资源管理器打开；
    仅允许打开清单内路径(白名单)。找不到或路径不存在返回错误。
.PARAMETER TargetId
    目标 id
.EXAMPLE
    $r = Open-TargetFolder -TargetId 'user_temp'
#>
function Open-TargetFolder {
    param([string]$TargetId)
    $t = @($script:Sync.Results) | Where-Object { $_.id -eq $TargetId } | Select-Object -First 1
    if (-not $t) { return @{ ok = $false; error = '未找到该清理项' } }
    $dirs = @()
    foreach ($r in @($t.real)) { if ($r) { $dirs += $r } }
    if (-not $dirs.Count) {
        foreach ($p in @($t.paths)) {
            $exp = [System.Environment]::ExpandEnvironmentVariables([string]$p)
            if ($exp -ne 'RecycleBin' -and (Test-Path -LiteralPath $exp)) { $dirs += $exp }
        }
    }
    if (-not $dirs.Count) { return @{ ok = $false; error = '该目标没有实际存在的目录' } }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($dirs[0])`""
    return @{ ok = $true }
}

<#
.SYNOPSIS
    分发处理单个 HTTP 请求
.DESCRIPTION
    路由:GET / 返回页面;GET /api/status 返回状态;POST /api/clean、/api/open、
    /api/add、/api/rescan、/api/stop 执行对应动作。异常统一返回 500 JSON。
.PARAMETER Ctx
    HttpListenerContext 上下文对象
.EXAMPLE
    Invoke-RequestHandler -Ctx $ctx
#>
function Invoke-RequestHandler {
    param($Ctx)
    $route = $Ctx.Request.Url.AbsolutePath
    try {
        if ($Ctx.Request.HttpMethod -eq 'GET' -and ($route -eq '/' -or $route -eq '/index.html')) {
            Send-Html -Ctx $Ctx -Html (Get-PageHtml)
            return
        }
        if ($route -eq '/api/status' -and $Ctx.Request.HttpMethod -eq 'GET') {
            Send-Json -Ctx $Ctx (Get-StatusPayload)
            return
        }
        if ($route -eq '/api/clean' -and $Ctx.Request.HttpMethod -eq 'POST') {
            $body = Read-JsonBody -Ctx $Ctx
            $ids = @()
            if ($body -and $body.ids) { $ids = @($body.ids | ForEach-Object { [string]$_ }) }
            if (-not $ids.Count) { Send-Json -Ctx $Ctx @{ ok = $false; error = '未指定清理目标' }; return }
            # 白名单校验:仅接受已扫描结果中存在的 id
            $known = @(@($script:Sync.Results) | ForEach-Object { $_.id })
            $valid = @($ids | Where-Object { $known -contains $_ })
            if (-not $valid.Count) { Send-Json -Ctx $Ctx @{ ok = $false; error = '目标不在清理清单中' }; return }
            $started = Start-Clean -Ids $valid -Sync $script:Sync
            if ($started) { Send-Json -Ctx $Ctx @{ ok = $true; count = $valid.Count } }
            else { Send-Json -Ctx $Ctx @{ ok = $false; error = '清理任务正在进行中，请稍候' } }
            return
        }
        if ($route -eq '/api/upgrade' -and $Ctx.Request.HttpMethod -eq 'POST') {
            if ($script:Sync.Clean.state -eq 'running') { Send-Json -Ctx $Ctx @{ ok = $false; error = '清理正在进行中，无法升级' }; return }
            Send-Json -Ctx $Ctx (Start-Upgrade)
            return
        }
        if ($route -eq '/api/open' -and $Ctx.Request.HttpMethod -eq 'POST') {
            $body = Read-JsonBody -Ctx $Ctx
            Send-Json -Ctx $Ctx (Open-TargetFolder -TargetId ([string]$body.id))
            return
        }
        if ($route -eq '/api/add' -and $Ctx.Request.HttpMethod -eq 'POST') {
            $body = Read-JsonBody -Ctx $Ctx
            Send-Json -Ctx $Ctx (Add-CustomTarget -PathText ([string]$body.path))
            return
        }
        if ($route -eq '/api/rescan' -and $Ctx.Request.HttpMethod -eq 'POST') {
            if ($script:Sync.Clean.state -eq 'running') { Send-Json -Ctx $Ctx @{ ok = $false; error = '清理正在进行中，请稍候' }; return }
            Start-Scan
            Send-Json -Ctx $Ctx @{ ok = $true }
            return
        }
        if ($route -eq '/api/stop' -and $Ctx.Request.HttpMethod -eq 'POST') {
            Send-Json -Ctx $Ctx @{ ok = $true }
            $script:StopRequested = $true
            try { $script:Listener.Stop() } catch { }
            return
        }
        $Ctx.Response.StatusCode = 404
        Send-Json -Ctx $Ctx @{ ok = $false; error = 'not found' }
    } catch {
        try {
            $Ctx.Response.StatusCode = 500
            Send-Json -Ctx $Ctx @{ ok = $false; error = $_.Exception.Message }
        } catch { }
    }
}

#endregion

#region ---------------- 主流程 ----------------

# 初始化同步状态表(扫描/清理线程与 HTTP 主线程之间的通信载体)
$script:Sync = [hashtable]::Synchronized(@{})
$script:Sync.State       = 'init'
$script:Sync.Done        = 0
$script:Sync.Total       = 0
$script:Sync.Current     = ''
$script:Sync.Results     = @()
$script:Sync.Disk        = $null
$script:Sync.Clean       = @{ state = 'idle'; done = 0; total = 0; current = '' }
$script:Sync.LastReleased = [double]0
$script:Sync.Update       = @{ available = $false; current = $script:Version; version = ''; assetUrl = ''; zipballUrl = '' }
$script:StopRequested    = $false
$script:Port             = $StartPort

# 绑定本地监听端口(被占用则向后尝试 10 个);
# 若探测到已有本工具实例在运行,则直接打开现有页面并退出(单实例模式)
$script:Listener = $null
foreach ($p in $StartPort..($StartPort + 9)) {
    $probe = $null
    try { $probe = Invoke-RestMethod -Uri "http://127.0.0.1:$p/api/status" -TimeoutSec 2 } catch { }
    if ($probe -and $probe.ok -and $null -ne $probe.results) {
        Write-Host "检测到清理助手已在运行(端口 $p),将直接打开现有页面。" -ForegroundColor Yellow
        Start-Process -FilePath "http://127.0.0.1:$p/"
        exit 0
    }
    try {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://127.0.0.1:$p/")
        $l.Start()
        $script:Listener = $l
        $script:Port = $p
        break
    } catch { }
}
if (-not $script:Listener) {
    Write-Host "错误：端口 $StartPort 至 $($StartPort+9) 均被占用，无法启动服务。" -ForegroundColor Red
    exit 1
}

Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '  C盘清理助手 已启动' -ForegroundColor Green
Write-Host "  地址：http://127.0.0.1:$script:Port/" -ForegroundColor Yellow
Write-Host '  停止服务：直接关闭本窗口即可停止服务，也可在页面上点击"退出服务"' -ForegroundColor Gray
Write-Host '  注意：清理进行中请勿关闭本窗口，否则清理会被中断' -ForegroundColor Yellow
Write-Host '==============================================' -ForegroundColor Cyan

# 启动首次扫描;升级器重启时传 -NoBrowser,由已打开的页面自动恢复
Start-Scan
if (-not $NoBrowser) { Start-Process -FilePath "http://127.0.0.1:$script:Port/" }

# 主循环：阻塞处理请求，/api/stop 或 Ctrl+C 退出
try {
    while ($script:Listener.IsListening -and -not $script:StopRequested) {
        $ctx = $script:Listener.GetContext()
        Invoke-RequestHandler -Ctx $ctx
    }
} catch {
    # Listener.Stop() 会使 GetContext 抛异常，视为正常退出路径
}

# 收尾：停止后台线程
foreach ($worker in @($script:ScanPS, $script:CleanPS)) {
    if ($worker) { try { $worker.Stop(); $worker.Dispose() } catch { } }
}
try { $script:Listener.Close() } catch { }
Write-Host '服务已退出。' -ForegroundColor Gray
#endregion
