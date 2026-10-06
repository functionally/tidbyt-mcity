"""Midnight City character status for Tidbyt.

Three columns, one per character. Each column reads top-down:

    name  /  XP rank  /  Work rank  /  current activity

Ranks, not values: XP and contracts completed are the two leaderboards our
control policies actually move, and a rank says where that puts us against
the field. Crystal was dropped because it is a migration grant rather than
something earned — it changes about once a week — and hunger and the
control dot were dropped because a starving or stolen character is an
*alert*, not a steady-state fact worth a row of a 32 px display. Both are
still caught by _alerts() below.

Data comes from two public observer endpoints, neither needing an API
token: the per-agent read for activity, and the leaderboard read for the
two ranks. When something is wrong (one of our self-hosted characters is
offline, starving, hurt, or has been taken over by the City's hosted AI)
the display alternates with an alert frame; otherwise it is static.

See ./design-notes.md for layout math, the color language, and how to
change which characters are shown.
"""

load("render.star", "render")
load("http.star", "http")
load("schema.star", "schema")

OBSERVER = "https://midnight.city/observer"

# The observer updates per world tick, but the push daemon only refreshes
# the device every few minutes, so a short cache costs nothing and keeps
# local `pixlet serve` hot-reloads from hammering the endpoint.
AGENT_TTL_S = 60

# Ranks move on the order of once a day, so they can be cached far longer
# than position and activity. One request per board, narrowed to our three
# characters with `agentIds` — about 10-13 KB each, against 174 KB for the
# unnarrowed call that returns all 24 boards' top-100 lists.
BOARD_TTL_S = 300

# The two boards shown, in row order. `experience` is total XP; the API
# calls completed contracts `completedContracts`, which we call Work.
BOARDS = ["experience", "completedContracts"]
BOARD_PREFIX = {"experience": "X", "completedContracts": "W"}

# Characters to display, left to right. Three is the maximum the 64 px
# width supports at a readable font size — see design-notes.md.
#
#   (display name, canonical agent id, expected driver)
#
# "expected" is what *should* be driving the character: "ours" for a
# self-hosted (own-AI) character we run a control loop for, "hosted" for
# one the City's own AI runs. It is not readable from the API — it is our
# intent — and it is what makes a takeover detectable: a character we
# expect to drive ourselves that turns up hosted raises an alert, while
# one that is meant to be hosted raises nothing. Since the control dot
# came off the grid, this field has no effect on the steady-state display
# at all — it only decides what counts as an alert.
DEFAULT_AGENTS = [
    ("Praise", "user-agent-6b5bd91843c92aa99f", "ours"),
    ("Raze", "user-agent-bd73j2hhzv", "ours"),
    ("Blame", "user-agent-7599665622ac802b", "hosted"),
]

# ---------------------------------------------------------------- layout

WIDTH = 64
HEIGHT = 32

# 64 px does not divide by three, so the last column takes the odd pixel.
COL_W = [21, 21, 22]

# tom-thumb is 6 px tall with a 4 px advance, so a 21 px column holds five
# characters. Four 7 px rows are 28 px; the grid is centered in the 32 px
# height, leaving a 2 px margin top and bottom. (It was five 6 px rows
# before crystal and hunger came out; the extra pixel per row is the only
# dividend, and it is worth having at this size.)
ROW_H = 7
NAME_CHARS = 5

# CG-pixel-3x5-mono is the only bundled font that is genuinely fixed-width,
# so five glyphs are always 20 px and never spill into the next column.
# tom-thumb looks similar but is proportional — "Blame" is wider than
# "Prais" and overruns a 21 px column. The mono font renders uppercase
# only, which is fine at this size. See design-notes.md.
FONT = "CG-pixel-3x5-mono"

# A column fits five glyphs, so longer names need a short form. Set one
# here rather than letting the blind truncation below pick it — "Praise"
# truncates to "PRAIS", which is recognizable but not pretty. Alerts use
# the full name, since they get the whole 64 px width.
SHORT_NAMES = {
    "Praise": "Prais",
    "Raze": "Raze",
    "Blame": "Blame",
}

# Alert frame: full-width marquee rows over a colored bar.
ALERT_ROW_W = 64
ALERT_ROW_H = 6
ALERT_ROWS_MAX = 3
ALERT_BAR_H = 7

# Two-frame animation at pixlet's 20 fps. 14.5 s total so one full cycle
# fits the Tidbyt's ~15 s app slot; the alert frame holds the screen for
# most of it because that is the part you need to read.
GRID_FRAMES = 87
ALERT_FRAMES = 203

# ---------------------------------------------------------------- colors

GREEN = "#00E400"
BLUE = "#0080FF"
YELLOW = "#FFFF00"
ORANGE = "#FF7E00"
RED = "#FF0000"
GREY = "#888888"
WHITE = "#FFFFFF"
LABEL = "#AAAAAA"
BLACK = "#000000"
NAME_COLOR = "#FFFF00"

# _drive() still classifies who holds the character — _alerts() needs it,
# and an offline character's name greys out — but it no longer gets a row
# of its own. The control dot was the strongest color on the display and
# it was spending it on a fact that is almost always "fine"; the cases
# that are not fine raise an alert, which is louder than a dot.
#
# Every activity gets its own color, so a glance at the bottom row tells
# you what the three are doing without reading the words. Keyed by the
# label _activity() returns, not by the raw API string.
ACTIVITY_COLOR = {
    "mine": "#E09A3E",  # ore, warm ochre
    "chop": "#5FBF3F",  # timber, leaf green
    "hack": "#00D9E5",  # crypto terminal, electric cyan
    "fish": "#3FA0FF",  # water blue
    "data": "#9C7BFF",  # data extraction, violet
    "salv": "#B08D57",  # salvage, brass
    "brch": "#FF3FA4",  # breaching a cache, magenta
    "climb": "#66FFCC",  # agility, mint
    "farm": "#9ACD32",  # crops, yellow-green
    "power": "#FFC800",  # energy tap, amber
    "crft": "#FF8C42",  # crafting, orange
    "sell": "#FFD700",  # trading, gold
    "gath": "#A0C878",  # generic gathering, sage
    "walk": "#7A8FA6",  # travelling, slate
    "zzz": "#6A5ACD",  # asleep, slate blue
    "work": "#C0C0C0",  # working, unspecified
    "busy": "#909090",  # busy, unspecified
    "idle": "#707070",  # doing nothing
    "off": "#505050",  # not in the world
}

# Activity labels, five characters at most. Keys are the observer's
# `activeAction.activity` strings; `craft:<recipe>` and `trade <n> <item>`
# are handled by prefix in _activity() below.
#
# Marked (v) are verified against live agents — a 120-agent sample of the
# observer on 2026-10-06, plus our own three. The rest are plausible
# guesses carried from the first draft and have never been seen: an
# unrecognised string is not an error, it just falls through to the
# KIND_LABELS fallback below, so a wrong guess costs a nicer label and
# nothing more. `tap_energy` was one of those guesses and was wrong — the
# real string is `collect_energy`, which only surfaced when Raze was
# retargeted onto the energy board. Both are kept; a dead key is free.
ACTIVITY_LABELS = {
    "mine_ore": "mine",  # v
    "chop_wood": "chop",  # v
    "trade_crypto": "hack",  # v
    "catch_fish": "fish",  # v
    "extract_data": "data",  # v
    "search_salvage": "salv",  # v
    "harvest_crop": "farm",  # v
    "collect_energy": "power",  # v
    "linger": "idle",  # v — engage with nothing to engage
    "tap_energy": "power",
    "breach_cache": "brch",
    "traverse_obstacle": "climb",
}

# Fallbacks when there is no activity string, keyed by activeAction.kind.
KIND_LABELS = {
    "move_to": "walk",
    "sleep": "zzz",
    "gather": "gath",
    "trade": "sell",
    "craft": "crft",
    "engage": "work",
}

# ------------------------------------------------------------- data layer

def fetch_agent(name, agent_id):
    """Public per-agent read. Returns None when the character is not in
    the world — for a self-hosted character that nobody is driving, the
    observer removes it entirely and this 404s, which is a meaningful
    state rather than an error."""
    url = "%s/api/agents/%s" % (OBSERVER, agent_id)
    r = http.get(url, ttl_seconds = AGENT_TTL_S)
    if r.status_code != 200:
        print("[fetch] %s HTTP=%d (treating as offline)" % (name, r.status_code))
        return None
    print("[fetch] %s HTTP=200 bytes=%d" % (name, len(r.body())))
    return r.json()

def _drive(agent, expected):
    """Classify who is driving, worst-first so a problem always wins."""
    if agent == None:
        return "offline"

    vitals = agent.get("vitals") or {}
    hp = vitals.get("health", 100)
    hp_max = vitals.get("maxHealth", 100)
    if hp_max > 0 and hp * 2 < hp_max:
        return "hurt"

    control = agent.get("control") or {}

    # A hosted character is driven by a City model; the model id is the
    # reliable tell, since `aiMode` lags a mode change.
    if agent.get("aiMode") == "hosted" or control.get("modelId") != None:
        return "hosted"

    if control.get("state") != "active":
        return "unheld"

    return "ours"

def _activity(agent):
    """Five characters describing what the character is doing now."""
    if agent == None:
        return "off"

    action = agent.get("activeAction") or {}
    activity = action.get("activity")

    if activity != None:
        if activity.startswith("craft:"):
            return "crft"
        if activity.startswith("trade "):
            return "sell"
        if activity in ACTIVITY_LABELS:
            return ACTIVITY_LABELS[activity]

    kind = action.get("kind")
    if kind in KIND_LABELS:
        return KIND_LABELS[kind]

    status = agent.get("status", "")
    if status == "traveling":
        return "walk"
    if status == "sleeping":
        return "zzz"
    if agent.get("isPerformingJob", False):
        return "work"
    if status == "busy":
        return "busy"
    return "idle"

def fetch_board_ranks(board, agent_ids):
    """{agentId: rank} for one leaderboard, for the characters we show.

    `agentIds` narrows the response to our three, but the top-100 list for
    the board still comes back, hence BOARD_TTL_S. Passing `board` also
    changes the shape of `requestedAgents` from an object keyed by board
    to a bare list, which is why this takes one board at a time — the API
    rejects a repeated `board` parameter with a 400.

    An agent who has not placed comes back as {"entry": null, "status":
    "unranked"} rather than being omitted, so a missing key here means the
    request failed, not that the character is off the board."""
    url = "%s/api/leaderboards?agentIds=%s&board=%s" % (
        OBSERVER,
        ",".join(agent_ids),
        board,
    )
    r = http.get(url, ttl_seconds = BOARD_TTL_S)
    if r.status_code != 200:
        print("[board] %s HTTP=%d (ranks unavailable)" % (board, r.status_code))
        return {}

    out = {}
    for row in r.json().get("requestedAgents") or []:
        entry = row.get("entry")
        out[row.get("agentId")] = entry.get("rank") if entry != None else None
    print("[board] %s HTTP=200 ranked=%d" % (
        board,
        len([v for v in out.values() if v != None]),
    ))
    return out

def _rank(ranks, agent_id):
    """Five characters at most: "X162", "W22", or "-" when unplaced.

    The prefix is what makes two bare rank numbers tell themselves apart
    on a display with no room for a legend."""
    if agent_id not in ranks:
        return "-"
    rank = ranks[agent_id]
    if rank == None:
        return "-"
    return "%d" % int(rank)

def _short_name(name):
    if name in SHORT_NAMES:
        return SHORT_NAMES[name]
    if len(name) > NAME_CHARS:
        return name[:NAME_CHARS]
    return name

# ----------------------------------------------------------- grid drawing

def _cell(width, child):
    """One 6 px row of a column, child centered."""
    return render.Box(width = width, height = ROW_H, child = child)

def _text_cell(width, text, color):
    return _cell(width, render.Text(text, color = color, font = FONT))

def _rank_cell(width, prefix, text):
    """A grey board letter against a white rank, so the two rank rows are
    distinguishable without a legend. Drawn as a Row of two Texts because
    render.Text takes a single color."""
    if text == "-":
        return _text_cell(width, "-", GREY)
    return _cell(width, render.Row(
        children = [
            render.Text(prefix, color = LABEL, font = FONT),
            render.Text(text, color = WHITE, font = FONT),
        ],
    ))

def _column(width, name, agent_id, agent, expected, ranks):
    drive = _drive(agent, expected)
    activity = _activity(agent)
    name_color = GREY if drive == "offline" else NAME_COLOR

    children = [_text_cell(width, _short_name(name), name_color)]
    for board in BOARDS:
        children.append(_rank_cell(
            width,
            BOARD_PREFIX[board],
            _rank(ranks.get(board) or {}, agent_id),
        ))
    children.append(
        _text_cell(width, activity, ACTIVITY_COLOR.get(activity, LABEL)),
    )
    return render.Column(children = children)

def _grid(rows, ranks):
    """rows is a list of (name, agentId, agent, expected) in display order."""
    columns = []
    for i in range(len(rows)):
        name, agent_id, agent, expected = rows[i]
        columns.append(_column(COL_W[i], name, agent_id, agent, expected, ranks))
    return render.Box(
        width = WIDTH,
        height = HEIGHT,
        color = BLACK,
        child = render.Row(children = columns),
    )

# ---------------------------------------------------------- alert drawing

def _alerts(rows):
    """Problems worth interrupting the display for, worst first.

    A character we expect the City to host is not an alert when it is
    hosted — that is its normal state. The same reading on a character we
    expect to drive ourselves means we lost it."""
    urgent = []
    lesser = []
    for name, _agent_id, agent, expected in rows:
        drive = _drive(agent, expected)

        if drive == "hurt":
            urgent.append((name + " HURT", RED))
        elif drive == "offline" and expected == "ours":
            urgent.append((name + " OFFLINE", RED))
        elif drive == "hosted" and expected == "ours":
            urgent.append((name + " TAKEN OVER", ORANGE))
        elif drive == "unheld" and expected == "ours":
            lesser.append((name + " NOT HELD", YELLOW))

        if agent != None:
            state = (agent.get("hunger") or {}).get("state", "normal")
            if state == "starving":
                urgent.append((name + " STARVING", RED))

    return urgent + lesser

def _alert_row(text, color):
    return render.Box(
        width = ALERT_ROW_W,
        height = ALERT_ROW_H,
        child = render.Marquee(
            width = ALERT_ROW_W,
            child = render.Text(text, color = color, font = FONT),
        ),
    )

def _alert_frame(alerts):
    shown = alerts[:ALERT_ROWS_MAX]
    rows = [_alert_row(text, color) for text, color in shown]
    for _ in range(ALERT_ROWS_MAX - len(shown)):
        rows.append(render.Box(width = ALERT_ROW_W, height = ALERT_ROW_H))

    worst = shown[0][1] if len(shown) > 0 else GREY
    label = "%d alert" % len(alerts) if len(alerts) == 1 else "%d alerts" % len(alerts)
    bar = render.Box(
        width = WIDTH,
        height = ALERT_BAR_H,
        color = worst,
        child = render.Padding(
            pad = (2, 1, 0, 0),
            child = render.Text(label, color = BLACK, font = FONT),
        ),
    )

    return render.Box(
        width = WIDTH,
        height = HEIGHT,
        color = BLACK,
        child = render.Column(
            expanded = True,
            main_align = "space_between",
            children = [render.Column(children = rows), bar],
        ),
    )

# ------------------------------------------------------------------ main

def _parse_agents(spec):
    """Override the character list from config: a comma-separated list of
    Name:agentId:expected entries. Falls back to DEFAULT_AGENTS."""
    if spec == None or spec == "":
        return DEFAULT_AGENTS
    out = []
    for chunk in spec.split(","):
        parts = chunk.strip().split(":")
        if len(parts) < 2:
            continue
        expected = parts[2] if len(parts) > 2 else "ours"
        out.append((parts[0], parts[1], expected))
    if len(out) == 0:
        return DEFAULT_AGENTS
    return out[:len(COL_W)]

def _error_view(message):
    return render.Root(
        child = render.Box(
            color = "#222222",
            child = render.Text(message, color = WHITE, font = FONT),
        ),
    )

def main(config):
    agents = _parse_agents(config.get("agents"))

    rows = []
    for name, agent_id, expected in agents:
        rows.append((name, agent_id, fetch_agent(name, agent_id), expected))

    if len(rows) == 0:
        return _error_view("NO AGENTS")

    # One leaderboard request per board for all three characters at once.
    # A failed board yields {} and renders as "-" rather than failing the
    # whole display: activity and the alerts are still worth showing.
    agent_ids = [agent_id for _n, agent_id, _a, _e in rows]
    ranks = {}
    for board in BOARDS:
        ranks[board] = fetch_board_ranks(board, agent_ids)

    for name, agent_id, agent, expected in rows:
        print("[render] %s drive=%s act=%s %s" % (
            name,
            _drive(agent, expected),
            _activity(agent),
            " ".join([
                "%s=%s" % (BOARD_PREFIX[b], _rank(ranks.get(b) or {}, agent_id))
                for b in BOARDS
            ]),
        ))

    grid = _grid(rows, ranks)
    alerts = _alerts(rows)
    print("[render] alerts=%d %s" % (
        len(alerts),
        ", ".join([a[0] for a in alerts]) if len(alerts) > 0 else "-",
    ))

    if len(alerts) == 0:
        body = grid
    else:
        body = render.Animation(
            children = [grid] * GRID_FRAMES + [_alert_frame(alerts)] * ALERT_FRAMES,
        )

    return render.Root(child = render.Box(color = BLACK, child = body))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "agents",
                name = "Characters",
                desc = "Comma-separated Name:agentId:ours|hosted. Blank uses the built-in three.",
                icon = "user",
                default = "",
            ),
        ],
    )
