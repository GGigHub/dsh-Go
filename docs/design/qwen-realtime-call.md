# Qwen-Audio Realtime 全双工通话（一期）

范围：App 直连阿里云百炼 Qwen-Audio Realtime；复用现有通话页；Realtime 模式下轮次制选项加删除线。不做后台麦克风前台服务，不做 DSH 任务委派。

## 行为

- **设置 › 语音 › Qwen Realtime 全双工**：开关、API Key（安全存储）、WebSocket 地址、模型、音色。
- 开关打开且 Key 非空时，加号「语音通话」走 `RealtimeCallController`（PCM 旁路上送、下行 PCM 播放）；否则仍用原来的 `VoiceCallController`。
- Realtime 下不适用：「停顿多久算说完」「口语回答」「思考提示音」「她的声音」「识别方式」——设置页与通话设置里保留可见，标题/说明删除线并禁用。
- 切后台仍挂断（与现网一致）。

## 代码

| 路径 | 作用 |
|---|---|
| `app/lib/speech/realtime/qwen_realtime_settings.dart` | 配置与凭据 |
| `app/lib/speech/realtime/qwen_realtime_session.dart` | DashScope WebSocket |
| `app/lib/speech/call/realtime_call.dart` | 全双工通话控制器 |
| `app/lib/speech/call/voice_call.dart` | `CallController` 抽象，页面对齐 |
| `app/lib/ui/speech/voice_call_page.dart` | 按配置选择控制器 |

验收步骤见 Project 文档 `docs/qwen-realtime-call-acceptance.md`（Agent Store）。
