"""Midnight City character status for Tidbyt.

Three columns, one per character. Each column reads top-down:

    name  /  control dot  /  current activity  /  crystal  /  hunger

Data comes from the observer's public per-agent endpoint, which needs no
API token. When something is wrong (one of our self-hosted characters is
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
# one that is meant to be hosted just shows a blue dot.
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
# characters. Five 6 px rows are 30 px; the grid is centered in the 32 px
# height, leaving a 1 px margin top and bottom.
ROW_H = 6
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

# Who is driving the character. This is the one strong color on the
# display, so it carries the signal that matters most: whether our own
# control loop still holds the character.
DRIVE_COLOR = {
    "ours": GREEN,  # self-hosted, our loop holds an active session
    "hosted": BLUE,  # the City's hosted AI is driving
    "unheld": YELLOW,  # in world, but no active controller
    "offline": GREY,  # not in the world at all (endpoint 404s)
    "hurt": RED,  # health below half
}

# Every activity gets its own color, so a glance at the middle row tells
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

# Hunger is drawn as a continuous spectrum rather than three fixed
# colors: hue rotates from 210 degrees (blue) at 0% down to 30 degrees
# (orange) at 100%. That arc passes through cyan, green and yellow, so
# the row reads as a gauge — blue just ate, green comfortable, yellow
# getting hungry, orange starving. The endpoints land exactly on the
# palette's blue (#0080FF) and orange (#FF7F00).
HUNGER_HUE_START = 210
HUNGER_HUE_END = 30

# Activity labels, five characters at most. Keys are the observer's
# `activeAction.activity` strings; `craft:<recipe>` and `trade <n> <item>`
# are handled by prefix in _activity() below.
ACTIVITY_LABELS = {
    "mine_ore": "mine",
    "chop_wood": "chop",
    "trade_crypto": "hack",
    "catch_fish": "fish",
    "extract_data": "data",
    "search_salvage": "salv",
    "breach_cache": "brch",
    "traverse_obstacle": "climb",
    "harvest_crop": "farm",
    "tap_energy": "power",
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

def _crystal(agent):
    """Compact crystal count, four characters at most. Truncates rather
    than rounds, so the number never reads higher than the truth."""
    if agent == None:
        return "-"
    n = (agent.get("inventory") or {}).get("crystal", 0)
    if n >= 1000000000:
        return ">1G"
    if n >= 1000000:
        tenths = n // 100000
        return "%d.%dM" % (tenths // 10, tenths % 10)
    if n >= 10000:
        return "%dK" % (n // 1000)
    if n >= 1000:
        tenths = n // 100
        return "%d.%dK" % (tenths // 10, tenths % 10)
    return str(n)

HEX_DIGITS = "0123456789ABCDEF"

def _hex2(v):
    """Two-digit uppercase hex. Starlark's % operator has no width or
    zero-pad flags, so %02X is not available."""
    if v < 0:
        v = 0
    if v > 255:
        v = 255
    return HEX_DIGITS[v // 16] + HEX_DIGITS[v % 16]

def _hunger_color(pct):
    """Full-saturation HSV sweep, done in integer thousandths of a degree
    so no float behaviour is relied on. JSON numbers decode as floats, so
    coerce first — a float index into HEX_DIGITS is a runtime error."""
    pct = int(pct)
    if pct < 0:
        pct = 0
    if pct > 100:
        pct = 100

    span = (HUNGER_HUE_START - HUNGER_HUE_END) * 1000
    hue = HUNGER_HUE_START * 1000 - span * pct // 100
    sector = hue // 60000
    up = (hue - sector * 60000) * 255 // 60000
    down = 255 - up

    if sector == 0:
        r, g, b = 255, up, 0
    elif sector == 1:
        r, g, b = down, 255, 0
    elif sector == 2:
        r, g, b = 0, 255, up
    elif sector == 3:
        r, g, b = 0, down, 255
    elif sector == 4:
        r, g, b = up, 0, 255
    else:
        r, g, b = 255, 0, down

    return "#" + _hex2(r) + _hex2(g) + _hex2(b)

def _hunger(agent):
    """(text, color). Higher is hungrier; 100 is starving."""
    if agent == None:
        return ("-", GREY)
    hunger = agent.get("hunger") or {}
    value = hunger.get("value")
    if value == None:
        return ("-", GREY)
    return ("%d%%" % value, _hunger_color(value))

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

def _column(width, name, agent, expected):
    drive = _drive(agent, expected)
    activity = _activity(agent)
    hunger_text, hunger_color = _hunger(agent)
    name_color = GREY if drive == "offline" else NAME_COLOR

    return render.Column(
        children = [
            _text_cell(width, _short_name(name), name_color),
            _cell(width, render.Circle(color = DRIVE_COLOR[drive], diameter = 5)),
            _text_cell(width, activity, ACTIVITY_COLOR.get(activity, LABEL)),
            _text_cell(width, _crystal(agent), WHITE),
            _text_cell(width, hunger_text, hunger_color),
        ],
    )

def _grid(rows):
    """rows is a list of (name, agent, expected) in display order."""
    columns = []
    for i in range(len(rows)):
        name, agent, expected = rows[i]
        columns.append(_column(COL_W[i], name, agent, expected))
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
    for name, agent, expected in rows:
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
        rows.append((name, fetch_agent(name, agent_id), expected))

    if len(rows) == 0:
        return _error_view("NO AGENTS")

    for name, agent, expected in rows:
        print("[render] %s drive=%s act=%s crystal=%s hunger=%s" % (
            name,
            _drive(agent, expected),
            _activity(agent),
            _crystal(agent),
            _hunger(agent)[0],
        ))

    grid = _grid(rows)
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
