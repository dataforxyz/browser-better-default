"""Exercise the native protocol with a temporary picker on PATH."""

import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

HOST = Path(__file__).resolve().parents[1] / "bin/browser-picker-host"
HEADER = struct.Struct("=I")


def request(data, env):
    result = subprocess.run([HOST], input=data, capture_output=True, env=env, check=True)
    length = HEADER.unpack_from(result.stdout)[0]
    body = result.stdout[HEADER.size:]
    assert len(body) == length
    return json.loads(body)


def frame(message):
    body = json.dumps(message).encode()
    return HEADER.pack(len(body)) + body


with tempfile.TemporaryDirectory() as temp:
    picker = Path(temp) / "browser-picker"
    # Starting this file succeeds only while its interpreter exists.
    picker.write_text("#!/bin/sh\nexit 0\n")
    picker.chmod(0o700)
    env = {**os.environ, "PATH": f"{temp}:/usr/bin:/bin"}
    url = "https://example.test/path"
    for data in (
        frame({"url": "mailto:user@example.test"}),
        frame({"url": url, "act": False}),
        frame([url]),
        HEADER.pack(2**32 - 1),
        HEADER.pack(50) + b"{}",
    ):
        assert request(data, env) == {"ok": False}

    assert request(frame({"url": url}), env) == {"ok": True}
    picker.write_text("#!/nonexistent/browser-picker-interpreter\n")
    assert request(frame({"url": url}), env) == {"ok": False}
