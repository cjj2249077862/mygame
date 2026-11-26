"""Export the five XLSX source tables. Python 3.11+, standard library only.

Cells are literal typed values; formulas must be replaced with explicit values.
Validation completes for the entire set before any runtime file is replaced.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import tempfile
import zipfile
import xml.etree.ElementTree as ET

NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
BOOKS = ('cards', 'characters', 'encounters', 'battle_rules', 'texts_zh_cn')
ROLES = {'tank', 'assassin', 'healer', ''}
EFFECTS = {'damage', 'heal', 'shield', 'interrupt', 'dispel'}
SCHEMAS = {
    'cards': {'main': 's:id,name_key,description_key,role,owner,target,rarity;b:reward,exhaust,retain;n:cost', 'effects': 's:id,card_id,kind,status,target,parameter;b:upgraded;n:order,amount,hits,threat_mult'},
    'characters': {'main': 's:id,name_key,role,passive,portrait;n:max_hp,strength,passive_amount', 'starter': 's:id,character_id,card_id;n:count'},
    'encounters': {'main': 's:id,name_key,enemies;n:order,gold', 'enemies': 's:id,name_key;n:max_hp,strength,interrupt_threshold,immunity_count', 'intents': 's:id,enemy_id,kind,status;n:order,amount,hits,stacks'},
    'battle_rules': {'main': 's:id;n:value', 'statuses': 's:id,name_key;b:dispellable;n:per_stack,decay'},
    'texts_zh_cn': {'main': 's:id,text'},
}


def require(ok, row, field, message):
    if not ok:
        raise ValueError(f"{row.get('_source', '?')} [{field}]: {message}")


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
        require(book in books and books[book].get('version') == 1, {}, book, '缺少表或版本错误')
        require(set(books[book]['sheets']) == set(sheets), {}, book, '工作表缺失或存在未知工作表')
        for name, schema in sheets.items():
            records = books[book]['sheets'][name]
            require(isinstance(records, list) and bool(records), {}, name, '工作表为空或格式错误')
            for row in records:
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
            placeholders = set(re.findall(r'{(\w+)}',texts[row['description_key']]['text']))
            require(placeholders == {e['parameter'] for e in effects if e['parameter']},row,'description_key','占位符与效果参数不一致')
    for row in rows('cards','effects'):
        require(row['card_id'] in cards,row,'card_id','卡牌不存在')
        require(type(row['upgraded']) is bool,row,'upgraded','必须为布尔值')
        require(row['kind'] in EFFECTS,row,'kind','未实现的效果')
        require(row['target'] == 'selected',row,'target','效果目标须为 selected')
        number(row,'amount',integer=True); number(row,'hits',1,True); number(row,'order',1,True); number(row,'threat_mult')
        target = cards[row['card_id']]['target']
        require((row['kind'] not in ('damage','interrupt') or target == 'enemy') and (row['kind'] not in ('heal','shield','dispel') or target in ('ally','self')),row,'kind','效果与目标不匹配')
    for row in chars.values():
        number(row,'max_hp',1,True);number(row,'strength',integer=True);number(row,'passive_amount',integer=True)
        require(row['role'] in ROLES - {''},row,'role','未知职业')
        require(row['passive'] in ('first_damage','first_heal','first_shield'),row,'passive','未实现的被动')
    for row in rows('characters','starter'):
        require(row['character_id'] in chars and row['card_id'] in cards,row,'card_id','缺少引用')
        number(row,'count',1,True)
        c, u = cards[row['card_id']], chars[row['character_id']]
        require((not c['owner'] or c['owner']==u['id']) and (not c['role'] or c['role']==u['role']),row,'card_id','初始牌不能施放')
    for row in enemies.values():
        for key in ('max_hp','strength','interrupt_threshold','immunity_count'):
            number(row,key,1 if key=='max_hp' else 0,True)
        intents = sorted([i for i in rows('encounters','intents') if i['enemy_id']==row['id']],key=lambda i:i['order'])
        require([i['order'] for i in intents] == list(range(1,len(intents)+1)) and bool(intents),row,'intents','意图顺序无效')
    for row in rows('encounters','intents'):
        require(row['enemy_id'] in enemies,row,'enemy_id','敌人不存在')
        require(row['kind'] in ('normal','interruptible','uninterruptible'),row,'kind','未知意图')
        require(row['status']=='' or row['status'] in statuses,row,'status','状态不存在')
        for key in ('amount','stacks','hits','order'):
            number(row,key,1 if key in ('hits','order') else 0,True)
    for row in rows('encounters'):
        require(all(e in enemies for e in row['enemies'].split(',')),row,'enemies','敌人不存在')
        number(row,'gold',integer=True);number(row,'order',1,True)
    require(sorted(r['order'] for r in rows('encounters')) == list(range(1,len(rows('encounters'))+1)),rows('encounters')[0],'order','遭遇顺序不连续')
    required={'party_size','base_energy','draw_count','hand_limit','initial_tank_threat','initial_other_threat','heal_threat','post_battle_revive','reward_count','weak_multiplier','vulnerable_multiplier','starting_gold'}
    rule_index=index('battle_rules')
    require(required == set(rule_index),rows('battle_rules')[0],'id','规则缺失或存在未知规则')
    for row in rule_index.values():
        number(row,'value',0,row['id'] not in ('heal_threat','post_battle_revive','weak_multiplier','vulnerable_multiplier'))
    require(0 < rule_index['post_battle_revive']['value'] <= 1,rule_index['post_battle_revive'],'value','复活比例须在 (0,1]')
    require(rule_index['party_size']['value']==3,rule_index['party_size'],'value','当前固定三人')
    for row in statuses.values():
        require(row['id'] in ('poison','burn','regen','weak','vulnerable'),row,'id','未实现的状态')
        number(row,'per_stack',1,True);number(row,'decay',1,True)
        require(type(row['dispellable']) is bool,row,'dispellable','必须为布尔值')
    for row in texts.values():
        require(isinstance(row['text'],str) and bool(row['text']),row,'text','文案为空')


def export(source, output, check=False):
    books = {name:read_book(source / (name+'.xlsx')) for name in BOOKS}
    validate(books)
    if check:
        for name, book in books.items():
            if json.loads((output/(name+'.json')).read_text(encoding='utf-8')) != book:
                raise ValueError(f'{name}.json 与源表不同，请重新导出')
    else:
        output.mkdir(parents=True,exist_ok=True)
        for name, book in books.items():
            dest=output/(name+'.json')
            with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',dir=output,delete=False,suffix='.tmp') as handle:
                json.dump(book,handle,ensure_ascii=False,indent=2,allow_nan=False)
                handle.write('\n'); handle.flush(); os.fsync(handle.fileno())
                temp=handle.name
            os.replace(temp,dest)
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
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, ET.ParseError) as exc:
        parser.exit(1,f'配置未生效：{exc}\n')
