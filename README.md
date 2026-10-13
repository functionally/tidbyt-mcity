# Midnight City — Tidbyt app

A Pixlet/Starlark Tidbyt app showing the live state of our three [Midnight City](https://midnight.city) characters at a glance: **Praise**, **Raze**, and **Blame**.

```
┌────────────────────────────────┐
│ PRAIS      #178          DATA  │  name · XP rank · what it is doing
│ ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ │  1 px legend: the colour scale itself
│ AGI BTY CHM COK CRF            │  the 15 skills reachable without combat,
│ PWR ENG FRM FSH HAK            │    alphabetical, one fixed cell each
│ INF MIN SCV SMI WOD            │
│ EXP WRK CRY REN RCH            │  the five ranked dimensions
└────────────────────────────────┘
            64 × 32 px, one character per frame
```

## The colour scale

**Hue is standing. Brightness is trend.** Where a cell sits on the scale says
how far up that board the character stands; whether it is bright or dim says
whether that rank has improved in the past week. The two come from independent
sources, so neither can mask the other.

The 1 px strip under the title row *is* the scale, worst on the left:

| | band | standing | meaning |
| --- | --- | --- | --- |
| ⬜ | `#FFFFFF` white | ≥ 85 | within sight of the leader |
| 🟨 | `#FFD700` gold | 75 – 85 | strong |
| 🟩 | `#00E400` green | 65 – 75 | solid |
| 🟦 | `#00D9E5` cyan | 55 – 65 | middling |
| 🟦 | `#0080FF` blue | 45 – 55 | weak |
| 🟪 | `#9C7BFF` violet | < 45 | barely started |
| ⬛ | `#3A3A3A` dark grey | — | not on that board at all |

Each band has a dimmed twin at roughly 40 % brightness. A **bright** cell means
the rank improved by at least 3 places over the past 7 days; a **dim** cell
means it held or slipped. With no history yet, every cell renders bright.

Seven days is the window where this is signal rather than noise. Measured
2026-10-13: a 1-day delta moves ≥ 3 ranks on 3 of Praise's 15 boards, a 7-day
delta on 11 of 15 — she gained 174 ranks in hacking that week while losing 51
in mining.

### How "standing" is computed

Standing is the share of the **board leader's** value, but on two different
scales, because the boards have two different shapes:

- **log**, for the 15 skills and for total XP. Those leaders are orders of
  magnitude ahead — 49 M farming XP against Praise's 110 k — so a linear share
  puts ten of fifteen skills under 1 % and paints the grid a single colour.
  Taking the log spreads the same data across 33 – 91 with real separation.
- **linear**, for Work, Crystal, Renown and Reach. Their leaders are two or
  three times ahead, not a hundred, so log would saturate all four into the top
  band. Renown is a signed ratio and can go negative; it clamps at zero.

Numbers are deliberately absent from the grid: fifteen ranks will not fit as
text at this size, and the shape of the whole set is what we actually look at —
whether a character is level across the board or spiked.

When something is wrong — one of our self-hosted characters is offline,
starving, hurt, or taken over by the City's hosted AI — the display alternates
with a full-width alert frame. When everything is fine it just cycles the
characters.

Data sources, both **public and unauthenticated** — no Midnight City API token
is stored in or needed by this app:

| | |
| --- | --- |
| `GET /observer/api/agents/<agentId>` | activity and alert state, one request per character |
| `GET /observer/api/leaderboards?agentIds=<a,b,c>` | every board's leader and our own standing, one request |

The trend shading needs memory, which a Pixlet applet has not got — the push
daemon spawns a fresh `pixlet render` every cycle. `scripts/rank-history.sh`
keeps the state file and passes last week's ranks in as a render parameter;
without it every cell simply renders bright.

## Quickstart

```bash
nix develop                                # dev shell with pixlet, jq, yq
./scripts/check.sh                         # read the three characters, print what the device will show
./scripts/render.sh --look                 # look.gif at 10x — eyeball the layout
./scripts/preview.sh                       # browser preview at http://localhost:8080

./scripts/rank-history.sh --show           # record ranks, show the 7-day deltas
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

**Which characters are shown** lives in `DEFAULT_AGENTS` at the top of `main.star`, as `(display name, agent id, expected driver)`. `expected` is `ours` for a self-hosted character we run a control loop for, or `hosted` for one the City's AI runs — it is our intent, not something the API reports, and it is only used to decide what counts as an alert. Override the list at render time without editing the file:

```bash
pixlet render main.star 'agents=Praise:user-agent-6b5…:ours,Raze:user-agent-bd7…:ours'
```

In the container, the same string comes from **`MCITY_AGENTS`**. Blank shows all three, one frame each:

```yaml
- name: MCITY_AGENTS
  value: "Raze:user-agent-bd73j2hhzv:ours"
```

### One container per character

Each character then gets a full slot in the Tidbyt rotation instead of sharing one. Give every container its own **`MCITY_INSTALLATION_ID`** — two renders pushed to the same installation id overwrite the same slot rather than taking a slot each, so you would only ever see whichever pushed last. Ids must be alphanumeric.

| Env var | What |
| --- | --- |
| `MCITY_AGENTS` | Characters to show; blank means all three |
| `MCITY_INSTALLATION_ID` | Tidbyt slot; overrides the value baked from `config.yaml` |
| `MCITY_RANK_STATE_DIR` | Where the 7-day rank history lives; use a volume so it survives a container recreate |
| `PUSH_INTERVAL_S` | Seconds between pushes (default 300) |

`mcitystat.yaml` carries a worked three-container example, commented out.

## Design notes

See [design-notes.md](./design-notes.md) for the data source, the pixel math, the color language, the font trap that will bite anyone who edits the layout, and how to verify a change.
