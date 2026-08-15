# Public visual assets

`social-preview.png` is rendered from `social-preview.html` at 1280 × 640. It uses the
repository app icon and the synthetic `projectsOverview` snapshot; it does not contain
a capture of a maintainer's desktop, real project path, account, or session.

To regenerate it with Playwright:

```bash
./scripts/render-social-preview.sh
```

The script uses the installed Google Chrome when available. Otherwise, the first run
downloads Playwright's headless Chromium shell; later runs reuse the local cache.

Inspect the PNG after every regeneration. GitHub's repository social preview is a
separate repository setting and must be re-uploaded when this asset changes.
