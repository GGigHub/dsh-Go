# Qwen Realtime 全双工通话

范围：App 直连 Realtime WebSocket（阿里云百炼 **或** 局域网本地网关）；复用现有通话页；Realtime 模式下轮次制选项加删除线。不做后台麦克风前台服务，不做 DSH 任务委派。

## 行为

- **设置 › 语音 › Qwen Realtime 全双工**：开关、API Key（安全存储，局域网可空）、WebSocket 地址、模型、音色。
- **百炼**：开关打开且 Key 非空 → `RealtimeCallController`。
- **局域网**：接入地址为 `ws://…` 或私网 IP 时视为 `isLocalLan`；无需 Key（发送 `Authorization: Bearer local`）；`session.update` 使用 PCM 音频形状。
- Realtime 下不适用：「停顿多久算说完」「口语回答」「思考提示音」「她的声音」「识别方式」——删除线并禁用。
- 切后台仍挂断。
- Debug APK 允许明文 `ws://`（`app/src/debug/res/xml/network_security_config.xml`）。日志标签 `dsh.realtime`。

## 代码

| 路径 | 作用 |
|---|---|
| `app/lib/speech/realtime/qwen_realtime_settings.dart` | 配置、`isLocalLan`、凭据 |
| `app/lib/speech/realtime/qwen_realtime_session.dart` | WebSocket + 详细 log |
| `app/lib/speech/call/realtime_call.dart` | 全双工通话控制器 |
| `tooling/lan-realtime/` | LAN 冒烟网关与主机部署说明 |

验收：Project Store / 真机；主机步骤见 `tooling/lan-realtime/README.md`。
