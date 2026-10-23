---
name: svn-auto-commit
description: 在 SVN 工作副本里提交改动：先确认 svn CLI 可用（缺了就装好并修 PATH），提交前把涉及文件列给用户、update 检查并处理冲突，确认后再 commit。适用于 svn 仓库的日常提交与冲突处理，不用于 Git 仓库。
metadata:
  short-description: SVN 提交前检查、冲突处理与安全提交
---

# svn 自动提交

提交是不可撤销的对外动作，所以流程是：**确认工具 → 列文件 → 查冲突 → 处理冲突 → 再提交**。任何一步信息不全就停下问用户，不要猜。

## 1. 先确认 svn 可用

```powershell
powershell -NoProfile -File scripts/find-svn.ps1
```

返回 JSON：`svn_path` / `svn_version` / `source` / `on_path`。exit 0 可用，exit 1 未安装。探测顺序是 PATH → 每个固定盘的 `Program Files` / `Soft` / `Software` / `Apps` 下的 SlikSVN、TortoiseSVN、VisualSVN、Apache 安装目录（svn 装在 D:、E: 上也能找到）。

`on_path=false` 时**不要**依赖 `svn` 裸命令，直接用返回的绝对路径调用（同一次会话里改 PATH 不会自动生效）。

## 2. 缺 svn 时装（Windows）

按顺序选第一个可行的：

1. `winget install --id Slik.Subversion -e --source winget` —— 自带 `svn.exe`，安装器会写系统 PATH，装完直接可用。
2. 机器上已有 TortoiseSVN：它默认**不带**命令行客户端，需补装 CLI 组件。winget 安装可用 `--override "/quiet ADDLOCAL=CLI"`，但不保证生效——装完必须用 `find-svn.ps1` 复核；仍然找不到就改用 SlikSVN。
3. 没有 winget：从 <https://subversion.apache.org/packages.html#windows> 的官方推荐项（SlikSVN / VisualSVN）下载安装包，或装 TortoiseSVN 时勾选 “command line client tools”。

跨平台：macOS `brew install subversion`；Debian/Ubuntu `sudo apt install subversion`。

**关于“去 GitHub 下载 exe”**：Apache 的 GitHub 仓库只有源码，官方 Windows 二进制不发在 GitHub Releases。直链下载请用 SlikSVN / VisualSVN 官方站点；不要给用户一个 GitHub 上不存在的 exe 链接。

## 3. PATH 规则

- 优先选会自动写 PATH 的安装包（SlikSVN、VisualSVN 都行）。
- 只有解压式/手工安装才需要自己加：用户级 `[Environment]::SetEnvironmentVariable('Path', $new, 'User')`，当前会话同时 `$env:Path += ";<bin>"`。
- 新 PATH 只对新进程生效；不要去重启用户的终端或 IDE，继续用绝对路径即可。
- 改 PATH 属于系统级改动：仅在用户同意安装 svn 的情况下做，并明确告知改了用户级 Path。

## 4. 提交前：列文件 + 冲突检查

一次拿到全部前置信息，别反复问用户：

```powershell
powershell -NoProfile -File scripts/svn-preflight.ps1 -Path <工作副本里的路径> [-SvnPath <绝对路径>]
```

脚本只读（`svn info` + `svn status --xml` + `svn status -u --xml`，按 XML 解析，不受控制台编码/列宽影响），输出 JSON：`wc_root`、`url`、`revision`、`against`（远端最新 revision）、`local_changes`（`status`/`props`/`path`）、`unversioned`、`conflicted`（含 `conflicted` 项与 props 冲突）、`tree_conflicted`、`remote_pending`（远端有改动、尚未 update）、`remote_check_ok`、`remote_check_err`。

**先把文件表交给用户**，再谈提交。表里至少要有：路径、状态码（`M`/`A`/`D`/`?`/`C`）、是否属于用户说的那个功能。不属于本次功能的改动要单独点出来，问是否一起提交（默认不提交）。

`unversioned` 的条目**不要自动 `svn add`**，逐个确认。

## 5. 冲突处理

`conflicted` 非空，或 `remote_pending` 非空时才需要 update：

```powershell
svn update --accept postpone <wc_root>
```

- `--accept postpone` 把冲突落到工作副本（生成 `.mine` / `.rOLD` / `.rNEW`），信息最全，比自动 `theirs-full` 安全。
- 树冲突（`tree_conflicted` 非空，`svn status` 第 7 列 `>`，例如本地新增与远端同路径新增、改/删交叉）**不要脚本化处理**，先向用户说明两个方向的区别再动手。
- 属性冲突（第 2 列 `C`，常见于 `svn:mergeinfo`、`svn:externals`）同样先问。

可自动处理的边界：

| 情况 | 处理 |
| --- | --- |
| 文本冲突，本地侧就是用户要的功能 | 取本地内容，`svn resolve --accept working <file>` |
| 文本冲突，远端侧是无关格式化/别人的改动 | 取远端内容后重跑构建或测试 |
| 二进制文件冲突 | 停，问用户留哪一版 |
| 树冲突 / 属性冲突 / externals 变更 | 停，问用户 |

解决后**必须** `svn resolve --accept working <file>` 标记 resolved，否则 commit 会拒绝。方向拿不准就问，别靠猜。

## 6. 提交前自检

1. `svn status` 中不应再有 `C`。
2. `svn diff <file...>` 扫一遍：没有调试代码、密钥、无关文件。
3. **显式列出要提交的路径**。默认 `svn commit .` 会带上整个副本的所有改动，是常见的误提交来源。
4. 认证/编码：命令可能卡在密码提示，先用 `--non-interactive` 试一次；中文提交信息写进文件再提交，并用 `--encoding UTF-8`：

```powershell
svn commit -F msg.txt --encoding UTF-8 --non-interactive <file1> <file2> ...
```

5. 提交信息按仓库习惯写（`svn log -l 5` 看几条）。

## 7. 收尾与汇报

- 报告 revision 号，`svn update` 让工作副本对齐。
- commit 被拒（需要 update、锁冲突、hook 拒绝）→ 回到第 5 步重新检查，**不要加 `--force`**、不要绕过 hook。
- 汇报结构：文件表 → 冲突与处理结果 → revision → 剩余风险（未提交的 `?` 文件等）。

## 注意事项

- 不要用管理员权限运行 `svn`：Windows 上会把工作副本文件改成管理员所有者，之后普通账号提交会失败。
- 用户只想看状态时，只跑 `svn-preflight.ps1`，不要顺手 commit。
