#!/usr/bin/env python3
"""Unit tests for bin/browser-picker-apps (no GUI, no display, no network)."""
import importlib.machinery
import importlib.util
import os
import stat
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "bin", "browser-picker-apps")

loader = importlib.machinery.SourceFileLoader("bpapps", SRC)
spec = importlib.util.spec_from_loader("bpapps", loader)
bpapps = importlib.util.module_from_spec(spec)
loader.exec_module(bpapps)

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def mkexec(dirpath, name):
    p = os.path.join(dirpath, name)
    with open(p, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
    return p


def write_desktop(dirpath, filename, body):
    p = os.path.join(dirpath, filename)
    with open(p, "w", encoding="utf-8") as f:
        f.write(body)
    return p


# --- 1) Built-in native app URL converters ---
def conv(fn, url, scheme):
    parsed = bpapps.parse_http_url(url)
    return fn(url, parsed, scheme) if parsed else None


# T3 Code
delegated_id = "thread%3Adelegated-task%3Acommand%3Amcp%3Aexample%3Adelegate-task%3Areview"
canonical_id = "thread%3Adelegated-task%3Acommand%253Amcp%253Aexample%253Adelegate-task%253Areview"
for segment in (delegated_id, canonical_id):
    check(
        conv(bpapps._convert_t3code, f"https://app.t3.codes/threads/env-1/{segment}", "t3code")
        == f"t3code://threads/env-1/{canonical_id}",
        "t3code uses the stored delegated thread ID",
    )
check(
    conv(bpapps._convert_t3code, "https://app.t3.codes/threads/env-1/thread-2", "t3code")
    == "t3code://threads/env-1/thread-2",
    "t3code thread link",
)
check(
    conv(
        bpapps._convert_t3code,
        "https://app.t3.codes/threads/00000000-1111-2222-3333-444444444444/abc?prompt=hi",
        "t3code",
    )
    == "t3code://threads/00000000-1111-2222-3333-444444444444/abc?prompt=hi",
    "t3code thread link with query",
)
check(
    conv(bpapps._convert_t3code, "https://app.t3.codes/new?prompt=Hello&repo=owner/name", "t3code")
    == "t3code://new?prompt=Hello&repo=owner/name",
    "t3code /new prompt link",
)
check(
    conv(bpapps._convert_t3code, "https://app.t3.codes/env-1/thread-1?prompt=go", "t3code-dev")
    == "t3code-dev://threads/env-1/thread-1?prompt=go",
    "t3code direct thread prompt link with dev scheme",
)
check(
    conv(
        bpapps._convert_t3code,
        "https://app.t3.codes/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "t3code",
    )
    == "t3code://threads/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "t3code browser-copied uuid thread URL",
)
check(conv(bpapps._convert_t3code, "https://app.t3.codes/settings/general", "t3code") is None, "t3code skips settings")
check(conv(bpapps._convert_t3code, "https://app.t3.codes/threads/only-one", "t3code") is None, "t3code skips incomplete thread")
check(conv(bpapps._convert_t3code, "https://app.t3.codes/threads/only-one?prompt=hi", "t3code") is None, "t3code skips incomplete thread with prompt")
check(conv(bpapps._convert_t3code, "https://app.t3.codes/", "t3code") is None, "t3code skips root")
check(conv(bpapps._convert_t3code, "https://evil.test/new?prompt=hi", "t3code") is None, "t3code rejects other host")

# Spotify
check(
    conv(bpapps._convert_spotify, "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=123", "spotify")
    == "spotify:track:4cOdK2wGLETKBW3PvgPWqT",
    "spotify track",
)
check(
    conv(bpapps._convert_spotify, "https://open.spotify.com/intl-es/album/abc123", "spotify")
    == "spotify:album:abc123",
    "spotify intl prefix stripped",
)
check(
    conv(bpapps._convert_spotify, "https://open.spotify.com/user/alice/playlist/pl999", "spotify")
    == "spotify:playlist:pl999",
    "spotify legacy user playlist",
)
check(
    conv(bpapps._convert_spotify, "https://open.spotify.com/search/daft%20punk", "spotify")
    == "spotify:search:daft%20punk",
    "spotify search",
)
check(conv(bpapps._convert_spotify, "https://open.spotify.com/", "spotify") is None, "spotify skips root")

# Zoom
check(
    conv(bpapps._convert_zoom, "https://us02web.zoom.us/j/1234567890?pwd=secret", "zoommtg")
    == "zoommtg://zoom.us/join?action=join&confno=1234567890&pwd=secret",
    "zoom join with pwd",
)
check(
    conv(bpapps._convert_zoom, "https://zoom.us/s/987654321?zak=eyJ0eXAi.abc", "zoommtg")
    == "zoommtg://zoom.us/start?confno=987654321&zak=eyJ0eXAi.abc",
    "zoom host start preserves zak",
)
check(
    conv(bpapps._convert_zoom, "https://app.zoom.us/wc/join/123456789?pwd=xyz", "zoommtg")
    == "zoommtg://zoom.us/join?action=join&confno=123456789&pwd=xyz",
    "zoom wc/join",
)
check(conv(bpapps._convert_zoom, "https://zoom.us/pricing", "zoommtg") is None, "zoom skips pricing")

# Slack
check(
    conv(bpapps._convert_slack, "https://app.slack.com/client/T0123ABCD/C0456EFGH", "slack")
    == "slack://channel?team=T0123ABCD&id=C0456EFGH",
    "slack app client channel",
)
check(
    conv(bpapps._convert_slack, "https://app.slack.com/client/T0123ABCD/C0456EFGH/thread/C0456EFGH-1700000000.123456", "slack")
    == "slack://channel?team=T0123ABCD&id=C0456EFGH",
    "slack app client does not emit message=thread",
)
check(
    conv(bpapps._convert_slack, "https://app.slack.com/client/T0123ABCD/browse-channels", "slack")
    == "slack://open?team=T0123ABCD",
    "slack non-channel client view falls back to open?team=",
)
check(
    conv(bpapps._convert_slack, "https://app.slack.com/client/T0123ABCD", "slack")
    == "slack://open?team=T0123ABCD",
    "slack app client workspace",
)
check(
    conv(
        bpapps._convert_slack,
        "https://acme.slack.com/archives/C0456EFGH/p1650000000123456?team=T0123ABCD&thread_ts=1650000000.000100",
        "slack",
    )
    == "slack://channel?team=T0123ABCD&id=C0456EFGH&message=1650000000.123456&thread_ts=1650000000.000100",
    "slack archives permalink with ts",
)
check(
    conv(bpapps._convert_slack, "https://acme.slack.com/archives/C0456EFGH", "slack") is None,
    "slack archives without team= is skipped",
)
check(conv(bpapps._convert_slack, "https://slack.com/pricing", "slack") is None, "slack skips marketing")

# Telegram
check(conv(bpapps._convert_telegram, "https://t.me/+AbCdEf123", "tg") == "tg://join?invite=AbCdEf123", "tg invite +")
check(conv(bpapps._convert_telegram, "https://t.me/+15551234567", "tg") == "tg://resolve?phone=15551234567", "tg phone +digits")
check(conv(bpapps._convert_telegram, "https://t.me/joinchat/XYZ", "tg") == "tg://join?invite=XYZ", "tg joinchat")
check(
    conv(bpapps._convert_telegram, "https://t.me/c/123456/78?thread=5", "tg")
    == "tg://privatepost?channel=123456&post=78&thread=5",
    "tg privatepost",
)
check(
    conv(bpapps._convert_telegram, "https://t.me/s/mychannel/42", "tg")
    == "tg://resolve?domain=mychannel&post=42",
    "tg /s/ channel post",
)
check(
    conv(bpapps._convert_telegram, "https://t.me/mybot?start=payload", "tg")
    == "tg://resolve?domain=mybot&start=payload",
    "tg resolve with start",
)
check(conv(bpapps._convert_telegram, "https://t.me/addstickers/CoolPack", "tg") == "tg://addstickers?set=CoolPack", "tg stickers")
check(conv(bpapps._convert_telegram, "https://t.me/share/url?url=x", "tg") is None, "tg skips /share")
check(conv(bpapps._convert_telegram, "https://t.me/faq", "tg") is None, "tg skips reserved path")

# Discord
check(conv(bpapps._convert_discord, "https://discord.gg/myinvite", "discord") == "discord://-/invite/myinvite", "discord.gg invite")
check(
    conv(bpapps._convert_discord, "https://discord.com/channels/111/222/333", "discord")
    == "discord://-/channels/111/222/333",
    "discord channel message",
)
check(conv(bpapps._convert_discord, "https://discord.com/download", "discord") is None, "discord skips download")

# Linear / Notion / Figma / Teams / Steam / Signal / Matrix
check(
    conv(bpapps._convert_linear, "https://linear.app/acme/issue/ACM-42", "linear")
    == "linear://acme/issue/ACM-42",
    "linear issue",
)
check(conv(bpapps._convert_linear, "https://linear.app/pricing", "linear") is None, "linear skips pricing")
check(
    conv(bpapps._convert_notion, "https://www.notion.so/myteam/Doc-123#sec", "notion")
    == "notion://www.notion.so/myteam/Doc-123#sec",
    "notion page",
)
check(conv(bpapps._convert_notion, "https://www.notion.so/login", "notion") is None, "notion skips login")
check(
    conv(bpapps._convert_figma, "https://www.figma.com/design/KEY123/My-File?node-id=1-2", "figma")
    == "figma://design/KEY123/My-File?node-id=1-2",
    "figma design",
)
check(conv(bpapps._convert_figma, "https://www.figma.com/pricing", "figma") is None, "figma skips pricing")
check(
    conv(bpapps._convert_teams, "https://teams.microsoft.com/l/meetup-join/abc?context=1", "msteams")
    == "msteams://teams.microsoft.com/l/meetup-join/abc?context=1",
    "teams meetup-join",
)
check(
    conv(bpapps._convert_steam, "https://store.steampowered.com/app/440/Team_Fortress_2/", "steam")
    == "steam://openurl/https://store.steampowered.com/app/440/Team_Fortress_2/",
    "steam store",
)
check(
    conv(bpapps._convert_signal, "https://signal.me/#p/+15551234567", "sgnl")
    == "sgnl://signal.me/#p/+15551234567",
    "signal.me",
)
check(
    conv(bpapps._convert_matrix, "https://matrix.to/#/#room:example.org/$evt1?via=example.org", "matrix")
    == "matrix:r/room:example.org/e/evt1?via=example.org",
    "matrix.to room+event",
)
check(
    conv(bpapps._convert_matrix, "https://matrix.to/#/@alice:example.org", "matrix")
    == "matrix:u/alice:example.org",
    "matrix.to user",
)


# --- 2) Desktop discovery, mimeapps.list precedence, Hidden masking, webapps, custom apps.conf ---
tmp = tempfile.mkdtemp()
bin_dir = os.path.join(tmp, "bin")
user_apps = os.path.join(tmp, "user_apps")
sys_apps = os.path.join(tmp, "sys_apps")
os.makedirs(bin_dir)
os.makedirs(user_apps)
os.makedirs(sys_apps)

t3_appimage = mkexec(bin_dir, "T3-Code-Nightly.AppImage")
t3_alt = mkexec(bin_dir, "t3code-alt")
spotify_bin = mkexec(bin_dir, "spotify-bin")
webapp_bin = mkexec(bin_dir, "omarchy-launch-webapp")
chromium_bin = mkexec(bin_dir, "chromium")
custom_bin = mkexec(bin_dir, "my-custom-app")
nheko_bin = mkexec(bin_dir, "nheko-bin")

# T3 Code hidden-from-launcher URL handler (NoDisplay=true) + alternate entry
write_desktop(
    user_apps,
    "com.t3tools.T3Code.desktop",
    f"""[Desktop Entry]
Type=Application
Name=T3 Code (Nightly)
Exec={t3_appimage} %U
NoDisplay=true
MimeType=x-scheme-handler/t3code;
""",
)
write_desktop(
    user_apps,
    "t3code.desktop",
    f"""[Desktop Entry]
Type=Application
Name=T3 Code
Exec={t3_alt} %U
MimeType=x-scheme-handler/t3code;
""",
)
# Spotify with --uri=%u
write_desktop(
    sys_apps,
    "spotify.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Spotify
Exec={spotify_bin} --uri=%u
MimeType=x-scheme-handler/spotify;
""",
)
# Broken app whose binary does not exist -> must be ignored
write_desktop(
    sys_apps,
    "slack.desktop",
    """[Desktop Entry]
Type=Application
Name=Slack
Exec=/nonexistent/path/to/slack %U
MimeType=x-scheme-handler/slack;
""",
)
# Matrix client using desktop Name
write_desktop(
    sys_apps,
    "nheko.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Nheko
Exec={nheko_bin} %u
MimeType=x-scheme-handler/matrix;
""",
)
# Hidden override in user_apps masks sys_apps entry
write_desktop(
    sys_apps,
    "steam.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Steam
Exec={custom_bin} %U
MimeType=x-scheme-handler/steam;
""",
)
write_desktop(
    user_apps,
    "steam.desktop",
    """[Desktop Entry]
Hidden=true
""",
)
# Omarchy webapps
write_desktop(
    user_apps,
    "Figma.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Figma
Exec={webapp_bin} https://figma.com/ --profile-directory="Profile 3"
""",
)
write_desktop(
    user_apps,
    "YouTube.desktop",
    f"""[Desktop Entry]
Type=Application
Name=YouTube
Exec={webapp_bin} https://youtube.com/ --profile-directory="Profile 3"
""",
)
write_desktop(
    user_apps,
    "YouTube Music.desktop",
    f"""[Desktop Entry]
Type=Application
Name=YouTube Music
Exec={webapp_bin} https://music.youtube.com/ --profile-directory="Profile 3"
""",
)
# Chromium --app= PWA
write_desktop(
    user_apps,
    "Fizzy.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Fizzy
Exec={chromium_bin} --profile-directory="Profile 3" --app=https://app.fizzy.do/
""",
)
# NoDisplay=true webapp must be ignored
write_desktop(
    user_apps,
    "HiddenApp.desktop",
    f"""[Desktop Entry]
Type=Application
Name=HiddenApp
NoDisplay=true
Exec={webapp_bin} https://hidden.example.com/
""",
)
# Self desktop entry must never be matched
write_desktop(
    user_apps,
    "browser-picker.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Browser Picker
Exec={custom_bin} %U
MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/t3code;
""",
)

# Custom apps.conf
apps_conf = os.path.join(tmp, "apps.conf")
with open(apps_conf, "w", encoding="utf-8") as f:
    f.write(
        f"# custom apps\n"
        f"Custom Reader|||regex:^https://docs\\.example\\.com/item/([^/?#]+)|||{custom_bin} --id={{1}} --url={{url}}\n"
        f"Custom URI|||regex:^https://custom\\.t3\\.test/t/([^/]+)/([^/?#]+)|||uri:t3code://threads/{{1}}/{{2}}\n"
        f"Missing Scheme|||missing.example.com|||uri:nosuchscheme://open/{{path_no_slash}}\n"
        f"Missing Bin|||missingbin.example.com|||/nonexistent/bin/missing-app {{url}}\n"
        f"Unsafe Shell|||unsafesh.example.com|||/bin/sh -c 'echo {{url}}'\n"
        f"Safe Shell|||safesh.example.com|||/bin/sh -c 'echo \"$1\"' _ {{url}}\n"
        f"Bad Loop|||loop.example.com|||uri:https://loop.example.com/forever\n"
        f"Figma — Web App|||extra.figma.example.com|||{webapp_bin} {{url}} --profile-directory=\"Profile 3\"\n"
        f"YouTube — Web App|||*|||disabled\n"
    )

# Also verify unsafe desktop Exec=sh -c "... %u" is rejected and wrapped browser-picker is skipped
write_desktop(
    sys_apps,
    "unsafe-linear.desktop",
    """[Desktop Entry]
Type=Application
Name=Linear
Exec=/bin/sh -c "echo %u"
MimeType=x-scheme-handler/linear;
""",
)
write_desktop(
    user_apps,
    "wrapped-picker.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Wrapped Picker
Exec=/usr/bin/env FOO=1 browser-picker %U
MimeType=x-scheme-handler/notion;
""",
)

reg = bpapps.build_registry(
    app_dirs=[user_apps, sys_apps],
    mimeapps_defaults={"t3code": ["com.t3tools.T3Code.desktop"]},
    apps_file=apps_conf,
    enable_auto=True,
    enable_webapps=True,
)

labels = [lbl for lbl, _k, _s in bpapps.list_apps(reg)]
check("T3 Code" in labels, "discovers T3 Code (NoDisplay=true URL handler)")
check("Spotify" in labels, "discovers Spotify")
check("Nheko" in labels, "uses installed Matrix client Name (Nheko)")
check("Slack" not in labels, "skips broken executable (Slack)")
check("Steam" not in labels, "respects Hidden=true masking (Steam)")
check("Notion" not in labels, "wrapped browser-picker self-entry is ignored")
check("Figma — Web App" in labels, "discovers Omarchy webapp (Figma)")
check("Fizzy — Web App" in labels, "discovers Chromium --app= PWA (Fizzy)")
check("HiddenApp — Web App" not in labels, "skips NoDisplay=true webapp")
check("YouTube — Web App" not in labels, "disabled in apps.conf hides auto-discovered webapp")
check("YouTube Music — Web App" in labels, "sibling host webapp stays enabled")
check("Missing Scheme" not in labels, "uninstalled uri: scheme hidden from list_apps")
check("Missing Bin" not in labels, "missing binary hidden from list_apps")
check("Unsafe Shell" not in labels, "unsafe sh -c placeholder hidden from list_apps")
check("Safe Shell" in labels, "safe sh -c positional arg allowed")

# Verify disabled app returns no_url (exit 2) so saved rules fall through to later rules
check(
    bpapps.resolve_for_label("YouTube — Web App", "https://youtube.com/watch?v=1", reg)[0] == "no_url",
    "disabled app returns no_url so saved rules fall through",
)

# Verify unsafe desktop Exec=sh -c "echo %u" and startup-option bypasses are rejected
check(bpapps.match_url("https://linear.app/acme/issue/ACM-1", reg) == [], "refuses desktop sh -c %u injection")
check(
    bpapps.expand_desktop_exec(["/bin/bash", "-o", "pipefail", "-c", "echo %u"], "t3code://new") is None,
    "refuses desktop bash -o pipefail -c %u",
)
check(
    bpapps.expand_desktop_exec(["/bin/bash", "+x", "-c", "echo %u"], "t3code://new") is None,
    "refuses desktop bash +x -c %u",
)
check(
    bpapps.expand_desktop_exec(["fish", "--command=echo %u"], "t3code://new") is None,
    "refuses desktop fish --command=%u",
)
check(
    bpapps.expand_desktop_exec(["alacritty", "-e", "sh", "-c", "echo %u"], "t3code://new") is None,
    "refuses desktop terminal wrapper alacritty -e sh -c %u",
)
check(
    bpapps.expand_desktop_exec(["/usr/bin/env", "-S", "echo %u"], "t3code://new") is None,
    "refuses desktop env -S %u",
)
check(
    bpapps.expand_desktop_exec(["/usr/bin/env", "-S", "sh -c", "%u"], "t3code://new") is None,
    "refuses desktop env -S 'sh -c' %u",
)
check(
    bpapps.expand_desktop_exec(["/usr/bin/env", "-iS", "sh -c", "%u"], "t3code://new") is None,
    "refuses desktop env -iS 'sh -c' %u",
)
check(
    bpapps.expand_desktop_exec(["/bin/bash", "-c"], "t3code://new") is None,
    "refuses desktop trailing bash -c with implicit URL append",
)
check(
    bpapps.expand_desktop_exec(["/bin/sh", "-c", "%f"], "t3code://new") is None,
    "refuses desktop sh -c %f where dropping %f would shift appended URL into script slot",
)
check(
    bpapps.expand_desktop_exec(["/bin/sh", "-c", "--", "%u"], "t3code://new") is None,
    "refuses desktop sh -c -- %u",
)
check(
    bpapps.expand_desktop_exec(["/bin/bash", "-c", "-o", "pipefail", "%u"], "t3code://new") is None,
    "refuses desktop bash -c -o pipefail %u",
)
check(
    bpapps.expand_desktop_exec(["/bin/bash", "-c", "-", "%u"], "t3code://new") is None,
    "refuses desktop bash -c - %u",
)
check(
    bpapps.expand_desktop_exec(["/bin/bash", "-c", "-eo", "pipefail", "%u"], "t3code://new") is None,
    "refuses desktop bash -c -eo pipefail %u",
)
check(
    bpapps.expand_desktop_exec(["/bin/bash", "-c", "-oe", "pipefail", "%u"], "t3code://new") is None,
    "refuses desktop bash -c -oe pipefail %u",
)
check(
    bpapps.expand_desktop_exec(["/bin/bash", "-c", "-Oe", "extglob", "%u"], "t3code://new") is None,
    "refuses desktop bash -c -Oe extglob %u",
)
check(
    bpapps.expand_desktop_exec(["/bin/bash", "-c", "+oe", "pipefail", "%u"], "t3code://new") is None,
    "refuses desktop bash -c +oe pipefail %u",
)
check(
    bpapps.expand_desktop_exec(["fish", "--init-command=echo %u"], "t3code://new") is None,
    "refuses desktop fish --init-command=%u",
)
check(
    bpapps.expand_desktop_exec(["fish", "--comm=echo %u"], "t3code://new") is None,
    "refuses desktop fish abbreviated --comm=%u",
)
check(
    bpapps.expand_desktop_exec(["fish", "--init-com", "echo %u"], "t3code://new") is None,
    "refuses desktop fish abbreviated --init-com",
)
check(
    bpapps.expand_desktop_exec(["fish", "-c", "true", "-ec", "%u"], "t3code://new") is None,
    "refuses desktop fish post--c clustered repeat option",
)

# Verify custom shell bypass forms are rejected, while safe sh -c positional arg still works
fake_fish = mkexec(bin_dir, "fish")
for desc, bad_cmd in (
    ("bash -o pipefail -c", "/bin/bash -o pipefail -c 'echo {url}'"),
    ("bash +x -c", "/bin/bash +x -c 'echo {url}'"),
    ("bash -c -e", "/bin/bash -c -e {url}"),
    ("sh -c --", "/bin/sh -c -- {url}"),
    ("bash -c -", "/bin/bash -c - {url}"),
    ("bash -c -o pipefail", "/bin/bash -c -o pipefail {url}"),
    ("bash -c -eo pipefail", "/bin/bash -c -eo pipefail {url}"),
    ("bash -c -oe pipefail", "/bin/bash -c -oe pipefail {url}"),
    ("bash -c -Oe extglob", "/bin/bash -c -Oe extglob {url}"),
    ("bash -c +oe pipefail", "/bin/bash -c +oe pipefail {url}"),
    ("trailing bash -c", "/bin/bash -c"),
    ("fish --command=", f"{fake_fish} --command='echo {{url}}'"),
    ("fish --command arg", f"{fake_fish} --command 'echo {{url}}'"),
    ("fish --comm= abbrev", f"{fake_fish} --comm='echo {{url}}'"),
    ("fish --init-command", f"{fake_fish} --init-command 'echo {{url}}'"),
    ("fish --init-command=", f"{fake_fish} --init-command='echo {{url}}'"),
    ("fish --init-com= abbrev", f"{fake_fish} --init-com='echo {{url}}'"),
    ("fish post--c -ec", f"{fake_fish} -c true -ec {{url}}"),
    ("wrapper sh -c", f"{custom_bin} -e /bin/sh -c 'echo {{url}}'"),
    ("env -S", "/usr/bin/env -S 'echo {url}'"),
    ("env -S trailing", "/usr/bin/env -S 'sh -c' {url}"),
    ("env -iS trailing", "/usr/bin/env -iS 'sh -c x' {url}"),
):
    check(
        bpapps.resolve_custom_command(bad_cmd, "https://example.com/a", None, {}) == (None, None),
        f"refuses custom {desc}",
    )
    check(
        not bpapps._custom_command_available(bad_cmd, {}),
        f"_custom_command_available refuses {desc}",
    )
check(
    bpapps._shell_c_script_index(["fish", "--command=echo {url}"]) == 2,
    "fails closed on fish --command= script",
)

# Verify TryExec does not bypass broken Exec, and flatpak run checks app installation
check(
    not bpapps.exec_is_available(["/nonexistent/real-bin", "%u"], try_exec=custom_bin),
    "valid TryExec does not bypass missing Exec",
)
fp_dir = os.path.join(tmp, "flatpak_user")
fp_sys_dir = os.path.join(tmp, "flatpak_sys")
fp_extra_dir = os.path.join(tmp, "flatpak_extra")
fp_cfg_root = os.path.join(tmp, "flatpak_etc")
os.makedirs(os.path.join(fp_dir, "app", "com.example.Installed"))
os.makedirs(os.path.join(fp_sys_dir, "app", "com.example.SysOnly"))
os.makedirs(os.path.join(fp_extra_dir, "app", "com.example.ExtraOnly"))
os.makedirs(os.path.join(fp_cfg_root, "installations.d"))
with open(os.path.join(fp_cfg_root, "installations.d", "extra.conf"), "w") as f:
    f.write(f'[Installation "extra"]\nPath={fp_extra_dir}\n')
fake_fp = mkexec(bin_dir, "flatpak")
saved_fp_env = os.environ.get("FLATPAK_USER_DIR")
saved_fp_sys = os.environ.get("FLATPAK_SYSTEM_DIR")
saved_fp_cfg = os.environ.get("FLATPAK_CONFIG_DIR")
try:
    os.environ["FLATPAK_USER_DIR"] = fp_dir
    os.environ["FLATPAK_SYSTEM_DIR"] = fp_sys_dir
    os.environ["FLATPAK_CONFIG_DIR"] = fp_cfg_root
    check(
        bpapps.exec_is_available([fake_fp, "run", "com.example.Installed", "%u"]),
        "flatpak run succeeds when app is installed",
    )
    check(
        not bpapps.exec_is_available([fake_fp, "run", "com.example.Missing", "%u"]),
        "flatpak run fails when app is not installed",
    )
    check(
        not bpapps.exec_is_available([fake_fp, "run", "--user", "com.example.SysOnly", "%u"]),
        "flatpak run --user rejects system-only app",
    )
    check(
        not bpapps.exec_is_available([fake_fp, "run", "-u", "com.example.SysOnly", "%u"]),
        "flatpak run -u rejects system-only app",
    )
    check(
        not bpapps.exec_is_available([fake_fp, "run", "--installation=default", "com.example.Installed", "%u"]),
        "flatpak run --installation=default rejects user-only app",
    )
    check(
        bpapps.exec_is_available([fake_fp, "run", "--installation=default", "com.example.SysOnly", "%u"]),
        "flatpak run --installation=default accepts system app",
    )
    check(
        bpapps.exec_is_available([fake_fp, "run", "--installation=extra", "com.example.ExtraOnly", "%u"]),
        "flatpak run --installation=extra resolves $FLATPAK_CONFIG_DIR/installations.d/*.conf",
    )
    check(
        not bpapps.exec_is_available([fake_fp, "run", "--installation", "extra", "com.example.SysOnly", "%u"]),
        "flatpak run --installation extra rejects app outside extra installation",
    )
    check(
        bpapps.exec_is_available([fake_fp, "run", "--system", "com.example.SysOnly", "%u"]),
        "flatpak run --system accepts system app",
    )
finally:
    if saved_fp_env is None:
        os.environ.pop("FLATPAK_USER_DIR", None)
    else:
        os.environ["FLATPAK_USER_DIR"] = saved_fp_env
    if saved_fp_sys is None:
        os.environ.pop("FLATPAK_SYSTEM_DIR", None)
    else:
        os.environ["FLATPAK_SYSTEM_DIR"] = saved_fp_sys
    if saved_fp_cfg is None:
        os.environ.pop("FLATPAK_CONFIG_DIR", None)
    else:
        os.environ["FLATPAK_CONFIG_DIR"] = saved_fp_cfg

# Verify [Added Associations], [Removed Associations], and unassociated [Default Applications]
assoc_tmp = tempfile.mkdtemp()
assoc_apps = os.path.join(assoc_tmp, "apps")
os.makedirs(assoc_apps)
added_bin = mkexec(bin_dir, "added-t3")
write_desktop(
    assoc_apps,
    "added-t3.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Added T3
Exec={added_bin} %U
""",
)
write_desktop(
    assoc_apps,
    "only-spotify.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Spotify
Exec={spotify_bin} --uri=%u
MimeType=x-scheme-handler/spotify;
""",
)
write_desktop(
    assoc_apps,
    "removed-t3.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Removed T3
Exec={t3_alt} %U
MimeType=x-scheme-handler/t3code;
""",
)
_ae, assoc_handlers = bpapps.scan_desktop_entries(
    app_dirs=[assoc_apps],
    mimeapps_defaults={"t3code": ["only-spotify.desktop"]},
    mimeapps_added={"t3code": ["added-t3.desktop"]},
    mimeapps_removed={"t3code": {"removed-t3.desktop"}},
)
check(
    assoc_handlers.get("t3code", {}).get("id") == "added-t3.desktop",
    f"rejects unassociated default and removed handler, picks Added Associations: got {assoc_handlers.get('t3code')}",
)

# Verify Slack archive rejects bad team=, percent-encoded trailing newline, and strips bad thread_ts=
check(
    conv(bpapps._convert_slack, "https://acme.slack.com/archives/C0456EFGH?team=notvalid", "slack") is None,
    "slack archive rejects invalid team id",
)
check(
    conv(bpapps._convert_slack, "https://acme.slack.com/archives/C0456EFGH?team=T0123ABCD%0A", "slack") is None,
    "slack archive rejects percent-encoded trailing newline in team",
)
check(
    conv(
        bpapps._convert_slack,
        "https://acme.slack.com/archives/C0456EFGH?team=T0123ABCD&thread_ts=1650000000.000100%0A",
        "slack",
    )
    == "slack://channel?team=T0123ABCD&id=C0456EFGH",
    "slack archive rejects percent-encoded trailing newline in thread_ts",
)
check(
    conv(
        bpapps._convert_slack,
        "https://acme.slack.com/archives/C0456EFGH?team=T0123ABCD&thread_ts=bogus",
        "slack",
    )
    == "slack://channel?team=T0123ABCD&id=C0456EFGH",
    "slack archive ignores invalid thread_ts",
)

# Verify lower-priority system [Removed Associations] cannot suppress higher-priority user .desktop entry
lvl_tmp = tempfile.mkdtemp()
lvl_cfg = os.path.join(lvl_tmp, "cfg")
lvl_user_apps = os.path.join(lvl_tmp, "user_share", "applications")
lvl_sys_apps = os.path.join(lvl_tmp, "sys_share", "applications")
os.makedirs(lvl_cfg)
os.makedirs(lvl_user_apps)
os.makedirs(lvl_sys_apps)
write_desktop(
    lvl_user_apps,
    "user-t3.desktop",
    f"""[Desktop Entry]
Type=Application
Name=User T3
Exec={t3_appimage} %U
MimeType=x-scheme-handler/t3code;
""",
)
write_desktop(
    lvl_user_apps,
    "user-no-mime.desktop",
    f"""[Desktop Entry]
Type=Application
Name=User No Mime
Exec={spotify_bin} %U
""",
)
write_desktop(
    lvl_user_apps,
    "shadowed.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Shadowed User Copy
Exec={custom_bin} %U
""",
)
write_desktop(
    lvl_sys_apps,
    "shadowed.desktop",
    f"""[Desktop Entry]
Type=Application
Name=Shadowed Sys Copy
Exec={custom_bin} %U
""",
)
with open(os.path.join(lvl_sys_apps, "mimeapps.list"), "w") as f:
    f.write(
        "[Removed Associations]\nx-scheme-handler/t3code=user-t3.desktop;\n"
        "[Added Associations]\nx-scheme-handler/spotify=user-no-mime.desktop;\n"
        "x-scheme-handler/linear=shadowed.desktop;\n"
    )
saved_lvl_env = {k: os.environ.get(k) for k in ("XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CURRENT_DESKTOP")}
try:
    os.environ["XDG_CONFIG_HOME"] = lvl_cfg
    os.environ["XDG_CONFIG_DIRS"] = lvl_cfg
    os.environ["XDG_DATA_HOME"] = os.path.join(lvl_tmp, "user_share")
    os.environ["XDG_DATA_DIRS"] = os.path.join(lvl_tmp, "sys_share")
    os.environ["XDG_CURRENT_DESKTOP"] = ""
    _le, lvl_handlers = bpapps.scan_desktop_entries(app_dirs=[lvl_user_apps, lvl_sys_apps])
    check(
        lvl_handlers.get("t3code", {}).get("id") == "user-t3.desktop",
        f"system-level Removed Associations must not suppress user desktop entry: got {lvl_handlers.get('t3code')}",
    )
    check(
        "spotify" not in lvl_handlers,
        f"system-level Added Associations must not register user-only desktop entry: got {lvl_handlers.get('spotify')}",
    )
    check(
        "linear" not in lvl_handlers,
        f"higher-precedence user desktop copy shadows system-level Added Associations per spec: got {lvl_handlers.get('linear')}",
    )
finally:
    for k, v in saved_lvl_env.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v

# Verify apps.conf augmentation of an auto-discovered web app stays classified as kind='webapp'
m_fig_extra_kind = bpapps.match_url("https://extra.figma.example.com/board/1", reg)
check(
    len(m_fig_extra_kind) == 1 and m_fig_extra_kind[0]["kind"] == "webapp",
    f"custom pattern reusing web-app label keeps kind='webapp': got {m_fig_extra_kind}",
)

# Verify missing custom scheme/bin and unsafe custom sh -c do not match, while safe sh -c does
check(bpapps.match_url("https://missing.example.com/a", reg) == [], "uninstalled uri: custom scheme does not match")
check(bpapps.match_url("https://missingbin.example.com/a", reg) == [], "missing custom binary does not match")
check(bpapps.match_url("https://unsafesh.example.com/a", reg) == [], "unsafe custom sh -c {url} does not match")
m_safesh = bpapps.match_url("https://safesh.example.com/a?x=$(id)", reg)
check(
    len(m_safesh) == 1 and m_safesh[0]["argv"] == ["/bin/sh", "-c", 'echo "$1"', "_", "https://safesh.example.com/a?x=$(id)"],
    f"safe sh -c positional arg matches: got {m_safesh}",
)

# Verify custom apps.conf entry with auto-discovered label AUGMENTS rather than breaking original host
m_fig_extra = bpapps.match_url("https://extra.figma.example.com/board/1", reg)
check(len(m_fig_extra) == 1 and m_fig_extra[0]["label"] == "Figma — Web App", "custom pattern augments Figma — Web App")

# Verify mimeapps.list Freedesktop precedence (desktop-specific + sys config > legacy user data)
mime_tmp = tempfile.mkdtemp()
m_cfg = os.path.join(mime_tmp, "cfg")
m_sys_cfg = os.path.join(mime_tmp, "sys_cfg")
m_data = os.path.join(mime_tmp, "data")
os.makedirs(m_cfg)
os.makedirs(m_sys_cfg)
os.makedirs(os.path.join(m_data, "applications"))
with open(os.path.join(m_cfg, "hyprland-mimeapps.list"), "w") as f:
    f.write("[Default Applications]\nx-scheme-handler/t3code=t3code.desktop\n")
with open(os.path.join(m_cfg, "mimeapps.list"), "w") as f:
    f.write("[Default Applications]\nx-scheme-handler/t3code=com.t3tools.T3Code.desktop\n")
with open(os.path.join(m_sys_cfg, "mimeapps.list"), "w") as f:
    f.write("[Default Applications]\nx-scheme-handler/spotify=spotify.desktop\n")
with open(os.path.join(m_data, "applications", "mimeapps.list"), "w") as f:
    f.write("[Default Applications]\nx-scheme-handler/spotify=wrong.desktop\n")
saved_env = {k: os.environ.get(k) for k in ("XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CURRENT_DESKTOP")}
try:
    os.environ["XDG_CONFIG_HOME"] = m_cfg
    os.environ["XDG_CONFIG_DIRS"] = m_sys_cfg
    os.environ["XDG_DATA_HOME"] = m_data
    os.environ["XDG_DATA_DIRS"] = m_data
    os.environ["XDG_CURRENT_DESKTOP"] = "Hyprland"
    paths = bpapps.mimeapps_paths()
    check(
        paths == [
            os.path.join(m_cfg, "hyprland-mimeapps.list"),
            os.path.join(m_cfg, "mimeapps.list"),
            os.path.join(m_sys_cfg, "mimeapps.list"),
            os.path.join(m_data, "applications", "mimeapps.list"),
        ],
        f"mimeapps_paths spec precedence: got {paths}",
    )
    defs = bpapps._read_mimeapps_defaults()
    check(defs["t3code"][0] == "t3code.desktop", "hyprland-mimeapps.list beats generic mimeapps.list")
    check(defs["spotify"][0] == "spotify.desktop", "system config mimeapps.list beats legacy user data mimeapps.list")
finally:
    for k, v in saved_env.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v

# Verify normalize_host strips IPv6 port and sanitize_label cleans control chars / delimiter
check(bpapps.normalize_host("[::1]:8080") == "[::1]", "normalize_host strips IPv6 port")
check(bpapps.sanitize_label("Bad\tName\n|||Here") == "Bad Name Here", "sanitize_label strips control chars and |||")

# Verify mimeapps.list picked com.t3tools.T3Code.desktop (t3_appimage, not t3_alt)
m_t3 = bpapps.match_url("https://app.t3.codes/threads/env-1/t-2", reg)
check(len(m_t3) == 1 and m_t3[0]["label"] == "T3 Code", "matches T3 Code")
check(
    m_t3[0]["argv"] == [t3_appimage, "t3code://threads/env-1/t-2"],
    f"t3code argv honors mimeapps.list default: got {m_t3[0]['argv']}",
)

# Verify resolve_for_label statuses: match / no_url / unknown
check(bpapps.resolve_for_label("T3 Code", "https://app.t3.codes/threads/e/t", reg)[0] == "match", "resolve match")
check(bpapps.resolve_for_label("T3 Code", "https://app.t3.codes/settings/general", reg)[0] == "no_url", "resolve no_url")
check(bpapps.resolve_for_label("Nonexistent", "https://example.com", reg)[0] == "unknown", "resolve unknown")

# Verify Spotify --uri=%u inline substitution
m_sp = bpapps.match_url("https://open.spotify.com/track/12345", reg)
check(
    len(m_sp) == 1 and m_sp[0]["argv"] == [spotify_bin, "--uri=spotify:track:12345"],
    f"spotify inline %u substitution: got {m_sp}",
)

# Verify Omarchy webapp & www normalization & profile flag preservation
m_fig = bpapps.match_url("https://www.figma.com/design/abc/Deck", reg)
check(
    len(m_fig) == 1
    and m_fig[0]["label"] == "Figma — Web App"
    and m_fig[0]["kind"] == "webapp"
    and m_fig[0]["argv"] == [webapp_bin, "https://www.figma.com/design/abc/Deck", "--profile-directory=Profile 3"],
    f"figma webapp argv: got {m_fig}",
)

# Verify Chromium --app= PWA replacement
m_fiz = bpapps.match_url("https://app.fizzy.do/board/99", reg)
check(
    len(m_fiz) == 1
    and m_fiz[0]["argv"] == [chromium_bin, "--profile-directory=Profile 3", "--app=https://app.fizzy.do/board/99"],
    f"fizzy chromium --app= argv: got {m_fiz}",
)

# Verify YouTube host isolation + disabled override
check(bpapps.match_url("https://youtube.com/watch?v=1", reg) == [], "disabled YouTube webapp does not match")
m_ytm = bpapps.match_url("https://music.youtube.com/watch?v=1", reg)
check(len(m_ytm) == 1 and m_ytm[0]["label"] == "YouTube Music — Web App", "music.youtube.com isolated from youtube.com")

# Verify custom apps.conf regex capture + shell metacharacter safety
tricky_url = "https://docs.example.com/item/abc?x=$(whoami);'\"`id`"
m_cust = bpapps.match_url(tricky_url, reg)
check(
    len(m_cust) == 1
    and m_cust[0]["label"] == "Custom Reader"
    and m_cust[0]["argv"] == [custom_bin, "--id=abc", f"--url={tricky_url}"],
    f"custom regex + shell safety: got {m_cust}",
)

# Verify custom uri: dispatch through discovered scheme handler
m_uri = bpapps.match_url("https://custom.t3.test/t/envA/thB", reg)
check(
    len(m_uri) == 1 and m_uri[0]["argv"] == [t3_appimage, "t3code://threads/envA/thB"],
    f"custom uri: dispatch: got {m_uri}",
)

# Verify loop prevention: uri:https://... is rejected
check(bpapps.match_url("https://loop.example.com/a", reg) == [], "uri:https:// loop is blocked")

# Verify webapps=False keeps native apps but drops web apps
reg_no_web = bpapps.build_registry(
    app_dirs=[user_apps, sys_apps],
    mimeapps_defaults={"t3code": ["com.t3tools.T3Code.desktop"]},
    apps_file=apps_conf,
    enable_auto=True,
    enable_webapps=False,
)
no_web_labels = [lbl for lbl, _k, _s in bpapps.list_apps(reg_no_web)]
check(
    "T3 Code" in no_web_labels
    and "Fizzy — Web App" not in no_web_labels
    and "YouTube Music — Web App" not in no_web_labels,
    "enable_webapps=False drops auto-discovered webapps while keeping native apps",
)

# Verify enable_auto=False keeps only custom apps.conf
reg_custom_only = bpapps.build_registry(
    app_dirs=[user_apps, sys_apps],
    mimeapps_defaults={"t3code": ["com.t3tools.T3Code.desktop"]},
    apps_file=apps_conf,
    enable_auto=False,
    enable_webapps=True,
)
custom_only_labels = [lbl for lbl, _k, _s in bpapps.list_apps(reg_custom_only)]
check("T3 Code" not in custom_only_labels and "Custom Reader" in custom_only_labels, "enable_auto=False keeps custom only")

if fails:
    print("FAILED:")
    for m in fails:
        print("  -", m)
    sys.exit(1)
print("test_apps.py: all passed")
