"""Export the five XLSX source tables. Python 3.11+, standard library only.

Cells are literal typed values; formulas must be replaced with explicit values.
Validation completes for the entire set before any runtime file is replaced.
"""
from __future__ import annotations

from copy import deepcopy
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import tempfile
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = json.loads((ROOT / 'data/config_contract.json').read_text(encoding='utf-8'))
NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
BOOKS = ('cards', 'characters', 'encounters', 'battle_rules', 'texts_zh_cn')
ROLES = set(CONTRACT['roles']) | {''}
EFFECTS = set(CONTRACT['effects'])
SCHEMAS = CONTRACT['schemas']


def require(ok, row, field, message):
    if not ok:
        source = row.get('_source', 'config') if isinstance(row, dict) else 'config'
        raise ValueError(f"{source} [{field}]: {message}")


def placeholders(template, row, field='text'):
    require(isinstance(template, str) and bool(template.strip()), row, field, '文案为空')
    names = re.findall(r'{(\w+)}', template)
    rest = re.sub(r'{\w+}', '', template)
    require('{' not in rest and '}' not in rest, row, field, '占位符格式错误')
    return set(names)


def read_book(path):
    with zipfile.ZipFile(path) as z:
        strings = []
        if 'xl/sharedStrings.xml' in z.namelist():
            strings = [''.join(n.itertext()) for n in ET.fromstring(z.read('xl/sharedStrings.xml'))]
        rels = {r.attrib['Id']: r.attrib['Target'] for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
        sheets = {}
        for sheet in ET.fromstring(z.read('xl/workbook.xml')).find('s:sheets', NS):
            target = rels[sheet.attrib['{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id']]
            target = target.lstrip('/') if target.startswith('/') else 'xl/' + target
            rows = []
            headers = []
            for row in ET.fromstring(z.read(target)).findall('s:sheetData/s:row', NS):
                cells = {}
                for c in row:
                    address = c.attrib['r']
                    index = 0
                    for letter in re.match('[A-Z]+', address).group():
                        index = index * 26 + ord(letter) - 64
                    if c.find('s:f', NS) is not None:
                        raise ValueError(f'{path.name}/{sheet.attrib["name"]}/{address}: 不允许公式')
                    v = c.find('s:v', NS)
                    kind = c.attrib.get('t', 'n')
                    value = v.text if v is not None else ''
                    if kind == 's':
                        value = strings[int(value)]
                    elif kind == 'inlineStr':
                        value = ''.join(c.find('s:is', NS).itertext())
                    elif kind == 'b':
                        value = value == '1'
                    elif kind == 'n' and value:
                        value = float(value)
                        if value.is_integer():
                            value = int(value)
                    cells[index - 1] = value
                if not headers:
                    headers = [cells.get(i, '') for i in range(max(cells, default=-1) + 1)]
                    if not headers or any(not isinstance(h, str) or not h for h in headers) or len(set(headers)) != len(headers):
                        raise ValueError(f'{path.name}: 无效或重复表头')
                elif any(v != '' for v in cells.values()):
                    record = {key: cells.get(i, '') for i, key in enumerate(headers)}
                    record['_source'] = f'{path.name}/{sheet.attrib["name"]}/row {row.attrib["r"]}'
                    rows.append(record)
            sheets[sheet.attrib['name']] = rows
        return {'version': 1, 'sheets': sheets}


def validate(books):
    for book, sheets in SCHEMAS.items():
        require(isinstance(books.get(book), dict) and books[book].get('version') == CONTRACT['version'], {}, book, '缺少表或版本错误')
        require(isinstance(books[book].get('sheets'), dict) and set(books[book]['sheets']) == set(sheets), {}, book, '工作表缺失或存在未知工作表')
        for name, schema in sheets.items():
            records = books[book]['sheets'][name]
            require(isinstance(records, list) and bool(records), {}, name, '工作表为空或格式错误')
            for row in records:
                require(isinstance(row, dict), {}, f'{book}/{name}', '行必须为对象')
                for group in schema.split(';'):
                    kind, fields = group.split(':')
                    for field in fields.split(','):
                        value = row.get(field)
                        valid = isinstance(value, str) if kind == 's' else (type(value) is bool if kind == 'b' else type(value) in (int, float))
                        require(valid, row, field, '缺少字段或类型错误')
    def rows(book, sheet='main'):
        return books[book]['sheets'][sheet]
    def index(book, sheet='main'):
        result = {}
        for row in rows(book, sheet):
            require(isinstance(row.get('id'), str) and bool(row['id']), row, 'id', '必须为非空字符串')
            require(row['id'] not in result, row, 'id', '重复 ID')
            result[row['id']] = row
        return result
    def number(row, field, minimum=0, integer=False):
        value = row.get(field)
        require(type(value) in (int, float) and math.isfinite(value) and value >= minimum and (not integer or value == int(value)), row, field, '数值类型或范围错误')
    for book in BOOKS:
        for sheet in books[book]['sheets']:
            index(book, sheet)
    cards, chars, enemies, texts, statuses = index('cards'), index('characters'), index('encounters','enemies'), index('texts_zh_cn'), index('battle_rules','statuses')
    for book in BOOKS:
        for sheet in books[book]['sheets'].values():
            for row in sheet:
                for key, value in row.items():
                    if key.endswith('_key'):
                        require(value in texts, row, key, '缺少文案')
    for row in texts.values():
        placeholders(row['text'], row)
    for key, expected in CONTRACT['required_texts'].items():
        row = texts.get(key, {'_source': 'texts_zh_cn.xlsx/main'})
        require(key in texts, row, key, '缺少程序必需文案')
        require(placeholders(row['text'], row) == set(expected), row, 'text', '文案占位符与程序参数不一致')
    for row in cards.values():
        for field in ('cost',):
            number(row,field,integer=True)
        require(row['role'] in ROLES, row,'role','未知职业')
        require(row['owner'] == '' or row['owner'] in chars, row,'owner','缺少角色')
        require(not (row['owner'] and row['role']), row,'owner','职业与专属限制不能同时填写')
        require(row['target'] in ('enemy','ally','self'),row,'target','未知目标类型')
        require(row['rarity'] in ('common','rare','epic'),row,'rarity','未知稀有度')
        for key in ('reward','exhaust','retain'):
            require(type(row[key]) is bool,row,key,'必须为布尔值')
        for upgraded in (False, True):
            effects = sorted([e for e in rows('cards','effects') if e['card_id'] == row['id'] and e['upgraded'] == upgraded], key=lambda e:e['order'])
            require(bool(effects),row,'effects','缺少基础或升级效果')
            require([e['order'] for e in effects] == list(range(1,len(effects)+1)),row,'order','效果序号须从 1 连续且不重复')
            parameters = [e['parameter'] for e in effects if e['parameter']]
            require(len(parameters) == len(set(parameters)), row, 'effects.parameter', '效果参数重名会覆盖卡面数值')
            require(placeholders(texts[row['description_key']]['text'], row, 'description_key') == set(parameters),row,'description_key','占位符与效果参数不一致')
    for row in rows('cards','effects'):
        require(row['card_id'] in cards,row,'card_id','卡牌不存在')
        require(type(row['upgraded']) is bool,row,'upgraded','必须为布尔值')
        require(row['kind'] in EFFECTS,row,'kind','未实现的效果')
        require(row['target'] == 'selected',row,'target','效果目标须为 selected')
        require(row['status'] == '', row, 'status', '当前卡牌效果不支持附加状态')
        number(row,'amount',integer=True); number(row,'hits',1,True); number(row,'order',1,True); number(row,'threat_mult')
        target = cards[row['card_id']]['target']
        require((row['kind'] not in ('damage','interrupt') or target == 'enemy') and (row['kind'] not in ('heal','shield','dispel') or target in ('ally','self')),row,'kind','效果与目标不匹配')
        require(row['kind'] == 'damage' or row['hits'] == 1, row, 'hits', '非伤害效果只结算一次')
        require(row['kind'] not in ('interrupt', 'dispel') or (row['amount'] == 1 and row['parameter'] == ''), row, 'amount', '打断与单种驱散固定一次且无数值占位参数')
    def effects_for(card_id, upgraded):
        return sorted((e for e in rows('cards', 'effects') if e['card_id'] == card_id and e['upgraded'] == upgraded), key=lambda e:e['order'])
    for card_id, spec in CONTRACT['starter_cards'].items():
        row = cards.get(card_id, {'_source': 'cards.xlsx/main'})
        require(card_id in cards, row, card_id, '缺少已确认起始卡')
        for field in ('role', 'owner', 'target'):
            require(row[field] == spec[field], row, field, '起始卡施放语义与确认稿不符')
        base, upgraded = effects_for(card_id, False), effects_for(card_id, True)
        require(len(base) == len(upgraded) == len(spec['effects']), row, 'effects', '起始卡基础和升级效果数量不符')
        for before, after, expected in zip(base, upgraded, spec['effects']):
            require(all(before[k] == expected[k] for k in expected), before, 'kind/hits', '起始卡效果与确认稿不符')
            require(all(before[k] == after[k] for k in CONTRACT['fixed_upgrade_fields']), after, 'effects', '升级不能更改效果种类、段数或目标')
            require(after['amount'] >= before['amount'], after, 'amount', '升级数值不能低于基础版本')
    require(all(id in chars for id in CONTRACT['initial_lineup']), {'_source':'characters.xlsx/main'}, 'id', '缺少初始阵容角色')
    for row in chars.values():
        number(row,'max_hp',1,True);number(row,'strength',integer=True);number(row,'passive_amount',integer=True)
        require(row['role'] in ROLES - {''},row,'role','未知职业')
        require(row['passive'] in CONTRACT['passives'],row,'passive','未实现的被动')
        require(any(s['character_id'] == row['id'] for s in rows('characters', 'starter')), row, 'starter', '角色缺少初始牌单')
        if row['portrait']:
            path = (ROOT / row['portrait'].removeprefix('res://')).resolve()
            require(row['portrait'].startswith('res://') and path.is_relative_to(ROOT) and path.is_file(), row, 'portrait', '立绘资源不存在或超出项目')
    for row in rows('characters','starter'):
        require(row['character_id'] in chars and row['card_id'] in cards,row,'card_id','缺少引用')
        number(row,'count',1,True)
        c, u = cards[row['card_id']], chars[row['character_id']]
        require((not c['owner'] or c['owner']==u['id']) and (not c['role'] or c['role']==u['role']),row,'card_id','初始牌不能施放')
    for row in enemies.values():
        for key in ('max_hp','strength','interrupt_threshold','immunity_count'):
            number(row,key,1 if key=='max_hp' else 0,True)
        require((row['interrupt_threshold'] > 0) == (row['immunity_count'] > 0), row, 'immunity_count', '抗性阈值与免疫次数须同时启用')
        intents = sorted([i for i in rows('encounters','intents') if i['enemy_id']==row['id']],key=lambda i:i['order'])
        require([i['order'] for i in intents] == list(range(1,len(intents)+1)) and bool(intents),row,'intents','意图顺序无效')
    for row in rows('encounters','intents'):
        require(row['enemy_id'] in enemies,row,'enemy_id','敌人不存在')
        require(row['kind'] in ('normal','interruptible','uninterruptible'),row,'kind','未知意图')
        require(row['status']=='' or row['status'] in statuses,row,'status','状态不存在')
        for key in ('amount','stacks','hits','order'):
            number(row,key,1 if key in ('hits','order') else 0,True)
        require(bool(row['status']) == (row['stacks'] > 0), row, 'stacks', '附加状态与层数不匹配')
    for row in rows('encounters'):
        require(all(e in enemies for e in row['enemies'].split(',')),row,'enemies','敌人不存在')
        number(row,'gold',integer=True);number(row,'order',1,True)
    require(sorted(r['order'] for r in rows('encounters')) == list(range(1,len(rows('encounters'))+1)),rows('encounters')[0],'order','遭遇顺序不连续')
    required=set(CONTRACT['rules'])
    rule_index=index('battle_rules')
    require(required == set(rule_index),rows('battle_rules')[0],'id','规则缺失或存在未知规则')
    for key, spec in CONTRACT['rules'].items():
        row = rule_index[key]
        number(row, 'value', spec['min'], spec.get('integer', False))
        require('max' not in spec or row['value'] <= spec['max'], row, 'value', '数值超过规则上限')
        require(not spec.get('exclusive_min') or row['value'] > spec['min'], row, 'value', '数值须大于规则下限')
    require(set(statuses) == set(CONTRACT['statuses']), {'_source':'battle_rules.xlsx/statuses'}, 'id', '缺少或存在未知状态')
    for row in statuses.values():
        require(row['id'] in CONTRACT['statuses'],row,'id','未实现的状态')
        number(row,'per_stack',1,True);number(row,'decay',1,True)
        require(type(row['dispellable']) is bool,row,'dispellable','必须为布尔值')
    for row in texts.values():
        require(isinstance(row['text'],str) and bool(row['text']),row,'text','文案为空')


def bundle_books(books):
    result = deepcopy(books)
    for book in result.values():
        book.pop('bundle_id', None)
    digest = hashlib.sha256(json.dumps(result, ensure_ascii=False, sort_keys=True, allow_nan=False).encode('utf-8')).hexdigest()
    for book in result.values():
        book['bundle_id'] = digest
    return result


def write_bundle(books, output):
    """Stage every file first; roll back the entire set on replacement failure."""
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.export-', dir=output) as directory:
        stage = Path(directory)
        existing, replaced = {}, []
        for name, book in books.items():
            destination = output / (name + '.json')
            existing[name] = destination.exists()
            if existing[name]:
                shutil.copy2(destination, stage / (name + '.old'))
            payload = (json.dumps(book, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode('utf-8')
            with (stage / (name + '.new')).open('wb') as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        try:
            for name in books:
                os.replace(stage / (name + '.new'), output / (name + '.json'))
                replaced.append(name)
        except OSError as original:
            rollback_errors = []
            for name in reversed(replaced):
                try:
                    destination = output / (name + '.json')
                    if existing[name]:
                        os.replace(stage / (name + '.old'), destination)
                    else:
                        destination.unlink()
                except OSError as error:
                    rollback_errors.append(str(error))
            if rollback_errors:
                raise OSError(f'导出失败且回滚失败，游戏将拒绝混合批次，请重新导出：{rollback_errors}') from original
            raise OSError('导出失败，原有整组 JSON 已恢复：' + str(original)) from original


def export(source, output, check=False):
    books = {name:read_book(source / (name+'.xlsx')) for name in BOOKS}
    validate(books)
    books = bundle_books(books)
    if check:
        for name, book in books.items():
            if json.loads((output/(name+'.json')).read_text(encoding='utf-8')) != book:
                raise ValueError(f'{name}.json 与源表不同，请重新导出')
    else:
        write_bundle(books, output)
    print('五份源表校验通过；' + ('JSON 与源表一致。' if check else 'JSON 已导出。'))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    root=Path(__file__).resolve().parents[1]
    parser.add_argument('--source',type=Path,default=root/'tables')
    parser.add_argument('--output',type=Path,default=root/'data')
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    try:
        export(args.source,args.output,args.check)
    except (ValueError, KeyError, IndexError, AttributeError, TypeError, OSError, zipfile.BadZipFile, ET.ParseError) as exc:
        parser.exit(1,f'配置未生效：{exc}\n')
