"""Ensure parse/runtime/assertion errors cannot be reported as passing tests."""
import importlib.util
import json
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
