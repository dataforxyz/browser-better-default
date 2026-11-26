#!/usr/bin/env python3
"""Isolated tests for bin/browser-picker-editor-data (no GTK, no external state)."""
import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BIN_DIR = os.path.join(HERE, "..", "bin")
SCRIPT = os.path.join(BIN_DIR, "browser-picker-editor-data")


def _make_executable(path, content="#!/bin/sh\nexit 0\n"):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(path, 0o755)


class EditorDataTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.home = os.path.join(self.root, "home")
        self.xdg_config = os.path.join(self.root, "config")
        self.xdg_data = os.path.join(self.root, "data")
        self.xdg_data_dirs = os.path.join(self.root, "sysdata")
        self.fake_bin = os.path.join(self.root, "bin")
        self.conf_dir = os.path.join(self.xdg_config, "browser-picker")
        for d in (
            self.home,
            self.xdg_config,
            os.path.join(self.xdg_data, "applications"),
            os.path.join(self.xdg_data_dirs, "applications"),
            self.fake_bin,
        ):
            os.makedirs(d, exist_ok=True)

    def tearDown(self):
        self.tmp.cleanup()

    def _env(self, extra=None):
        env = {
            "HOME": self.home,
            "XDG_CONFIG_HOME": self.xdg_config,
            "XDG_CONFIG_DIRS": os.path.join(self.root, "etc-xdg"),
            "XDG_DATA_HOME": self.xdg_data,
            "XDG_DATA_DIRS": self.xdg_data_dirs,
            "PATH": f"{self.fake_bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
        }
        if extra:
            env.update(extra)
        return env

    def _run(self, *args, env_extra=None, input=None):
        return subprocess.run(
            [sys.executable, SCRIPT, *args],
            capture_output=True,
            text=True,
            env=self._env(env_extra),
            input=input,
        )

    def _write_conf(self, filename, text):
        os.makedirs(self.conf_dir, exist_ok=True)
        path = os.path.join(self.conf_dir, filename)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def _read_conf(self, filename):
        with open(os.path.join(self.conf_dir, filename), encoding="utf-8") as f:
            return f.read()

    def _install_fake_zoom_app(self):
        zoom_bin = os.path.join(self.fake_bin, "zoom")
        _make_executable(zoom_bin)
        desktop = os.path.join(self.xdg_data, "applications", "Zoom.desktop")
        with open(desktop, "w", encoding="utf-8") as f:
            f.write(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=Zoom\n"
                f"Exec={zoom_bin} %u\n"
                "MimeType=x-scheme-handler/zoommtg;\n"
            )

    def _install_fake_t3_app(self):
        t3_bin = os.path.join(self.fake_bin, "t3code")
        _make_executable(t3_bin)
        desktop = os.path.join(self.xdg_data, "applications", "t3-code.desktop")
        with open(desktop, "w", encoding="utf-8") as f:
            f.write(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=T3 Code\n"
                f"Exec={t3_bin} %u\n"
                "MimeType=x-scheme-handler/t3code;\n"
            )

    def test_no_gtk_dependency(self):
        loader = importlib.machinery.SourceFileLoader("editor_data_mod", SCRIPT)
        spec = importlib.util.spec_from_loader("editor_data_mod", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        self.assertNotIn("gi", sys.modules)
        self.assertTrue(os.access(SCRIPT, os.X_OK))

    def test_load_missing_config_is_compact_json_and_side_effect_free(self):
        proc = self._run("load")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stderr, "")
        self.assertEqual(len(proc.stdout.splitlines()), 1)
        data = json.loads(proc.stdout)
        # Compact JSON check (no indentation or spaces after separators)
        self.assertEqual(
            proc.stdout.rstrip("\n"),
            json.dumps(data, separators=(",", ":"), ensure_ascii=False),
        )
        self.assertEqual(
            set(data.keys()),
            {"rules", "fallback", "browsers", "apps", "suggestions", "revision", "sort", "autosave", "onboarding_seen"},
        )
        self.assertEqual(data["rules"], [])
        self.assertEqual(data["sort"], "priority")
        self.assertIs(data["autosave"], True)
        self.assertIs(data["onboarding_seen"], False)
        self.assertIsNone(data["fallback"])
        self.assertEqual(data["browsers"], [])
        self.assertEqual(data["apps"], [])
        self.assertEqual(data["suggestions"], [])
        self.assertEqual(data["revision"], "missing")
        self.assertFalse(os.path.exists(self.conf_dir))

    def test_sort_preference_survives_reload_without_writing_rules(self):
        self.assertEqual(self._run("sort", "target").returncode, 0)
        self.assertEqual(json.loads(self._run("load").stdout)["sort"], "target")
        self.assertNotEqual(self._run("sort", "invalid").returncode, 0)
        self.assertEqual(json.loads(self._run("load").stdout)["sort"], "target")
        self.assertFalse(os.path.exists(os.path.join(self.conf_dir, "rules.conf")))

    def test_autosave_preference_defaults_on_and_survives_reload(self):
        self.assertIs(json.loads(self._run("load").stdout)["autosave"], True)
        self.assertEqual(self._run("autosave", "off").returncode, 0)
        self.assertIs(json.loads(self._run("load").stdout)["autosave"], False)
        self.assertEqual(self._run("autosave", "on").returncode, 0)
        self.assertIs(json.loads(self._run("load").stdout)["autosave"], True)
        self.assertFalse(os.path.exists(os.path.join(self.conf_dir, "rules.conf")))

    def test_app_onboarding_dismissal_persists_without_writing_rules(self):
        self.assertIs(json.loads(self._run("load").stdout)["onboarding_seen"], False)
        self.assertEqual(self._run("onboarding").returncode, 0)
        self.assertIs(json.loads(self._run("load").stdout)["onboarding_seen"], True)
        self.assertFalse(os.path.exists(os.path.join(self.conf_dir, "rules.conf")))

    def test_url_trace_uses_draft_priority_and_never_writes_rules(self):
        self._write_conf("browsers.conf", "Firefox|||firefox\n")
        self._install_fake_zoom_app()
        rules = [
            {"pattern": "127.0.0.1:3100", "enabled": False, "label": "Firefox", "private": False},
            {"pattern": "*", "enabled": True, "label": "Zoom", "private": False},
            {"pattern": "regex:[?&]tenant=test$", "enabled": True, "label": "Firefox", "private": True},
            {"pattern": "http://127.0.0.1:3100/*", "enabled": True, "label": "Firefox", "private": False},
        ]
        payload = {"url": "http://127.0.0.1:3100/?tenant=test", "rules": rules, "fallback": "Firefox"}
        proc = self._run("trace", input=json.dumps(payload))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data["outcome"], "rule")
        self.assertEqual([row["status"] for row in data["matches"]],
                         ["disabled", "unsupported", "winner", "later", "later"])
        self.assertTrue(data["matches"][-1]["fallback"])
        self.assertFalse(os.path.exists(os.path.join(self.conf_dir, "rules.conf")))

    def test_load_preserves_priority_private_catchall_and_stale_labels(self):
        self._write_conf(
            "browsers.conf",
            "# comment\n"
            "Chromium — Work|||chromium --profile-directory=\"Profile 1\"\n"
            "Firefox — default|||firefox -P \"default\"\n",
        )
        self._write_conf(
            "rules.conf",
            "# header\n\n"
            "1|||github.com/myorg|||Chromium — Work\n"
            "0|||bank.example.com|||Firefox — default|||1\n"
            "1|||legacy.internal|||Removed Profile|||1\n"
            "1|||*|||Stale Fallback\n",
        )
        proc = self._run("load")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(
            data["browsers"],
            ["Chromium — Work", "Firefox — default"],
        )
        self.assertEqual(
            data["rules"],
            [
                {
                    "enabled": True,
                    "pattern": "github.com/myorg",
                    "label": "Chromium — Work",
                    "private": False,
                },
                {
                    "enabled": False,
                    "pattern": "bank.example.com",
                    "label": "Firefox — default",
                    "private": True,
                },
                {
                    "enabled": True,
                    "pattern": "legacy.internal",
                    "label": "Removed Profile",
                    "private": True,
                },
            ],
        )
        self.assertEqual(data["fallback"], "Stale Fallback")
        self.assertTrue(data["revision"].startswith("sha256:"))

    def test_load_keeps_private_disabled_and_non_trailing_catchall_in_rules(self):
        # Private catch-all
        self._write_conf(
            "rules.conf",
            "1|||a.example.com|||Browser A\n1|||*|||Browser B|||1\n",
        )
        data = json.loads(self._run("load").stdout)
        self.assertIsNone(data["fallback"])
        self.assertEqual(len(data["rules"]), 2)
        self.assertEqual(
            data["rules"][1],
            {"enabled": True, "pattern": "*", "label": "Browser B", "private": True},
        )

        # Disabled catch-all
        self._write_conf(
            "rules.conf",
            "1|||a.example.com|||Browser A\n0|||*|||Browser B\n",
        )
        data = json.loads(self._run("load").stdout)
        self.assertIsNone(data["fallback"])
        self.assertEqual(len(data["rules"]), 2)
        self.assertEqual(
            data["rules"][1],
            {"enabled": False, "pattern": "*", "label": "Browser B", "private": False},
        )

        # Non-trailing catch-all
        self._write_conf(
            "rules.conf",
            "1|||*|||Browser B\n1|||a.example.com|||Browser A\n",
        )
        data = json.loads(self._run("load").stdout)
        self.assertIsNone(data["fallback"])
        self.assertEqual(
            [r["pattern"] for r in data["rules"]],
            ["*", "a.example.com"],
        )

    def test_suggestions_apps_learned_habits_and_policy(self):
        self._install_fake_zoom_app()
        self._install_fake_t3_app()
        self._write_conf(
            "browsers.conf",
            "Chromium — Work|||chromium --profile-directory=\"Profile 1\"\n",
        )
        self._write_conf("settings.conf", "threshold=2\n")
        history = {
            "events": [
                # Browser private habit (should be suggested)
                {
                    "url": "https://docs.example.com/private/one",
                    "host": "docs.example.com",
                    "segs": ["private", "one"],
                    "label": "Chromium — Work",
                    "private": True,
                    "ts": 1,
                },
                {
                    "url": "https://docs.example.com/private/two",
                    "host": "docs.example.com",
                    "segs": ["private", "two"],
                    "label": "Chromium — Work",
                    "private": True,
                    "ts": 2,
                },
                # Valid matched local app habit (should be suggested)
                {
                    "url": "https://app.t3.codes/threads/ws1/abc",
                    "host": "app.t3.codes",
                    "segs": ["threads", "ws1", "abc"],
                    "label": "T3 Code",
                    "ts": 3,
                },
                {
                    "url": "https://app.t3.codes/threads/ws1/def",
                    "host": "app.t3.codes",
                    "segs": ["threads", "ws1", "def"],
                    "label": "T3 Code",
                    "ts": 4,
                },
                # Private habit on a local app (MUST NOT be suggested)
                {
                    "url": "https://app.t3.codes/new?p=1",
                    "host": "app.t3.codes",
                    "segs": ["new"],
                    "label": "T3 Code",
                    "private": True,
                    "ts": 5,
                },
                {
                    "url": "https://app.t3.codes/new?p=2",
                    "host": "app.t3.codes",
                    "segs": ["new"],
                    "label": "T3 Code",
                    "private": True,
                    "ts": 6,
                },
                # Zoom learned habit (suppressed because Zoom has a scoped app default)
                {
                    "url": "https://zoom.us/j/123456",
                    "host": "zoom.us",
                    "segs": ["j", "123456"],
                    "label": "Zoom",
                    "ts": 7,
                },
                {
                    "url": "https://zoom.us/j/789012",
                    "host": "zoom.us",
                    "segs": ["j", "789012"],
                    "label": "Zoom",
                    "ts": 8,
                },
                # Uninstalled/unknown app habit (MUST NOT be suggested)
                {
                    "url": "https://music.example.com/track/1",
                    "host": "music.example.com",
                    "segs": ["track", "1"],
                    "label": "Ghost App",
                    "ts": 9,
                },
                {
                    "url": "https://music.example.com/track/2",
                    "host": "music.example.com",
                    "segs": ["track", "2"],
                    "label": "Ghost App",
                    "ts": 10,
                },
            ]
        }
        _make_executable(os.path.join(self.fake_bin, "omarchy-launch-webapp"))
        with open(os.path.join(self.xdg_data, "applications", "Notes.desktop"), "w", encoding="utf-8") as f:
            f.write("[Desktop Entry]\nType=Application\nName=Notes\n"
                    "Exec=omarchy-launch-webapp https://notes.example.com/\n")
        with open(os.path.join(self.xdg_data, "applications", "Calendar.desktop"), "w", encoding="utf-8") as f:
            f.write("[Desktop Entry]\nType=Application\nName=Calendar\n"
                    "Exec=omarchy-launch-webapp https://calendar.example.com/\n")
        history["events"].extend(
            {"url": f"https://notes.example.com/docs/{i}", "host": "notes.example.com",
             "segs": ["docs", str(i)], "label": "Notes — Web App", "ts": 20 + i}
            for i in range(2)
        )
        self._write_conf("history.json", json.dumps(history))
        # Disabled rule for docs.example.com/private should still allow suggestion
        self._write_conf(
            "rules.conf",
            "0|||docs.example.com/private|||Chromium — Work|||1\n",
        )

        proc = self._run("load")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertIn("Zoom", data["apps"])
        self.assertIn("T3 Code", data["apps"])

        by_key = {(s["pattern"], s["label"], s["private"]): s for s in data["suggestions"]}
        # Zoom detected app default
        zoom_sugs = [s for s in data["suggestions"] if s["label"] == "Zoom"]
        self.assertEqual(len(zoom_sugs), 1)
        self.assertEqual(zoom_sugs[0]["title"], "Zoom meetings")
        self.assertEqual(zoom_sugs[0]["reason"], "Detected app")
        self.assertEqual((zoom_sugs[0]["kind"], zoom_sugs[0]["uses"], zoom_sugs[0]["last_used"]),
                         ("desktop", 2, 8))
        self.assertFalse(zoom_sugs[0]["private"])

        # Learned private browser habit
        self.assertIn(("docs.example.com/private", "Chromium — Work", True), by_key)
        self.assertEqual(
            by_key[("docs.example.com/private", "Chromium — Work", True)]["reason"],
            "Chosen 2 times",
        )
        browser = by_key[("docs.example.com/private", "Chromium — Work", True)]
        self.assertEqual((browser["kind"], browser["uses"], browser["last_used"]), ("browser", 2, 2))

        # Learned non-private T3 Code habit
        self.assertIn(("app.t3.codes/threads/ws1", "T3 Code", False), by_key)
        webapp = by_key[("notes.example.com/docs", "Notes — Web App", False)]
        self.assertEqual((webapp["kind"], webapp["uses"], webapp["last_used"]), ("webapp", 2, 21))
        detected = by_key[("calendar.example.com", "Calendar — Web App", False)]
        self.assertEqual((detected["kind"], detected["uses"], detected["reason"]),
                         ("webapp", 0, "Installed web app"))
        self.assertNotIn(("notes.example.com", "Notes — Web App", False), by_key)

        # Private local-app habit and unknown app habit excluded
        self.assertNotIn(("app.t3.codes/new", "T3 Code", True), by_key)
        self.assertFalse(any(s["label"] == "Ghost App" for s in data["suggestions"]))

        # Saving an enabled rule still returns the raw suggestion list so frontends
        # can dynamically filter/reveal suggestions as draft rules are toggled or removed.
        save_payload = {
            "rules": [
                {
                    "enabled": True,
                    "pattern": "docs.example.com/private",
                    "label": "Chromium — Work",
                    "private": True,
                }
            ],
            "fallback": None,
            "revision": data["revision"],
        }
        saved = self._run("save", json.dumps(save_payload))
        self.assertEqual(saved.returncode, 0, saved.stderr)
        saved_data = json.loads(saved.stdout)
        self.assertTrue(
            any(s["pattern"] == "docs.example.com/private" for s in saved_data["suggestions"])
        )

    def test_rescan_merges_and_deduplicates_profiles_like_gtk(self):
        # Put fake chromium and firefox binaries on PATH (and exclude real ones)
        _make_executable(os.path.join(self.fake_bin, "chromium"))
        _make_executable(os.path.join(self.fake_bin, "firefox"))

        chromium_dir = os.path.join(self.home, ".config", "chromium")
        os.makedirs(chromium_dir, exist_ok=True)
        with open(os.path.join(chromium_dir, "Local State"), "w", encoding="utf-8") as f:
            json.dump(
                {
                    "profile": {
                        "info_cache": {
                            "Default": {"name": "Personal"},
                            "Profile 1": {"name": "Work"},
                        }
                    }
                },
                f,
            )

        ff_dir = os.path.join(self.home, ".mozilla", "firefox")
        os.makedirs(ff_dir, exist_ok=True)
        with open(os.path.join(ff_dir, "profiles.ini"), "w", encoding="utf-8") as f:
            f.write("[Profile0]\nName=default-release\nPath=abc.default\n")

        # Existing custom label for Profile 1 (without quotes) must dedup via normcmd
        self._write_conf(
            "browsers.conf",
            "My Work Browser|||chromium --profile-directory=Profile 1\n",
        )

        # Restrict PATH to only fake_bin so host browsers don't leak into the test
        proc = self._run("rescan", env_extra={"PATH": self.fake_bin})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(
            data["browsers"],
            [
                "My Work Browser",
                "Chromium — Personal",
                "Firefox — default-release",
            ],
        )

        # Second rescan is idempotent
        before = self._read_conf("browsers.conf")
        proc2 = self._run("rescan", env_extra={"PATH": self.fake_bin})
        self.assertEqual(proc2.returncode, 0, proc2.stderr)
        self.assertEqual(self._read_conf("browsers.conf"), before)
        self.assertEqual(json.loads(proc2.stdout)["browsers"], data["browsers"])

    def test_save_atomic_roundtrip_and_stale_revision_conflict(self):
        self._write_conf("browsers.conf", "Chromium — Work|||chromium\nFirefox|||firefox\n")

        # Initial load when rules.conf is missing
        loaded = json.loads(self._run("load").stdout)
        self.assertEqual(loaded["revision"], "missing")

        payload1 = {
            "rules": [
                {
                    "enabled": True,
                    "pattern": "  regex:^https://(mail|cal)\\.google\\.com/  ",
                    "label": "Chromium — Work",
                    "private": False,
                },
                {
                    "enabled": False,
                    "pattern": "secret.example.com",
                    "label": "Firefox",
                    "private": True,
                },
                {
                    "enabled": True,
                    "pattern": "legacy.example.com",
                    "label": "Stale Profile",
                    "private": True,
                },
            ],
            "fallback": "Firefox",
            "revision": loaded["revision"],
        }
        proc1 = self._run("save", json.dumps(payload1))
        self.assertEqual(proc1.returncode, 0, proc1.stderr)
        state1 = json.loads(proc1.stdout)
        self.assertNotEqual(state1["revision"], "missing")
        self.assertEqual(state1["fallback"], "Firefox")
        self.assertEqual(
            state1["rules"][0]["pattern"],
            "regex:^https://(mail|cal)\\.google\\.com/",
        )

        # Check exact on-disk formatting and no leftover .tmp files
        disk = self._read_conf("rules.conf")
        self.assertIn("1|||regex:^https://(mail|cal)\\.google\\.com/|||Chromium — Work\n", disk)
        self.assertIn("0|||secret.example.com|||Firefox|||1\n", disk)
        self.assertIn("1|||legacy.example.com|||Stale Profile|||1\n", disk)
        self.assertTrue(disk.endswith("1|||*|||Firefox\n"))
        self.assertFalse(
            any(name.endswith(".tmp") for name in os.listdir(self.conf_dir))
        )

        # Stale editor save using old revision ("missing") MUST fail
        stale_proc = self._run("save", json.dumps(payload1))
        self.assertEqual(stale_proc.returncode, 3)
        self.assertEqual(stale_proc.stdout, "")
        self.assertIn("changed on disk", stale_proc.stderr.lower())
        self.assertEqual(self._read_conf("rules.conf"), disk)

        # External edit invalidates state1["revision"]
        self._write_conf("rules.conf", disk + "# external edit\n")
        payload2 = {
            "rules": [],
            "fallback": None,
            "revision": state1["revision"],
        }
        conflict = self._run("save", json.dumps(payload2))
        self.assertEqual(conflict.returncode, 3)
        self.assertEqual(conflict.stdout, "")
        self.assertIn("# external edit", self._read_conf("rules.conf"))

        # Reloading gets fresh revision and save succeeds (preserving private catchall)
        reloaded = json.loads(self._run("load").stdout)
        payload3 = {
            "rules": [
                {
                    "enabled": True,
                    "pattern": "*",
                    "label": "Firefox",
                    "private": True,
                }
            ],
            "fallback": None,
            "revision": reloaded["revision"],
        }
        proc3 = self._run("save", json.dumps(payload3))
        self.assertEqual(proc3.returncode, 0, proc3.stderr)
        state3 = json.loads(proc3.stdout)
        self.assertIsNone(state3["fallback"])
        self.assertEqual(
            state3["rules"],
            [{"enabled": True, "pattern": "*", "label": "Firefox", "private": True}],
        )
        self.assertTrue(self._read_conf("rules.conf").endswith("1|||*|||Firefox|||1\n"))

    def test_stale_revision_when_rules_missing_does_not_create_config_dir(self):
        payload = {"rules": [], "fallback": None, "revision": "sha256:0000"}
        proc = self._run("save", json.dumps(payload))
        self.assertEqual(proc.returncode, 3)
        self.assertEqual(proc.stdout, "")
        self.assertFalse(os.path.exists(self.conf_dir))

    def test_validation_rejects_injection_and_malformed_inputs(self):
        self._write_conf("browsers.conf", "Firefox|||firefox\n")
        orig = "# original\n1|||example.com|||Firefox\n"
        self._write_conf("rules.conf", orig)
        rev = json.loads(self._run("load").stdout)["revision"]

        bad_cli = [
            (),
            ("unknown",),
            ("load", "extra"),
            ("rescan", "extra"),
            ("save",),
            ("save", "{}", "extra"),
            ("save", "{not json"),
            ("save", "[]"),
        ]
        for argv in bad_cli:
            proc = self._run(*argv)
            self.assertEqual(proc.returncode, 2, f"expected 2 for {argv}")
            self.assertEqual(proc.stdout, "")
            self.assertTrue(proc.stderr.strip())

        bad_payloads = [
            # Missing / invalid top-level fields
            {"rules": "nope", "fallback": None, "revision": rev},
            {"rules": [], "fallback": None, "revision": ""},
            {"rules": [], "fallback": None},
            {"rules": [], "fallback": 123, "revision": rev},
            {"rules": [], "fallback": "", "revision": rev},
            {"rules": [], "fallback": "   ", "revision": rev},
            # Delimiter / newline / control / trailing-pipe injection in fallback
            {"rules": [], "fallback": "Fire|||fox", "revision": rev},
            {"rules": [], "fallback": "Firefox\n1|||*|||Evil", "revision": rev},
            {"rules": [], "fallback": "Firefox\r", "revision": rev},
            {"rules": [], "fallback": "Firefox\x00", "revision": rev},
            {"rules": [], "fallback": "Firefox|", "revision": rev},
            {"rules": [], "fallback": " Firefox ", "revision": rev},
            # Bad rule objects / field types
            {"rules": ["not-an-object"], "fallback": None, "revision": rev},
            {
                "rules": [{"enabled": 1, "pattern": "a.com", "label": "Firefox", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "a.com", "label": "Firefox", "private": "0"}],
                "fallback": None,
                "revision": rev,
            },
            # Empty pattern / label
            {
                "rules": [{"enabled": True, "pattern": "   ", "label": "Firefox", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "a.com", "label": "", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            # Delimiter / newline / trailing-pipe injection in pattern
            {
                "rules": [{"enabled": True, "pattern": "a|||b", "label": "Firefox", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "a.com\n1|||*|||Evil", "label": "Firefox", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "a.com\n", "label": "Firefox", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "a.com\u2028b", "label": "Firefox", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "regex:foo|", "label": "Firefox", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            # Delimiter / newline / trailing-pipe / whitespace injection in label
            {
                "rules": [{"enabled": True, "pattern": "a.com", "label": "A|||B", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "a.com", "label": "A\nB", "private": False}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "a.com", "label": "A|", "private": True}],
                "fallback": None,
                "revision": rev,
            },
            {
                "rules": [{"enabled": True, "pattern": "a.com", "label": "Firefox ", "private": False}],
                "fallback": None,
                "revision": rev,
            },
        ]
        for idx, payload in enumerate(bad_payloads):
            proc = self._run("save", json.dumps(payload))
            self.assertEqual(proc.returncode, 2, f"case {idx} should fail: {payload}")
            self.assertEqual(proc.stdout, "", f"case {idx} wrote stdout: {proc.stdout}")
            self.assertTrue(proc.stderr.strip(), f"case {idx} missing stderr")
            self.assertEqual(self._read_conf("rules.conf"), orig)

    def test_app_private_and_fallback_policy_matches_gtk(self):
        self._install_fake_t3_app()
        self._install_fake_zoom_app()
        self._write_conf("browsers.conf", "Firefox|||firefox\n")
        self._write_conf(
            "rules.conf",
            "1|||t3.codes/legacy|||T3 Code|||1\n",
        )

        state = json.loads(self._run("load").stdout)
        self.assertIn("T3 Code", state["apps"])
        self.assertIn("Zoom", state["apps"])

        # 1. Existing private flag on a local app is preserved when saving unrelated edits.
        p1 = {
            "rules": [
                {
                    "enabled": True,
                    "pattern": "t3.codes/legacy",
                    "label": "T3 Code",
                    "private": True,
                },
                {
                    "enabled": True,
                    "pattern": "zoom.us/j/*",
                    "label": "Zoom",
                    "private": False,
                },
            ],
            "fallback": "Firefox",
            "revision": state["revision"],
        }
        r1 = self._run("save", json.dumps(p1))
        self.assertEqual(r1.returncode, 0, r1.stderr)
        state1 = json.loads(r1.stdout)
        self.assertTrue(state1["rules"][0]["private"])

        # 2. Adding a NEW private rule for Zoom (or a second private rule for T3 Code) is rejected.
        for bad_label in ("Zoom", "T3 Code"):
            bad = {
                "rules": state1["rules"]
                + [
                    {
                        "enabled": True,
                        "pattern": "extra.example.com",
                        "label": bad_label,
                        "private": True,
                    }
                ],
                "fallback": "Firefox",
                "revision": state1["revision"],
            }
            res = self._run("save", json.dumps(bad))
            self.assertEqual(res.returncode, 2, f"private rule for {bad_label} must be rejected")
            self.assertIn("does not support private", res.stderr)

        # 3. Setting fallback to a local app when it wasn't already the fallback is rejected.
        bad_fb = {
            "rules": state1["rules"],
            "fallback": "Zoom",
            "revision": state1["revision"],
        }
        res_fb = self._run("save", json.dumps(bad_fb))
        self.assertEqual(res_fb.returncode, 2)
        self.assertIn("local app", res_fb.stderr.lower())

        # 4. Unchecking private on T3 Code succeeds, and re-enabling it afterwards is rejected.
        p_uncheck = {
            "rules": [
                {
                    "enabled": True,
                    "pattern": "t3.codes/legacy",
                    "label": "T3 Code",
                    "private": False,
                }
            ],
            "fallback": None,
            "revision": state1["revision"],
        }
        r_uncheck = self._run("save", json.dumps(p_uncheck))
        self.assertEqual(r_uncheck.returncode, 0, r_uncheck.stderr)
        state2 = json.loads(r_uncheck.stdout)
        p_reenable = {
            "rules": [
                {
                    "enabled": True,
                    "pattern": "t3.codes/legacy",
                    "label": "T3 Code",
                    "private": True,
                }
            ],
            "fallback": None,
            "revision": state2["revision"],
        }
        r_reenable = self._run("save", json.dumps(p_reenable))
        self.assertEqual(r_reenable.returncode, 2)

        # 5. If a label is in browsers.conf, browser precedence applies (private & fallback allowed).
        self._write_conf("browsers.conf", "Firefox|||firefox\nZoom|||custom-zoom-browser\n")
        state3 = json.loads(self._run("load").stdout)
        self.assertIn("Zoom", state3["browsers"])
        self.assertNotIn("Zoom", state3["apps"])
        p_browser_wins = {
            "rules": [
                {
                    "enabled": True,
                    "pattern": "zoom.us/j/*",
                    "label": "Zoom",
                    "private": True,
                }
            ],
            "fallback": "Zoom",
            "revision": state3["revision"],
        }
        r_browser_wins = self._run("save", json.dumps(p_browser_wins))
        self.assertEqual(r_browser_wins.returncode, 0, r_browser_wins.stderr)

    def test_existing_local_app_fallback_is_preserved(self):
        self._install_fake_zoom_app()
        self._write_conf("browsers.conf", "Firefox|||firefox\n")
        self._write_conf("rules.conf", "1|||*|||Zoom\n")
        state = json.loads(self._run("load").stdout)
        self.assertEqual(state["fallback"], "Zoom")

        # Saving while preserving existing fallback succeeds
        p = {
            "rules": [
                {
                    "enabled": True,
                    "pattern": "example.com",
                    "label": "Firefox",
                    "private": False,
                }
            ],
            "fallback": "Zoom",
            "revision": state["revision"],
        }
        res = self._run("save", json.dumps(p))
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(json.loads(res.stdout)["fallback"], "Zoom")


if __name__ == "__main__":
    unittest.main(verbosity=2)
