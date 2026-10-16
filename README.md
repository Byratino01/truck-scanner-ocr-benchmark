# Truck Scanner OCR Benchmark

Isolated public code for comparing Apple Vision V9 (with V8 fallback), SmolVLM-256M-Instruct, and an agreement-only hybrid on three private BOLs. This repository contains no BOL images, ground truth, predictions, decrypted data, or production app code.

## Private setup

Set these **Actions repository secrets** in this new repository only:

- `BOL_VISION_AES_KEY`: the existing 32-byte AES-GCM key as 64 hex characters.
- `BOL_ENCRYPTED_FIXTURE_URL`: an HTTPS direct download URL for the existing encrypted `BOLVISION1` fixture. Use a stable authenticated or tightly scoped URL; do not commit its value.
- `BOL_3_GROUND_TRUTH_JSON`: a private JSON object keyed by `BOL_14`, `BOL_18`, and `BOL_27`. Each item must have `sha256` (SHA-256 of the **original image bytes** at ZIP entry 14, 18, or 27) and `verified.pickup` and `verified.delivery` objects containing `city`, `state`, and `zip`.

The SHA-256 values must be independently verified against the original ZIP ordering. The workflow refuses to score a mismatched fixture. Never paste the secret values into an issue, chat, workflow input, or commit. If the ground truth or fingerprints have not been independently verified, stop and verify them privately first.

Run **Private three-BOL OCR comparison** manually after the repository has been audited and secrets are installed. The job uses the standard `macos-15` runner and prints only aggregate counts out of six pickup/delivery roles. There are no workflow artifacts or uploaded predictions. The hybrid emits an address only when Apple Vision and SmolVLM agree exactly.

## Security boundaries

The encrypted fixture is downloaded into runner memory, decrypted under `RUNNER_TEMP`, and only three selected images are written there. The code checks all archive paths, size limits, entry count, and each selected image fingerprint before inference. Ground truth and predictions stay in runner temporary storage and are removed by an always-run cleanup step. The public repository and its Git history must contain source files only.

A public Actions workflow is readable by everyone with access to GitHub. Only a trusted maintainer should edit its default branch; a malicious workflow edit could exfiltrate secrets on a manual run. Review workflow changes before every run. This benchmark downloads model packages and weights from third-party package/model hosts, so evaluate those supply-chain dependencies under your privacy policy. The code does not send BOL pixels to an inference API.

This is an experimental three-document score, not a general accuracy claim. Removing a private document-specific company normalization from V9 may change its behavior versus the private branch.
