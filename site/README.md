# site

The public page for Better Claude: one `index.html`, one `styles.css`, no build step, no
dependencies, and nothing loaded from a third party.

## Publishing

Open the repository on GitHub, go to **Settings → Pages**, and set **Source** to
**GitHub Actions**. That is the whole setup.

Do not reach for *Deploy from a branch* — it cannot publish this directory. Branch-deploy
offers exactly two source folders, `/ (root)` and `/docs`, so a site in `/site` is not
reachable that way at all.

`.github/workflows/pages.yml` publishes this directory on every push to `main` that touches
it, and can also be run by hand from the Actions tab. It serves at
`https://mandipadk.github.io/BetterClaude/`.

## The self-containment check

The page tells its readers it loads no fonts, no scripts and no third-party assets. The
deploy workflow enforces that rather than trusting it: a `<script>`, `<iframe>`, `@import`,
`@font-face`, off-origin `<link href>`/`<img src>`, or a CSS `url(http…)` fails the build.

Ordinary `<a href="https://…">` links are allowed — a link is fetched when someone clicks
it, which is not the page loading an asset.

If you add something legitimate that trips the check, widen the pattern in the workflow
deliberately. Do not delete the step; the claim is in the page's own footer.
