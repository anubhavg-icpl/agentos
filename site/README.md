# site

The landing page, published to GitHub Pages by `.github/workflows/pages.yml`
on every push to `main` that touches `site/`. Plain HTML, CSS and a little
JavaScript; no build step.

- Preview: open `site/index.html`, or `python3 -m http.server -d site`.
- Raster assets (`og-card.png`, `apple-touch-icon.png`) and the copies of
  the logo are generated from `assets/nestlo-logo.svg`:
  `site/tools/gen-assets.sh /path/to/chromium`.
- One-time repository setting: Settings → Pages → Source: **GitHub Actions**.
