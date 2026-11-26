"""Export the XLSX source tables. Python 3.11+, standard library only.

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
BOOKS = tuple(CONTRACT['schemas'])
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
        return {'version': CONTRACT['version'], 'sheets': sheets}


def validate(books):
    for book, sheets in SCHEMAS.items():
        require(isinstance(books.get(book), dict) and books[book].get('version') == CONTRACT['version'], {}, book, '缺少表或版本错误')
        require(isinstance(books[book].get('sheets'), dict) and set(books[book]['sheets']) == set(sheets), {}, book, '工作表缺失或存在未知工作表')
        for name, schema in sheets.items():
            records = books[book]['sheets'][name]
            require(isinstance(records, list) and (bool(records) or f'{book}/{name}' in CONTRACT.get('empty_sheets', [])), {}, name, '工作表为空或格式错误')
            for row in records:
                require(isinstance(row, dict), {}, f'{book}/{name}', '行必须为对象')
                for group in schema.split(';'):
                    kind, fields = group.split(':')
                    for field in fields.split(','):
                        value = row.get(field)
                        valid = isinstance(value, str) if kind == 's' else (type(value) is bool if kind == 'b' else type(value) in (int, float))
                        require(valid, row, field, '缺少字段或类型错误')
                        if kind == 'n': require(math.isfinite(value), row, field, '数值必须有限')
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
        require(row['target'] in CONTRACT['card_targets'],row,'target','未知目标类型')
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
        _validate_effect(row, 'cards', number, statuses, cards[row['card_id']]['target'])
    def effects_for(card_id, upgraded):
        return sorted((e for e in rows('cards', 'effects') if e['card_id'] == card_id and e['upgraded'] == upgraded), key=lambda e:e['order'])
    for card_id, card in cards.items():
        before, after = effects_for(card_id, False), effects_for(card_id, True)
        require(len(before) == len(after), card, 'effects', '升级不能新增或删除效果')
        for base, upgraded in zip(before, after):
            require(all(base[k] == upgraded[k] for k in CONTRACT['fixed_upgrade_fields']), upgraded, 'effects', '升级不能更改效果机制')
            require(upgraded['amount'] >= base['amount'], upgraded, 'amount', '升级数值不能低于基础版本')
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
        pools={i['pool_id'] for i in rows('encounters','intents') if i['enemy_id']==row['id']}
        require('' in pools,row,'intents','缺少初始意图池')
        for pool in pools:
            intents = sorted([i for i in rows('encounters','intents') if i['enemy_id']==row['id'] and i['pool_id']==pool],key=lambda i:i['order'])
            require([i['order'] for i in intents] == list(range(1,len(intents)+1)),row,'intents','意图顺序无效')
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
    _validate_phase_two(books, rows, index, number, placeholders)


def _validate_effect(row, book, number, statuses, card_target=''):
    kinds=CONTRACT['effects'] if book=='cards' else CONTRACT['relic_effects'] if book=='relics' else CONTRACT['encounter_effects']
    require(row['kind'] in kinds,row,'kind','未知效果')
    targets=CONTRACT['effect_targets'] + (['event_source','event_target'] if book=='relics' else [])
    require(row['target'] in targets,row,'target','未知效果目标')
    fractional=row['kind'] in ('revive','camp_heal_ratio')
    number(row,'amount',-math.inf if row['kind'] in ('base_energy','base_draw') else 0,not fractional)
    for key in ('hits','order'):number(row,key,1,True)
    number(row,'duration',0,True);number(row,'threat_mult')
    require(row['kind']=='damage' or row['hits']==1,row,'hits','非伤害效果只结算一次')
    global_effects=('draw','energy','base_energy','base_draw','base_damage_bonus','first_damage_bonus','first_shield_bonus','first_heal_bonus','camp_heal_ratio')
    require((row['target']=='none')==(row['kind'] in global_effects),row,'target','单位效果与全局效果目标不符')
    require(row['kind']=='bomb' or row['duration']==0,row,'duration','只有炸弹配置倒计时')
    require(row['kind'] not in ('interrupt','dispel','clear_status') or row['amount']==1,row,'amount','打断或单种清除固定一次')
    require(row['kind'] not in ('interrupt','dispel','clear_status') or row['parameter']=='',row,'parameter','无可升级数量参数')
    require(row['kind'] not in ('revive','camp_heal_ratio') or 0 < row['amount'] <= 1,row,'amount','比例须在(0,1]')
    if row['kind'] in ('apply_status','clear_status','bomb'):
        require(row['status'] in statuses,row,'status','缺少状态')
        require(row['kind']=='bomb' or row['status']!='bomb',row,'status','炸弹必须用独立机制效果')
        if row['kind']=='apply_status':require(row['amount']>0,row,'amount','状态强度必须为正')
    else:require(row['status']=='',row,'status','该效果不支持状态字段')
    if row['kind']=='bomb':require(row['status']=='bomb' and row['duration']>0,row,'duration','炸弹必须有正倒计时')
    if not card_target:return
    target=row['target'];kind=row['kind']
    if kind in ('damage','interrupt'):
        require(target=='all_enemies' or target=='selected' and card_target=='enemy',row,'target','攻击目标不匹配')
    elif kind in ('heal','shield','dispel'):
        require(target in ('self','all_allies') or target=='selected' and card_target in ('ally','self'),row,'target','友方效果目标不匹配')
    elif kind=='revive':require(target=='selected' and card_target=='dead_ally',row,'target','复活必须选择阵亡队友')
    elif kind in ('draw','energy'):require(target=='none',row,'target','共享资源效果无需目标')
    elif kind=='taunt':require(target=='self' and row['amount']>0,row,'target','嘲讽须提高自身仇恨')
    elif kind=='apply_status':
        friendly=row['status']=='regen'
        valid=target in (('self','all_allies') if friendly else ('all_enemies',)) or target=='selected' and card_target in (('ally','self') if friendly else ('enemy',))
        require(valid,row,'target','状态与目标不匹配')


def _validate_phase_two(books, rows, index, number, template_parameters):
    cards,chars,enemies,texts,statuses=[index(*args) for args in [('cards',),('characters',),('encounters','enemies'),('texts_zh_cn',),('battle_rules','statuses')]]
    encounters,relics,events,maps=index('encounters'),index('relics'),index('events'),index('maps')
    groups={book:{} for book in ('encounters','relics')}
    for book in groups:
        for effect in rows(book,'effects'):
            _validate_effect(effect,book,number,statuses)
            require(bool(effect['group_id']),effect,'group_id','效果组不能为空')
            groups[book].setdefault(effect['group_id'],[]).append(effect)
        for group,effects in groups[book].items():
            require(sorted(e['order'] for e in effects)==list(range(1,len(effects)+1)),effects[0],'order','效果组顺序不连续')
    for enemy in enemies.values():
        require(enemy['kind'] in ('normal','elite','boss'),enemy,'kind','敌人种类无效')
        number(enemy,'enrage_turn',0,True);number(enemy,'enrage_mult',1)
    used_encounter_groups=set()
    for intent in rows('encounters','intents'):
        require(intent['target_rule'] in ('threat','lowest_hp_ratio'),intent,'target_rule','未知目标规则')
        if intent['effect_group']:
            require(intent['effect_group'] in groups['encounters'],intent,'effect_group','缺少意图效果')
            require(intent['amount']==0 and intent['status']=='' and intent['stacks']==0,intent,'effect_group','复合意图不能重复填写旧数值')
            used_encounter_groups.add(intent['effect_group'])
    thresholds=set()
    for phase in rows('encounters','phases'):
        require(phase['enemy_id'] in enemies and enemies[phase['enemy_id']]['kind']=='boss',phase,'enemy_id','阶段必须引用Boss')
        number(phase,'threshold');require(0<phase['threshold']<1,phase,'threshold','阶段比例须在(0,1)')
        pair=(phase['enemy_id'],phase['threshold']);require(pair not in thresholds,phase,'threshold','阶段阈值重复');thresholds.add(pair)
        require(phase['enter_effect_group'] in groups['encounters'],phase,'enter_effect_group','缺少阶段效果')
        require(phase['intent_pool'] and any(i['enemy_id']==phase['enemy_id'] and i['pool_id']==phase['intent_pool'] for i in rows('encounters','intents')),phase,'intent_pool','缺少阶段意图池')
        used_encounter_groups.add(phase['enter_effect_group'])
    require(set(groups['encounters'])==used_encounter_groups,{},'encounters.effects','存在未引用效果组')
    for row in encounters.values():
        require(row['kind'] in ('normal','elite','boss'),row,'kind','遭遇种类无效')
        number(row,'min_depth',1,True);number(row,'max_depth',1,True)
        require(row['min_depth']<=row['max_depth']<=10,row,'max_depth','投放范围无效')
        require((row['kind']=='boss')==any(enemies[e]['kind']=='boss' for e in row['enemies'].split(',')),row,'kind','Boss分类不一致')
    used_relic_groups=set()
    for relic in relics.values():
        require(relic['pool'] in ('normal','boss'),relic,'pool','未知遗物池')
        require(relic['role'] in ROLES and (not relic['owner'] or relic['owner'] in chars) and not(relic['owner'] and relic['role']),relic,'role/owner','无效施放资格')
        require(relic['rarity'] in ('common','rare','epic'),relic,'rarity','未知稀有度')
        triggers=[t for t in rows('relics','triggers') if t['relic_id']==relic['id']]
        require(bool(triggers),relic,'triggers','遗物缺少触发器')
        parameters=[]
        for trigger in triggers:
            require(trigger['effect_group'] in groups['relics'],trigger,'effect_group','缺少遗物效果')
            parameters += [e['parameter'] for e in groups['relics'][trigger['effect_group']] if e['parameter']]
        require(len(parameters)==len(set(parameters)),relic,'parameter','遗物参数重复')
        require(set(parameters)==template_parameters(texts[relic['description_key']]['text'],relic),relic,'description_key','遗物占位符不符')
    for trigger in rows('relics','triggers'):
        require(trigger['relic_id'] in relics,trigger,'relic_id','遗物不存在')
        for field,allowed in [('event',CONTRACT['relic_events']),('qualifier',CONTRACT['relic_qualifiers']),('limit_scope',CONTRACT['relic_scopes'])]:require(trigger[field] in allowed,trigger,field,'未知触发条件')
        for field in ('priority','order','limit_count'):number(trigger,field,0,True)
        require((trigger['limit_scope']=='none')==(trigger['limit_count']==0),trigger,'limit_count','计数范围与次数不符')
        require(trigger['effect_group'] in groups['relics'],trigger,'effect_group','缺少遗物效果')
        require(trigger['limit_scope']!='actor_turn' or trigger['event']=='card_played',trigger,'limit_scope','该通知没有施放者上下文')
        require(trigger['limit_scope']!='card_target' or trigger['event'] in ('card_played','status_dispelled','interrupt_resolved'),trigger,'limit_scope','该通知没有卡牌目标上下文')
        for effect in groups['relics'][trigger['effect_group']]:
            kind=effect['kind']
            if kind in ('first_damage_bonus','first_shield_bonus','first_heal_bonus'):require(trigger['event']=='card_played',trigger,'event','首次加成必须响应出牌')
            if kind in ('base_energy','base_draw','base_damage_bonus'):require(trigger['event']=='base_resources',trigger,'event','基础资源修改必须响应初始化')
            if kind=='camp_heal_ratio':require(trigger['event']=='camp_rest',trigger,'event','营地加成必须响应休息')
            if effect['target'] in ('event_source','event_target'):require(trigger['event'] in ('card_played','status_dispelled','interrupt_resolved'),trigger,'event','缺少事件单位上下文')
        used_relic_groups.add(trigger['effect_group'])
    require(set(groups['relics'])==used_relic_groups,{},'relics.effects','存在未引用效果组')
    options,outcomes=index('events','options'),index('events','outcomes')
    for event in events.values():
        number(event,'weight',1)
        choices=[o for o in options.values() if o['event_id']==event['id']]
        require(bool(choices) and any(o['leave'] for o in choices),event,'options','事件缺少免费离开')
        require(sorted(o['order'] for o in choices)==list(range(1,len(choices)+1)),event,'options','选项顺序不连续')
    for option in options.values():
        require(option['event_id'] in events,option,'event_id','事件不存在')
        require(option['selection'] in ('none','hero','card','unupgraded_card'),option,'selection','未知选择类型')
        require(option['required_relic_pool'] in ('','normal','boss'),option,'required_relic_pool','遗物池不存在')
        for field in ('cost_gold','cost_hp','min_hp','order'):number(option,field,0,True)
        require(not option['cost_hp'] or option['selection']=='hero' and option['min_hp']>option['cost_hp'],option,'cost_hp','生命代价不得致死')
        branches=[o for o in outcomes.values() if o['option_id']==option['id']]
        require(bool(branches),option,'outcomes','缺少结果')
        if option['leave']:
            require(option['selection']=='none' and option['cost_gold']==option['cost_hp']==0 and not option['required_relic_pool'],option,'leave','离开必须免费无条件')
            require(not any(e['outcome_id'] in {o['id'] for o in branches} for e in rows('events','effects')),option,'leave','离开不得附加效果')
    for outcome in outcomes.values():
        require(outcome['option_id'] in options,outcome,'option_id','选项不存在');number(outcome,'weight',1)
        effects=sorted([e for e in rows('events','effects') if e['outcome_id']==outcome['id']],key=lambda e:e['order'])
        require([e['order'] for e in effects]==list(range(1,len(effects)+1)),outcome,'effects','结果顺序无效')
        option=options[outcome['option_id']]
        life_cost=option['cost_hp']+sum(e['amount'] for e in effects if e['kind']=='hp_loss')
        require(life_cost==0 or option['selection']=='hero' and option['min_hp']>life_cost,option,'min_hp','完整分支的生命代价不得致死')
    for effect in rows('events','effects'):
        require(effect['outcome_id'] in outcomes,effect,'outcome_id','结果不存在')
        kind=effect['kind'];selection=options[outcomes[effect['outcome_id']]['option_id']]
        allowed={'heal':['party','selected_hero'],'hp_loss':['selected_hero'],'gold':['none'],'upgrade':['selected_card'],'remove':['selected_card'],'grant_relic':['none']}
        require(kind in allowed and effect['target'] in allowed[kind],effect,'kind/target','事件效果不匹配');number(effect,'amount',1,True)
        if kind in ('hp_loss','heal') and effect['target']=='selected_hero':require(selection['selection']=='hero',effect,'target','缺少队员选择')
        if kind=='hp_loss':require(selection['min_hp']>effect['amount']+selection['cost_hp'],effect,'amount','随机生命代价不得致死')
        if kind in ('upgrade','remove'):require(selection['selection'] in ('card','unupgraded_card') and effect['amount']==1,effect,'target','必须选择一个卡牌副本')
        if kind=='grant_relic':require(effect['content_pool'] in ('normal','boss') and effect['amount']==1 and selection['required_relic_pool']==effect['content_pool'],effect,'content_pool','遗物池或前置检查缺失')
        else:require(effect['content_pool']=='',effect,'content_pool','非遗物效果不能指定池')
    economy=index('economy')
    require(set(economy)==set(CONTRACT['economy_rules']),{},'economy','经济参数缺少或未知')
    for key,spec in CONTRACT['economy_rules'].items():
        number(economy[key],'value',spec['min'],spec.get('integer',False));require('max' not in spec or economy[key]['value']<=spec['max'],economy[key],'value','超过上限')
    for sheet in ('card_prices','relic_prices'):
        require({r['rarity'] for r in rows('economy',sheet)}=={'common','rare','epic'} and len(rows('economy',sheet))==3,{},sheet,'稀有度价格缺少或重复')
        for price in rows('economy',sheet):number(price,'price',0,True)
    weight_keys=set()
    for weight in rows('economy','weights'):
        pair=(weight['kind'],weight['source'],weight['rarity']);require(pair not in weight_keys,weight,'id','权重重复');weight_keys.add(pair)
        require(weight['kind'] in ('card','relic') and weight['source'] in ('battle','elite','boss','shop') and weight['rarity'] in ('common','rare','epic'),weight,'source','未知权重分类');number(weight,'weight',0)
    require(len(weight_keys)==24,{},'weights','来源稀有度权重缺失')
    for kind in ('card','relic'):
        for source in ('battle','elite','boss','shop'):
            require(sum(w['weight'] for w in rows('economy','weights') if w['kind']==kind and w['source']==source)>0,{},'weights','同一来源权重总量必须为正')
    for field,rule in [('base_draw','draw_count'),('base_energy','base_energy')]:
        worst=index('battle_rules')[rule]['value']+sum(min(0,e['amount']) for e in rows('relics','effects') if e['kind']==field)
        require(worst>=0,{},field,'持有负向遗物后基础资源不能为负')
    for map in maps.values():
        number(map,'node_count',10,True);require(map['node_count']==10,map,'node_count','当前章节必须经过10节点');number(map,'width',2,True)
        require(map['first_encounter_id'] in encounters and encounters[map['first_encounter_id']]['kind']=='normal',map,'first_encounter_id','起点必须普通战')
        require(map['boss_encounter_id'] in encounters and encounters[map['boss_encounter_id']]['kind']=='boss',map,'boss_encounter_id','终点必须Boss')
    for rule in rows('maps','node_rules'):
        require(rule['map_id'] in maps and rule['kind'] in ('battle','elite','camp','shop','event'),rule,'kind','地图规则不存在');number(rule,'weight',1)
        number(rule,'min_depth',2,True);number(rule,'max_depth',2,True);require(rule['min_depth']<=rule['max_depth']<=8,rule,'max_depth','节点范围非法')
    for entry in rows('maps','pools'):
        require(entry['map_id'] in maps and entry['kind'] in ('battle','elite','event'),entry,'map_id','地图池分类非法');number(entry,'weight',1)
        if entry['kind']=='event':require(entry['content_id'] in events,entry,'content_id','事件不存在')
        else:require(entry['content_id'] in encounters and encounters[entry['content_id']]['kind']==('normal' if entry['kind']=='battle' else 'elite'),entry,'content_id','遭遇类型不符')
    for map in maps.values():
        rules=[r for r in rows('maps','node_rules') if r['map_id']==map['id']]
        pool=[p for p in rows('maps','pools') if p['map_id']==map['id']]
        require(len({(p['kind'],p['content_id']) for p in pool})==len(pool),map,'pools','地图池重复内容')
        for depth in range(2,9):
            active=[r for r in rules if r['min_depth']<=depth<=r['max_depth']]
            require(any(r['kind']!='elite' for r in active),map,'node_rules',f'第{depth}层没有无精英候选')
            for rule in active:
                if rule['kind'] not in ('battle','elite','event'):continue
                candidates=[p for p in pool if p['kind']==rule['kind'] and (rule['kind']=='event' or encounters[p['content_id']]['min_depth']<=depth<=encounters[p['content_id']]['max_depth'])]
                require(bool(candidates),rule,'pools',f'第{depth}层没有可投放内容')
    difficulties=index('difficulty')
    require('difficulty_1' in difficulties and difficulties['difficulty_1']['enabled'],{},'difficulty','必须启用难度1')
    require(all(not r['enabled'] or r['id']=='difficulty_1' for r in difficulties.values()),{},'difficulty','本阶段只启用难度1')
    require(not rows('difficulty','modifiers'),{},'difficulty.modifiers','其他难度机制尚未定义')


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
    print(f'{len(BOOKS)} 份源表校验通过；' + ('JSON 与源表一致。' if check else 'JSON 已导出。'))


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
