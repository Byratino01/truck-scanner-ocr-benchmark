"""Decrypt three private images after checking an independently verified manifest."""
import hashlib
import io
import json
import os
import pathlib
import re
import stat
import sys
import urllib.request
import zipfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

IDS = (14, 18, 27)
ROOT = pathlib.Path(os.environ["RUNNER_TEMP"]) / "bol-private"

def main():
    key = bytes.fromhex(os.environ["BOL_VISION_AES_KEY"])
    url = os.environ["BOL_ENCRYPTED_FIXTURE_URL"]
    truth = json.loads(os.environ["BOL_3_GROUND_TRUTH_JSON"])
    if len(key) != 32 or not url.startswith("https://"):
        raise ValueError("Invalid secret configuration")
    if set(truth) != {f"BOL_{i}" for i in IDS}:
        raise ValueError("Unexpected truth manifest IDs")
    ROOT.mkdir(mode=0o700, exist_ok=True)
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read(100 * 1024 * 1024 + 1)
    if len(data) > 100 * 1024 * 1024 or not data.startswith(b"BOLVISION1"):
        raise ValueError("Invalid encrypted fixture")
    plain = AESGCM(key).decrypt(data[10:22], data[22:], b"Truck-scanner Apple Vision private test v1")
    with zipfile.ZipFile(io.BytesIO(plain)) as archive:
        entries = archive.infolist()
        if len(entries) != 30 or sum(e.file_size for e in entries) > 500 * 1024 * 1024:
            raise ValueError("Invalid fixture size or count")
        names = set()
        for item in entries:
            path = pathlib.PurePosixPath(item.filename)
            if (len(path.parts) != 2 or path.parts[0] != "private-images"
                    or path.suffix.lower() not in (".jpg", ".jpeg", ".png", ".heic")
                    or item.is_dir() or stat.S_ISLNK(item.external_attr >> 16)
                    or not 0 < item.file_size <= 50 * 1024 * 1024 or str(path) in names):
                raise ValueError("Invalid fixture entry")
            names.add(str(path))
        for index in IDS:
            item = entries[index - 1]
            content = archive.read(item)
            expected = truth[f"BOL_{index}"].get("sha256")
            if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
                raise ValueError("Missing verified image fingerprint")
            if hashlib.sha256(content).hexdigest() != expected.lower():
                raise ValueError("Fixture and truth manifest mismatch")
            destination = ROOT / f"BOL_{index}{pathlib.PurePosixPath(item.filename).suffix.lower()}"
            with destination.open("xb") as output:
                output.write(content)
            destination.chmod(0o600)
    print("PRIVATE_IMAGES_PREPARED: 3; content suppressed")

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Private fixture preparation failed: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
