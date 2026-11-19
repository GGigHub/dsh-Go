#!/usr/bin/env python3
"""Minimal Bailian-compatible Realtime WS gateway for LAN smoke tests.

Speaks enough of the App protocol to pass「验证连接」and exercise uplink PCM:
  session.created → (client session.update) → session.updated
  input_audio_buffer.append (accepted)
  optional: after ~1.2s silence of speech energy, emits a short PCM beep reply

This is NOT MiniCPM. Use it to prove phone ↔ LAN connectivity, then swap in a
real duplex backend (see README.md).

  pip install websockets
  python3 gateway.py --host 0.0.0.0 --port 8091

App settings:
  接入地址  ws://<LAN-IP>:8091/v1/realtime
  模型      lan-smoke
  API Key   (empty)
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import logging
import math
import struct
import time
from typing import Any

try:
    from websockets.asyncio.server import serve
except ImportError:  # websockets < 13
    from websockets.server import serve  # type: ignore

log = logging.getLogger("lan-realtime")


def _pcm16_beep(seconds: float = 0.35, rate: int = 24000, hz: float = 660.0) -> bytes:
    n = int(seconds * rate)
    samples = []
    for i in range(n):
        t = i / rate
        env = min(1.0, i / 200) * min(1.0, (n - i) / 200)
        samples.append(int(16000 * env * math.sin(2 * math.pi * hz * t)))
    return struct.pack("<" + "h" * n, *samples)


def _chunk_b64(pcm: bytes, frame: int = 2400) -> list[str]:
    out = []
    for i in range(0, len(pcm), frame):
        out.append(base64.b64encode(pcm[i : i + frame]).decode("ascii"))
    return out


class Session:
    def __init__(self, ws: Any, path: str) -> None:
        self.ws = ws
        self.path = path
        self.event = 0
        self.uplink = 0
        self._reply_task: asyncio.Task[None] | None = None
        self._last_append = 0.0

    def _eid(self) -> str:
        self.event += 1
        return f"evt_{self.event}"

    async def send(self, payload: dict[str, Any]) -> None:
        payload.setdefault("event_id", self._eid())
        raw = json.dumps(payload, ensure_ascii=False)
        log.info("→ %s", payload.get("type"))
        await self.ws.send(raw)

    async def run(self) -> None:
        peer = getattr(self.ws, "remote_address", None)
        log.info("open path=%s peer=%s", self.path, peer)
        await self.send(
            {
                "type": "session.created",
                "session": {"id": f"sess_{int(time.time())}", "model": "lan-smoke"},
            }
        )
        async for raw in self.ws:
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8", errors="replace")
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                log.warning("bad json: %r", raw[:200])
                continue
            await self._on_client(msg)

    async def _on_client(self, msg: dict[str, Any]) -> None:
        typ = msg.get("type")
        if typ == "session.update":
            log.info("session.update keys=%s", list((msg.get("session") or {}).keys()))
            await self.send({"type": "session.updated", "session": msg.get("session") or {}})
            return
        if typ == "input_audio_buffer.append":
            audio = msg.get("audio") or ""
            try:
                n = len(base64.b64decode(audio))
            except Exception:
                n = 0
            self.uplink += n
            self._last_append = time.time()
            if self.uplink == n or self.uplink % 32000 < n:
                log.info("uplink total_bytes=%s last=%s", self.uplink, n)
            if self._reply_task is None or self._reply_task.done():
                self._reply_task = asyncio.create_task(self._maybe_reply())
            return
        if typ == "response.cancel":
            log.info("response.cancel")
            if self._reply_task and not self._reply_task.done():
                self._reply_task.cancel()
            return
        log.info("← %s", typ)

    async def _maybe_reply(self) -> None:
        try:
            await asyncio.sleep(1.2)
            if time.time() - self._last_append < 0.8:
                return
            rid = f"resp_{int(time.time() * 1000)}"
            await self.send({"type": "input_audio_buffer.speech_stopped"})
            await self.send({"type": "response.created", "response": {"id": rid}})
            await self.send(
                {
                    "type": "response.audio_transcript.delta",
                    "response_id": rid,
                    "delta": "局域网网关已连通。",
                }
            )
            await self.send(
                {
                    "type": "response.audio_transcript.done",
                    "response_id": rid,
                    "transcript": "局域网网关已连通。",
                }
            )
            for chunk in _chunk_b64(_pcm16_beep()):
                await self.send({"type": "response.audio.delta", "response_id": rid, "delta": chunk})
                await asyncio.sleep(0.02)
            await self.send({"type": "response.done", "response": {"id": rid}})
            log.info("smoke reply done id=%s", rid)
        except asyncio.CancelledError:
            log.info("smoke reply cancelled")
            raise


async def handler(ws: Any) -> None:
    path = getattr(ws, "request", None)
    path_s = getattr(path, "path", None) or getattr(ws, "path", "/")
    if "/v1/realtime" not in str(path_s):
        log.warning("reject path=%s (want /v1/realtime)", path_s)
        await ws.close(code=1008, reason="path must include /v1/realtime")
        return
    try:
        await Session(ws, str(path_s)).run()
    except Exception:
        log.exception("session ended with error")
    finally:
        log.info("close path=%s", path_s)


async def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8091)
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    log.info("listening ws://%s:%s/v1/realtime", args.host, args.port)
    async with serve(handler, args.host, args.port):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
