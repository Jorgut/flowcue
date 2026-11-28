# FlowCue Web Console — prototype

Static design reference for the web control surface. The working console now
lives in `RemoteNode/internal/server/web/`, is embedded in the node binary,
and is served at `/`; these screenshots and the single-file mockup are kept
for design review.

## English pre-launch demo

`en/` is the English build used for the X preview:

- demo: `https://loose-hero-part-digital.trycloudflare.com/en/`
- assets and copy: `en/X_POSTS.md`
- `card-4x5.png` (1080×1350), `desktop-1600x900.png`, `mobile-1080x1920.png`,
  `og.png` (1200×630), `demo.mp4` (6.4 s)

The tunnel is temporary; deploy `en/` to a static host for a durable link.

## Screens

| File | Screen |
|---|---|
| `desktop.png` | Desktop: devices + sessions, chat, session/node inspector |
| `mobile-list.png` | Phone: agents and recent sessions on the paired node |
| `mobile-chat.png` | Phone: conversation with an approval card |

## Open it

```bash
cd docs/design/web-console
python3 -m http.server 8808
# http://127.0.0.1:8808/index.html?screen=chat
# http://127.0.0.1:8808/index.html?screen=list
```

Resize the window below 900 px to switch to the phone layout. `?screen=list`
and `?screen=chat` select the two mobile screens.

## What is real

- Colors, radii, spacing, and type follow `FlowCueTokens` (Airy Dark).
- The agent/device/session vocabulary matches the current product.
- The approval card and the composer are the two interactions the node must
  support first.

## What is mocked

- All names, times, counts, and messages are sample data.
- Buttons do not call the node yet. The next step is to fetch
  `/v1/threads`, `/v1/threads/{id}/messages`, and post `/v1/send` (see
  `RemoteNode/internal/server`), then replace the sample data.
