# site

The public marketing page for Better Claude: one `index.html`, one `styles.css`, no build
step, no dependencies, no network requests.

To publish it, open the repository on GitHub, go to **Settings → Pages**, set **Source** to
*Deploy from a branch*, choose the `main` branch and the `/site` folder, and save. GitHub
builds the page within a minute or two and serves it at
`https://mandipadk.github.io/BetterClaude/`. Any later push to `main` that touches this
directory redeploys it automatically.
