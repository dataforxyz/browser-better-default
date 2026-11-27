#!/usr/bin/env python3
"""Verify that the editor launcher sends rules requests to Omarchy as JSON."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

EDITOR = Path(__file__).resolve().parent.parent / "bin/browser-picker-rules"


def main():
    with tempfile.TemporaryDirectory() as work:
        directory = Path(work)
        ipc = directory / "omarchy-shell"
        ipc.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, sys\n'
            'assert sys.argv[1:4] == ["shell", "summon", "browser-better-default"]\n'
            'with open(os.environ["IPC_CAPTURE"], "w") as f:\n'
            '    json.dump(json.loads(sys.argv[4]), f)\n'
            'print("ok")\n'
        )
        ipc.chmod(0o700)
        capture = directory / "payload.json"
        env = dict(os.environ, IPC_CAPTURE=str(capture), XDG_CONFIG_HOME=work,
                   PATH=f"{work}:{os.environ['PATH']}")
        subprocess.run([EDITOR], env=env, check=True)
        assert json.loads(capture.read_text()) == {}

        url = 'https://www.example.invalid/org/repo/issues?label="literal"'
        subprocess.run([EDITOR, url], env=env, check=True)
        payload = json.loads(capture.read_text())
        assert payload["url"] == url
        assert payload["pattern"] == "example.invalid/org/repo"

        subprocess.run([EDITOR, "mailto:test@example.invalid"], env=env, check=True)
        assert json.loads(capture.read_text())["pattern"] == "mailto:"
        assert subprocess.run([EDITOR, "file:///tmp/file"], env=env).returncode == 2

    print("test_rules.py: all passed")


if __name__ == "__main__":
    main()
