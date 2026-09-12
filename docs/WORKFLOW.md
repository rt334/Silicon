# 提交与发布工作流（rt334）

本文件定义仓库的提交/发布规范与自动化，配套脚本位于 `scripts/`。

## 一、版本号规则

版本格式 **`a0.X.Y.Z`**，`a0.` 前缀固定不变。**版本号只在向主仓库（[SiliconMod/Silicon](https://github.com/SiliconMod/Silicon)）提交 PR 时递增，一个 PR 只对应一个版本号**；日常往自己仓库推提交、跑构建、发 fork 构建都**不动版本号**。

| 变更类型 | 规则 | 例（当前 `a0.12.4.4`） |
|---|---|---|
| **更新方块**（新增/改动方块） | `X+1`，其余归零 | `a0.13.0.0` |
| **更新功能**（无方块变更） | `Y+1`，末位归零 | `a0.12.5.0` |
| **修 bug** | `Z+1` | `a0.12.4.5` |

判定顺序：只要涉及方块，一律按「更新方块」处理（优先级最高）；否则看是功能还是修 bug。

**用法**：

```powershell
# 提上游 PR 前，按变更类型递增版本号，并在 README 更新日志插入新条目（自动去掉旧条目的「最新」后缀）
powershell -ExecutionPolicy Bypass -File scripts\version-bump.ps1 -Type block
powershell -ExecutionPolicy Bypass -File scripts\version-bump.ps1 -Type feature
powershell -ExecutionPolicy Bypass -File scripts\version-bump.ps1 -Type bug

# 带更新日志内容（UTF-8 文件，写入条目正文），并先看结果不落盘
powershell -ExecutionPolicy Bypass -File scripts\version-bump.ps1 -Type feature -EntryFile build\entry.md -DryRun
```

> 脚本只改两处：`mod.hjson` 的 `version`，以及 README「更新日志」里最新条目上方的插入。更新日志正文默认留一个 `- ` 占位，按需填内容。

## 二、往 rt334 推提交之后（fork 流水线）

**本地一条命令（推荐）**：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\fork-publish.ps1 -Message "[a0.13.0.0] fix: 描述"
```

依次完成：

1. 提交当前改动（`-Message` / `-MessageFile`，UTF-8 文件避免 PowerShell 引号问题）
2. 推送源分支到 `rt334`
3. 把本地 `fork/main` **先快进到远端**（CI 每次都会往它加一个 README 区块提交），再把源分支 **`--no-ff` 并入**（冲突则中止并恢复原分支，让你手动解）
4. 构建 jar（gradle，带代理回退）
5. 刷新滚动 release `fork-latest`（覆盖 jar 资产 + 重写说明）
6. 安装 jar 到 `%APPDATA%\Mindustry\mods\Silicon.jar`

> **README 最新构建区块由 CI 单一维护**：本地流程默认跳过（否则本地与 CI 会各自生成一版同区块提交、下次推送必被非快进拒绝）；确实需要本地写时加 `-LocalReadme`。

常用开关：`-SkipCommit`、`-SkipBuild`、`-SkipRelease`、`-SkipReadme`、`-SkipInstall`、`-LocalReadme`、`-DryRun`。

**CI（无需本地环境）**：推送到 `fork/main` 即触发 `.github/workflows/fork-publish.yml`；需要先把别的分支并进来时，在 Actions 页手动运行该工作流并填 `source_branch`。

**上游镜像不受影响**：`test` 保持与上游一致（用于对比与发起 PR），所有自动合并只发生在 `fork/main`。

## 三、release 与 README 策略

- **release**：单一滚动 tag **`fork-latest`**，每次构建覆盖其中的 `Silicon.jar` 资产，说明里列出分支/提交/时间/mod 版本与本次提交列表。
- **README**：自动维护**最新构建区块**（分支、提交、时间、下载链接），由脚本在 `<!-- FORK-BUILD:BEGIN -->` / `<!-- FORK-BUILD:END -->` 之间替换——**请勿手改该区块**。
- **更新日志**：仍**按版本号**人工/按需增加条目（与版本递增绑定），自动化不会代写业务内容。

## 四、跟踪其他开发者的仓库（便于随时拿 jar 本地测试）

清单在 `scripts/tracked-forks.json`，默认跟踪：`upstream`（上游主线）、`arc`（ARCloud217）、`xiaobei09`、`by514`、`sm09`（Silicon09）。要加人只需加一条记录（`name` / `repo` / `branch` / `remote` / `label`）。

```powershell
# 同步全部跟踪分支并打印状态表（tip / 日期 / 相对上游多出多少提交 / 已有 jar）
powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1

# 下载对方 release 里的 jar（最快）
powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action jar -Name arc

# 从对方源码构建 jar（临时 worktree，不碰当前工作树；对方未发 release 时用这个）
powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action build -Name arc

# 装进游戏测试（会先把现有 mods\Silicon.jar 备份到 build\tracked\）
powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action install -Name arc

# 看对方比上游多了哪些提交
powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action diff -Name xiaobei09
```

- 跟踪分支只存在**本地**，名为 `track/<name>`；**不把别人的代码镜像进我们仓库**（上游仓库没有 license 声明）。
- 下载/构建出的 jar 统一落在 `build/tracked/`，命名 `<name>-<tag|sha>.jar`，可反复取用。
- 网络抖动时脚本会自动在**直连与本地代理**之间来回重试。

## 五、提交信息与 PR 约定

- 提交格式：`[版本] 类型: 描述`，例如 `[a0.13.0.0] fix: 频谱表头居中`；类型用 `feat` / `fix` / `chore` / `docs` / `ci` / `merge`。
- 一个上游 PR 一个版本号：改完 → `version-bump.ps1` → 提交 → 推 `rt334` → 向上游开 PR。
- 提上游前建议先把分支与上游 `test` 同步（merge），并在本地跑通 `.\gradlew.bat compileJava jar`。
- 含中文的 API 负载**必须走文件 + curl**（`--data-binary @file`）；不要用 `Invoke-RestMethod -Body <字符串>`，PowerShell 5.1 会按 ASCII 发送把中文写成 `?`。
- `scripts/*.ps1` **保持纯 ASCII**（PS 5.1 在部分代码页下无法解析含非 ASCII 的 .ps1），中文文案统一放 `scripts/workflow-strings.json`（UTF-8）。
