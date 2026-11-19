// WebSocket handshake that always sends Authorization and surfaces 401 bodies.
// dart:io WebSocket.connect only reports status code; DashScope puts InvalidApiKey
// in the JSON body — we need that text for the verify button / call error line.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'qwen_realtime_log.dart';

/// Connect with explicit handshake headers. On non-101, throws [StateError]
/// whose message includes the server JSON `code`/`message` when present.
Future<WebSocket> connectQwenRealtime(
  Uri uri, {
  Map<String, String> headers = const {},
}) async {
  final httpUri = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
  final client = HttpClient();
  try {
    final request = await client.openUrl('GET', httpUri);
    request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
    request.headers.set(HttpHeaders.upgradeHeader, 'websocket');
    request.headers.set('Sec-WebSocket-Version', '13');
    final nonce = base64Encode(Uint8List.fromList(List<int>.generate(16, (_) => Random.secure().nextInt(256))));
    request.headers.set('Sec-WebSocket-Key', nonce);
    for (final entry in headers.entries) {
      // Authorization must keep its case; some gateways are picky.
      request.headers.set(entry.key, entry.value, preserveHeaderCase: true);
    }
    realtimeLog(
      'handshake GET $httpUri auth=${headers.containsKey('Authorization')} '
      'workspace=${headers['X-DashScope-WorkSpace'] ?? '(none)'}',
    );

    final response = await request.close();
    if (response.statusCode != HttpStatus.switchingProtocols) {
      final body = await response.transform(utf8.decoder).join();
      realtimeLog('handshake HTTP ${response.statusCode} body=$body');
      throw StateError(_handshakeError(response.statusCode, body));
    }
    final protocol = response.headers.value('sec-websocket-protocol');
    final socket = await response.detachSocket();
    return WebSocket.fromUpgradedSocket(socket, protocol: protocol, serverSide: false);
  } finally {
    // Detached sockets keep the connection; closing the client does not drop them.
    client.close(force: false);
  }
}

String _handshakeError(int status, String body) {
  String? code;
  String? message;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      code = decoded['code']?.toString();
      message = decoded['message']?.toString();
    }
  } on Object {
    // Keep raw body.
  }
  if (code != null || message != null) {
    return 'HTTP $status ${[?code, ?message].join(': ')}';
  }
  final trimmed = body.trim();
  if (trimmed.isNotEmpty) return 'HTTP $status $trimmed';
  return 'HTTP $status websocket upgrade failed';
}
