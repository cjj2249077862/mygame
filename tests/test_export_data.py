"""Exporter checks; runs without Godot and without changing source tables."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import shutil
import zipfile
import xml.etree.ElementTree as ET

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
        self.assertEqual(len(self.books['cards']['sheets']['main']), 40)
        EXPORT.validate(self.books)

    def test_chapter_content_and_initial_lineup_coverage(self):
        cards=self.books['cards']['sheets']['main']
        initial_ids={'warden','blade','mender'}
        self.assertEqual(set(EXPORT.CONTRACT['initial_lineup']),initial_ids)
        heroes=[h for h in self.books['characters']['sheets']['main'] if h['id'] in initial_ids]
        self.assertEqual({h['id'] for h in heroes},initial_ids)
        self.assertEqual(sum(bool(c['role']) for c in cards),18)
        self.assertEqual(sum(bool(c['owner']) for c in cards),18)
        self.assertEqual(sum(not c['owner'] and not c['role'] for c in cards),4)
        for hero in heroes:
            self.assertEqual(sum(c['role']==hero['role'] for c in cards),6)
            self.assertEqual(sum(c['owner']==hero['id'] for c in cards),6)
        card_weights={(w['source'],w['rarity']):w['weight'] for w in self.books['economy']['sheets']['weights'] if w['kind']=='card'}
        for card in cards:
            self.assertTrue(any((not card['owner'] or card['owner']==h['id']) and (not card['role'] or card['role']==h['role']) for h in heroes),card['id'])
            self.assertTrue(card['reward'],card['id'])
            for source in ('battle','elite','boss','shop'):
                self.assertGreater(card_weights[source,card['rarity']],0,f'{source}/{card["id"]}')
        relics=self.books['relics']['sheets']['main']
        self.assertEqual(len(relics),15)
        self.assertEqual(sum(r['pool']=='boss' for r in relics),3)
        for relic in relics:
            self.assertTrue(any((not relic['owner'] or relic['owner']==h['id']) and (not relic['role'] or relic['role']==h['role']) for h in heroes),relic['id'])
        enemies=self.books['encounters']['sheets']['enemies']
        self.assertEqual(sum(e['kind']!='boss' for e in enemies),10)
        self.assertEqual(sum(e['kind']=='boss' for e in enemies),1)
        self.assertEqual(len(self.books['events']['sheets']['main']),3)
        self.assertEqual(len(EXPORT.BOOKS),10)

    def test_approved_chapter_delivery_ids_and_placement(self):
        # This is the chapter-one delivery checklist, not a runtime content cap.
        # Generic additions remain valid in test_new_character_and_reusable_card_need_no_new_script.
        expected_cards=set('''
            slash guard tank_bulwark tank_crush tank_cover tank_break
            stab parry assassin_precise assassin_feint assassin_toxin assassin_opening
            smite heal healer_renew healer_shelter healer_cleanse healer_ember
            shield_bash warden_fortress warden_rally warden_command warden_wall warden_resolve
            double_stab blade_execution blade_flurry blade_disrupt blade_exploit blade_prepare
            first_aid mender_restore mender_mass_heal mender_purify mender_resuscitate mender_reserve
            tactic_plan tactic_guard tactic_bandage tactic_purge
        '''.split())
        expected_relics=set('''
            iron_rivet vanguard_banner sentry_lens quiet_incense tank_buckle assassin_seal
            mercy_charm purge_charm shock_ring medical_kit camp_kettle weapon_stone
            boss_furnace boss_tome boss_aegis
        '''.split())
        expected_enemies=set('''
            sentry cultist sharpshooter shield_guard torchbearer prison_hound hexer
            captain gaoler alchemist boss_iron_warden
        '''.split())
        expected_events={'event_abandoned_infirmary','event_forgotten_anvil','event_sealed_cache'}
        for book,sheet,expected in (
            ('cards','main',expected_cards),('relics','main',expected_relics),
            ('encounters','enemies',expected_enemies),('events','main',expected_events),
        ):
            self.assertEqual({r['id'] for r in self.books[book]['sheets'][sheet]},expected,book)
        relics=self.books['relics']['sheets']['main']
        self.assertEqual({r['id'] for r in relics if r['pool']=='boss'},
                         {'boss_furnace','boss_tome','boss_aegis'})
        pools=self.books['maps']['sheets']['pools']
        chapter=next(m for m in self.books['maps']['sheets']['main'] if m['id']=='chapter_one')
        self.assertEqual({p['content_id'] for p in pools if p['map_id']==chapter['id'] and p['kind']=='event'},expected_events)
        encounters={r['id']:r for r in self.books['encounters']['sheets']['main']}
        used_encounters={chapter['first_encounter_id'],chapter['boss_encounter_id']}
        used_encounters.update(p['content_id'] for p in pools if p['map_id']==chapter['id'] and p['kind'] in ('battle','elite'))
        self.assertEqual({e for id in used_encounters for e in encounters[id]['enemies'].split(',')},expected_enemies)

    def test_phase_two_invalid_references_and_semantics(self):
        mutations=[
            ('revive ratio',lambda b: next(e for e in b['cards']['sheets']['effects'] if e['kind']=='revive').update(amount=1.1)),
            ('energy target',lambda b: next(e for e in b['cards']['sheets']['effects'] if e['kind']=='energy').update(target='selected')),
            ('unknown status',lambda b: next(e for e in b['cards']['sheets']['effects'] if e['kind']=='apply_status').update(status='missing')),
            ('relic event',lambda b:b['relics']['sheets']['triggers'][0].update(event='missing')),
            ('relic counter',lambda b:b['relics']['sheets']['triggers'][0].update(limit_count=0)),
            ('relic owner',lambda b:b['relics']['sheets']['main'][0].update(owner='missing')),
            ('relic group',lambda b:b['relics']['sheets']['triggers'][0].update(effect_group='missing')),
            ('phase ratio',lambda b:b['encounters']['sheets']['phases'][0].update(threshold=1)),
            ('phase pool',lambda b:b['encounters']['sheets']['phases'][0].update(intent_pool='missing')),
            ('bomb countdown',lambda b:next(e for e in b['encounters']['sheets']['effects'] if e['kind']=='bomb').update(duration=0)),
            ('intent target',lambda b:b['encounters']['sheets']['intents'][0].update(target_rule='random_unlisted')),
            ('negative gold',lambda b:b['economy']['sheets']['card_prices'][0].update(price=-1)),
            ('missing weight',lambda b:b['economy']['sheets']['weights'].pop()),
            ('wrong map boss',lambda b:b['maps']['sheets']['main'][0].update(boss_encounter_id='outpost_gate')),
            ('map pool',lambda b:b['maps']['sheets']['pools'][0].update(content_id='missing')),
            ('map layer range',lambda b:b['maps']['sheets']['node_rules'][0].update(max_depth=10)),
            ('event outcome',lambda b:b['events']['sheets']['outcomes'][0].update(option_id='missing')),
            ('zero probability',lambda b:b['events']['sheets']['outcomes'][0].update(weight=0)),
            ('paid leave',lambda b:next(o for o in b['events']['sheets']['options'] if o['leave']).update(cost_gold=1)),
            ('lethal cost',lambda b:next(o for o in b['events']['sheets']['options'] if o['cost_hp']).update(min_hp=6)),
            ('lethal random cost',lambda b:next(o for o in b['events']['sheets']['options'] if o['id']=='cache_force').update(min_hp=8)),
            ('unchecked relic pool',lambda b:next(o for o in b['events']['sheets']['options'] if o['id']=='cache_force').update(required_relic_pool='')),
            ('event target',lambda b:b['events']['sheets']['effects'][0].update(target='enemy')),
            ('nonfinite price',lambda b:b['economy']['sheets']['card_prices'][0].update(price=float('nan'))),
            ('missing actor context',lambda b:b['relics']['sheets']['triggers'][0].update(limit_scope='actor_turn')),
            ('missing target context',lambda b:b['relics']['sheets']['effects'][0].update(target='event_target')),
            ('wrong modifier notification',lambda b:next(t for t in b['relics']['sheets']['triggers'] if t['relic_id']=='weapon_stone').update(event='turn_started')),
            ('negative final base draw',lambda b:next(e for e in b['relics']['sheets']['effects'] if e['kind']=='base_draw' and e['amount']<0).update(amount=-99)),
            ('zero source weights',lambda b:[w.update(weight=0) for w in b['economy']['sheets']['weights'] if w['kind']=='card' and w['source']=='battle']),
            ('missing depth candidates',lambda b:[e.update(min_depth=3) for e in b['encounters']['sheets']['main'] if e['kind']=='normal' and e['id']!='outpost_gate']),
            ('missing safe route candidates',lambda b:b['maps']['sheets'].update(node_rules=[r for r in b['maps']['sheets']['node_rules'] if r['kind']=='elite'])),
            ('duplicate map content',lambda b:b['maps']['sheets']['pools'].append(dict(b['maps']['sheets']['pools'][0],id='duplicate_pool_fixture'))),
            ('combined branch life cost',lambda b:b['events']['sheets']['effects'].append(dict(next(e for e in b['events']['sheets']['effects'] if e['kind']=='hp_loss'),id='additional_life_cost_fixture',order=3))),
        ]
        for label,mutate in mutations:
            with self.subTest(label=label):
                bad=deepcopy(self.books);mutate(bad)
                with self.assertRaises(ValueError):EXPORT.validate(bad)

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
            ('upgrade hits', lambda b: next(r for r in b['cards']['sheets']['effects'] if r['card_id']=='double_stab' and r['upgraded']).update(hits=3)),
            ('weaker upgrade', lambda b: next(r for r in b['cards']['sheets']['effects'] if r['card_id']=='slash' and r['upgraded']).update(amount=0)),
            ('upgrade removed dispel', lambda b: b['cards']['sheets'].update(effects=[r for r in b['cards']['sheets']['effects'] if not (r['card_id']=='first_aid' and r['upgraded'] and r['kind']=='dispel')])),
            ('missing UI text', lambda b: b['texts_zh_cn']['sheets'].update(main=[r for r in b['texts_zh_cn']['sheets']['main'] if r['id']!='ui.end_turn'])),
            ('log parameter', lambda b: next(r for r in b['texts_zh_cn']['sheets']['main'] if r['id']=='log.damage').update(text='{missing}')),
            ('malformed placeholder', lambda b: next(r for r in b['texts_zh_cn']['sheets']['main'] if r['id']=='log.damage').update(text='{amount')),
            ('duplicate parameter', lambda b: next(r for r in b['cards']['sheets']['effects'] if r['card_id']=='shield_bash' and not r['upgraded'] and r['kind']=='interrupt').update(parameter='amount')),
            ('missing starter', lambda b: b['characters']['sheets'].update(starter=[r for r in b['characters']['sheets']['starter'] if r['character_id']!='mender'])),
            ('missing portrait', lambda b: b['characters']['sheets']['main'][0].update(portrait='res://assets/characters/missing.png')),
            ('weak increases damage', lambda b: next(r for r in b['battle_rules']['sheets']['main'] if r['id']=='weak_multiplier').update(value=1.5)),
            ('vulnerable reduces damage', lambda b: next(r for r in b['battle_rules']['sheets']['main'] if r['id']=='vulnerable_multiplier').update(value=0.5)),
            ('empty hand cap', lambda b: next(r for r in b['battle_rules']['sheets']['main'] if r['id']=='hand_limit').update(value=0)),
            ('non-object row', lambda b: b['cards']['sheets']['main'].append(3)),
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
                self.assertEqual(parsed, EXPORT.bundle_books(self.books)[name])
                self.assertIn('.xlsx/', parsed['sheets']['main'][0]['_source'])
            self.assertEqual(len({json.loads((output/(name+'.json')).read_text(encoding='utf-8'))['bundle_id'] for name in EXPORT.BOOKS}), 1)
            self.assertFalse(list(output.glob('.export-*')))

    def test_failed_publication_restores_entire_bundle(self):
        for initially_present in (False, True):
            with self.subTest(initially_present=initially_present), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                old = EXPORT.bundle_books(self.books)
                if initially_present:
                    EXPORT.write_bundle(old, output)
                previous = {p.name: p.read_bytes() for p in output.glob('*.json')}
                changed = deepcopy(self.books)
                changed['cards']['sheets']['effects'][0]['amount'] = 7
                new = EXPORT.bundle_books(changed)
                self.assertNotEqual(new['cards']['bundle_id'], old['cards']['bundle_id'])
                replace = EXPORT.os.replace
                calls = 0

                def fail_third(source, destination):
                    nonlocal calls
                    calls += 1
                    if calls == 3:
                        raise PermissionError('injected failure on third published file')
                    return replace(source, destination)

                with patch.object(EXPORT.os, 'replace', side_effect=fail_third):
                    with self.assertRaisesRegex(OSError, '原有整组 JSON 已恢复'):
                        EXPORT.write_bundle(new, output)
                self.assertEqual(previous, {p.name: p.read_bytes() for p in output.glob('*.json')})
                self.assertFalse(list(output.glob('.export-*')))

    def test_real_xlsx_single_cell_change_exports_18(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'tables'
            output = Path(directory) / 'data'
            source.mkdir()
            for name in EXPORT.BOOKS:
                shutil.copy2(ROOT/'tables'/(name+'.xlsx'), source/(name+'.xlsx'))
            path = source / 'cards.xlsx'
            original_book = EXPORT.read_book(path)
            effect = next(r for r in original_book['sheets']['effects'] if r['card_id']=='heal' and not r['upgraded'])
            self.assertEqual(effect['amount'], 14)
            row_number = int(effect['_source'].split('row ')[1])
            amount_column = list(effect).index('amount')
            # Change exactly the numeric XML cell in a disposable XLSX copy.
            with zipfile.ZipFile(path) as archive:
                parts = {name: archive.read(name) for name in archive.namelist()}
            rels = {r.attrib['Id']:r.attrib['Target'] for r in ET.fromstring(parts['xl/_rels/workbook.xml.rels'])}
            sheet = next(s for s in ET.fromstring(parts['xl/workbook.xml']).find('s:sheets', EXPORT.NS) if s.attrib['name']=='effects')
            target = rels[sheet.attrib['{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id']]
            target = target.lstrip('/') if target.startswith('/') else 'xl/'+target
            xml = ET.fromstring(parts[target])
            address = chr(ord('A') + amount_column) + str(row_number)
            cell = next(c for c in xml.findall('s:sheetData/s:row/s:c', EXPORT.NS) if c.attrib['r']==address)
            cell.find('s:v', EXPORT.NS).text = '18'
            parts[target] = ET.tostring(xml, encoding='utf-8', xml_declaration=True)
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
                for name, payload in parts.items():
                    archive.writestr(name, payload)
            edited = EXPORT.read_book(path)
            changed_rows = [r for a,r in zip(original_book['sheets']['effects'],edited['sheets']['effects']) if a!=r]
            self.assertEqual(len(changed_rows), 1)
            self.assertEqual(changed_rows[0]['amount'], 18)
            EXPORT.export(source, output)
            result = json.loads((output/'cards.json').read_text(encoding='utf-8'))
            self.assertEqual(next(r['amount'] for r in result['sheets']['effects'] if r['card_id']=='heal' and not r['upgraded']), 18)
            self.assertEqual(next(r['amount'] for r in EXPORT.read_book(ROOT/'tables/cards.xlsx')['sheets']['effects'] if r['card_id']=='heal' and not r['upgraded']), 14)

    def test_new_character_and_reusable_card_need_no_new_script(self):
        books = deepcopy(self.books)
        new_char = deepcopy(books['characters']['sheets']['main'][0])
        new_char.update(id='other_tank_fixture')
        books['characters']['sheets']['main'].append(new_char)
        books['characters']['sheets']['starter'].append({'id':'other.starter', 'character_id':new_char['id'], 'card_id':'guard', 'count':2})
        new_card = deepcopy(books['cards']['sheets']['main'][0])
        new_card.update(id='other_slash_fixture')
        books['cards']['sheets']['main'].append(new_card)
        for upgraded in (False, True):
            effect = deepcopy(next(r for r in books['cards']['sheets']['effects'] if r['card_id']=='slash' and r['upgraded']==upgraded))
            effect.update(id=f'other.{upgraded}', card_id=new_card['id'])
            books['cards']['sheets']['effects'].append(effect)
        EXPORT.validate(books)


if __name__ == '__main__':
    unittest.main()
