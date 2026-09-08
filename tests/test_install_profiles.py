"""Verify configuration installation without vendor assets or system changes."""
from contextlib import ExitStack, redirect_stdout
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import call, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import install_profiles


class InstallProfilesTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.repository = self.directory / 'repository'
        self.home = self.directory / 'home'
        self.home.mkdir()
        self.unrelated = self.home / 'unrelated/nested'
        self.unrelated.mkdir(parents=True)
        (self.unrelated / 'settings.conf').write_text('Unrelated configuration.\n')
        self.payload = self.repository / 'payload'
        self.system_library = self.directory / 'usr/lib/ladspa'
        self.udev_rules = self.directory / 'etc/udev/rules.d'
        shutil.copytree(ROOT / 'configs', self.repository / 'configs')
        for directory in ('native', 'src', 'assets', 'docs', 'payload'):
            (self.repository / directory).mkdir()
        (self.repository / 'native/inzone_dsp.so').write_bytes(b'plugin fixture')
        for source in (ROOT / 'src').glob('*.py'):
            shutil.copy2(source, self.repository / 'src' / source.name)
        (self.repository / 'README.md').write_text('Installation fixture.\n')
        for name in ('sony-eq-tables.json', 'sony-presets.json'):
            (self.repository / 'assets' / name).write_text('{}\n')
        for name in ('inzonevirtualizer.dll', 'shp_for_game_v2.0_512tap.hki', 'wh_g910n_standard.ba'):
            (self.payload / name).write_bytes(b'asset fixture')
        self.data = self.home / '.config/inzone-h9-ii'
        self.wireplumber = self.home / '.config/wireplumber/wireplumber.conf.d'
        self.active = self.wireplumber / '51-inzone-h9-ii.conf'
        self.destinations = {
            name + '.conf': self.data / (name + '.conf')
            for name in ('fps', 'music', 'voice', 'balanced', 'original')
        }
        self.destinations.update({
            '52-inzone-game-chat.conf': self.wireplumber / '52-inzone-game-chat.conf',
            'systemd/inzone-profile-auto.service': self.home / '.config/systemd/user/inzone-profile-auto.service',
            'udev/70-inzone-h9-ii.rules': self.udev_rules / '70-inzone-h9-ii.rules',
        })

    def install(self):
        def export_fixture(payload, assets):
            self.assertEqual(payload, self.payload)
            assets.mkdir(parents=True, exist_ok=True)
            (assets / 'h9-ii-biquads.json').write_text('[[1, 0, 0, 0, 0]]\n')

        directories_before = {path for path in self.home.rglob('*') if path.is_dir()}
        owner = self.home.stat()
        with ExitStack() as stack:
            for name, value in (
                ('ROOT', self.repository),
                ('SYSTEM_LIBRARY_DIRECTORY', self.system_library),
                ('UDEV_RULES_DIRECTORY', self.udev_rules),
            ):
                stack.enter_context(patch.object(install_profiles, name, value))
            stack.enter_context(patch.object(sys, 'argv', [
                'install_profiles.py', '--home', str(self.home), '--payload', str(self.payload),
            ]))
            stack.enter_context(patch.object(install_profiles.os, 'getuid', return_value=0))
            ownership = stack.enter_context(patch.object(install_profiles.os, 'chown'))
            commands = stack.enter_context(patch.object(install_profiles.subprocess, 'run'))
            stack.enter_context(patch.object(install_profiles, 'export', side_effect=export_fixture))
            stack.enter_context(redirect_stdout(io.StringIO()))
            install_profiles.main()
            self.assertEqual(commands.call_args_list, [
                call(['make', '-C', str(self.repository / 'native')], check=True),
                call(['udevadm', 'control', '--reload-rules'], check=True),
            ])
            ownership_calls = {
                (Path(entry.args[0]), entry.args[1], entry.args[2])
                for entry in ownership.call_args_list
            }
        created_directories = {
            path for path in self.home.rglob('*') if path.is_dir()
        } - directories_before
        for directory in created_directories:
            with self.subTest(owner=directory.relative_to(self.home)):
                self.assertIn((directory, owner.st_uid, owner.st_gid), ownership_calls)
        for path, _, _ in ownership_calls:
            self.assertNotEqual(path, self.home)
            self.assertFalse(path.is_relative_to(self.unrelated.parent), str(path))
        self.assertEqual((self.unrelated / 'settings.conf').read_text(), 'Unrelated configuration.\n')

    def assert_python_sources_installed(self):
        self.assertEqual(
            (self.home / '.local/bin/inzone-profile').read_bytes(),
            (self.repository / 'src/inzone-profile.py').read_bytes(),
        )
        for name in (
            'build_graph.py', 'sony_filters.py', 'inzone_settings.py', 'personalization.py',
            'inzone_device.py', 'device_tui.py', 'sony_presets.py', 'profile_automation.py',
        ):
            with self.subTest(module=name):
                self.assertEqual(
                    (self.home / '.local/share/inzone-linux/python' / name).read_bytes(),
                    (self.repository / 'src' / name).read_bytes(),
                )

    def test_first_install_deploys_all_configs_and_generates_profiles(self):
        self.assertFalse(self.udev_rules.exists())
        self.install()
        self.assert_python_sources_installed()
        for source, destination in self.destinations.items():
            with self.subTest(source=source):
                self.assertEqual(destination.read_bytes(), (self.repository / 'configs' / source).read_bytes())
        self.assertEqual(self.active.read_bytes(), (self.data / 'balanced.conf').read_bytes())
        surround = json.loads('\n'.join((self.data / 'surround.conf').read_text().splitlines()[1:]))
        graph = json.loads((self.data / 'sony-surround.json').read_text())
        self.assertEqual(surround['wireplumber.profiles']['main']['node.software-dsp'], 'required')
        rule = surround['node.software-dsp.rules'][0]
        self.assertEqual(rule['matches'], [{'node.name': install_profiles.GAME}])
        self.assertEqual(json.loads(rule['actions']['create-filter']['filter-graph']), graph)
        self.assertEqual(graph['playback.props']['target.object'], install_profiles.GAME)
        self.assertEqual(graph['capture.props']['audio.channels'], 8)

    def test_reinstall_refreshes_templates_and_preserves_user_state_with_backup(self):
        self.install()
        self.unrelated = self.home / '.config/unrelated/nested'
        self.unrelated.mkdir(parents=True)
        (self.unrelated / 'settings.conf').write_text('Unrelated configuration.\n')
        previous = {}
        for name in ('fps', 'music', 'voice', 'balanced'):
            path = self.data / (name + '.conf')
            previous[path] = '# Existing profile: ' + name + '\n{}\n'
        preserved = {
            self.data / 'original.conf': '# Saved restore configuration.\nmonitor.alsa.rules = []\n',
            self.active: '# INZONE profile: music\n{"custom": true}\n',
            self.data / 'profile-settings.json': '{"music": {"drc": 2}}\n',
            self.data / 'auto-profiles.json': '{"enabled": false, "bindings": []}\n',
        }
        previous.update(preserved)
        for path, contents in previous.items():
            path.write_text(contents)
        for source in ('52-inzone-game-chat.conf', 'systemd/inzone-profile-auto.service', 'udev/70-inzone-h9-ii.rules'):
            self.destinations[source].write_text('Existing configuration.\n')
        self.install()
        self.assert_python_sources_installed()
        for source, destination in self.destinations.items():
            if source == 'original.conf':
                continue
            with self.subTest(source=source):
                self.assertEqual(destination.read_bytes(), (self.repository / 'configs' / source).read_bytes())
        for path, contents in preserved.items():
            with self.subTest(preserved=path.name):
                self.assertEqual(path.read_text(), contents)
        backups = list((self.home / '.local/state/inzone-linux/backups').iterdir())
        self.assertEqual(len(backups), 1)
        for path, contents in previous.items():
            with self.subTest(backup=path.name):
                self.assertEqual((backups[0] / path.relative_to(self.home)).read_text(), contents)


if __name__ == '__main__':
    unittest.main()
