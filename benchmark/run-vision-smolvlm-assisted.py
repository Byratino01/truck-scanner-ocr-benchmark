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

def parse_role_response(raw, choices):
    """Strictly validate two-line role output; never log raw model output.

    Also accept valid legacy JSON to preserve backwards compatibility.
    Returns (selections, response-category). Unknown IDs invalidate the whole result.
    """
    empty = {'pickup': None, 'delivery': None}
    cleaned = raw.strip()
    if cleaned.startswith('```'):
        cleaned = re.sub(r'^```(?:json|text)?\s*|\s*```$', '', cleaned, flags=re.I).strip()
    try:
        obj = json.loads(cleaned)
    except (TypeError, ValueError):
        obj = None
    if isinstance(obj, dict) and set(obj) == {'pickup', 'delivery'}:
        selected = {}
        for role in ('pickup', 'delivery'):
            value = obj[role]
            if value is not None and (not isinstance(value, str) or value not in choices):
                return empty, 'invalid_candidate_id'
            selected[role] = value
        return selected, 'abstained' if all(v is None for v in selected.values()) else 'valid_selection'
    # Constrained fallback: exactly two full lines, with no uncontrolled free text.
    lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
    if len(lines) != 2:
        return empty, 'invalid_format'
    found = {}
    for line in lines:
        match = re.fullmatch(r'(PICKUP|DELIVERY)\s*[:=]\s*(C[0-9]{2}|NONE)', line, flags=re.I)
        if match is None:
            return empty, 'invalid_format'
        role = match.group(1).lower()
        if role in found:
            return empty, 'invalid_format'
        value = match.group(2).upper()
        if value != 'NONE' and value not in choices:
            return empty, 'invalid_candidate_id'
        found[role] = None if value == 'NONE' else value
    if set(found) != {'pickup', 'delivery'}:
        return empty, 'invalid_format'
    return found, 'abstained' if all(v is None for v in found.values()) else 'valid_selection'


def parse_selection(raw, choices):
    """Legacy helper retained for existing synthetic tests and callers."""
    cleaned = raw.strip()
    if cleaned.startswith('```'):
        cleaned = re.sub(r'^```(?:json|text)?\s*|\s*```$', '', cleaned, flags=re.I).strip()
    try:
        obj = json.loads(cleaned)
    except (TypeError, ValueError):
        return {'pickup': None, 'delivery': None}
    if not isinstance(obj, dict) or set(obj) != {'pickup', 'delivery'}:
        return {'pickup': None, 'delivery': None}
    return {role: (obj[role] if isinstance(obj[role], str) and obj[role] in choices else None)
            for role in ('pickup', 'delivery')}


def selection_diagnostics(raw, choices):
    return parse_role_response(raw, choices)[1]


def candidate_context(lines, options, limit=16):
    """Short neighborhood around candidate evidence; do not log or persist text."""
    texts = [item.get('text', '') for item in lines if isinstance(item, dict)]
    texts = [t for t in texts if isinstance(t, str)]
    anchors = []
    for index, text in enumerate(texts):
        if any(part in text.upper() for part in ('SHIP', 'CONSIGN', 'DELIVER', 'PICK', 'FROM', 'TO:')):
            anchors.append(index)
        if any(loc['zip'] in text for loc in options.values()):
            anchors.append(index)
    chosen = set()
    for index in anchors:
        for j in range(max(0,index-2),min(len(texts),index+3)):
            chosen.add(j)
        if len(chosen) >= limit: break
    return [{'line': i+1, 'text': texts[i][:160]} for i in sorted(chosen)[:limit]]

def generation_diagnostics(output_ids, input_ids, answer, processor):
    """Only non-reversible counts/categories; never expose model content."""
    tokens = output_ids[0].tolist()
    prompt_tokens = input_ids[0].tolist()
    prefix = tokens[:len(prompt_tokens)] == prompt_tokens
    generated = tokens[len(prompt_tokens):] if prefix else tokens
    eos = getattr(processor.tokenizer, 'eos_token_id', None)
    pad = getattr(processor.tokenizer, 'pad_token_id', None)
    # Do not print token IDs, decoded text, hashes, or candidate identifiers.
    return {
        'output_includes_prompt': int(prefix),
        'generated_tokens': len(generated),
        'decoded_chars': len(answer),
        'empty_output': int(not answer.strip()),
        'eos_seen': int(eos is not None and eos in generated),
        'pad_seen': int(pad is not None and pad in generated),
        'max_tokens_hit': int(len(generated) >= 100 and (eos is None or eos not in generated)),
    }


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
              'invalid_format': 0, 'invalid_candidate_id': 0,
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
            instruction = ('Classify the pickup and delivery on this Bill of Lading. '
                           'Use ONLY the candidate IDs shown below. Never invent an address. '
                           'SHIPPER / FROM means PICKUP; CONSIGNEE / SHIP TO means DELIVERY. '
                           'Ignore billing, carrier and headquarters. If unsure use NONE. '
                           'Return EXACTLY these two lines (no JSON, explanation, or markdown):\n'
                           'PICKUP=C01\nDELIVERY=C02\n'
                           'Replace an unknown role with NONE. Candidate IDs:\n' +
                           json.dumps(options, separators=(',', ':')) + '\n'
                           'Nearby OCR context:\n' +
                           json.dumps(candidate_context(row['ocr_lines'], options), separators=(',', ':')))
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
                generation = generation_diagnostics(output, inputs['input_ids'], answer, processor)
                print(doc + ': SAFE_GENERATION_DIAGNOSTICS ' +
                      ' '.join(key + '=' + str(value) for key, value in generation.items()))
                selected, category = parse_role_response(answer, options)
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
