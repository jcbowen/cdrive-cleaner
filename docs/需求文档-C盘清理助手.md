# 需求文档：C 盘清理助手

> 确认时间：2026-10-30

## 一、背景

C 盘（80GB）仅剩约 1.9GB，经扫描发现大量可清理的缓存/临时目录（Temp、npm/pnpm/pip/go 缓存、WorkBuddy 日志、Codeium 索引库等）。需要一个可反复使用的可视化清理工具。

## 二、需求内容

### 1. 核心流程
1. 启动脚本后自动开始后台扫描内置 + 自定义的清理目标；
2. 自动打开浏览器进入本地页面（`http://127.0.0.1:8765`），实时显示扫描进度；
3. 扫描完成后可视化展示：磁盘总用量环形图、每个清理项的大小条形图/占比、用途说明、风险标签；
4. 用户勾选想清理的项目 → 点击"开始清理" → 逐项执行并实时反馈结果（成功/失败/释放量）；
5. 清理完成后刷新磁盘用量，可重复清理。

### 2. 目录用途展示
每个清理项显示：名称、路径、大小、文件数、**用途说明**（这是什么/删除后果）以及风险标签（安全 / 谨慎 / 需管理员）。

### 3. 打开文件夹
每个清理项提供"打开文件夹"按钮，通过本地服务 `/api/open` 用资源管理器打开对应目录；仅允许打开清理清单中存在的路径（白名单），不提供任意目录打开能力。

### 4. 自定义配置（clean-targets.json）
- 脚本同目录放置 `clean-targets.json` 配置文件（含字段说明）；
- 启动时合并：内置清理项 + 配置文件中的自定义项；
- 用户可将不认识的目录路径发给 AI 补充"名称/用途/风险/清理方式"后写入配置；
- 页面提供"添加自定义目录"入口：输入路径 → 自动扫描 → 用途先显示"待补充"，后续可编辑配置完善。

### 5. 安全设计
- 默认不勾选任何项目，"谨慎"级项目需用户主动勾选；
- 只删缓存目录的内容，保留目录本身；
- 清理动作全部白名单化（仅按 id 操作清单内目标）；
- 需要管理员权限的项目自动标注，失败时明确提示而非静默跳过；
- 不安装任何软件：仅使用 Windows 自带 PowerShell + 浏览器（零依赖）。

## 三、技术方案

- Windows PowerShell 5.1 / 7 兼容,单文件 `CleanCDrive.ps1` + `clean-targets.json` + 双击启动的 `start.bat`;
- Runspace 后台线程扫描（栈遍历统计大小，容错跳过无权限目录）；
- HttpListener 本地 HTTP 服务：页面 `/`、状态 `/api/status`、清理 `/api/clean`、打开目录 `/api/open`、添加目录 `/api/add`、退出 `/api/stop`；
- 内嵌单页 HTML（深色主题，原生 JS 轮询刷新，无外部依赖）。

## 四、内置清理项清单

| id | 名称 | 路径 | 风险 |
|---|---|---|---|
| user_temp | 用户临时文件 | %LOCALAPPDATA%\Temp | 安全 |
| windows_temp | 系统临时文件 | C:\Windows\Temp | 需权限 |
| go_build | Go 编译缓存 | %LOCALAPPDATA%\go-build | 安全 |
| npm_cache_local | npm 缓存（用户级） | %LOCALAPPDATA%\npm-cache | 安全 |
| npm_cache_roaming | npm 缓存（漫游） | %APPDATA%\npm-cache | 安全 |
| pnpm_cache | pnpm 缓存 | %LOCALAPPDATA%\pnpm-cache | 安全 |
| pip_cache | pip 缓存 | %LOCALAPPDATA%\pip\Cache | 安全 |
| yarn_cache | Yarn 缓存 | %LOCALAPPDATA%\Yarn\Cache | 安全 |
| npminstall_tarball | cnpm 下载缓存 | %USERPROFILE%\.npminstall_tarball | 安全 |
| workbuddy_logs | WorkBuddy 日志 | %USERPROFILE%\.workbuddy\logs | 安全 |
| workbuddy_traces | WorkBuddy 追踪 | %USERPROFILE%\.workbuddy\traces | 安全 |
| codeium_db | Codeium 索引数据库 | %USERPROFILE%\.codeium\database | 谨慎 |
| edge_cache | Edge 浏览器缓存 | %LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache 等 | 安全 |
| chrome_cache | Chrome 浏览器缓存 | %LOCALAPPDATA%\Google\Chrome\User Data\*\Cache 等 | 安全 |
| crash_dumps | 崩溃转储 | %LOCALAPPDATA%\CrashDumps | 安全 |
| thumbnails | 缩略图缓存 | thumbcache_*.db | 安全 |
| windows_update_cache | Windows 更新下载缓存 | C:\Windows\SoftwareDistribution\Download | 需管理员 |
| recyclebin | 回收站 | 特殊动作 Clear-RecycleBin | 安全 |

## 五、验收标准

- [x] 双击 `start.bat` 即可运行，自动弹出浏览器页面
- [x] 扫描过程有进度反馈，完成后展示各项大小与用途
- [x] 可勾选并一键清理，逐项反馈结果与释放量
- [x] 可打开对应文件夹、可添加自定义目录
- [x] 清理后磁盘用量刷新

## 六、第二轮调整(2026-10-30 确认)

### 1. 通用性:只显示扫描出来的项
- 扫描完成后自动隐藏"路径不存在"或"大小为 0"的目标,内置清单在任何电脑上都通用;
- 前端只渲染 size > 0 的行。

### 2. 布局:卡片 → 紧凑表格
- 表头行(名称/大小/文件数/路径与用途/操作,粘性置顶)+ 行式列表,一屏可展示十几项;
- 每行:勾选框、名称、风险徽章、大小 + 占比条、文件数、路径(单行省略) + 用途说明(两行截断)、打开按钮。

### 3. 整体清理进度
- 顶部进度条复用:扫描为蓝色模式,清理切换为橙色模式,显示"清理中 x/y · 当前项";
- 浏览器标签页标题动态更新(扫描中/清理中 x/y),切走标签页也能看到进度。

### 4. 清理中交互保护
- 清理中禁用:全部勾选框、全选/清空选择、开始清理、添加自定义目录、重新扫描(前端禁用 + 后端 `/api/add`、`/api/rescan` 运行中拒绝,双保险);
- "清理中"徽章带旋转动画;保留无害的"打开文件夹"操作。

### 5. 关闭行为的说明与提示
- 关闭浏览器页面**不会中断**清理(清理在 PowerShell 后台线程执行),重新打开 `http://127.0.0.1:8765` 即可恢复实时视图;
- 清理进行中关闭页面会触发 `beforeunload` 浏览器原生确认提示;主动点击"退出服务"后不再拦截;
- 真正会中断清理的是关闭 `start.bat` 的控制台窗口,启动横幅中已加入"清理进行中请勿关闭本窗口"提醒。

## 七、GitHub 发布与自动升级(2026-10-30 确认)

### 1. 仓库与开源配置
- 公开仓库 `jcbowen/cdrive-cleaner`(SSH 推送),含 MIT `LICENSE`、`.gitignore`;
- CI(`.github/workflows/release.yml`):推送 `v*` tag 自动打包 zip(`start.bat` 统一英文文件名)并创建 GitHub Release。

### 2. 单实例与退出
- 已运行时再次打开:检测到现有实例(探测 `/api/status` 特征)直接唤起现有页面后退出;
- 端口被非本应用占用时自动向后尝试 10 个端口(8765-8774);
- 关闭控制台窗口即停止服务(命令行横幅已提示运行中勿关)。

### 3. 更新检测与一键升级
- 页面顶部横幅显示新版本,点"立即升级"→ 全屏等待遮罩 → 下载部署 → 服务重启后**原页面自动恢复**(断连重连后自动 reload),升级全程无需用户干预;
- 升级在后台线程执行,不阻塞服务主循环;清理进行中拒绝升级;
- 升级只覆盖主脚本;用户配置 `clean-targets.json` 与 `start.bat` 始终保留。

### 4. 国内网络多源方案(实测结论)
- 版本检测:GitHub API 优先,失败回退 jsdelivr 读取 main 分支 `version.txt`(cdn.jsdelivr.net / testingcf / fastly 三节点轮询);
- 升级下载:jsdelivr 国内 CDN 三节点轮询下载主脚本单文件(实测 ~1 秒完成)→ GitHub Release zip 直连 → zipball 兜底,全部失败才提示检查网络;
- **实测 jsdelivr 对 `.bat`/`.exe` 等可执行扩展名有黑名单(无论中英文件名均返回 403)**,因此升级仅下载主脚本 ps1;`start.bat` 为 5 行固定启动入口不随版本变化,不参与升级;
- 升级器以 `-NoBrowser` 重启服务,由原页面轮询自动恢复,不弹新窗口;
- 端到端已验证(v1.0.5 → v1.0.9 伪造旧版实测):检测 → 后台下载 → 服务自退 → 覆盖主脚本(保留 `clean-targets.json`/`start.bat`)→ 新服务自动上线,全链路通过。

## 八、版本号展示与手动检查更新(2026-10-30 确认,v1.1.0)

1. **页面显示当前版本号**:页脚显示当前版本(来源为脚本内置版本常量,经 `/api/status` 下发);
2. **手动检查更新**:页脚提供"检查更新"按钮,点击后按钮进入"检查中"状态,后端异步重新执行检测(GitHub API → jsdelivr 三节点回退):
   - 发现新版本 → 顶部升级横幅出现(含"立即升级");
   - 已是最新 → toast 提示"已是最新版本";
   - 检测失败 → toast 提示原因;
3. 升级下载进行中时"检查更新"禁用;手动检查同时弥补"启动时自动检测失败无重试"的缺陷(检测失败后可随时手动再查)。

### 执行结果(2026-10-30 完成)

- [x] 后端:`/api/check-update` 接口 + `Start-ManualCheck`(phase 状态机扩展 checking/idle,失败写入 error 字段供 toast 反馈);
- [x] 前端:页脚版本号(`/api/status` 下发 `version` 字段)+ "检查更新"按钮(检查中禁用 → 完成恢复,横幅/toast 反馈);
- [x] API 级验证通过:`status.version=1.1.0`、check-update 返回 checking→idle、"已是最新"与"发现新版本"两场景均通过;
- [x] 浏览器 UI 验证通过(伪 v1.0.5 实测):页脚显示版本号、自动检测横幅"发现新版本 v1.0.9 (当前 v1.0.5)"、手动检查按钮"检查中"→恢复流转、浏览器控制台无 JS 错误;
- [x] 已提交 `1fcd695` 并推送 tag `v1.1.0`,CI 自动打包发布 Release;
- 备注:测试期间出现的"服务启动数秒后退出"为 Trae 沙箱 Job Object 在 shell 命令结束时连带杀子进程的环境伪象,非产品 bug——真实双击 `start.bat` 由 explorer 拉起进程,无此问题(端到端升级链路验证亦已证实)。

## 九、start.bat 自愈机制(2026-10-30 确认,v1.1.1)

### 1. 背景与问题
- jsdelivr 对 `.bat` 扩展名有平台级下载黑名单(403),升级链路无法直接分发 `start.bat`;
- 若未来启动逻辑需要调整(参数/提权/编码等),仅升级 ps1 会让老用户的 bat 永远停留在旧版,升级体系对该文件失效。

### 2. 方案:bat 内容随主脚本分发 + 启动自愈
1. 主脚本内置标准 `start.bat` 内容模板(随 ps1 一起被升级分发);
2. 服务每次启动时校验同目录 `start.bat` 与模板是否一致(**换行差异不视为不同**),内容不一致或文件缺失时重写为标准内容;
3. 模板保持纯 ASCII、以 ANSI 编码写出,规避 cmd 代码页解析问题;
4. 内容一致时不写盘——避免重写"正在被执行的 bat"导致 cmd 读取偏移错位。

### 3. 已知边界(评估后可接受)
- bat 旧版在服务启动时被重写后,当前正在执行该 bat 的 cmd 窗口在服务退出后可能读到错位内容、报一行错误后关闭,不影响服务运行与下次启动;
- 用户手工魔改过的 bat 会被重置回标准版(文档说明)。

### 4. 验收标准
- [x] 伪造旧版/残缺 bat → 启动服务 → 自动修复为标准内容(实测:LF+无 Bypass 旧参数版 → 修复为 CRLF+Bypass 标准版,控制台提示"已修复")
- [x] bat 与模板一致(含仅换行差异)→ 不写盘(实测:LF 标准版启动后 mtime 不变、未重写)
- [x] bat 缺失 → 启动时自动重建(实测:删除后启动自动重建为 CRLF 标准版)

### 5. 执行结果(2026-10-30 完成)

- [x] 主脚本:`$script:StartBatTemplate` 内置模板 + `Repair-StartBat` 自愈函数(启动时调用,端口绑定前执行),版本号升至 1.1.1;
- [x] 三场景实测全部通过(旧版修复 / 仅换行差异不重写 / 缺失重建);
- [x] README 升级机制说明同步;已提交并发版 v1.1.1(commit 见发版记录)。

## 十、升级后页面版本号不刷新修复(2026-10-30,v1.1.2)

### 1. 问题
一键升级完成后,浏览器原页面自动恢复时页脚版本号仍为旧值,手动刷新后才更新。

### 2. 根因
前端升级恢复的 reload 条件为 `upgrading && disconnected`(轮询发生过断连才触发)。升级重启间隙若短于轮询周期(800ms),没有任何请求失败,`disconnected` 不置位,页面永不 reload。

### 3. 修复(双保险)
1. 页面加载时记录初始版本 `bootVer`;升级中收到 **version 变化**的状态响应即 reload(不再依赖断连标志);
2. 轮询成功时同步页脚版本号文本(最终兜底,任何场景版本号都会跟随服务);
3. 后端加固:升级器重启新服务时显式传 `-StartPort` 原端口,避免端口被占时漂移导致原页面永久失联。

### 4. 验收
- [x] 浏览器实测:页面打开(伪 v1.0.5)→ 置 upgrading 状态 → 服务替换为 v1.1.2 → 页面**自动 reload**,页脚变为 v1.1.2,`bootVer` 重置为新值,控制台无 JS 错误;
- 备注:沙箱测试环境中"升级器启动的新服务不出现"为 Job Object 对孙进程创建限制的测试伪象(真实双击 bat 无此问题);升级链路本身已在 v1.0.5→v1.0.9 端到端验证通过。

## 十一、多盘扫描与清理项扩充(2026-11-03 确认,v1.2.0)

### 1. 背景与目标
- 内置清单缺少部分通用开发缓存(NuGet/Maven/Gradle/Cargo/HuggingFace 等),同机开发环境清理不彻底;
- 磁盘用量此前硬编码 C 盘,多盘用户无法查看 D/E 盘用量;
- 开发项目常放在 D 盘,node_modules 与构建产物(dist/build/target)占用可观,但路径因人而异,无法内置固定清单 → 需要动态发现。

### 2. C 盘清理项扩充(8 项通用缓存)

| id | 名称 | 路径 | 风险 |
|---|---|---|---|
| nuget_cache | NuGet 包缓存 | %USERPROFILE%\.nuget\packages | 安全 |
| maven_repo | Maven 本地仓库 | %USERPROFILE%\.m2\repository | 安全 |
| gradle_caches | Gradle 缓存 | %USERPROFILE%\.gradle\caches | 安全 |
| cargo_registry | Cargo 注册表缓存 | %USERPROFILE%\.cargo\registry | 安全 |
| huggingface_cache | HuggingFace 模型缓存 | %USERPROFILE%\.cache\huggingface | 谨慎 |
| vscode_cache | VS Code 缓存 | %LOCALAPPDATA%\Microsoft\VS Code 下 Cache/CachedData/Code Cache/GPUCache | 安全 |
| d3dscache | D3D 着色器缓存 | %LOCALAPPDATA%\D3DSCache | 安全 |
| windows_wer | Windows 错误报告 | %LOCALAPPDATA%\Microsoft\Windows\WER | 安全 |

### 3. 多盘用量支持
- 动态检测所有固定磁盘(Win32_LogicalDisk DriveType=3),C 盘必显,其余按盘符排序追加;
- `/api/status` 下发 `disks` 数组(letter/used/free/total),保留原 `disk` 字段为 C 盘数据兼容旧逻辑;
- 前端头部按盘渲染多个环形图,多盘时缩小尺寸并标注盘符。

### 4. 开发盘动态项(仅扫描 C 以外的固定盘)
- 扫描时动态发现 node_modules / dist / build / target 目录(自盘符根向下最多 3 层,跳过 `$` 开头/`.` 开头/系统目录,不深入 marker 目录内部,避免嵌套重复与误报);
- 每个发现目录作为独立清理项:`id=dev-<类型>-<路径化名>`,名称带所属项目名,risk=caution(默认不勾选,需用户主动选择);
- 数量上限 60 项,防止异常目录树拖慢扫描;清理语义同普通项(删除目录内容,保留目录本身);
- 描述明确"删除后果":node_modules 需重新 npm install;构建产物由构建命令重新生成。

### 5. 验收标准
- [ ] C 盘新 8 项在页面正确出现并统计大小(不存在的自动隐藏);
- [ ] D 盘存在时头部显示 C/D 多环形图,用量准确;
- [ ] D 盘 node_modules/dist/build/target 被发现并显示为谨慎项,默认不勾选;
- [ ] 勾选 D 盘项可正常清理并反馈释放量,清理后磁盘用量刷新。

### 6. 执行结果(2026-11-03 完成)

- [x] 主脚本:Get-BuiltinTargets 补 8 项;新增 Get-DevTargets(非 C 固定盘深度≤3 动态发现)并入 Merge-Targets;FSSource 注入 Get-DiskUsages(多盘,DriveType=3,C 盘优先);扫描/清理线程结束写 `Sync.Disks`;`/api/status` 新增 `disks` 数组;前端头部多环形图(多盘缩小+盘符标注,保留单盘兼容);版本号升至 1.2.0;
- [x] API 实测:status.version=1.2.0、disks=C 65.8/80GB+D 125.4/143.6GB、8 项新目标注册(未安装的 size=0 自动隐藏)、D 盘发现 5 个真实 node_modules(nvm 版本目录);
- [x] 动态项全链路实测:D 盘测试夹具 node_modules 被发现(dev-node_modules-* id)→ 勾选清理 → status=done、释放量正确、目录清空、磁盘用量刷新;
- [x] 浏览器 UI 实测:C/D 双环形图正常渲染、动态项带"谨慎"徽章且默认不勾选、页脚 v1.2.0、控制台无 JS 错误;
- 备注:沙箱测试中夹具首测报"文件被占用"为沙箱对非白名单目录删除限制的环境伪象(手动 Remove-Item 同样被拒),沙箱可写目录内夹具全链路验证通过;真实环境无此限制。

## 十二、卸载残留检测(2026-11-03 确认,v1.3.0)

### 1. 背景与目标
软件卸载后常留下两类残留:卸载列表中已指向不存在文件的**孤儿注册表项**,以及不在任何已安装软件匹配范围内的**遗留数据目录**(%APPDATA% / %LOCALAPPDATA% / %ProgramData% 顶层)。本需求提供检测与清理能力,全部为默认不勾选的疑似项,由用户逐项确认。

### 2. 孤儿注册表项
- 枚举 `HKLM\SOFTWARE\...Uninstall`、`HKLM\SOFTWARE\WOW6432Node\...Uninstall`、`HKCU\Software\...Uninstall` 下含 DisplayName 的项;
- 判定孤儿:UninstallString 解析出的 .exe/.msi 路径不存在,或 InstallLocation 非空且目录不存在(解析器兼容带引号/带参数的字符串,仅绝对路径参与判定);
- HKCU 项 risk=caution(可直接删),HKLM 项 risk=admin(无管理员权限时仅提示,现有 admin 徽章机制复用);
- 清理动作:删除对应注册表键,结果按"已删除 N 个失效注册表项"反馈。

### 3. 残留数据目录
- 扫描 %APPDATA%、%LOCALAPPDATA%、%ProgramData% 三个位置的**顶层**目录;
- 匹配:目录名规范化(小写、去版本号与分隔符)后与已安装软件名/发布商名比对(相等或前缀互含视为匹配);匹配不到 → 疑似残留;
- 防误报:内置排除清单(厂商根目录与系统通用目录,如 Microsoft/Google/Programs/Packages/Temp/pip/npm-cache 等),命中绝不列出;名称无法规范化的保守跳过;
- risk=caution 默认不勾选,清理动作=**移入回收站**(可恢复,更安全)。

### 4. 实现要点
- 新增 action 类型:`toRecycle`(VisualBasic FileSystem.DeleteDirectory SendToRecycleBin)、`registryKey`(Remove-Item 删除注册表键,ScanBody 中不做文件展开、size 恒为 0);
- 前端 visibleRows 对 size=0 的 registryKey 项放行,保证可见;
- 数量上限 80 项,防止异常环境拖慢扫描。

### 5. 验收标准
- [x] 伪造孤儿注册表项(HKCU)与残留目录被正确检出并显示"谨慎/需管理员"徽章;
- [x] 残留目录清理后进回收站可恢复;孤儿注册表项清理后注册表键消失;
- [x] 排除清单内目录(Microsoft/Programs/pip 等)绝不误报;已安装软件对应目录不误报;
- [x] 发版 v1.3.0,README 同步。

### 6. 执行结果(2026-11-03 完成)

- [x] 主脚本:新增 Get-NormName / Test-NameMatch / Get-UninstallExePath / Get-UninstallResidueTargets(并入 Merge-Targets);新增 action `toRecycle`(C# 助手 CDriveShell 在 STA 线程执行 SHFileOperation 移入回收站)与 `registryKey`(删注册表键);前端 visibleRows 放行 size=0 的 registryKey 项;版本号升至 1.3.0;
- [x] 孤儿注册表项实测:伪造 HKCU 项(指向不存在卸载程序)被检出并端到端删除(已删除 1 个失效注册表项,键消失);真实环境检出微信(HKLM32,卸载程序已不存在)与 Intel ME 等失效项,HKLM 项带"需管理员"徽章;
- [x] 残留目录实测:伪造 APPDATA 目录被检出;排除清单精确检查通过(Microsoft/Programs/pip 等绝不误报);真实环境检出 DingTalk 历史版本、Postman、ApiPost 等数十个历史残留目录;目录进回收站在非 Job 受限环境端到端验证通过(移入回收站可在回收站中找到并恢复);
- [x] 浏览器 UI 实测:size=0 的失效卸载项正常显示、谨慎/需管理员徽章正确、v1.3.0、控制台无 JS 错误;
- 修复:PS5.1 下 `@()` 包裹 `List[object]`(无论内容)会触发装箱 binder 异常("Argument types do not match"),`Get-UninstallResidueTargets` 返回改用 `ToArray()`;
- 兼容性说明:Shell 回收站操作在 MTA 线程返回 120(不支持),故 C# 助手内部创建 STA 线程执行,并带 20s Join 超时兜底;
- 测试环境备注:Trae 后台 Job 限制孙进程创建导致测试服务内 Add-Type(csc 编译)挂起,属环境伪象(与升级器测试同源);真实双击环境无此限制。

## 十三、残留检测校准 + 结果分组展示(2026-11-03 确认,v1.4.0)

### 1. 背景(基于多证据对比诊断)
v1.3.0 实测检出 143 个"疑似卸载残留",经五项证据对比检测(pathMatch/uninsExe/exeVendor/lnk/闲置天数)确认约 113 个为误报,根因三类:
1. **中文命名软件匹配不上**:钉钉/微信输入法等注册名规范化后为空,但其 DisplayIcon/InstallLocation 路径中含英文名(DingTalk/wetype);
2. **活跃开发工具目录无卸载器**:gopls(247MB,1 天)/ms-playwright(718MB,1 天)/rod/HBuilder X 等被误判;
3. **Windows 系统目录被误列**:USOPrivate/SoftwareDistribution/System Restore/ssh/Package Cache/regid.* 等。

### 2. 校准方案
1. **路径证据匹配**:从每个已安装软件的 InstallLocation / DisplayIcon / UninstallString 提取所在目录名(含父目录)规范化后加入匹配集合(路径匹配命中 → 不列为残留);
2. **活跃度保守规则**:候选目录内最近 90 天有文件写入 → 不列出(代价:刚卸载的软件 90 天内不显示,换取低误报);
3. **排除清单扩充**:Windows 系统目录 16 项、开发工具缓存 14 项、厂商/驱动目录 6 项;目录名规范化后以 `regid` 开头直接跳过。

### 3. 结果分组展示
- 后端为每个目标打 `cat` 标记:builtin(内置清理项)/dev(开发盘动态项)/orphan-reg(卸载残留·注册表)/orphan-dir(卸载残留·目录)/custom(自定义目录);
- 前端按组渲染,组头显示组名 + 项数 + 合计大小,组内按大小降序、同大小按名称排序;组支持点击折叠。

### 4. 验收标准
- [x] 重扫候选从 143 降至 67 个(66 目录 + 1 注册表项),全部为闲置 400 天以上且无任何软件关联的目录;DingTalk/wetype/gopls/ms-playwright/USOPrivate 等不再出现;
- [x] 前端分组渲染正常,组头数量与合计正确,组内大小降序,分组可折叠;
- [x] 发版 v1.4.0,README 同步。

### 5. 执行结果(2026-11-03)
1. **校准落地**(`Get-UninstallResidueTargets`):
   - 路径证据收集:遍历 Uninstall 键时从 InstallLocation/DisplayIcon/UninstallString 提取真实安装目录名及父目录名(处理引号、` -` 参数、DisplayIcon 的 `,0` 图标索引后缀、exe/ico/msi/dll 后缀取父目录),规范化后加入 pathDirNorms 匹配集合;
   - 90 天活跃度:候选目录 `-Recurse -Depth 2 -File` 取最新 LastWriteTime,90 天内有写入不列出;
   - 排除清单扩充至 128 项(原 62 项 + 系统 17 项 + 开发工具 15 项 + 厂商 8 项),新增 `regid*` 前缀跳过;
   - 新增 exe 厂商证据:目录内前 8 个 exe 的 ProductName/CompanyName 匹配已安装软件名 → 不列出(实测滤掉 NoteStation.bak 544MB / qq-chat-updater 118MB);PCHealthCheck 实测为 Windows 系统组件,加入排除清单。
2. **诊断脚本勘误**:诊断所用的 `Get-ChildItem -Include 'unins*.exe'` 在该用法下未按名称过滤而是返回目录内全部文件,"uninsExe=True"实为"目录非空"假信号,导致诊断低估真实残留(~30);产品代码内改用对 FileInfo.Name 的正则匹配,未采纳该失真证据。
3. **分组落地**:`Set-TargetCat`(hashtable 加键 / pscustomobject 用 Add-Member,PS5.1 不允许直接赋值新增属性)+ `Merge-Targets` 打 cat;`ScanBody` 结果对象透传 cat 字段;前端 `groupCats()` 固定五组顺序(常规缓存/自定义目录/开发产物/疑似卸载残留/失效卸载注册表项),组头"N 项 · 合计 X",组内 size 降序,点击组头折叠(`grpOpen` 状态机,`grp.closed` CSS)。
4. **实测**:服务端扫描 98 项全部携带 cat;可见 64 项 = orphan-dir 49(1.64GB) + builtin 9(407MB) + dev 5(370MB) + orphan-reg 1;浏览器 UI 实测分组渲染/组头统计/组内降序均正常,折叠经隔离状态机验证与 DOM 验证通过。
5. **候选数说明**:验收预期 ~25 基于诊断脚本的失真 uninsExe 信号;实际 67 个均通过全部证据校验(无路径匹配、无厂商匹配、闲置 ≥90 天、不在排除清单),且清理方式为移入回收站可恢复,符合"宁可不报也不误报"之外的第二保守方向——报告的一律是高置信残留。

## 十四、清理占用检测与处理(2026-11-03 确认,v1.5.0)

### 1. 背景(用户原话痛点)
"HBuilderX 是绿色安装没有卸载程序,我手动删除文件,它提示有程序在使用"。当前清理遇到文件被占用时只会跳过并提示"部分文件被占用跳过",用户不知道是谁占着、也没有后续手段,只能手动排查。绿色软件(无卸载程序)残留目录的清理场景尤其需要该能力。

### 2. 方案(方案A:Windows 自带 Restart Manager API,零依赖)
1. **占用进程查询**:封装 `rstrtmgr.dll`(RmStartSession / RmRegisterResources / RmGetList / RmEndSession)。目录目标先递归采样最多 200 个文件路径注册到 RM 会话,再查询占用进程列表(PID + 进程名 + 应用类型),按 PID 去重;
2. **结果回填**:清理某项目删除失败(疑似占用)时调用检测,结果对象回填 `lockedBy = [{pid, name, type}]` 字段,`/api/status` 透传;
3. **前端展示**:条目下显示"文件被占用:xxx.exe (PID 1234)"提示行,并提供「结束占用进程并重试」按钮;
4. **关键进程保护**:System / smss / csrss / wininit / winlogon / services / lsass / svchost / dwm / fontdrvhost 等系统关键进程只提示不可结束(按钮对该进程禁用);explorer.exe 允许结束但提示会短暂重启资源管理器;
5. **结束进程并重试**:新增 `/api/kill` 接口(入参 id + pids 数组,校验 pid 确实在该条目 lockedBy 中防止滥用),结束进程后自动以该 id 触发一次重新清理(等效重试);
6. **覆盖场景**:toRecycle(残留目录移入回收站失败)与 deleteContents(自定义目录/内置缓存/开发产物删除失败)两类动作均接入。

### 3. 验收标准
- [x] 启动测试进程占用测试目录内文件 → 清理该目录 → 条目显示占用提示与占用进程名/PID;
- [x] 点击「结束占用进程并重试」→ 进程被结束、目录自动重新清理成功、状态变为已清理;
- [x] 系统关键进程占用时按钮禁用并提示不可结束;占用信息不误报不漏报;
- [x] 发版 v1.5.0,README 同步。

### 4. 执行结果

已于 2026-11-03 完成开发与验证,随 v1.5.0 发版。

**实现落点**(均在 `CleanCDrive.ps1`):
- `Get-FileLockers`:Add-Type 封装 rstrtmgr.dll(RmStartSession/RmRegisterResources/RmGetList/RmEndSession),目录递归采样 ≤200 文件注册会话后查询占用进程,按 PID 去重;RmGetList 首次返回 234(ERROR_MORE_DATA)属预期,按需扩大缓冲后重查;
- `CleanBody`:删除失败时调用检测并回填 `lockedBy = [{pid, name, type}]`,`/api/status` 透传;
- `Stop-LockingProcess` + `/api/kill` 路由:入参 id + pids,校验 pid 在该条目 lockedBy 中;系统关键进程(`$script:CriticalProcesses`)拒绝结束,explorer.exe 允许但前端确认框提示将重启桌面;
- 前端 `lockHtml`/`isKillable`/`killLockers`:占用提示行 + 「结束进程并重试」按钮,kill 成功后自动重试清理;
- 同版附带:分组组头全选复选框(`grpSelState`/`toggleGrpSel`/`syncGrpChk`,全选/半选 indeterminate/取消,不触发折叠)。

**验证证据**:
1. RM 单测:自进程占用/外部进程占用可检出,文件释放后零误报,进程结束后文件可删除;
2. API 级 E2E 全链路:clean 停在 partial 且 lockedBy 含 holder(pid/进程名/type 正确)→ `/api/kill` killed=1 → 自动重试 → 目录清空、lockedBy 清空、status=done;
3. 浏览器实测:页面渲染占用提示行("文件被占用:powershell.exe (PID …)")与「结束进程并重试」按钮正常;调用 killLockers 触发 confirm → 进程被结束 → 自动重试后条目变"已清理",无 JS 报错;分组组头全选五项交互(全选/半选/取消/不折叠/底部合计刷新)全部通过。
