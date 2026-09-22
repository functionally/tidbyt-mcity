# Midnight City — Tidbyt app

A Pixlet/Starlark Tidbyt app showing the live state of our three [Midnight City](https://midnight.city) characters at a glance: **Praise**, **Raze**, and **Blame**.

```
┌───────┬───────┬───────┐
│ PRAIS │ RAZE  │ BLAME │  name (yellow)
│   ●   │   ●   │   ●   │  who is driving  (green ours / blue hosted / grey off)
│ MINE  │ HACK  │ WALK  │  what it is doing now (one color per activity)
│ 1.3M  │ 6.4K  │ 2.7M  │  crystal
│  25%  │  61%  │  43%  │  hunger (blue 0% → green → yellow → orange 100%)
└───────┴───────┴───────┘
        64 × 32 px
```

When something is wrong — one of our self-hosted characters is offline, starving, hurt, or has been taken over by the City's hosted AI — the display alternates with a full-width alert frame. When everything is fine it is completely static.

Data source: `GET https://midnight.city/observer/api/agents/<agentId>`, one request per character, **public and unauthenticated**. No Midnight City API token is stored in or needed by this app.

## Quickstart

```bash
nix develop                                # dev shell with pixlet, jq, yq
./scripts/check.sh                         # read the three characters, print what the device will show
./scripts/render.sh --look                 # look.gif at 10x — eyeball the layout
./scripts/preview.sh                       # browser preview at http://localhost:8080

cp config-example.yaml config.yaml         # then fill in your Tidbyt creds
./scripts/deploy.sh                        # one-shot push to your Tidbyt
```

For the always-on push daemon (every 5 minutes):

```bash
./scripts/build-container.sh               # builds the OCI image, loads it into podman
./scripts/run-container.sh -d              # detached, restarts forever
# or
podman kube play --replace mcitystat.yaml
```

## Configuration

`config.yaml` carries Tidbyt push credentials only — see `config-example.yaml`.

| Field | What |
|---|---|
| `tidbyt_api_key` | From `pixlet auth` or the Tidbyt account page |
| `tidbyt_device_id` | From `pixlet devices` |
| `tidbyt_installation_id` | Any short alphanumeric tag (`mcity`) |

**Which characters are shown** lives in `DEFAULT_AGENTS` at the top of `main.star`, as `(display name, agent id, expected driver)`. `expected` is `ours` for a self-hosted character we run a control loop for, or `hosted` for one the City's AI runs — it is our intent, not something the API reports, and it is what makes a takeover detectable. You can also override the list at render time without editing the file:

```bash
pixlet render main.star 'agents=Praise:user-agent-6b5…:ours,Raze:user-agent-bd7…:ours'
```

## Design notes

See [design-notes.md](./design-notes.md) for the data source, the pixel math, the color language, the font trap that will bite anyone who edits the layout, and how to verify a change.
