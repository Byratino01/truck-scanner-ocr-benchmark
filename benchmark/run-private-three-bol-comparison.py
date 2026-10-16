#!/usr/bin/env python3
"""Compare private SmolVLM and Apple Vision predictions without printing addresses."""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

import torch
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener
from transformers import AutoProcessor, AutoModelForImageTextToText

register_heif_opener()

BASE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("private_score", BASE / "compare-private-three-bol.py")
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)

def parse_location(response):
    # Accept a single JSON object only; never turn prose into an address.
    response = response.strip()
    if response.startswith("```"):
        response = re.sub(r"^\x60{3}(?:json)?\s*|\s*\x60{3}$", "", response, flags=re.I)
    try:
        value = json.loads(response)
        return score.location(value)
    except (ValueError, TypeError, KeyError):
        return None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("images", type=Path)
    parser.add_argument("vision", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    vision = json.loads(args.vision.read_text())
    if set(vision) != set(score.IDS):
        raise ValueError("Unexpected Apple Vision document IDs")
    for name in score.IDS:
        if set(vision[name]) != {"apple_vision"} or set(vision[name]["apple_vision"]) != {"pickup", "delivery"}:
            raise ValueError("Unexpected Apple Vision fields")
    model_id = "HuggingFaceTB/SmolVLM-256M-Instruct"
    processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=False)
    model = AutoModelForImageTextToText.from_pretrained(model_id, dtype=torch.float32, trust_remote_code=False).eval()
    results = {}
    for name in score.IDS:
        matches = [f for f in args.images.iterdir() if f.is_file() and f.stem == name and f.suffix.lower() in (".jpg", ".jpeg", ".png", ".heic")]
        if len(matches) != 1:
            raise ValueError("Missing or duplicate private document")
        with Image.open(matches[0]) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
            image.thumbnail((1400, 1400))
            predicted = {}
            for role, label in (("pickup", "shipper or ship-from"), ("delivery", "consignee or ship-to")):
                instruction = (
                    "Extract ONLY the " + role + " location (" + label + ") from this bill of lading. "
                    'Respond with one JSON object: {"city":"CITY","state":"ST","zip":"12345"}. '
                    "Use the two-letter state and first five ZIP digits. If uncertain respond {}. "
                    "Ignore bill-to, billing, and carrier addresses."
                )
                messages = [{"role": "user", "content": [{"type": "image"}, {"type": "text", "text": instruction}]}]
                prompt = processor.apply_chat_template(messages, add_generation_prompt=True)
                inputs = processor(text=prompt, images=[image], return_tensors="pt")
                with torch.inference_mode():
                    output = model.generate(**inputs, max_new_tokens=128, do_sample=False)
                token_ids = output[0, inputs["input_ids"].shape[-1]:]
                predicted[role] = parse_location(processor.decode(token_ids, skip_special_tokens=True))
        apple = vision[name]["apple_vision"]
        normalized_apple = {}
        hybrid = {}
        for role in ("pickup", "delivery"):
            try:
                normalized_apple[role] = score.location(apple[role]) if apple[role] is not None else None
            except (ValueError, TypeError):
                normalized_apple[role] = None
            # Agreement-only hybrid: disagreements are withheld for manual review.
            hybrid[role] = normalized_apple[role] if normalized_apple[role] is not None and normalized_apple[role] == predicted[role] else None
        results[name] = {"apple_vision": normalized_apple, "smolvlm": predicted, "hybrid": hybrid}
        print(name + ": comparison complete; address contents suppressed")
    args.output.write_text(json.dumps(results))
    args.output.chmod(0o600)
    print("THREE_BOL_PREDICTIONS_READY: 3/3; ground-truth scoring is separate")

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Private comparison failed: " + type(exc).__name__, file=sys.stderr)
        sys.exit(1)
