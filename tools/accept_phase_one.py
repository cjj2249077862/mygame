"""Phase-one acceptance runner. Engine checks are opt-in via --godot.

--static-only never starts Godot. Full checks run in separate bounded child
processes and require both a clean log and the suite's structured success marker.
Reports always leave the human visual/playability review pending.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SUITES = ('test_game_data', 'test_battle_rules', 'test_run_flow', 'test_battle_ui', 'test_battle_sim')
ERROR_LINE = re.compile(r'(?im)^\s*(?:SCRIPT ERROR|ERROR|Parse Error|Assertion failed|FATAL)\b')
MARKER = 'RAIDDECK_TEST_RESULT '


def run_process(command, timeout, cwd=ROOT):
    try:
        completed = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=timeout,
                                   encoding='utf-8', errors='replace')
        return {'returncode': completed.returncode, 'output': completed.stdout, 'timeout': False}
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b''
        if isinstance(output, bytes):
            output = output.decode('utf-8', errors='replace')
        return {'returncode': None, 'output': output, 'timeout': True}
    except OSError as exc:
        return {'returncode': None, 'output': str(exc), 'timeout': False}


def evaluate_suite(result, suite):
    markers = []
    for line in result['output'].splitlines():
        if line.startswith(MARKER):
            try:
                markers.append(json.loads(line[len(MARKER):]))
            except json.JSONDecodeError:
                return False, 'invalid_result_json'
    if result['timeout']:
        return False, 'timeout'
    if result['returncode'] != 0:
        return False, 'nonzero_exit'
    if ERROR_LINE.search(result['output']):
        return False, 'engine_error_in_log'
    if len(markers) != 1:
        return False, 'missing_or_duplicate_result'
    report = markers[0]
    if (not isinstance(report, dict) or report.get('suite') != suite or report.get('passed') is not True
            or report.get('failures') != [] or type(report.get('assertions')) is not int
            or report['assertions'] <= 0):
        return False, 'failed_or_empty_suite'
    return True, report


def fingerprint():
    digest = hashlib.sha256()
    for folder in ('scripts', 'scenes', 'tests', 'tools', 'data', 'tables', 'themes', 'assets'):
        for path in sorted((ROOT/folder).rglob('*')):
            if not path.is_file() or '__pycache__' in path.parts or path.suffix == '.pyc' or path.name.endswith('.inspect.ndjson'):
                continue
            digest.update(path.relative_to(ROOT).as_posix().encode('utf-8'))
            digest.update(path.read_bytes())
    digest.update((ROOT/'project.godot').read_bytes())
    return digest.hexdigest()


def check_resource_paths():
    count = 0
    for folder, pattern in (('scripts', '*.gd'), ('scenes', '*.tscn'), ('themes', '*.tres')):
        for path in (ROOT/folder).rglob(pattern):
            for resource in re.findall(r'res://[^"\s]+', path.read_text(encoding='utf-8')):
                if not (ROOT/resource[6:]).exists():
                    raise ValueError(f'{path.relative_to(ROOT)}: missing {resource}')
                count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--static-only', action='store_true')
    mode.add_argument('--godot', type=Path, help='Explicit Godot executable path; starts isolated tests')
    parser.add_argument('--samples', type=int, default=32)
    parser.add_argument('--turn-limit', type=int, default=150)
    parser.add_argument('--seed', type=int, default=261126)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if min(args.samples, args.turn_limit, args.timeout) <= 0:
        parser.error('samples, turn-limit and timeout must be positive')
    stamp = datetime.now(timezone(timedelta(hours=8))).strftime('%Y%m%d-%H%M%S')
    output = (args.output or ROOT/'mywork/codex/phase-one-acceptance'/stamp).resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'started': stamp, 'mode': 'static' if args.static_only else 'engine',
              'source_sha256': fingerprint(), 'checks': [], 'human_review': 'pending',
              'phase_one_accepted': False}
    commands = [
        ('source_json', [sys.executable, '-X', 'utf8', 'tools/export_data.py', '--check']),
        ('export_tests', [sys.executable, '-X', 'utf8', 'tests/test_export_data.py']),
        ('runner_tests', [sys.executable, '-X', 'utf8', 'tests/test_accept_phase_one.py']),
        ('whitespace', ['git', 'diff', '--check']),
    ]
    for label, command in commands:
        result = run_process(command, args.timeout)
        (output/(label+'.log')).write_text(result['output'], encoding='utf-8')
        passed = result['returncode'] == 0 and not result['timeout']
        report['checks'].append({'name': label, 'passed': passed})
        print(f'{label}: {"passed" if passed else "FAILED"}')
    try:
        count = check_resource_paths()
        report['checks'].append({'name': 'resource_paths', 'passed': True, 'references': count})
    except (ValueError, OSError) as exc:
        report['checks'].append({'name': 'resource_paths', 'passed': False, 'error': str(exc)})
    if args.godot and all(c['passed'] for c in report['checks']):
        # A fresh clone has source textures and import settings, but no .ctex cache.
        result = run_process([str(args.godot.resolve()), '--headless', '--editor', '--import',
                              '--path', str(ROOT)], args.timeout)
        (output/'godot_import.log').write_text(result['output'], encoding='utf-8')
        import_passed = result['returncode'] == 0 and not result['timeout'] and not ERROR_LINE.search(result['output'])
        report['checks'].append({'name': 'godot_import', 'passed': bool(import_passed)})
        print(f'godot_import: {"passed" if import_passed else "FAILED"}')
    if args.godot and all(c['passed'] for c in report['checks']):
        for suite in SUITES:
            command = [str(args.godot.resolve()), '--headless', '--path', str(ROOT),
                       '--script', f'res://tests/{suite}.gd', '--',
                       f'--samples={args.samples}', f'--turn-limit={args.turn_limit}',
                       f'--seed={args.seed}', f'--log-dir={output.as_posix()}/simulation']
            result = run_process(command, args.timeout)
            (output/(suite+'.log')).write_text(result['output'], encoding='utf-8')
            passed, detail = evaluate_suite(result, suite)
            report['checks'].append({'name': suite, 'passed': passed, 'detail': detail})
            print(f'{suite}: {"passed" if passed else "FAILED"}')
    passed = all(c['passed'] for c in report['checks'])
    report['status'] = ('pending_engine' if args.static_only else 'automated_passed') if passed else 'failed'
    report['source_unchanged'] = fingerprint() == report['source_sha256']
    if not report['source_unchanged']:
        report['status'] = 'source_changed_during_checks'
        passed = False
    (output/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(f'Report: {output / "report.json"}')
    print('Human visual/playability review is still required; phase two is not enabled.')
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
