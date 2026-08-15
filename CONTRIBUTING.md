# Contributing

Contributions are welcome. Keep changes focused, explain user impact, and include tests
for behavior changes.

## Development workflow

1. Update `project.yml` when changing project structure or resources.
2. Run `xcodegen generate` before building the app.
3. Run the privacy audit and relevant tests.
4. Keep UI snapshot recording set to `.missing` outside an intentional baseline update.

```bash
./scripts/privacy-audit.sh
swift test --package-path DevHubPackage
xcodebuild -project DevHub.xcodeproj -scheme DevHub \
  -destination 'platform=macOS,arch=arm64' test
```

## Test data rules

- Use synthetic names such as `ExampleApp` and `/Users/example/...`.
- Do not commit real session files, account data, local paths, logs, or screenshots.
- Credential-shaped strings are allowed only in the dedicated redaction/scanner tests
  and must be obviously non-functional examples.
- Never commit signing certificates, provisioning profiles, update keys, or API tokens.

## Pull requests

Describe what changed, why it changed, visible impact, and the checks you ran. For UI
changes, include synthetic snapshots only.
