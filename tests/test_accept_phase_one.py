"""Ensure parse/runtime/assertion errors cannot be reported as passing tests."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import re
import unittest
import tempfile
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('accept_phase_one', Path(__file__).resolve().parents[1]/'tools/accept_phase_one.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RunnerTests(unittest.TestCase):
    def result(self, output='', code=0, timeout=False):
        return {'output': output, 'returncode': code, 'timeout': timeout}

    def marker(self, **updates):
        result = {'suite': 'fixture', 'passed': True, 'assertions': 3, 'failures': []}
        result.update(updates)
        return RUNNER.MARKER + json.dumps(result) + '\n'

    def test_accepts_only_structured_success(self):
        self.assertTrue(RUNNER.evaluate_suite(self.result(self.marker()), 'fixture')[0])
        for output in ('', 'fixture: passed\n', self.marker()+self.marker(), RUNNER.MARKER+'broken'):
            self.assertFalse(RUNNER.evaluate_suite(self.result(output), 'fixture')[0])

    def test_engine_errors_override_success_marker(self):
        for error in ('SCRIPT ERROR: Assertion failed', 'ERROR: Failed to load script', 'Parse Error: missing type'):
            with self.subTest(error=error):
                self.assertFalse(RUNNER.evaluate_suite(self.result(error+'\n'+self.marker()), 'fixture')[0])

    def test_partial_suite_success_cannot_hide_script_errors(self):
        # The phase-two audit observed these assertion counts and successful
        # markers despite dependency errors; neither makes a clean engine run.
        for suite, assertions in (('test_battle_rules', 5), ('test_battle_sim', 3)):
            with self.subTest(suite=suite):
                output = (
                    'SCRIPT ERROR: Compile Error: Failed to compile depended scripts.\n'
                    + self.marker(suite=suite, assertions=assertions)
                )
                self.assertEqual(
                    RUNNER.evaluate_suite(self.result(output, code=0), suite),
                    (False, 'engine_error_in_log'),
                )

    def test_standalone_compile_error_overrides_success(self):
        output = 'Compile Error: Failed to compile depended scripts.\n' + self.marker()
        self.assertEqual(
            RUNNER.evaluate_suite(self.result(output, code=0), 'fixture'),
            (False, 'engine_error_in_log'),
        )

    def test_failed_empty_or_wrong_suite_is_rejected(self):
        for patch in ({'passed': False}, {'assertions': 0}, {'assertions': True}, {'failures':['failed']}, {'suite':'wrong'}):
            self.assertFalse(RUNNER.evaluate_suite(self.result(self.marker(**patch)), 'fixture')[0])

    def test_non_object_marker_is_rejected(self):
        for value in (None, [], 5, 'passed', True):
            output = RUNNER.MARKER + json.dumps(value)
            self.assertFalse(RUNNER.evaluate_suite(self.result(output), 'fixture')[0])

    def test_timeout_and_exit_code(self):
        self.assertFalse(RUNNER.evaluate_suite(self.result(self.marker(), code=1), 'fixture')[0])
        self.assertFalse(RUNNER.evaluate_suite(self.result(self.marker(), timeout=True), 'fixture')[0])

    def test_import_allows_only_generated_script_uids(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(RUNNER, 'ROOT', Path(folder)):
            root = Path(folder)
            (root/'scripts').mkdir()
            (root/'project.godot').write_text('config_version=5\n', encoding='utf-8')
            source = root/'scripts/fixture.gd'
            source.write_text('extends RefCounted\n', encoding='utf-8')
            before = RUNNER.fingerprint()
            uid = root/'scripts/fixture.gd.uid'
            uid.write_text('uid://cabc12345\n', encoding='utf-8')
            self.assertEqual(RUNNER.accept_generated_uids(set(), before), ['scripts/fixture.gd.uid'])
            source.write_text('extends Node\n', encoding='utf-8')
            self.assertEqual(RUNNER.accept_generated_uids(set(), before), [])
            source.write_text('extends RefCounted\n', encoding='utf-8')
            uid.write_text('invalid\n', encoding='utf-8')
            self.assertEqual(RUNNER.accept_generated_uids(set(), before), [])
            uid.write_text('uid://cabc12345\n', encoding='utf-8')
            self.assertEqual(RUNNER.accept_generated_uids({'scripts/fixture.gd.uid'}, before), [])

    def _asset_fixture(self, root):
        (root/'assets').mkdir()
        (root/'scripts').mkdir()
        (root/'project.godot').write_text('config_version=5\n', encoding='utf-8')
        (root/'assets/fixture.png').write_bytes(b'unchanged texture fixture')
        (root/'assets/fixture.wav').write_bytes(b'unchanged audio fixture')
        (root/'scripts/fixture.gd').write_text('extends Node\n', encoding='utf-8')

    def _sidecar(self, name='fixture.png'):
        sound = name.endswith('.wav')
        target = 'res://.godot/imported/' + name + '-0123456789abcdef.' + ('sample' if sound else 'ctex')
        return (
            '[remap]\n\n'
            'importer=' + json.dumps('wav' if sound else 'texture') + '\n'
            'type=' + json.dumps('AudioStreamWAV' if sound else 'CompressedTexture2D') + '\n'
            'uid="uid://cabc12345"\n'
            'path=' + json.dumps(target) + '\n'
            'metadata={\n"vram_texture": false\n}\n\n'
            '[deps]\n\n'
            'source_file=' + json.dumps('res://assets/' + name) + '\n'
            'dest_files=' + json.dumps([target]) + '\n\n'
            '[params]\n\ncompress/mode=0\n'
        )

    def test_import_accepts_new_texture_wav_and_uid_together(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(RUNNER, 'ROOT', Path(folder)):
            root = Path(folder)
            self._asset_fixture(root)
            before = RUNNER.fingerprint()
            for name in ('fixture.png', 'fixture.wav'):
                (root/'assets'/f'{name}.import').write_text(self._sidecar(name), encoding='utf-8')
            (root/'scripts/fixture.gd.uid').write_text('uid://cabc12345\n', encoding='utf-8')
            expected = {'script_uids': ['scripts/fixture.gd.uid'],
                        'asset_imports': ['assets/fixture.png.import', 'assets/fixture.wav.import']}
            self.assertEqual(RUNNER.accept_generated_metadata(set(), set(), before), expected)
            # The original helper retains its narrower contract.
            self.assertEqual(RUNNER.accept_generated_uids(set(), before), [])
            self.assertNotEqual(RUNNER.fingerprint(), before)

    def test_import_rejects_malformed_or_unrelated_asset_metadata(self):
        mutations = {
            'wrong importer': lambda text: text.replace('importer="texture"', 'importer="wav"'),
            'wrong type': lambda text: text.replace('CompressedTexture2D', 'AudioStreamWAV'),
            'wrong source': lambda text: text.replace('source_file="res://assets/fixture.png"', 'source_file="res://assets/unrelated.png"'),
            'external output': lambda text: text.replace('res://.godot/imported/', 'res://assets/'),
            'traversing output': lambda text: text.replace('res://.godot/imported/', 'res://.godot/imported/../'),
            'wrong extension': lambda text: text.replace('.ctex', '.gd'),
            'bad uid': lambda text: text.replace('uid://cabc12345', 'not-a-resource-id'),
            'empty outputs': lambda text: re.sub(r'^dest_files=.*$', 'dest_files=[]', text, flags=re.MULTILINE),
            'duplicate field': lambda text: text.replace('[deps]', '[deps]\nsource_file="res://assets/fixture.png"'),
            'duplicate section': lambda text: text + '\n[deps]\nsource_file="res://assets/fixture.png"\n',
            'unlisted remap': lambda text: text.replace('path="res://.godot/imported/fixture.png-', 'path="res://.godot/imported/unlisted.png-'),
        }
        with tempfile.TemporaryDirectory() as folder, patch.object(RUNNER, 'ROOT', Path(folder)):
            root = Path(folder)
            self._asset_fixture(root)
            before = RUNNER.fingerprint()
            sidecar = root/'assets/fixture.png.import'
            for label, mutate in mutations.items():
                with self.subTest(label=label):
                    sidecar.write_text(mutate(self._sidecar()), encoding='utf-8')
                    self.assertEqual(RUNNER.accept_generated_metadata(set(), set(), before), {})

    def test_import_does_not_hide_existing_sidecar_or_source_changes(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(RUNNER, 'ROOT', Path(folder)):
            root = Path(folder)
            self._asset_fixture(root)
            old = root/'assets/fixture.png.import'
            old.write_text(self._sidecar(), encoding='utf-8')
            existing = RUNNER.asset_imports()
            before = RUNNER.fingerprint()
            new = root/'assets/fixture.wav.import'
            new.write_text(self._sidecar('fixture.wav'), encoding='utf-8')
            expected = {'script_uids': [], 'asset_imports': ['assets/fixture.wav.import']}
            self.assertEqual(RUNNER.accept_generated_metadata(set(), existing, before), expected)
            old.write_text(self._sidecar().replace('compress/mode=0', 'compress/mode=1'), encoding='utf-8')
            self.assertEqual(RUNNER.accept_generated_metadata(set(), existing, before), {})
            old.write_text(self._sidecar(), encoding='utf-8')
            source = root/'assets/fixture.wav'
            source.write_bytes(b'changed audio')
            self.assertEqual(RUNNER.accept_generated_metadata(set(), existing, before), {})
            source.write_bytes(b'unchanged audio fixture')
            (root/'assets/unrelated.txt').write_text('new non-metadata file', encoding='utf-8')
            self.assertEqual(RUNNER.accept_generated_metadata(set(), existing, before), {})

    def test_import_cannot_whitelist_new_source_or_missing_source(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(RUNNER, 'ROOT', Path(folder)):
            root = Path(folder)
            self._asset_fixture(root)
            before = RUNNER.fingerprint()
            sidecar = root/'assets/new.png.import'
            sidecar.write_text(self._sidecar('new.png'), encoding='utf-8')
            self.assertFalse(RUNNER.valid_asset_import('assets/new.png.import'))
            self.assertEqual(RUNNER.accept_generated_metadata(set(), set(), before), {})
            (root/'assets/new.png').write_bytes(b'created during import')
            self.assertEqual(RUNNER.accept_generated_metadata(set(), set(), before), {})

    def test_phase_three_static_does_not_invoke_engine_or_accept_human_review(self):
        commands = []

        def success(command, timeout):
            commands.append(command)
            return self.result()

        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)/'report'
            argv = ['accept_phase_three.py', '--static-only', '--output', str(output)]
            with (patch.object(RUNNER.sys, 'argv', argv),
                  patch.object(RUNNER, 'fingerprint', return_value='unchanged'),
                  patch.object(RUNNER, 'run_process', side_effect=success),
                  patch.object(RUNNER, 'check_resource_paths', return_value=1),
                  contextlib.redirect_stdout(io.StringIO())):
                self.assertEqual(RUNNER.main(phase=3, suites=('test_presentation',)), 0)
            report = json.loads((output/'report.json').read_text(encoding='utf-8'))
            self.assertEqual(report['status'], 'pending_engine')
            self.assertEqual(report['human_review'], 'pending')
            self.assertFalse(report['phase_three_accepted'])
            for path in ('tools/export_presentation.py', 'tests/test_presentation_data.py', 'tools/generate_audio.py'):
                self.assertTrue(any(path in command for command in commands), path)
            self.assertFalse(any('--headless' in command or '--import' in command for command in commands))

    def test_engine_import_records_metadata_and_blocks_unrelated_changes(self):
        # Mock the executable boundary: this test never starts an actual engine.
        for mutate_source in (False, True):
            with self.subTest(mutate_source=mutate_source), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                self._asset_fixture(root)
                output = root/'reports'
                commands = []

                def simulated_engine(command, timeout):
                    commands.append(command)
                    if '--import' in command:
                        (root/'assets/fixture.png.import').write_text(self._sidecar(), encoding='utf-8')
                        (root/'scripts/fixture.gd.uid').write_text('uid://cabc12345\n', encoding='utf-8')
                        if mutate_source:
                            (root/'assets/fixture.png').write_bytes(b'changed during import')
                    if '--script' in command:
                        return self.result(self.marker())
                    return self.result()

                argv = ['accept_phase_three.py', '--godot', str(root/'unused-engine'), '--output', str(output)]
                with (patch.object(RUNNER, 'ROOT', root),
                      patch.object(RUNNER.sys, 'argv', argv),
                      patch.object(RUNNER, 'run_process', side_effect=simulated_engine),
                      patch.object(RUNNER, 'check_resource_paths', return_value=1),
                      contextlib.redirect_stdout(io.StringIO())):
                    before = RUNNER.fingerprint()
                    code = RUNNER.main(phase=3, suites=('fixture',))
                    after = RUNNER.fingerprint()
                report = json.loads((output/'report.json').read_text(encoding='utf-8'))
                self.assertEqual(report['source_before_import_sha256'], before)
                self.assertEqual(report['source_after_import_sha256'], after)
                self.assertEqual(report['human_review'], 'pending')
                self.assertFalse(report['phase_three_accepted'])
                if mutate_source:
                    self.assertEqual(code, 1)
                    self.assertEqual(report['status'], 'source_changed_during_checks')
                    self.assertFalse(any('--script' in command for command in commands))
                else:
                    self.assertEqual(code, 0)
                    self.assertEqual(report['status'], 'automated_passed')
                    self.assertEqual(report['generated_script_uids'], ['scripts/fixture.gd.uid'])
                    self.assertEqual(report['generated_asset_imports'], ['assets/fixture.png.import'])
                    self.assertEqual(report['source_sha256'], after)


if __name__ == '__main__':
    unittest.main()
