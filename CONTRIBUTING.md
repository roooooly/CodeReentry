# Contributing

Contributions are welcome. Keep changes focused, explain user impact, and include tests
for behavior changes.

DevHub prioritizes reliable recovery of the correct local project context. A new
integration should begin with a concrete user problem, supported versions, sanitized
fixtures, and an honest unsupported state. Please open a Discussion before investing in
a broad feature or a new product area.

## Development workflow

1. Update `project.yml` when changing project structure or resources.
2. Run `xcodegen generate` before building the app.
3. Run the privacy audit and relevant tests.
4. Keep UI snapshot recording set to `.missing` outside an intentional baseline update.

```bash
./scripts/privacy-audit.sh
./scripts/test-reentry-trial.sh
./scripts/test-performance-fixture.sh
./scripts/test-performance-summary.sh
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

Run `git diff --cached` before every commit and confirm that no generated history,
diagnostic output, account identifier, or local absolute path is included.

Performance changes should use the deterministic protocol in
[`docs/performance-baseline.md`](docs/performance-baseline.md). Never substitute a quick
zero-idle smoke run for the five-minute release result or weaken a budget after a failure.

## Compatibility changes

When changing a reader or launcher:

1. Name the third-party tool and version used for verification.
2. Add the smallest synthetic fixture that demonstrates the supported format.
3. Preserve bounded reads and explicit errors for unsupported data.
4. Document whether DevHub can discover, read, resume, or only open the tool.
5. Do not turn a successful local experiment into a claim of universal compatibility.

## Pull requests

Describe what changed, why it changed, visible impact, and the checks you ran. For UI
changes, include synthetic snapshots only.

By participating, you agree to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
