#!/usr/bin/env python3
"""Experimental private hybrid: Vision OCR candidate generation and local SmolVLM role assignment.

No OCR content, addresses, or generated responses are printed. Files remain in runner temp.
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('score', BASE / 'compare-private-three-bol.py')
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)

# Restrict model choices to addresses actually recognized by Apple Vision.
LOCATION = re.compile(r'(?P<city>[A-Za-z][A-Za-z .\'-]{1,45}?)\s*,?\s+(?P<state>AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)\s+(?P<zip>\d{5})(?:-\d{4})?\b', re.I)

def candidates(lines, baseline):
    found = {}
    for line in lines:
        value = line.get('text', '')
        if not isinstance(value, str):
            continue
        for match in LOCATION.finditer(value):
            try:
                location = score.location(match.groupdict())
            except ValueError:
                continue
            key = tuple(location[k] for k in ('city', 'state', 'zip'))
            found.setdefault(key, location)
    # Include V9 candidates even when OCR split addresses over multiple lines.
    for role in ('pickup', 'delivery'):
        value = baseline.get(role)
        if value is not None:
            normalized = score.location(value)
            key = tuple(normalized[k] for k in ('city', 'state', 'zip'))
            found.setdefault(key, normalized)
    return {'C%02d' % (i + 1): item for i, item in enumerate(found.values())}

def parse_selection(raw, choices):
    raw = raw.strip()
    if raw.startswith('```'):
        raw = re.sub(r'^```(?:json)?\s*|\s*```$', '', raw, flags=re.I)
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return {'pickup': None, 'delivery': None}
    if not isinstance(obj, dict) or set(obj) != {'pickup', 'delivery'}:
        return {'pickup': None, 'delivery': None}
    return {role: (obj[role] if isinstance(obj[role], str) and obj[role] in choices else None)
            for role in ('pickup', 'delivery')}


def selection_diagnostics(raw, choices):
    """Classify model output without displaying its text or any OCR candidates."""
    response = raw.strip()
    if response.startswith('```'):
        response = re.sub(r'^```(?:json)?\s*|\s*```$', '', response, flags=re.I)
    try:
        parsed = json.loads(response)
    except (ValueError, TypeError):
        return 'invalid_json'
    if not isinstance(parsed, dict) or set(parsed) != {'pickup', 'delivery'}:
        return 'invalid_schema'
    for role in ('pickup', 'delivery'):
        value = parsed[role]
        if value is not None and (not isinstance(value, str) or value not in choices):
            return 'invalid_candidate_id'
    if all(parsed[role] is None for role in ('pickup', 'delivery')):
        return 'abstained'
    return 'valid_selection'

def merge_roles(baseline, vlm):
    """Retain a baseline on abstention, fill missing roles, withhold conflicts."""
    assisted = {}
    for role in ('pickup', 'delivery'):
        base, hint = baseline[role], vlm[role]
        assisted[role] = None if base and hint and base != hint else (base or hint)
    return assisted

def main():
    import os
    import torch
    from PIL import Image, ImageOps
    from pillow_heif import register_heif_opener
    from transformers import AutoProcessor, AutoModelForImageTextToText
    register_heif_opener()
    os.umask(0o077)
    p = argparse.ArgumentParser()
    p.add_argument('images', type=Path)
    p.add_argument('vision', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    vision = json.loads(a.vision.read_text())
    if set(vision) != set(score.IDS):
        raise ValueError('Unexpected document IDs')

    model_id = 'HuggingFaceTB/SmolVLM-500M-Instruct'
    processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=False)
    model = AutoModelForImageTextToText.from_pretrained(model_id, dtype=torch.float32, trust_remote_code=False).eval()
    results = {}
    totals = {'documents': 0, 'candidates': 0, 'no_candidates': 0,
              'invalid_json': 0, 'invalid_schema': 0, 'invalid_candidate_id': 0,
              'abstained': 0, 'valid_selection': 0, 'selected_roles': 0,
              'conflicts': 0, 'filled_roles': 0}
    for doc in score.IDS:
        row = vision[doc]
        if set(row) != {'apple_vision', 'ocr_lines', 'ocr_rotation_degrees'} or not isinstance(row['ocr_lines'], list):
            raise ValueError('Apple Vision evidence missing')
        degrees = row['ocr_rotation_degrees']
        if type(degrees) is not int or degrees not in (0, 90, 180, 270):
            raise ValueError('Invalid OCR orientation')
        baseline = {role: score.location(row['apple_vision'][role]) if row['apple_vision'][role] else None
                    for role in ('pickup', 'delivery')}
        options = candidates(row['ocr_lines'], baseline)
        match = [x for x in a.images.iterdir() if x.stem == doc and x.suffix.lower() in ('.jpg', '.jpeg', '.png', '.heic')]
        if len(match) != 1:
            raise ValueError('Missing or duplicate private document')
        selected = {'pickup': None, 'delivery': None}
        category = 'no_candidates'
        if options:
            # Ask the model only to classify candidate IDs. It cannot invent city, state, or ZIP.
            instruction = ('This is a Bill of Lading. Choose which candidate ID is the actual '
                           'PICKUP / shipper / ship-from and which is DELIVERY / consignee / ship-to. '
                           'Do not use billing, carrier, notify party, or corporate headquarters addresses. '
                           'If uncertain use null. Respond with only JSON such as '
                           '{"pickup":"C01","delivery":"C02"}; values must be listed IDs or null.\n'
                           'Candidates:\n' + json.dumps(options, separators=(',', ':')) + '\n'
                           'Apple Vision OCR lines (top to bottom; coordinates normalized):\n' +
                           json.dumps(row['ocr_lines'][:200], separators=(',', ':')))
            with Image.open(match[0]) as source:
                pic = ImageOps.exif_transpose(source).convert('RGB')
                # Vision .right means clockwise; Pillow's positive rotation is counterclockwise.
                pic = pic.rotate(-degrees, expand=True)
                pic.thumbnail((1400, 1400))
                chat = [{'role':'user', 'content':[{'type':'image'}, {'type':'text','text':instruction}]}]
                prompt = processor.apply_chat_template(chat, add_generation_prompt=True)
                inputs = processor(text=prompt, images=[pic], return_tensors='pt')
                with torch.inference_mode():
                    output = model.generate(**inputs, max_new_tokens=100, do_sample=False)
                answer = processor.decode(output[0, inputs['input_ids'].shape[-1]:], skip_special_tokens=True)
                category = selection_diagnostics(answer, options)
                selected = parse_selection(answer, options)
        vlm = {role: options.get(selected[role]) for role in ('pickup', 'delivery')}
        # Assisted hybrid: prefer a non-conflicting V9 result; take VLM result only when
        # V9 is empty. Conflicts are withheld for review rather than replaced.
        assisted = merge_roles(baseline, vlm)
        conflicts = sum(baseline[role] is not None and vlm[role] is not None
                        and baseline[role] != vlm[role] for role in ('pickup', 'delivery'))
        filled = sum(baseline[role] is None and vlm[role] is not None
                     for role in ('pickup', 'delivery'))
        chosen = sum(selected[role] is not None for role in ('pickup', 'delivery'))
        totals['documents'] += 1
        totals['candidates'] += len(options)
        totals[category] += 1
        totals['selected_roles'] += chosen
        totals['conflicts'] += conflicts
        totals['filled_roles'] += filled
        print(doc + ': candidates=' + str(len(options)) +
              ' response_category=' + category + ' selected_roles=' + str(chosen) +
              ' conflicts=' + str(conflicts) + ' filled_roles=' + str(filled) +
              '; document contents suppressed')
        results[doc] = {'apple_vision': baseline, 'smolvlm': vlm, 'hybrid': assisted}
        print(doc + ': private assisted comparison complete; address content suppressed')
    a.output.write_text(json.dumps(results))
    a.output.chmod(0o600)
    print('SAFE_DIAGNOSTIC_TOTALS: ' + ' '.join(k + '=' + str(v) for k, v in totals.items()))
    print('VISION_SMOLVLM_ASSISTED_READY: 3/3; roles and addresses suppressed')

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Private assisted comparison failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
