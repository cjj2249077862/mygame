"""Independent presentation XLSX validation and atomic export checks."""
from copy import deepcopy
from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import export_presentation as EXPORT


class PresentationDataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = ROOT / 'tables/presentation.xlsx'
        cls.book = EXPORT.read_book(cls.source)

    def test_source_matches_runtime_and_is_independent(self):
        result = EXPORT.export(self.source, ROOT / 'data/presentation.json', check=True)
        self.assertEqual(set(result), {'version', 'texts', 'sources', 'source_sha256'})
        self.assertEqual(result['version'], 1)
        self.assertEqual(set(result['texts']), EXPORT.REQUIRED_KEYS)
        self.assertEqual(set(result['sources']), EXPORT.REQUIRED_KEYS)
        self.assertNotIn('presentation', json.loads((ROOT / 'data/config_contract.json').read_text())['schemas'])

    def test_reject_invalid_rows_and_missing_required_keys(self):
        mutations = (
            lambda b: b['sheets'].update(extra=[]),
            lambda b: b['sheets']['main'].append(deepcopy(b['sheets']['main'][0])),
            lambda b: b['sheets']['main'].pop(),
            lambda b: b['sheets']['main'][0].update(id='presentation.unknown'),
            lambda b: b['sheets']['main'][0].update(text='  '),
            lambda b: b['sheets']['main'][0].update(text=42),
            lambda b: b['sheets']['main'][0].update(extra='unexpected'),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                bad = deepcopy(self.book)
                mutate(bad)
                with self.assertRaises(ValueError):
                    EXPORT.validate_book(bad)

    def test_literal_cell_edit_reaches_export_without_gameplay_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'presentation.xlsx'
            self._rewrite(source, lambda sheet: self._set_text(sheet, 'B2', '演出选项测试'))
            result = EXPORT.export(source, Path(folder) / 'presentation.json')
            self.assertEqual(result['texts']['presentation.options'], '演出选项测试')
            self.assertEqual(result['sources']['presentation.options'], 'presentation.xlsx/main/row 2')
            self.assertNotEqual(result['source_sha256'], EXPORT.read_source(self.source)['source_sha256'])

    def test_formula_and_extra_populated_cell_rejected(self):
        def formula(sheet):
            cell = sheet.find("s:sheetData/s:row/s:c[@r='B2']", EXPORT.NS)
            ET.SubElement(cell, '{' + EXPORT.NS['s'] + '}f').text = '1+1'

        def extra(sheet):
            row = sheet.find("s:sheetData/s:row[@r='2']", EXPORT.NS)
            cell = ET.SubElement(row, '{' + EXPORT.NS['s'] + '}c', {'r': 'C2', 't': 'inlineStr'})
            inline = ET.SubElement(cell, '{' + EXPORT.NS['s'] + '}is')
            ET.SubElement(inline, '{' + EXPORT.NS['s'] + '}t').text = 'must not disappear'

        for index, mutate in enumerate((formula, extra)):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as folder:
                source = Path(folder) / 'presentation.xlsx'
                self._rewrite(source, mutate)
                with self.assertRaises(ValueError):
                    EXPORT.read_source(source)

    def test_check_detects_stale_json_without_replacing_it(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'presentation.json'
            output.write_text('{}', encoding='utf-8')
            with self.assertRaises(ValueError):
                EXPORT.export(self.source, output, check=True)
            self.assertEqual(output.read_text(), '{}')

    def test_failed_replace_preserves_previous_output(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'presentation.json'
            output.write_text('{"previous":true}', encoding='utf-8')
            with patch.object(EXPORT.os, 'replace', side_effect=OSError('injected replace failure')):
                with self.assertRaises(OSError):
                    EXPORT.export(self.source, output)
            self.assertEqual(output.read_text(), '{"previous":true}')
            self.assertEqual(sorted(path.name for path in Path(folder).iterdir()), ['presentation.json'])

    def _rewrite(self, destination, mutate):
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(destination, 'w') as output:
            for item in source.infolist():
                content = source.read(item.filename)
                if item.filename == 'xl/worksheets/sheet1.xml':
                    sheet = ET.fromstring(content)
                    mutate(sheet)
                    content = ET.tostring(sheet, encoding='utf-8', xml_declaration=True)
                output.writestr(item, content)

    @staticmethod
    def _set_text(sheet, address, value):
        cell = sheet.find(f"s:sheetData/s:row/s:c[@r='{address}']", EXPORT.NS)
        cell.clear()
        cell.attrib.update(r=address, t='inlineStr')
        inline = ET.SubElement(cell, '{' + EXPORT.NS['s'] + '}is')
        ET.SubElement(inline, '{' + EXPORT.NS['s'] + '}t').text = value


if __name__ == '__main__':
    unittest.main()
