"""Export the independent presentation texts without changing gameplay bundles."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import xml.etree.ElementTree as ET
import zipfile

try:
    from .export_data import NS, read_book
except ImportError:
    from export_data import NS, read_book

ROOT = Path(__file__).resolve().parents[1]
VERSION = 1
REQUIRED_KEYS = frozenset('presentation.' + name for name in (
    'options', 'master_volume', 'music_volume', 'sfx_volume', 'audio_enabled',
    'fast', 'show_log', 'shake_enabled', 'flash_enabled', 'parallax_enabled',
    'restore', 'save_error', 'load_error', 'description',
))


def validate_book(book: dict) -> tuple[dict[str, str], dict[str, str]]:
    sheets = book.get('sheets')
    if not isinstance(sheets, dict) or set(sheets) != {'main'}:
        raise ValueError('presentation.xlsx: only the main sheet is allowed')
    if not isinstance(sheets['main'], list):
        raise ValueError('presentation.xlsx/main: expected rows')
    texts, sources = {}, {}
    for row in sheets['main']:
        source = row.get('_source', 'presentation.xlsx/main') if isinstance(row, dict) else 'presentation.xlsx/main'
        if not isinstance(row, dict) or set(row) != {'id', 'text', '_source'}:
            raise ValueError(f'{source}: expected only id/text columns')
        key, value = row['id'], row['text']
        if not isinstance(key, str) or key not in REQUIRED_KEYS:
            raise ValueError(f'{source} [id]: unknown or invalid presentation key')
        if key in texts:
            raise ValueError(f'{source} [id]: duplicate {key}')
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f'{source} [text]: expected non-empty text')
        if not isinstance(source, str) or not source:
            raise ValueError(f'{key}: missing source location')
        texts[key], sources[key] = value, source
    missing = REQUIRED_KEYS - texts.keys()
    if missing:
        raise ValueError('presentation.xlsx/main: missing keys: ' + ', '.join(sorted(missing)))
    return texts, sources


def read_source(path: Path) -> dict:
    # The shared reader rejects formulas. It intentionally ignores cells beyond
    # the header, so check those here to avoid silently dropping extra input.
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if not re.fullmatch(r'xl/worksheets/sheet\d+\.xml', name):
                continue
            sheet = ET.fromstring(archive.read(name))
            for cell in sheet.findall('s:sheetData/s:row/s:c', NS):
                address = cell.attrib.get('r', '')
                column = re.match(r'[A-Z]+', address)
                if column and column[0] not in ('A', 'B'):
                    # Empty styled cells are harmless; values/formulas are not.
                    if cell.find('s:f', NS) is not None or any(
                        ''.join(part.itertext()) for part in cell
                        if part.tag in (f'{{{NS["s"]}}}v', f'{{{NS["s"]}}}is')
                    ):
                        raise ValueError(f'{path.name}/{address}: extra populated column')
    texts, sources = validate_book(read_book(path))
    return {
        'version': VERSION,
        'texts': texts,
        'sources': sources,
        'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def export(source: Path, output: Path, check: bool = False) -> dict:
    payload = read_source(Path(source))
    output = Path(output)
    if check:
        if not output.is_file() or json.loads(output.read_text(encoding='utf-8')) != payload:
            raise ValueError(f'{output}: presentation JSON does not match the source workbook')
        return payload
    encoded = json.dumps(payload, ensure_ascii=False, indent=2) + '\n'
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=output.name + '.', suffix='.tmp', dir=output.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        if json.loads(temporary.read_text(encoding='utf-8')) != payload:
            raise ValueError('Temporary presentation export failed verification')
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'tables/presentation.xlsx')
    parser.add_argument('--output', type=Path, default=ROOT / 'data/presentation.json')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        payload = export(args.source, args.output, args.check)
    except (ValueError, OSError, zipfile.BadZipFile, ET.ParseError) as exc:
        parser.exit(1, str(exc) + '\n')
    print(f'Presentation texts: {len(payload["texts"])} checked; ' + ('source matches JSON' if args.check else 'exported'))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
