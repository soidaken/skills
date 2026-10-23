# skills

个人 / 团队共享的 Agent Skill 集合。每个子目录是一个独立 Skill，可通过 Cindy、Claude Code、Codex、Pi 直接使用。

## 目录

| Skill | 说明 |
| --- | --- |
| [`svn-auto-commit`](svn-auto-commit/SKILL.md) | SVN 自动提交：检测并安装 svn CLI、提交前列出涉及文件、update 检查并处理冲突、确认后提交 |

## 安装

每个 Skill 是一个自包含目录（`SKILL.md` + 可选 `scripts/`、`references/`、`agents/`）。装法一致：

```powershell
# 用户级：所有项目可用
git clone https://github.com/soidaken/skills.git "$env:TEMP\skills"
Copy-Item "$env:TEMP\skills\svn-auto-commit" "$HOME\.agents\skills\" -Recurse -Force

# 或项目级：只在该仓库内可用
Copy-Item "$env:TEMP\skills\svn-auto-commit" ".\.agents\skills\" -Recurse -Force
```

macOS / Linux：

```bash
git clone https://github.com/soidaken/skills.git /tmp/skills
cp -r /tmp/skills/svn-auto-commit ~/.agents/skills/
```

装完新开一个 Agent 会话即可识别；在 Cindy 里用 `/svn-auto-commit` 显式调用。

## Windows 上的 svn CLI

`svn-auto-commit` 会自己检查 `svn.exe`，缺了就装。手工装也行：

```powershell
winget install --id Slik.Subversion -e --source winget
```

SlikSVN 自带 `svn.exe` 并写入 PATH。TortoiseSVN 默认**不带**命令行客户端，需要补装 “command line client tools” 组件；VisualSVN Server 的 `bin\svn.exe` 也能直接用，但不一定在 PATH 里。
