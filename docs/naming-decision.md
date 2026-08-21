# Public naming decision: CodeReentry

Date: 2026-08-21

DevHub is renamed **CodeReentry** for the public 0.3.0 source beta. The name describes
the product's narrow job: return to the correct coding project, session, and context.
It does not imply a hosted service or lossless conversation transfer between tools.

This is a public collision check and migration decision, not a legal trademark opinion.

## Decision criteria

- Searchable without the repository owner's name
- Relevant to local macOS project recovery
- Readable in English and Simplified Chinese documentation
- Available as a GitHub repository and macOS product name
- No cloud-hosting or universal-migration implication
- Safe for existing source-beta data

## Shortlist and collision check

Checks were run on 2026-08-21 against GitHub repository-name search, general web search,
Apple's Mac software search, and—where relevant—public package registries.

| Candidate | Result | Decision |
| --- | --- | --- |
| CodeReentry | No exact GitHub, public-product, Apple Mac app, or npm match found | **Selected**: direct meaning and low ambiguity |
| RepoReentry | No exact GitHub, public-product, or Apple Mac app match found | Clear but awkward to say and visually repetitive |
| Reposume | No exact GitHub, public-product, or Apple Mac app match found | Clever, but easily mistaken for a résumé product |
| RecallDock | Active commercial workspace-recall app for Ableton | Rejected: exact product collision on macOS |
| RepoRecall | Multiple AI-agent memory projects, including an established repository | Rejected: same developer-tool category |
| ContextDock | Multiple local-first AI context workspaces | Rejected: same category and several exact repositories |
| SessionDock | Existing macOS session products and repositories | Rejected: exact product collision |
| Threadport | Existing AI-context transfer extension and repositories | Rejected: adjacent workflow collision |

Search results can change. Re-run the check before registering a signing identity, App
Store record, domain, or update feed.

## Compatibility boundary

The public name changes; storage identity does not. Existing source-beta users must see
the same projects, sessions, settings, plugin permissions, and Keychain references after
updating.

The following identifiers intentionally remain legacy-compatible in 0.3.0:

- Bundle identifier: `io.github.roooooly.devhub`
- Application data: `~/Library/Application Support/DevHub/`
- Preferences domain derived from the existing bundle identifier
- Project marker: `.devhub/project.local.json`
- Environment variables and script internals prefixed `DEVHUB_` / `devhub_`
- Swift targets and modules such as `DevHub` and `DevHubCore`
- Existing Keychain account and service semantics

The visible application bundle and executable become `CodeReentry.app` and
`CodeReentry`. Keeping `PRODUCT_MODULE_NAME=DevHub` lets existing tests and internal
source modules remain stable while the shipped product name changes.

No copy, move, or deletion of user data is required. A future bundle-ID or data-directory
change must ship a tested, rollback-safe migrator before changing either identifier.

## Repository and release transition

1. Merge the code and documentation rename while the repository is still `DevHub`.
2. Rename the GitHub repository to `CodeReentry`; GitHub preserves redirects for old
   clone and web URLs.
3. Update the local `origin` URL and verify clone instructions through the new URL.
4. Keep `v0.2.0` as the historical DevHub Source Beta.
5. Publish `v0.3.0` as the first CodeReentry Source Beta only after the renamed `main`
   branch passes the complete CI suite.

The app icon remains unchanged for 0.3.0 because it contains no old wordmark. The social
preview and synthetic screenshots must use CodeReentry before the repository rename is
considered complete.
