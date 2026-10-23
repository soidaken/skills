---
name: svn-auto-commit
description: 在 SVN 工作副本里提交改动：先确认 svn CLI 可用（缺了就装好并修 PATH），提交前把涉及文件列给用户、update 检查并处理冲突，确认后再 commit。适用于 svn 仓库的日常提交与冲突处理，不用于 Git 仓库。
metadata:
  short-description: SVN 提交前检查、冲突处理与安全提交
---

# svn 自动提交

提交是不可撤销的对外动作，所以流程是：**确认工具 → 列文件 → 查冲突 → 处理冲突 → 报告并等用户确认 → 再提交**。任何一步信息不全就停下问用户，不要猜。

## 硬性要求（不可协商）

1. **必须用户明确确认后才 commit**：把待提交的完整结果报告给用户，然后**停下、结束本轮**，等用户回复确认。用户说“svn 提交”“帮我提交”只是启动流程的意图，**不是**提交授权。
2. **提交说明必须 UTF-8**：写文件（UTF-8 无 BOM）+ `svn commit -F msg.txt --encoding UTF-8`，不要用内联 `-m` 传中文。
3. **不得边报告边提交**：报告与 commit 不能在同一轮完成；“我已经提交了你看看”是错误做法。
4. **冲突不靠猜**：二进制冲突、树冲突、属性/externals 冲突一律停下来问用户。

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

**先把文件表交给用户**，再谈提交（但这时**不要** commit，见第 6.2 节的确认门）。表里至少要有：路径、状态码（`M`/`A`/`D`/`?`/`C`）、是否属于用户说的那个功能。不属于本次功能的改动要单独点出来，问是否一起提交（默认不提交）。

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

### 5.1 逐个解决，搞不定的汇总上报

冲突要在**同一轮里逐个过**，不要遇到第一个就停住、也不要一次问一堆零碎问题：

1. `conflicted` 列表依次处理：看 `<<<<<<<` / `=======` / `>>>>>>>` 段落（或 `.mine` 与 `.rNEW` 的差异）→ 判断归哪一类 → 按上表处理 → `svn resolve --accept working <file>` → 再跑一次 `svn-preflight.ps1` 确认该项已消失。
2. 能自己处理的全部处理完；**处理不了的、或者拿不准取舍的**（二进制冲突、树冲突、属性/externals 冲突、两边都改了同一段业务逻辑）不要强行选一边。
3. 把剩下的整理成一张表，一次性交给用户确认，每行至少给：文件路径、冲突类型、本地侧改了什么、远端侧改了什么、你建议怎么选（取本地/取远端/手工合并）。然后停下等回复。
4. 汇总时明确告知：**当前不会提交**；待用户给出选择后再处理、重新 preflight、进确认门。

任何情况下不要用 `svn resolve --accept theirs-full` / `mine-full` 批量刷过全部冲突来“清掉红色状态”。用户没拍板的部分就留在冲突状态。

## 6. 提交前自检

1. `svn status` 中不应再有 `C`。
2. `svn diff <file...>` 扫一遍：没有调试代码、密钥、无关文件。
3. **显式列出要提交的路径**。默认 `svn commit .` 会带上整个副本的所有改动，是常见的误提交来源。
4. 认证：命令可能卡在密码提示，先用 `--non-interactive` 试一次（见第 6.1 节的提交说明编码要求）。
5. 提交信息按仓库习惯写（`svn log -l 5` 看几条）。

### 6.1 提交说明必须 UTF-8（硬性要求）

每条 commit message 都必须以 UTF-8 字节提交，不能依赖控制台默认编码。实测（svn 1.9.7 / Windows，控制台 ANSI cp936）：`svn commit -m "中文说明"` 存进去的是 GBK 字节，`svn log --xml` 读出来是 `ÖÐÎÄ...`——真乱码，不可逆；中文 hook / CI 也会因非 UTF-8 失败。

固定做法——**写文件 + `-F` + `--encoding UTF-8`**：

```powershell
# 明确以 UTF-8 无 BOM 写盘，避免 Win 默认编码
$msg = "修改登录超时判断`r`n`r`n1) 超时阈值改为可配置`r`n2) 补充单元测试"
[System.IO.File]::WriteAllText("$env:TEMP\svnmsg.txt", $msg, (New-Object System.Text.UTF8Encoding($false)))

svn commit -F "$env:TEMP\svnmsg.txt" --encoding UTF-8 --non-interactive <file1> <file2> ...
```

- 不用内联 `-m` 传中文；纯英文短说明也建议走同一路径，行为一致。
- 校验用 `svn log -l 1 --xml`：XML 固定 UTF-8，能看出真实存储内容。普通 `svn log` 按本地代码页输出，即使存储正确也可能显示成 `???`，不要拿它判断编码。
- 若已提交成乱码：先告知用户，不要靠“再提交一次”掩盖；改历史需要 `svn propset --revprop svn:log`，且要服务端 `pre-revprop-change` hook 允许，由用户决定。
- 提交说明过长时同样写文件，不要拼断命令行。

## 6.2 提交前的确认门（必须遵守）

`svn commit` 只在**用户看过报告并明确说“提交”之后**执行。固定两轮：

**第一轮——只报告，不提交。** 内容固定为：

1. 工作副本：`wc_root`、`url`、当前 revision、`against`。
2. 待提交文件表：路径 + 状态码 + 是否属于本次功能；`unversioned` 单独列、不自动 add。
3. 冲突：`conflicted` / `tree_conflicted` 及你的处理方式和结果（无冲突也要写明“无冲突”。）。
4. 待执行的提交说明草稿（完整文本）。
5. 一句明确的收口：“以上是否正确？回复确认我就提交（revision 会变）。”

**第二轮——用户确认后才提交。**

- 确认要来自用户本轮的明确回复（如“提交”“可以”“确认”）。没回复、只回了别的问题、或只改了需求，都属于未确认。
- 用户改动了文件范围或提交说明 → 用新参数重新报告一次，再等确认；不要拿旧确认去提交新内容。
- 用户确认后文件又被改动（自己修了冲突、跑了格式化）→ 重新执行 preflight，重新报告并再次确认。
- 用户拒绝或要求先看完整 diff → 只给 diff，不动 commit。

## 7. 收尾与汇报

- 报告 revision 号，`svn update` 让工作副本对齐。
- commit 被拒（需要 update、锁冲突、hook 拒绝）→ 回到第 5 步重新检查，**不要加 `--force`**、不要绕过 hook。
- 汇报结构：实际提交的文件 → commit message 首行 → revision → 剩余风险（未提交的 `?` 文件、未处理的冲突等）。

## 注意事项

- 不要用管理员权限运行 `svn`：Windows 上会把工作副本文件改成管理员所有者，之后普通账号提交会失败。
- 用户只想看状态时，只跑 `svn-preflight.ps1`，不要顺手 commit。
- 无人值守/自动化场景同样不豁免确认门：拿不到用户确认就不提交，把报告留在输出里。
