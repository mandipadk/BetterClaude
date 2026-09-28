# site

The website, <https://betterclaude.mandip.dev>: static files in `public/`, served by
Cloudflare (`wrangler.jsonc`). Publish with `make deploy-site`.

The page says it loads nothing from anywhere else, and `Scripts/check-selfcontained.py`
enforces that: `make deploy-site` and CI both run it, and an off-origin script, font,
stylesheet or image fails them. Links are fine; they're only fetched when clicked.

Screenshots in `public/shots` come from the sample Mac (`make capture`), never from real
conversations.
