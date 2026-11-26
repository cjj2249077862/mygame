"""Exporter checks; runs without Godot and without changing source tables."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('export_data', ROOT / 'tools/export_data.py')
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)


class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.books = {name: EXPORT.read_book(ROOT / 'tables' / (name + '.xlsx')) for name in EXPORT.BOOKS}

    def test_source_matches_runtime(self):
        EXPORT.export(ROOT / 'tables', ROOT / 'data', check=True)

    def test_starter_counts_and_upgrades(self):
        starters = self.books['characters']['sheets']['starter']
        self.assertEqual(sum(row['count'] for row in starters), 15)
        for hero in ('warden', 'blade', 'mender'):
            self.assertEqual(sum(r['count'] for r in starters if r['character_id'] == hero), 5)
        self.assertEqual(len(self.books['cards']['sheets']['main']), 9)
        EXPORT.validate(self.books)

    def test_invalid_definitions(self):
        mutations = [
            ('duplicate', lambda b: b['cards']['sheets']['main'].append(deepcopy(b['cards']['sheets']['main'][0]))),
            ('negative', lambda b: b['cards']['sheets']['effects'][0].update(amount=-1)),
            ('type', lambda b: b['cards']['sheets']['main'][0].update(cost='1')),
            ('reference', lambda b: b['characters']['sheets']['starter'][0].update(card_id='missing')),
            ('unknown effect', lambda b: b['cards']['sheets']['effects'][0].update(kind='unknown')),
            ('wrong target', lambda b: b['cards']['sheets']['main'][0].update(target='ally')),
            ('placeholder', lambda b: b['texts_zh_cn']['sheets']['main'][1].update(text='{missing}')),
            ('missing upgrade', lambda b: b['cards']['sheets']['effects'].pop(1)),
            ('intent order', lambda b: b['encounters']['sheets']['intents'][0].update(order=9)),
            ('ratio', lambda b: next(r for r in b['battle_rules']['sheets']['main'] if r['id']=='post_battle_revive').update(value=2)),
        ]
        for label, mutate in mutations:
            with self.subTest(label=label):
                books = deepcopy(self.books)
                mutate(books)
                with self.assertRaises(ValueError):
                    EXPORT.validate(books)

    def test_heal_balance_edit_propagates(self):
        books = deepcopy(self.books)
        for row in books['cards']['sheets']['effects']:
            if row['card_id'] == 'heal' and not row['upgraded']:
                row['amount'] = 18
        EXPORT.validate(books)
        # Serialized runtime value and unchanged named template agree.
        value = json.loads(json.dumps(books, ensure_ascii=False))
        effects = value['cards']['sheets']['effects']
        amount = next(r['amount'] for r in effects if r['card_id']=='heal' and not r['upgraded'])
        template = next(r['text'] for r in value['texts_zh_cn']['sheets']['main'] if r['id']=='desc.heal')
        self.assertEqual(template.format(amount=amount), '恢复最多 18 点生命。')

    def test_atomic_file_replacement_and_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            EXPORT.export(ROOT / 'tables', output)
            for name in EXPORT.BOOKS:
                parsed = json.loads((output/(name+'.json')).read_text(encoding='utf-8'))
                self.assertEqual(parsed, self.books[name])
                self.assertIn('.xlsx/', parsed['sheets']['main'][0]['_source'])
            self.assertFalse(list(output.glob('*.tmp')))


if __name__ == '__main__':
    unittest.main()
