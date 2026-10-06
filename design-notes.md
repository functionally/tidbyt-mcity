# Midnight City Tidbyt — design notes

Written for whoever maintains this next. It assumes you know the Midnight City project (`../` in the repo this was developed in: `design-history.md`, `lessons-learned.md`, `item-catalogue.md`) but nothing about this app.

## Data source

| Endpoint | Size | Auth | Use |
| --- | --- | --- | --- |
| `GET /observer/api/agents/<agentId>` | ~3.3 KB | **none** | activity and alert state, one call per character |
| `GET /observer/api/leaderboards?agentIds=<a,b,c>&board=<b>` | ~10-13 KB | **none** | the two rank rows, one call per board for all characters at once |
| `GET /observer/api/leaderboards?agentIds=<a,b,c>` | **174 KB** | none | every rank on all 24 boards; too big to pull every 5 min for two numbers |
| `GET /observer/api/bootstrap` | **3.4 MB** | none | the whole world; far too big for Pixlet, do not use |
| `GET /observer/api/skill/agents/<id>/context` | ~1.4 KB | none | narrower than the per-agent read; `eventLines` is empty for our characters |

Two endpoints, five requests per render: three per-agent reads plus one per board.

**The leaderboard call changes shape depending on how you ask.** With `agentIds` alone, `requestedAgents` is an object keyed by board (`.requestedAgents.experience`, `.requestedAgents.experienceBySkill.<skill>`) and carries all 24 boards' top-100 lists — 174 KB. Adding `board=<name>` narrows it to ~10-13 KB but turns `requestedAgents` into a **bare list**, which is why `fetch_board_ranks()` takes one board at a time. A repeated `board` parameter is a 400, so there is no middle option.

A character who has not placed on a board comes back as `{"entry": null, "status": "unranked"}` rather than being left out, so a *missing* key means the request failed and a *null entry* means the character is genuinely off the board. The app renders both as `-`; only the former is worth worrying about.

Fields used from the per-agent read:

```
name · profession · status · aiMode
activeAction.{kind, activity}   → engage/move_to/gather/craft/trade/sleep, mine_ore/trade_crypto/…
isPerformingJob
hunger.{value, state}           → normal | hungry | starving  (higher value = hungrier; 100 = starving)
control.{modelId, state}        → modelId null = an external controller (us); non-null = a City model
vitals.{health, maxHealth}
```

**A self-hosted character that nobody is driving disappears from the world**, and this endpoint 404s for it. That is not an error — it is the normal resting state of an own-AI character whose control loop is stopped, and the app renders it as a grey `offline` column. (This caught us out in the main project too; see `lessons-learned.md` §27 addendum 6.)

**`control.modelId` is the reliable "who is driving" tell.** `aiMode` lags behind a mode change, and `control.mode` reads `browser_local` for *both* the City's hosted AI and our own direct-control sessions, so it distinguishes nothing. Only `modelId` does: `null` means an external controller holds the session, a string like `alibaba/qwen3.7-flash` means a City-hosted model is driving.

## Layout (64 × 32)

Three columns, one per character, read top-down:

```
 x:  0        21        42      63
     ├─ 21px ─┼─ 21px ─┼─ 22px ─┤
y 2  │ PRAIS  │ RAZE   │ BLAME  │  name        7px
y 9  │ X162   │ X243   │ X407   │  XP rank     7px
y16  │ W22    │ W20    │  -     │  Work rank   7px
y23  │ CHOP   │ POWER  │ DATA   │  activity    7px
```

64 does not divide by three, so `COL_W = [21, 21, 22]` gives the odd pixel to the last column. Four 7 px rows are 28 px; the grid is centred in the 32 px height by the enclosing `Box`, leaving 2 px top and bottom. Every cell is a fixed-size `Box` so the three columns stay row-aligned regardless of content.

**Why these four rows.** The first version showed a control dot, activity, crystal and hunger. Three of those were wrong for what this project actually cares about:

- **Crystal is a migration grant, not earnings.** At the ~100 crystal/hour the economy yields it changes about once a week, so the row was a constant. Its *rank* is equally inert.
- **The control dot spent the display's strongest colour on a fact that is almost always "fine".** Every state it reported that is *not* fine — offline, taken over, unheld, hurt — already raises an alert, which is louder than a dot and gets the full 64 px.
- **Hunger is the same argument.** The loops eat at 75; a value below that is noise. `starving` raises an alert.

What replaced them is rank on the two leaderboards the control policies actually move: total XP and completed contracts (`experience` and `completedContracts`; the project calls the latter *Work*). A rank says where a character stands against the field, which is the question the whole exercise is about, and it moves daily rather than weekly.

The two rank rows would be indistinguishable as bare numbers, so each carries a one-letter board prefix — `X` for experience, `W` for Work — drawn in grey against a white number by `_rank_cell()`. `render.Text` takes a single colour, so that cell is a `Row` of two `Text`s rather than one string.

### The font trap — read this before editing the layout

**`tom-thumb` is proportional, not monospaced.** It looks like a 4×6 fixed font and the sibling `tidbyte-claude` app uses it happily for left-aligned labels, but glyph widths differ: `m` and `w` are wider than `i` and `l`. The first version of this app used it and `BLAME` overran its column and was clipped at the screen edge, while `PRAIS` fitted with room to spare.

`CG-pixel-3x5-mono` is genuinely fixed-width at a 4 px advance, so **five glyphs are always exactly 20 px** and can never spill into the next column. That is why `FONT` is set to it. The cost is that it renders uppercase only — which is fine at this size, and arguably more legible.

Bundled fonts measured against a 21 px column (`"Blame"`, `"mmmmm"`):

| Font | Fits 5 chars in 21 px? | Notes |
| --- | --- | --- |
| `CG-pixel-3x5-mono` | **yes, always** | uppercase-only, 4 px advance — what we use |
| `tom-thumb` | only for narrow glyphs | proportional; will clip `m`/`w`-heavy strings |
| `tb-8`, `Dina_r400-6` | no | overflow badly |

If you change `COL_W`, `NAME_CHARS`, or any label, re-render and **look at it** (below). Do not trust character counts with any font other than the mono one.

### Name shortening

A column holds five glyphs, so `SHORT_NAMES` maps each display name to a short form; anything not in the map is truncated to `NAME_CHARS`. `Praise` → `PRAIS` is the ugly one — pick something better there if it bothers you. Alerts use the **full** name, since the alert frame gets all 64 px.

## Color language

One strong channel. Identity and rank are deliberately flat so the activity row carries the eye.

| Element | Meaning | Colors |
| --- | --- | --- |
| **name** | identity | yellow `#FFFF00`, grey when offline |
| **rank rows** | where we stand | grey `#AAAAAA` board letter, white `#FFFFFF` number, grey `-` when unplaced |
| **activity** | what it is doing | one color per activity, see `ACTIVITY_COLOR` |

Activity is now the only strong colour on the grid, which is deliberate: it is the only row that changes minute to minute. `_drive()` still exists and still classifies who holds each character — `_alerts()` needs it, and an offline character's name greys out — it simply no longer has a row.

### Activity colors

Each activity label gets its own color so the bottom row can be read without reading the words — ore ochre, timber green, crypto cyan, water blue, salvage brass, and so on; travelling, idle and offline stay deliberately desaturated so working characters stand out. The map is keyed by the **label** `_activity()` returns (`mine`, `hack`, …), not by the raw API string, so adding a new activity means adding it to both `ACTIVITY_LABELS` and `ACTIVITY_COLOR`. Anything unmapped falls back to grey `LABEL`.

**Verify the raw strings; do not guess them.** `ACTIVITY_LABELS` is keyed by `activeAction.activity`, and the first draft guessed several of those keys. One was wrong — energy gathering is `collect_energy`, not `tap_energy` — and it went unnoticed for weeks because no character worked the energy board until a retarget put one there, at which point the row quietly fell through to the generic `gath` label. The keys marked `# v` were confirmed against a 120-agent sample of the observer on 2026-10-06:

```bash
curl -s "$OBS/api/agents" | jq -r '.agents[].id' | head -120 | while read id; do
  curl -s "$OBS/api/agents/$id" | jq -r '.activeAction.activity // empty'; sleep 0.15
done | sort | uniq -c | sort -rn
```

That sample yields `trade_crypto`, `mine_ore`, `chop_wood`, `extract_data`, `harvest_crop`, `catch_fish`, `search_salvage`, `linger`, plus the `craft:` and `trade ` prefixes. It never produced an agility or infiltration string, so `breach_cache` and `traverse_obstacle` remain unverified guesses. An unrecognised key is not an error — it costs a nicer label and nothing else — so a wrong guess is cheap, but a *silent* one is worth knowing about.

### The hunger spectrum, removed

The first version drew hunger as a continuous hue sweep from 210° (blue) at 0% to 30° (orange) at 100%, which read well as a gauge. It came out with the row. If you ever want it back, two things bit us and will bite again:

- Write it in **integer thousandths of a degree**. Starlark's `%` operator has no width or zero-pad flags, so `"%02X"` does not exist — you need a `HEX_DIGITS` lookup and a `_hex2()` helper.
- **JSON numbers decode as floats.** Coerce with `int()` before indexing anything, or it fails at render time with `string index: got float, want int` — and only for certain values, so it will pass your first test.

`hunger.value` semantics are also inverted from the obvious reading: **higher is hungrier**, 100 is starving, and the loops eat at 75. A bar would need drawing as `100 - value`.

## Alerts

The second frame exists only when something is wrong; otherwise the app renders a single static frame with no animation at all.

| Condition | Severity | Text |
| --- | --- | --- |
| health < 50% | red | `<NAME> HURT` |
| expected `ours`, endpoint 404s | red | `<NAME> OFFLINE` |
| hunger state `starving` | red | `<NAME> STARVING` |
| expected `ours`, reads hosted | orange | `<NAME> TAKEN OVER` |
| expected `ours`, no active controller | yellow | `<NAME> NOT HELD` |

A character whose `expected` is `hosted` (Blame) never raises an alert for being hosted — that is its normal state. This is the whole reason `expected` exists in `DEFAULT_AGENTS`: the API cannot tell you what you *intended*, and "hosted" is either completely fine or the exact failure we spent days on, depending on the character.

Up to `ALERT_ROWS_MAX = 3` alerts are shown as full-width marquee rows (6 px each) over a 7 px status bar carrying the worst severity color and the alert count. Text under ~16 characters does not actually scroll, which covers every message above.

The animation is two frames, 14.5 s total at Pixlet's 20 fps — `GRID_FRAMES = 87` (4.35 s) and `ALERT_FRAMES = 203` (10.15 s) — so one full cycle fits a single Tidbyt app slot rather than looping distractingly. Same reasoning, and the same marquee scroll-position quirk, as the sibling Claude-status app's design notes.

## Checking the layout

Pixlet has no text-measurement API, so the only reliable check is to look at the pixels:

```bash
./scripts/render.sh --look     # look.gif, 64x32 magnified 10x
```

Open `look.gif` in anything. Clipped text is obvious at 10x and invisible at 1x. To exercise the alert frame without waiting for a real failure, point one character at a nonexistent id:

```bash
pixlet render main.star --gif -m 10 -o look.gif \
  'agents=Praise:user-agent-deadbeef:ours,Raze:user-agent-bd73j2hhzv:ours,Blame:user-agent-7599665622ac802b:hosted'
```

That renders an animation whose first frame is the grid; to see the alert frame as a still, temporarily replace `body = render.Animation(...)` with `body = _alert_frame(alerts)`.

`./scripts/check.sh` parses `DEFAULT_AGENTS` straight out of `main.star`, reads the same endpoint the app does, and prints both the per-character table and any alert that would fire — so it can never drift out of sync with what the device shows.

## Polling and caching

- `AGENT_TTL_S = 60` on each per-agent fetch, mainly to keep `pixlet serve` hot-reloads from hammering the observer during development.
- `BOARD_TTL_S = 300` on the leaderboard fetches. Ranks move on the order of once a day, so there is nothing to gain from a shorter cache and ~23 KB per render to lose.
- The container pushes every **300 s**. Characters change activity every few seconds, so the sibling app's 600 s felt stale; 300 s costs ~60 requests/hour (three per-agent plus two board calls per render), which is nothing.
- Worst-case staleness on the device is ~6 minutes. Fine for ambient awareness; this is not an alerting system.

## Diagnostics

Every render prints to stderr, captured by `podman logs mcitystat`:

```
[fetch] <name> HTTP=200 bytes=<n>          (or HTTP=404 → treated as offline)
[board] <board> HTTP=200 ranked=<n>        (or HTTP=<code> → ranks render as "-")
[render] <name> drive=<…> act=<…> X=<rank> W=<rank>
[render] alerts=<n> <comma-separated>
```

## Known limits and ideas

- **Three characters is the hard maximum.** A fourth column would be 16 px — four mono glyphs — which is not enough for a name plus `X162`. If a fourth character ever matters, rotate two of them through the third column on alternate frames.
- **Four-digit ranks are the width ceiling.** `X1234` is five glyphs and exactly fills a 21 px column. The field is ~900 agents, so this is not close, but a growing world would clip the prefix first.
- **A direction arrow on the rank rows was tried and rejected — on the data, not the plumbing.** The obvious next step is `X162 ▲`, and it is perfectly buildable: the app has no persistence, but the push loop in `flake.nix` does, so a state file and a `prev=` render parameter would do it without standing up a server. The reason not to is that **these ranks barely move**. Measured against the main project's hourly snapshots on 2026-10-06:

  | character / board | now | Δ6h | Δ12h | Δ24h | Δ48h | Δ72h | hourly jitter (max / mean) |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
  | praise / XP | 162 | 0 | −1 | +1 | +3 | 0 | 1 / 0.13 |
  | praise / Work | 22 | 0 | 0 | −1 | −2 | −2 | 1 / 0.06 |
  | raze / XP | 243 | −2 | −1 | +1 | +13 | +18 | 3 / 0.51 |
  | raze / Work | 20 | 0 | 0 | −1 | −1 | −2 | 1 / 0.04 |
  | blame / XP | 407 | +2 | +8 | +11 | +14 | +14 | 2 / 0.52 |

  (positive = improved, i.e. the rank number got smaller.)

  A 24-hour delta of ±1 against hourly jitter of up to ±3 is not a signal. Set the threshold at 1 and four of the five rows show an arrow that is mostly noise; set it at 2 and only Blame's XP ever moves, so the glyph is blank almost always and costs 4 px of a 21 px column for nothing. Either way the arrow is worse than the number it crowds.

  If this is ever revisited, the useful window is **48-72 hours**, not 24 — that is where Raze's +13/+18 and Blame's +14 separate from the noise — and the state file would need to survive container restarts (a volume, not `/tmp`).
- **An alternating detail frame is free.** The animation machinery already exists for alerts (`GRID_FRAMES` / `ALERT_FRAMES`) and goes unused when nothing is wrong. A second grid showing each character's best and worst *skill* board — `AGIL #6` against `HACK #290` — would make the maximin spread visible at no extra request cost, since `agentIds` without `board` already returns every skill rank in one call.
- **Conversation activity is invisible here**, which is a shame because it is the project's actual goal. Thread contents need an API token, and `eventLines` on the public context endpoint is empty for our characters. If you ever want "what did Praise just say?" on the device, the control loops already log every utterance to `tmp/agents/<name>/loop.log` and `conversations.tsv` — that would need a small local HTTP endpoint for Pixlet to read, and would tie this app to the machine running the loops.
- **No per-character history.** Everything shown is instantaneous. A sparkline of XP would need a persistence layer this app deliberately does not have.
