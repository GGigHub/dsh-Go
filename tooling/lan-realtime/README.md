# 局域网 Realtime 网关（LAN 先跑通）

App 复用一期 Qwen Realtime 通话页，直连主机上的 WebSocket（**不经** DSH bridge / Relay）做听写与 VAD；**对话进 DSH 会话**（上下文 / 记忆 / 工具），回复用 App TTS。  
本目录提供：

1. **`gateway.py`**：协议冒烟网关（验证连接 + 短提示音），不跑大模型  
2. 下文主机模型部署说明（优先 HF speech-to-speech；MiniCPM 备选）

## App 配置

| 字段 | 冒烟网关 | MiniCPM（示例） |
|---|---|---|
| 使用 Realtime 通话 | 开 | 开 |
| 接入地址 | `ws://<主机局域网IP>:8091/v1/realtime` | 同左（或你的服务端口） |
| 模型 | `lan-smoke` | `minicpm-o-4_5`（或网关要求的 id） |
| API Key | 空 | 空（或与网关约定的 token） |
| 音色 | 任意 | 任意（网关可忽略） |

手机与主机须同一局域网。Debug APK 已允许 `ws://` 明文。

日志：

```bash
adb logcat -d | grep dsh.realtime
```

## 1. 协议冒烟（先做）

```bash
cd tooling/lan-realtime
python3 -m pip install websockets
python3 gateway.py --host 0.0.0.0 --port 8091
# 查局域网 IP：ipconfig / ifconfig / ip a
```

主机防火墙放行 TCP `8091`。App 点「验证连接」应成功；再打语音通话，约 1 秒无上行后会听到短提示音并显示「局域网网关已连通。」

## 2. MiniCPM-o 4.5（4080S / 留显存）

约束：约 16GB 显存、不想占满、只要语音全双工。

推荐：**INT4 + llama.cpp-omni 或 SGLang/vLLM duplex**，官方实测 INT4 约 **11GB**，BF16≈19GB 不适合 16GB 卡。

### 权重

- Hugging Face：`openbmb/MiniCPM-o-4_5`（及仓库说明中的 INT4 / GGUF）
- 文档：https://github.com/OpenBMB/MiniCPM-V/blob/main/docs/minicpm_o4dot5_en.md

### 运行时选型

| 方案 | 说明 |
|---|---|
| llama.cpp-omni | 端侧 INT4，官方称全双工约 ≥12GB GPU；适合单机冒烟 |
| SGLang-Omni duplex | `/v1/realtime?duplex=1`；需自行或经薄适配层对齐 App 事件 |
| vLLM-Omni | 同类；注意显存占用 |

示例（以官方文档为准，命令随版本变化）：

```bash
# 伪示例：按 MiniCPM / SGLang 当前文档替换
# sglang 或 llama.cpp-omni 起服务后，监听例如 8091
```

### 与 App 协议对齐（必做）

App 期望类百炼 Realtime 事件子集：

1. 服务端先发 `session.created`
2. 客户端发 `session.update`（含 `input_audio_format=pcm16`、`audio.input 16k`、`audio.output 24k`、`server_vad`）
3. 服务端回 `session.updated`
4. 上行：`input_audio_buffer.append`（base64 PCM16）
5. 下行：`response.created` → `response.audio.delta`（base64 PCM16 @ 24k）→ `response.done`
6. 插话：`response.cancel`
7. 可选：`input_audio_buffer.speech_started/stopped`、transcript delta

若上游原生 `/v1/realtime` 字段不完全一致，在主机上加一层薄适配（可从本目录 `gateway.py` 改起），对手机只暴露：

`ws://0.0.0.0:8091/v1/realtime`

鉴权：Key 为空时 App 发送 `Authorization: Bearer local`；网关可忽略或校验该值。

### 显存

- 启动时限制引擎 `gpu_memory_utilization` / `mem_fraction`（若框架支持），为其它进程留余量  
- 只跑语音、不喂视频帧  

## 3. 验收

1. 验证连接成功  
2. 通话：正在接通 → 在听；说话有回复/播报  
3. AI 说话时插话：停播  
4. `adb logcat | grep dsh.realtime` 可见 `localLan=true`、handshake OK、uplink/downlink 统计  

## 非目标（本阶段）

- 不经 DSH SSH/Relay 隧道  
- 不对齐百炼 FC / MCP / 联网  
- 不保证音色与智力对齐 `qwen3.8-omni-flash-realtime`
