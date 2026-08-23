# Codex Audio Notification

为 Windows 上的 Codex 添加自然女声任务完成播报。默认先说“Codex 任务完成：”，再读出当前任务名称。

固定前缀 MP3 已包含在仓库中；任务名称使用 Microsoft Edge 在线 TTS 的 `zh-TW-HsiaoYuNeural`，语速 `-6%`、音调 `+22Hz`，并通过 FFmpeg 增益 `+4dB`。默认音色偏甜、偏高的台湾国语女声。

## 功能与行为规则

- 默认配置为 `Codex`：播放“Codex 任务完成：”和任务名称。
- 可切换为 `Claude`：播放“Claude 任务完成：”和任务名称。
- Codex 每轮结束后等待 15 秒；期间若出现 follow-up，新一轮会取消旧播报。
- 最新状态仍是执行中时不播报，避免把 follow-up 中间轮次当作任务完成。
- 子智能体以及任何由另一个 thread 发起的任务都不播报，只播报用户直接创建的顶层任务。
- 每天 23:00（含）至次日 08:00（不含）完全静默。
- 手动直接运行通知脚本且不提供 payload 时，只试听固定前缀。
- 保留并转发 Codex Desktop 原有的 `turn-ended` 桌面通知。

## 前置条件

- Windows 10/11。
- PowerShell 5.1 或更高版本。
- 推荐系统已安装 `winget`（Microsoft App Installer）。
- Python 3.10+、`edge-tts`、FFmpeg/ffplay。若缺失，安装脚本会通过 `winget`/`pip` 自动安装；任何依赖安装失败都会明确报错，不会静默留下残缺配置。

已在本机验证以下 winget 包 ID：

- `Python.Python.3.13`
- `Gyan.FFmpeg`

## 一键安装

克隆仓库后，在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

安装器会：

1. 检查并按需安装 Python、`edge-tts`、FFmpeg/ffplay。
2. 把运行时文件复制到 `$CODEX_HOME\hooks\codex-audio-notification`；未设置 `CODEX_HOME` 时使用 `$HOME\.codex`。
3. 在改动前备份现有 `config.toml`。
4. 精确更新用户级顶层 `notify`，保留配置中的其他内容。
5. 若已有 `notify`，会备份并替换它；卸载时会在当前值仍由本工具管理的前提下恢复旧值。
6. 执行 PowerShell、JSON、Python helper 与配置的最小自检。

Codex 官方规定通知配置只能放在用户级配置中，项目级 `.codex/config.toml` 中的 `notify` 会被忽略。安装后建议重启 Codex Desktop/CLI。

高级安装参数：

```powershell
# 安装到自定义 CODEX_HOME
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CodexHome D:\Temp\codex-home

# 不自动安装依赖；若依赖缺失则立即失败
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipDependencies
```

## 配置

安装后编辑：

```text
$CODEX_HOME\hooks\codex-audio-notification\task-completion-voice.json
```

### 切换 Codex / Claude

将 `activeProfile` 设置为 `codex` 或 `claude`：

```json
{
  "activeProfile": "claude"
}
```

实际文件还包含两个 profile 的 MP3 文件名，请保留 `profiles` 节点。

### 调整 follow-up 防抖时间

`settleSeconds` 默认是 `15`，允许范围为 0–300 秒：

```json
"settleSeconds": 15
```

### 调整静默时间

小时使用本机 24 小时制。默认从 23 点到次日 8 点：

```json
"quietHours": {
  "start": 23,
  "end": 8
}
```

跨午夜和同一天区间均支持；`start` 与 `end` 相同表示不启用静默时段。

## 手动试听

```powershell
& "$HOME\.codex\hooks\codex-audio-notification\turn-complete-voice.ps1"
```

手动运行没有 Codex payload，因此只播放当前 profile 的固定前缀。静默时间内仍会保持静默。

## 卸载

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

自定义安装目录需要传入相同参数：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -CodexHome D:\Temp\codex-home
```

卸载器会先再次备份 `config.toml`，恢复安装前的 `notify`，再删除独立运行目录。如果安装后有人手工修改了指向本工具的 `notify`，卸载器会停止并提示人工检查，不会强行覆盖。

## 故障排查

### 直接运行提示缺少 payload

当前版本支持无 payload 试听，不应报错。如果仍报错，确认 `config.toml` 指向的是独立安装目录，而不是旧脚本。

### 没有声音

1. 确认当前不在配置的静默时段。
2. 确认它是用户直接创建的顶层任务，不是子智能体或其他任务发起的 thread。
3. 运行 `Get-Command ffplay.exe`。
4. 用上面的命令手动试听固定前缀。
5. 重新运行 `install.ps1 -SkipDependencies`；它会在依赖缺失时给出明确错误。

### 固定前缀能播放，但任务名称不播放

任务名称首次合成需要联网。检查：

```powershell
python -c "import edge_tts; print(edge_tts.__version__)"
ffmpeg -version
```

同时确认 `$CODEX_HOME\state_5.sqlite` 存在。数据库中的任务名为空时，脚本会从同目录的 `session_index.jsonl` 回退读取任务名；两个来源都没有有效标题时会安全跳过标题语音。标题生成失败不会打断 Codex，也不会阻止固定前缀播放。

### 已有 notify 怎么办

Codex 只有一个用户级 `notify` 命令入口。安装器会先生成带时间戳的配置备份，再用本工具的 wrapper 替换原值；wrapper 会继续转发 Codex Desktop 的原生 `turn-ended` 通知。其他自定义 notify 命令不会自动串联，请根据备份手工合并，或卸载后恢复。

## 隐私与联网说明

- 固定“Codex/Claude 任务完成”前缀是仓库内 MP3，可完全离线播放。
- 任务名称首次播放时会把**任务标题文本**发送到 Microsoft Edge 在线 TTS 服务以生成语音。
- 生成后的标题 MP3 缓存在独立运行目录的 `voice-cache` 中，后续相同标题直接本地播放。
- 脚本只读本机 Codex 的 `state_5.sqlite`、`session_index.jsonl` 与对应 transcript 尾部，用于获取标题、识别父子任务和判断 follow-up；不会上传完整对话内容。

## 官方文档

- [Codex Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Codex Hooks](https://learn.chatgpt.com/docs/hooks)
