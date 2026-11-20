# 局域网 Realtime 网关（LAN）

App 直连主机 WebSocket（**不经** DSH bridge / Relay）做 **VAD + 听写**；**对话进 DSH 会话**（上下文 / 记忆 / 工具），回复用 App `SpeechOut` TTS。  
默认 `delegateToAgent=true`：`create_response: false`，主机 **不要** 再跑一套聊天 LLM。

本目录提供：

1. **`gateway.py`**：协议冒烟（握手 + 短提示音），不跑大模型  
2. 下文方案 2 主机部署（听写服务；完整 HF S2S 不推荐作默认）

## App 配置

| 字段 | 冒烟 | 方案 2 听写主机 |
|---|---|---|
| 使用 Realtime 通话 | 开 | 开 |
| 接入地址 | `ws://<主机IP>:8091/v1/realtime` | `ws://<主机IP>:8765/v1/realtime`（按实际） |
| 模型 | `lan-smoke` | 网关约定 id（可随意，App 不依赖） |
| API Key | 空 | 空（`Bearer local`） |

手机与主机同一局域网。Debug APK 允许 `ws://`。日志：`adb logcat -d | grep dsh.realtime`。

## 架构（方案 2）

```
手机 mic → Realtime WS → 主机 VAD/STT → transcript
                                    ↓
                          ChatCall → DSH agent（记忆/工具）
                                    ↓
                          App SpeechOut TTS → 听筒
```

这与 dsh-Go **原轮次制通话**同构，只是把 ASR 从「云端/本机」换成「主机本地模型」。

**主机不必部署完整 speech-to-speech（STT→LLM→TTS）。**  
默认 `speech-to-speech serve` 自带 LLM，会和 DSH 抢大脑；TTS 也会被 App 侧忽略。

| 主机跑什么 | 是否推荐 | 原因 |
|---|---|---|
| VAD + STT，Realtime 协议，出转写 | ✅ 推荐 | 与 App 闭环匹配，显存小 |
| 完整 HF S2S（含 LLM+TTS） | ⚠️ 不推荐默认 | 双大脑；主机 LLM/TTS 基本浪费 |
| MiniCPM 真全双工 Omni | 备选 | 与「DSH 大脑」目标冲突，且吃显存 |

## 1. 协议冒烟（先做）

```bash
cd tooling/lan-realtime
python3 -m pip install websockets
python3 gateway.py --host 0.0.0.0 --port 8091
```

防火墙放行 TCP `8091`。验证连接 → 短通话；冒烟网关约 1s 静音后有提示音（闭环后提示音可忽略，以转写→DSH 为准）。

## 2. 主机听写（方案 2 推荐）

目标：暴露 OpenAI Realtime 兼容 `ws://0.0.0.0:<port>/v1/realtime`，至少支持：

1. `session.created` → 客户端 `session.update`（可含 `create_response: false`）→ `session.updated`  
2. 上行 `input_audio_buffer.append`（PCM16 16k）  
3. `speech_started` / `speech_stopped`  
4. `conversation.item.input_audio_transcription.completed`（**必做**，App 靠它委派 DSH）  
5. 忽略或尊重 `create_response: false`（即使主机仍加载了 LLM，也不要因 VAD 自动 `response.create`）

### 用 Hugging Face speech-to-speech 时

仓库：[huggingface/speech-to-speech](https://github.com/huggingface/speech-to-speech)  
默认管线是 VAD→STT→**LLM**→TTS。对接本 App 时：

- **优先**：只依赖其 STT/VAD 与转写事件；确认客户端 `create_response: false` 后不会自动生成回复（以该版本文档为准；若仍自动生成，需改配置或加薄适配层丢掉 LLM 输出）。  
- **不要指望**主机 LLM 代替 DSH；工具与记忆仍在 DSH。  
- 4080S（16GB）：选小 STT（如 Parakeet / Whisper 量化）即可，**不必**再加载 4B LLM + TTS。

示例（命令随上游版本变化，以官方 `-h` 为准）：

```bash
# 伪示例：按当前 speech-to-speech CLI 调整；务必 --host 0.0.0.0
speech-to-speech serve --host 0.0.0.0 --port 8765 \
  --stt parakeet-tdt
# 若无法关掉 LLM：仍连 App，但以 dsh.realtime 的 delegate send 为准，
# 并确认不会因主机自答抢麦；否则加适配层只转发转写事件。
```

App 接入地址填：`ws://<主机局域网IP>:8765/v1/realtime`。

鉴权：Key 空时 App 发 `Authorization: Bearer local`；可忽略。

## 3. 备选 MiniCPM-o 4.5（真全双工）

仅在明确要原生边听边说、且接受与 DSH 委派模型冲突时使用。INT4≈11GB；BF16≈19GB 不适合 16GB。长聊需滑动窗口。协议仍要出转写事件，否则 App 无法委派。

## 4. 验收

1. 验证连接成功；`localLan=true`、handshake OK  
2. 说话后 log 出现 `delegate send`；DSH 会话里出现用户句  
3. Agent 回复被 App TTS 读出（不是主机自答抢麦）  
4. 插话：agent 回合被 interrupt  

## 非目标

- 不经 DSH SSH/Relay 隧道传语音  
- 主机 LLM 替代 DSH agent  
- 音色/智力对齐百炼 Omni 旗舰  
