"""SDK selection using temporary SDK metadata; no developer tools are modified."""
import contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
import io
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/macos-sdk'
LOADER = SourceFileLoader('board_macos_sdk', str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
sdk = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(sdk)


class SDKSelectionChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='Board SDK tests ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def make_sdk(self, version, canonical=None, parent=None):
        path = (parent or self.root) / ('MacOSX' + version + '.sdk')
        path.mkdir(parents=True)
        (path / 'SDKSettings.plist').write_bytes(plistlib.dumps({
            'CanonicalName': canonical or 'macosx' + version, 'Version': version,
        }))
        return path

    def test_minimum_is_macos_26(self):
        current = self.make_sdk('26.0')
        older = self.make_sdk('15.2')
        self.assertEqual(sdk.choose_sdk(current, [], False), current.resolve())
        with self.assertRaises(sdk.SDKError):
            sdk.choose_sdk(older, [older], True)

    def test_selected_stable_sdk_is_preserved(self):
        selected = self.make_sdk('26.0')
        newer = self.make_sdk('26.5')
        self.assertEqual(sdk.choose_sdk(selected, [newer], False), selected.resolve())

    def test_missing_beta_plugin_falls_back_to_newest_stable(self):
        beta = self.make_sdk('27.0')
        first = self.make_sdk('26.0')
        newest = self.make_sdk('26.5')
        self.assertEqual(sdk.choose_sdk(beta, [beta, first, newest], False), newest.resolve())

    def test_beta_with_matching_plugins_is_usable(self):
        beta = self.make_sdk('27.0')
        stable = self.make_sdk('26.5')
        self.assertEqual(sdk.choose_sdk(beta, [stable], True), beta.resolve())

    def test_no_compatible_fallback_reports_error(self):
        beta = self.make_sdk('27.0')
        with self.assertRaises(sdk.SDKError):
            sdk.choose_sdk(beta, [beta], False)

    def test_explicit_unsupported_missing_or_wrong_platform_sdk_is_rejected(self):
        stable = self.make_sdk('26.0')
        old = self.make_sdk('15.2')
        other = self.make_sdk('26.1', canonical='iphoneos26.1')
        broken = self.root / 'Broken.sdk'
        broken.mkdir()
        (broken / 'SDKSettings.plist').write_text('not a plist')
        for explicit in (old, other, broken, self.root / 'Missing.sdk'):
            with self.subTest(explicit=explicit.name), self.assertRaises(sdk.SDKError):
                sdk.choose_sdk(stable, [stable], True, str(explicit))

    def test_explicit_beta_without_plugins_does_not_silently_fallback(self):
        stable = self.make_sdk('26.0')
        beta = self.make_sdk('27.0')
        with self.assertRaises(sdk.SDKError):
            sdk.choose_sdk(stable, [stable], False, str(beta))

    def test_explicit_sdk_overrides_default(self):
        default = self.make_sdk('26.0')
        requested = self.make_sdk('26.5')
        self.assertEqual(sdk.choose_sdk(default, [default], False, str(requested)), requested.resolve())

    def test_xcode_path_with_spaces_survives_cli_selection(self):
        developer = self.root / 'Xcode Stable.app/Contents/Developer'
        selected = self.make_sdk('26.0', parent=developer / 'Platforms/MacOSX.platform/Developer/SDKs')
        swift = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'
        outputs = {
            ('xcrun', '--sdk', 'macosx', '--show-sdk-path'): str(selected),
            ('xcrun', '--find', 'swift'): str(swift),
        }
        output = io.StringIO()
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(sdk, 'command', side_effect=lambda *args: outputs[args]), contextlib.redirect_stdout(output):
            sdk.main()
        self.assertEqual(output.getvalue().strip(), str(selected.resolve()))

    def test_supported_sdkroot_preference_is_used(self):
        default = self.make_sdk('27.0')
        preferred = self.make_sdk('26.0')
        outputs = {
            ('xcrun', '--sdk', 'macosx', '--show-sdk-path'): str(default),
            ('xcrun', '--find', 'swift'): str(self.root / 'toolchain/usr/bin/swift'),
        }
        output = io.StringIO()
        with mock.patch.dict(os.environ, {'SDKROOT': str(preferred)}, clear=True), mock.patch.object(sdk, 'command', side_effect=lambda *args: outputs[args]), contextlib.redirect_stdout(output):
            sdk.main()
        self.assertEqual(output.getvalue().strip(), str(preferred.resolve()))

    def test_explicit_board_sdk_wins_over_sdkroot(self):
        default = self.make_sdk('27.0')
        preferred = self.make_sdk('26.5')
        explicit = self.make_sdk('26.0')
        outputs = {
            ('xcrun', '--sdk', 'macosx', '--show-sdk-path'): str(default),
            ('xcrun', '--find', 'swift'): str(self.root / 'toolchain/usr/bin/swift'),
        }
        output = io.StringIO()
        environment = {'SDKROOT': str(preferred), 'BOARD_SDK_PATH': str(explicit)}
        with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(sdk, 'command', side_effect=lambda *args: outputs[args]), contextlib.redirect_stdout(output):
            sdk.main()
        self.assertEqual(output.getvalue().strip(), str(explicit.resolve()))

    def test_sdk_symlink_resolves_to_installed_directory(self):
        selected = self.make_sdk('26.0')
        link = self.root / 'MacOSX.sdk'
        link.symlink_to(selected, target_is_directory=True)
        self.assertEqual(sdk.choose_sdk(link, [], False), selected.resolve())


if __name__ == '__main__':
    unittest.main()
