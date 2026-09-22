# Midnight City Tidbyt — design notes

Written for whoever maintains this next. It assumes you know the Midnight City project (`../` in the repo this was developed in: `design-history.md`, `lessons-learned.md`, `item-catalogue.md`) but nothing about this app.

## Data source

| Endpoint | Size | Auth | Use |
| --- | --- | --- | --- |
| `GET /observer/api/agents/<agentId>` | ~3.3 KB | **none** | what this app uses, one call per character |
| `GET /observer/api/bootstrap` | **3.4 MB** | none | the whole world; far too big for Pixlet, do not use |
| `GET /observer/api/leaderboards?board=<b>&agentId=<id>` | ~450 B | none | rank on any of 24 boards, if you ever want it |
| `GET /observer/api/skill/agents/<id>/context` | ~1.4 KB | none | narrower than the above; `eventLines` is empty for our characters |

The per-agent endpoint is the right one: it is small, public, and carries everything the display needs in a single request. Fields used:

```
name · profession · status · aiMode
activeAction.{kind, activity}   → engage/move_to/gather/craft/trade/sleep, mine_ore/trade_crypto/…
isPerformingJob
inventory.crystal
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
y 1  │ PRAIS  │ RAZE   │ BLAME  │  name         6px
y 7  │   ●    │   ●    │   ●    │  drive dot    6px
y13  │ MINE   │ HACK   │ WALK   │  activity     6px
y19  │ 1.3M   │ 6.4K   │ 2.7M   │  crystal      6px
y25  │  25%   │  61%   │  43%   │  hunger       6px
```

64 does not divide by three, so `COL_W = [21, 21, 22]` gives the odd pixel to the last column. Five 6 px rows are 30 px; the grid is centred in the 32 px height by the enclosing `Box`, leaving 1 px top and bottom. Every cell is a fixed-size `Box` so the three columns stay row-aligned regardless of content.

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

Two independent channels, so control state and health never mask each other.

| Element | Meaning | Colors |
| --- | --- | --- |
| **name** | identity | yellow `#FFFF00`, grey when offline |
| **dot** | who is driving | 🟢 `#00E400` ours · 🔵 `#0080FF` hosted · 🟡 `#FFFF00` in world but unheld · ⚪ `#888888` offline · 🔴 `#FF0000` health < 50% |
| **activity** | what it is doing | one color per activity, see `ACTIVITY_COLOR` |
| **crystal** | wealth | white |
| **hunger** | how hungry | continuous blue→orange spectrum, see below |

The dot keeps the EPA-derived palette shared with the sibling Claude-status and Air Quality apps, because its meaning (healthy / degraded / unknown) is the same kind of signal. The other rows are free to be decorative.

### Activity colors

Each activity label gets its own color so the middle row can be read without reading the words — ore ochre, timber green, crypto cyan, water blue, salvage brass, and so on; travelling, idle and offline stay deliberately desaturated so working characters stand out. The map is keyed by the **label** `_activity()` returns (`mine`, `hack`, …), not by the raw API string, so adding a new activity means adding it to both `ACTIVITY_LABELS` and `ACTIVITY_COLOR`. Anything unmapped falls back to grey `LABEL`.

### Hunger spectrum

Hunger is a gauge, not three states, so it is drawn as a continuous hue sweep: **210° (blue) at 0% down to 30° (orange) at 100%**. The arc passes through cyan, green and yellow, which happens to read exactly right — blue has just eaten, green is comfortable, yellow is getting hungry, orange is starving. The endpoints land on the palette's own `#0080FF` and `#FF7F00`.

```
  0  10  20  30   40  50  60  70   80  90  95  100
 blue ── cyan ──── green ──── yellow ──── amber ── orange
```

Two implementation notes for anyone touching `_hunger_color()`:

- It is written in **integer thousandths of a degree**. Starlark's `%` operator has no width or zero-pad flags, so `"%02X"` does not exist — hence `_hex2()` and the `HEX_DIGITS` lookup.
- **JSON numbers decode as floats**, so `pct` is coerced with `int()` first. Without it, `sector` is a float and indexing `HEX_DIGITS` fails at render time with `string index: got float, want int`. This is the kind of bug that only appears when a particular value arrives, so keep the coercion.

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

- `ttl_seconds = 60` on each fetch, mainly to keep `pixlet serve` hot-reloads from hammering the observer during development.
- The container pushes every **300 s**. Characters change activity every few seconds, so the sibling app's 600 s felt stale; 300 s costs ~36 requests/hour across three characters, which is nothing.
- Worst-case staleness on the device is ~6 minutes. Fine for ambient awareness; this is not an alerting system.

## Diagnostics

Every render prints to stderr, captured by `podman logs mcitystat`:

```
[fetch] <name> HTTP=200 bytes=<n>          (or HTTP=404 → treated as offline)
[render] <name> drive=<…> act=<…> crystal=<…> hunger=<…>
[render] alerts=<n> <comma-separated>
```

## Known limits and ideas

- **Three characters is the hard maximum.** A fourth column would be 16 px — four mono glyphs — which is not enough for `1.3M` plus a name. If a fourth character ever matters, rotate two of them through the third column on alternate frames.
- **Crystal is nearly static** for Praise (1.38 M) and Blame (2.77 M): at the ~100 crystal/hour the economy actually yields, the displayed value changes about once a week. Rank on the `experience` board (`/api/leaderboards?board=experience&agentId=…`, ~450 B) moves daily and would be a more alive fourth row — swap `_crystal()` for a rank fetch if the static number starts to bore you. The trade-off is three extra HTTP calls per render.
- **Conversation activity is invisible here**, which is a shame because it is the project's actual goal. Thread contents need an API token, and `eventLines` on the public context endpoint is empty for our characters. If you ever want "what did Praise just say?" on the device, the control loops already log every utterance to `tmp/agents/<name>/loop.log` and `conversations.tsv` — that would need a small local HTTP endpoint for Pixlet to read, and would tie this app to the machine running the loops.
- **No per-character history.** Everything shown is instantaneous. A sparkline of crystal or XP would need a persistence layer this app deliberately does not have.
- **`hunger.value` semantics are inverted** from what you might assume: higher is hungrier, and the loops eat at 75. If you add a bar instead of a percentage, remember to draw it as "fullness = 100 − value" or it will read backwards.
