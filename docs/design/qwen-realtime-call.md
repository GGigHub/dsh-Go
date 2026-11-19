# Qwen Omni Realtime 全双工通话

范围：App 直连阿里云百炼 **Omni Realtime**；复用现有通话页。Realtime 模式下轮次制选项加删除线。不做 DSH 任务委派；Key 存 App 侧。

## 行为

- **设置 › 语音 › Qwen Realtime 全双工**：开关、API Key（安全存储）、WebSocket 地址、模型、音色；**Android** 另有语音唤醒开关与唤醒词。
- 开关打开且 Key 非空时，加号「语音通话」走 `RealtimeCallController`（PCM 旁路上送、下行 PCM 播放）；否则仍用原来的 `VoiceCallController`。
- Realtime 下不适用：「停顿多久算说完」「口语回答」「思考提示音」「她的声音」「识别方式」——设置页与通话设置里保留可见，标题/说明删除线并禁用。
- **后台保活（Android）**：接通后起麦克风 FGS（`RealtimeCallService`）；`backgrounded` 不挂断；通知栏可挂断。
- **语音唤醒（Android）**：开启后 `RealtimeWakeService` 用系统 `SpeechRecognizer` 听唤醒词，命中则拉起 App 并打开 Realtime 通话；通话期间停唤醒，挂断后按设置恢复。

## 代码

| 路径 | 作用 |
|---|---|
| `app/lib/speech/realtime/qwen_realtime_settings.dart` | 配置与凭据（含 wake） |
| `app/lib/speech/realtime/qwen_realtime_session.dart` | DashScope WebSocket |
| `app/lib/speech/realtime/realtime_keep.dart` | MethodChannel `dsh/realtime_keep` |
| `app/lib/speech/call/realtime_call.dart` | 全双工通话控制器 + call keep |
| `app/lib/ui/speech/realtime_wake_host.dart` | HomeShell 下监听唤醒并开通话 |
| `app/lib/ui/speech/voice_call_page.dart` | 按配置选择控制器 |
| `app/android/.../speech/RealtimeKeepPlugin.kt` | 原生桥 |
| `app/android/.../speech/RealtimeCallService.kt` | 通话麦克风 FGS |
| `app/android/.../speech/RealtimeWakeService.kt` | 唤醒麦克风 FGS |

默认模型/音色见归档坑文档；验收见 Agent Store `docs/qwen-realtime-call-acceptance.md`。
