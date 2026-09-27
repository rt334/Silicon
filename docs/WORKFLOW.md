# 分支同步约定（2026-09-27 起）

`feat/satellite-v2`（PR 分支）与 `fork/main` **保持内容一致**，唯一允许的差异是 **fork 的发布/自动化基础设施**：

- `.github/workflows/fork-publish.yml`
- `scripts/*`（fork-publish / fork-release / track-forks / version-bump / workflow-lib / workflow-strings / tracked-forks）
- `docs/WORKFLOW.md`（本文档）
- `README.md` 里的 `<!-- FORK-BUILD:BEGIN --> … <!-- FORK-BUILD:END -->` 区块（由发布流程自动维护）

**做法**：改动先落在 PR 分支（面向上游，不含任何 fork 专属内容），然后原样同步到 `fork/main`
（只多出上面那些基础设施文件与 README 区块）。反向同步（main → PR）时，必须剔除 fork 专属内容。
同步推送时注意把行尾归一化为 **LF**（本仓库工作区 `core.autocrlf=true`，直接推上传会写进 CRLF，
导致 PR diff 变成整文件重写）。