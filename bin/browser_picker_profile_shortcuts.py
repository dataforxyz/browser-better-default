"""Add missing browser profile shortcuts to the desktop app launcher."""
import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
from tempfile import NamedTemporaryFile


def publish_shortcut(applications, filename, browser, name, command, icon):
    applications.mkdir(parents=True, exist_ok=True)
    name = " ".join(name.split()).replace(chr(92), chr(92) * 2)
    entry = f"""[Desktop Entry]
Type=Application
Name={browser} — {name}
GenericName=Web Browser
Exec={command} %U
Icon={icon}
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
Keywords={browser};Browser;Profile;
"""
    # Publish the complete entry without overwriting a concurrent sync.
    with NamedTemporaryFile(mode="w", encoding="utf-8", dir=applications) as temporary:
        temporary.write(entry)
        temporary.flush()
        try:
            os.link(temporary.name, applications / filename)
        except FileExistsError:
            return False
    return True


def sync_chromium(chromium, applications):
    if not shutil.which("chromium"):
        return 0
    try:
        state = json.loads((chromium / "Local State").read_text(encoding="utf-8"))
    except FileNotFoundError:
        return 0
    profiles = state.get("profile", {}).get("info_cache", {})
    existing = set()
    for shortcut in applications.glob("chromium-profile-*.desktop"):
        for line in shortcut.read_text().splitlines():
            if line.startswith("Exec="):
                try:
                    arguments = shlex.split(line[5:])
                except ValueError:
                    continue
                existing.update(
                    arg.removeprefix("--profile-directory=")
                    for arg in arguments
                    if arg.startswith("--profile-directory=")
                )

    added = 0
    for directory, profile in profiles.items():
        if directory in existing or profile.get("is_omitted") or profile.get("is_ephemeral"):
            continue
        if not re.fullmatch(r"Default|Profile(?: [0-9]+)?", directory):
            continue
        if not (chromium / directory).is_dir():
            continue
        name = profile.get("name") or directory
        filename = "chromium-profile-dir-" + directory.lower().replace(" ", "-") + ".desktop"
        added += publish_shortcut(
            applications, filename, "Chromium", name,
            f'chromium {desktop_exec_arg("--profile-directory=" + directory)}', "chromium",
        )
    return added


def desktop_exec_arg(value):
    # Escape the Exec quoting layer, then the Desktop Entry string layer.
    value = value.replace("%", "%%")
    value = re.sub(r'(["`$\\])', lambda match: chr(92) + match[0], value)
    return '"' + value.replace(chr(92), chr(92) * 2) + '"'


def sync_gecko(applications, browser, executable, icon, profile_root):
    if not shutil.which(executable):
        return 0
    profiles = configparser.ConfigParser(interpolation=None)
    profiles.read(profile_root / "profiles.ini", encoding="utf-8")
    added = 0
    for section in profiles.sections():
        if not re.fullmatch(r"Profile[0-9]+", section):
            continue
        name = profiles[section].get("Name")
        path = profiles[section].get("Path")
        if not name or not path or any(ord(char) < 32 for char in name):
            continue
        if not (profile_root / path).is_dir():
            continue
        identifier = hashlib.sha256(name.encode("utf-8")).hexdigest()[:16]
        filename = f"{icon}-profile-name-{identifier}.desktop"
        added += publish_shortcut(
            applications, filename, browser, name,
            f"{executable} -P {desktop_exec_arg(name)}", icon,
        )
    return added


def sync():
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    applications = data / "applications"
    added = sync_chromium(config / "chromium", applications)
    added += sync_gecko(applications, "Firefox", "firefox", "firefox", Path.home() / ".mozilla/firefox")
    added += sync_gecko(applications, "Zen", "zen-browser", "zen-browser", config / "zen")
    return added
