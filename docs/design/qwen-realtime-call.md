# Qwen Realtime 全双工通话

范围：App 直连 Realtime WebSocket（阿里云百炼 **或** 局域网本地网关）做听写与 VAD；**对话大脑是 DSH 会话**（上下文、记忆、工具），回复用 App 既有 `SpeechOut` 朗读。复用现有通话页；Realtime 模式下轮次制听写选项加删除线。Key 存 App 侧。

## 行为

- **设置 › 语音 › 通话方式** 三选一：`轮次制` / `云端` / `局域网`（`VoiceCallMode`）。
- **轮次制**：`VoiceCallController`（手机 VAD + 云端/本机 ASR + DSH + App TTS）。
- **云端**：百炼 Realtime 听写；需 Key；`RealtimeCallController` → DSH → App TTS。
- **局域网**：主机 STT；`ws://` / 私网；Key 可空（`Bearer local`）；同上委派 DSH。
- **DSH 闭环**：`session.update` 打开 `input_audio_transcription`，并设 `turn_detection.create_response: false`（云端不自动答）。用户转写定稿后经 `ChatCallConversation` 送入当前会话；agent 回复流式朗读。插话打断走 `conversation.interrupt()`。
- Realtime 下不适用：「停顿多久算说完」「口语回答」「思考提示音」「她的声音」「识别方式」——删除线并禁用（音色仍用通话/伙伴小屋已选的 `SpeechOut`）。
- **后台保活（Android）**：接通后起麦克风 FGS（`RealtimeCallService`）；`backgrounded` 不挂断；通知栏可挂断。不做语音唤醒。
- Debug APK 允许明文 `ws://`（`app/src/debug/res/xml/network_security_config.xml`）。日志标签 `dsh.realtime`。

## 代码

| 路径 | 作用 |
|---|---|
| `app/lib/speech/realtime/qwen_realtime_settings.dart` | 配置、`VoiceCallMode`、`isLocalLan`、凭据 |
| `app/lib/speech/realtime/qwen_realtime_session.dart` | WebSocket；`delegateToAgent` 会话形状 |
| `app/lib/speech/realtime/realtime_keep.dart` | MethodChannel `dsh/realtime_keep` |
| `app/lib/speech/call/realtime_call.dart` | 全双工听写 + DSH 委派 + call keep |
| `app/lib/speech/call/chat_call.dart` | 既有会话发送 / 回复 / 打断 |
| `app/lib/ui/speech/voice_call_page.dart` | 按配置选择控制器 |
| `app/android/.../speech/RealtimeKeepPlugin.kt` | 原生桥 |
| `app/android/.../speech/RealtimeCallService.kt` | 通话麦克风 FGS |
| `tooling/lan-realtime/` | LAN 冒烟网关与主机部署说明 |

验收：Project Store / 真机；主机步骤见 `tooling/lan-realtime/README.md`。

## 方案 2（局域网听写）

主机部署 **VAD + STT**（Realtime 协议出转写）即可；**不要**默认装完整 HF speech-to-speech（含 LLM+TTS）——会与 DSH 大脑重复。朗读仍走 App TTS。细节见 `tooling/lan-realtime/README.md`。
