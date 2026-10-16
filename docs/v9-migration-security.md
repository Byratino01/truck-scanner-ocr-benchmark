# Public V9 validation privacy boundary

This experimental branch is intended for sanitized Swift V8/V9 parser code, synthetic tests, and aggregate-only diagnostics.

Private BOL images, OCR contents, addresses, verified ground truth, encryption keys, authentication credentials, and decrypted fixtures must never be committed or logged.

Run synthetic validation before reviewing any encrypted-fixture workflow. Do not enable encrypted-fixture processing without a separate security audit of the source code, execution path, workflow triggers, secrets handling, and log/artifact output.

The private production application remains unchanged. SmolVLM is not part of this migration.
