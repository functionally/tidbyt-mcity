"""Midnight City character status for Tidbyt.

One character per frame. Each frame is a 5 x 3 grid of three-letter skill
codes, coloured by how far up that board the character stands, plus a
header and a row of the five ranked headline boards:

    RAZE #256                 name, XP rank
    AGI BTY CHM COK CRF       the 15 reachable skills, alphabetical,
    PWR ENG FRM FSH HAK         hue = standing, brightness = 7-day trend
    INF MIN SCV SMI WOD
    EXP WRK CRY REN RCH       the five ranked dimensions

Why colour and not numbers: fifteen ranks will not fit as text at this
size, and the shape of the whole set is the thing we actually look at —
whether a character is level across the board (the `maximin` policy) or
spiked (the `peak` policy). See design-notes.md.

Hunger, crystal value and the who-is-driving dot are deliberately absent.
A starving or stolen character is an *alert*, not a steady-state fact
worth a row; _alerts() below still catches every case.

Data: the observer's public per-agent endpoint (alerts) and one
leaderboard call carrying every board's leader plus our own standing.
No API token. The 7-day trend arrives as a render parameter from the
push daemon, which is the only thing in this system with any memory;
without it every cell simply renders at full brightness.
"""

load("render.star", "render")
load("http.star", "http")
load("schema.star", "schema")

OBSERVER = "https://midnight.city/observer"

AGENT_TTL_S = 60

# The combined leaderboard call is ~190 KB and carries all 24 boards: the
# top-100 list for each (we want only [0], the leader) plus our own rank
# and value under `requestedAgents`. Ranks move on the order of a day, so
# a long cache costs nothing.
BOARD_TTL_S = 300

DEFAULT_AGENTS = [
    ("Praise", "user-agent-6b5bd91843c92aa99f", "ours"),
    ("Raze", "user-agent-bd73j2hhzv", "ours"),
    ("Blame", "user-agent-7599665622ac802b", "hosted"),
]

# ---------------------------------------------------------------- layout

WIDTH = 64
HEIGHT = 32

# CG-pixel-3x5-mono is the only genuinely fixed-width bundled font: 4 px
# advance, 5 px tall, uppercase only. Three glyphs are always 12 px, so
# five codes plus four 1 px gaps are exactly 64 px — the grid cannot
# drift. tom-thumb has real lowercase and would let the codes read as
# "Agi Bty", which separates them nicely, but it is proportional and the
# total width then depends on which letters are in the codes. The fixed
# grid is worth more than the lowercase.
FONT = "CG-pixel-3x5-mono"
GLYPH_W = 4
GLYPH_H = 5
CODE_W = 3 * GLYPH_W          # 12
COL_GAP = 1
ROW_GAP = 1
COLS = 5
ROW_PITCH = GLYPH_H + ROW_GAP  # 6

# Five rows of 5 px with 1 px between = 29 px, centred in 32.
# header / skills x3 / headline

# The 15 boards reachable without combat, alphabetical so a cell keeps its
# position for ever. combat, defence, ranged and vitality are out of scope
# (SUR-8 / D-8) and unranked for all three characters anyway.
#
# `energy` is PWR rather than ENE because ENE/ENG are too easily confused
# at 3x5, and because the activity label for it is already "power".
SKILLS = [
    ("agility", "AGI"), ("bounty_hunting", "BTY"), ("chemistry", "CHM"),
    ("cooking", "COK"), ("crafting", "CRF"),
    ("energy", "PWR"), ("engineering", "ENG"), ("farming", "FRM"),
    ("fishing", "FSH"), ("hacking", "HAK"),
    ("infiltration", "INF"), ("mining", "MIN"), ("scavenging", "SCV"),
    ("smithing", "SMI"), ("woodcutting", "WOD"),
]

# The five ranked dimensions, in the API's own names, each with the scale
# that actually separates it.
#
# The skills all take "log" because their leaders are orders of magnitude
# ahead — 49 M farming XP against Praise's 110 k — so a linear share of
# the leader puts ten of fifteen skills under 1 % and paints the grid one
# colour. Total XP behaves the same way.
#
# The other four do not. Their leaders are two or three times ahead, not a
# hundred, so log saturates them all into the top band and the row goes
# uniformly white. Linear is the honest scale there. `mostLiked` is a
# signed ratio rather than a count and can go negative, which `standing()`
# clamps to zero.
HEADLINE = [
    ("experience", "EXP", "log"),
    ("completedContracts", "WRK", "linear"),
    ("richest", "CRY", "linear"),
    ("mostLiked", "REN", "linear"),
    ("mostPopular", "RCH", "linear"),
]

# Every value field the observer uses across the 24 boards. `richest` says
# `crystals` and `mostPopular` says `partners`; guessing these cost a
# render of three dim-grey cells.
VALUE_KEYS = ["xp", "totalXp", "crystals", "completed", "score", "partners"]

SHORT_NAMES = {"Praise": "PRAIS", "Raze": "RAZE", "Blame": "BLAME"}

ALERT_ROW_W = 64
ALERT_ROW_H = 6
ALERT_ROWS_MAX = 3
ALERT_BAR_H = 7

# 20 fps. Three character frames fill the Tidbyt's ~15 s slot; when an
# alert is up it takes half the slot and the characters share the rest.
FRAMES_PER_CHARACTER = 97
ALERT_FRAMES = 145

# ---------------------------------------------------------------- colours

YELLOW = "#FFFF00"
RED = "#FF0000"
ORANGE = "#FF7E00"
GREY = "#888888"
WHITE = "#FFFFFF"
BLACK = "#000000"

# Standing on a board, as a percentage of the leader on a LOG scale.
#
# Linear percent-of-the-leader is useless here and the numbers are worth
# recording: ten of our fifteen skills sit below 1 % of the leader's XP,
# so a linear map paints almost the whole grid one colour. The leaders are
# simply enormous — 49 M farming XP against Praise's 110 k. Taking the log
# of the ratio spreads the same data across 33-91 with real separation,
# because what we care about is orders of magnitude of progress, not the
# arithmetic fraction.
#
# Bands are tuned to the observed 33-91 range. Each has a bright and a dim
# form; see TREND below.
BANDS = [
    (85, "#FFFFFF", "#6E6E6E"),  # within sight of the leader
    (75, "#FFD700", "#6B5A00"),  # strong
    (65, "#00E400", "#006100"),  # solid
    (55, "#00D9E5", "#005C62"),  # middling
    (45, "#0080FF", "#00386E"),  # weak
    (0, "#9C7BFF", "#413466"),   # barely started
]
UNRANKED = ("#3A3A3A", "#2A2A2A")

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


# Brightness carries the 7-day rank trend, so hue and brightness come from
# independent sources and neither can mask the other. Seven days is the
# window where this becomes signal rather than noise: measured 2026-10-13,
# a 1-day delta moves >= 3 ranks on 3 of Praise's 15 boards, a 7-day delta
# on 11 of 15 — Praise gained 174 ranks in hacking over that week while
# losing 51 in mining. At 24 hours it is jitter, which is why the earlier
# arrow idea was dropped.
TREND_MIN_RANKS = 3

def _band(score):
    """(bright, dim) for a log-percent-of-leader score, or UNRANKED."""
    if score == None:
        return UNRANKED
    for cut, bright, dim in BANDS:
        if score >= cut:
            return (bright, dim)
    return BANDS[-1][1], BANDS[-1][2]

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

# ------------------------------------------------------------- data layer

def fetch_agent(name, agent_id):
    """Public per-agent read, for the alert frame only. A 404 means the
    character is not in the world, which for a self-hosted character whose
    loop is stopped is the normal resting state, not an error."""
    r = http.get("%s/api/agents/%s" % (OBSERVER, agent_id), ttl_seconds = AGENT_TTL_S)
    if r.status_code != 200:
        print("[fetch] %s HTTP=%d (treating as offline)" % (name, r.status_code))
        return None
    return r.json()

def fetch_boards(agent_ids):
    """One call for every board: each board's leader, and our standing.

    `agentIds` narrows `requestedAgents` to our characters while the
    top-100 list for each board still comes back — which is what we want,
    because entry [0] is the leader we measure against. Adding `board=`
    would shrink the response but turns `requestedAgents` into a bare list
    and only covers one board, and a repeated `board` is a 400."""
    url = "%s/api/leaderboards?agentIds=%s" % (OBSERVER, ",".join(agent_ids))
    r = http.get(url, ttl_seconds = BOARD_TTL_S)
    if r.status_code != 200:
        print("[board] HTTP=%d — grid will render unranked" % r.status_code)
        return None
    print("[board] HTTP=200 bytes=%d" % len(r.body()))
    return r.json()

def _leader(data, board, skill):
    """Top value on a board. `richest` and friends key their value
    differently from the skill boards, so try each known field."""
    if data == None:
        return None
    src = data.get("experienceBySkill", {}).get(skill) if skill else data.get(board)
    if src == None or len(src) == 0:
        return None
    top = src[0]
    for k in VALUE_KEYS:
        if top.get(k) != None:
            return top[k]
    return None

def _ours(data, board, skill, agent_id):
    """(value, rank) for one character on one board."""
    if data == None:
        return (None, None)
    req = data.get("requestedAgents")
    if req == None:
        return (None, None)
    src = req.get("experienceBySkill", {}).get(skill) if skill else req.get(board)
    if src == None:
        return (None, None)
    for row in src:
        if row.get("agentId") != agent_id:
            continue
        entry = row.get("entry")
        if entry == None:
            return (None, None)
        val = None
        for k in VALUE_KEYS:
            if entry.get(k) != None:
                val = entry[k]
                break
        return (val, entry.get("rank"))
    return (None, None)

def _log10(x):
    """Starlark has no math module. Ten iterations of bisection on the
    mantissa is plenty: we only need two significant figures to pick a
    colour band, and the inputs span 1 to 5e7."""
    if x <= 1:
        return 0.0
    e = 0
    v = float(x)
    for _ in range(40):
        if v < 10.0:
            break
        v = v / 10.0
        e = e + 1
    # v is now in [1,10); refine log10(v) by bisection on 10**m
    lo = 0.0
    hi = 1.0
    for _ in range(14):
        mid = (lo + hi) / 2.0
        # 10**mid via repeated squaring is awkward; compare v**1 against
        # the known decade split instead, using the identity that log10 is
        # monotone: test with a lookup-free Newton step on ln is overkill.
        p = _pow10(mid)
        if p < v:
            lo = mid
        else:
            hi = mid
    return e + (lo + hi) / 2.0

_POW10_HALVES = [
    3.1622776601683795,  # 10**0.5
    1.7782794100389228,  # 10**0.25
    1.333521432163324,   # 10**0.125
    1.1547819846894583,
    1.0746078283213176,
    1.0366329284180894,
    1.0181517217644568,
    1.0090350448414476,
    1.0045073642544626,
    1.0022511482929703,
    1.0011251137489141,
    1.0005624370007324,
    1.0002811795917959,
    1.0001405829185378,
]

def _pow10(frac):
    """10**frac for frac in [0,1), by binary expansion of the exponent."""
    out = 1.0
    f = frac
    for i in range(len(_POW10_HALVES)):
        f = f * 2.0
        if f >= 1.0:
            out = out * _POW10_HALVES[i]
            f = f - 1.0
    return out

def standing(ours, leader, mode):
    """0-100 against the board leader. None when we are not on the board.

    "log" is the share of the leader's *order of magnitude* we have
    reached, for boards whose leader is a hundred times ahead. "linear" is
    the plain share, for boards whose leader is two or three times ahead.
    Picking the wrong one collapses the whole scale into one band — see
    the note on HEADLINE above."""
    if ours == None or leader == None or leader <= 0:
        return None
    if ours <= 0:
        return 0.0
    if mode == "linear":
        v = 100.0 * float(ours) / float(leader)
        return 100.0 if v > 100.0 else v
    if leader <= 1:
        return None
    return 100.0 * _log10(ours) / _log10(leader)

def parse_prev(spec):
    """Last week's ranks from the push daemon, as
    `<agentId>;<board>=<rank>,…|<agentId>;…`. Absent or malformed means no
    trend information, and every cell renders bright."""
    out = {}
    if spec == None or spec == "":
        return out
    for chunk in spec.split("|"):
        parts = chunk.split(";")
        if len(parts) != 2:
            continue
        per = {}
        for kv in parts[1].split(","):
            bits = kv.split("=")
            if len(bits) != 2:
                continue
            per[bits[0]] = int(bits[1]) if bits[1].isdigit() else None
        out[parts[0]] = per
    return out

def rising(prev, agent_id, key, rank):
    """True when the rank improved by at least TREND_MIN_RANKS over the
    window. Unknown history counts as rising, so a fresh deployment is
    bright rather than uniformly dim."""
    if rank == None:
        return False
    per = prev.get(agent_id)
    if per == None:
        return True
    was = per.get(key)
    if was == None:
        return True
    return (was - rank) >= TREND_MIN_RANKS

# ----------------------------------------------------------- grid drawing

def _code(text, colour):
    return render.Text(text, color = colour, font = FONT)

def _grid_row(cells):
    """cells is a list of (text, colour); 1 px between columns."""
    kids = []
    for i in range(len(cells)):
        if i > 0:
            kids.append(render.Box(width = COL_GAP, height = GLYPH_H))
        kids.append(_code(cells[i][0], cells[i][1]))
    return render.Row(children = kids)

def _cells(data, prev, agent_id, items, is_skill):
    out = []
    for item in items:
        key = item[0]
        code = item[1]
        mode = "log" if is_skill else item[2]
        skill = key if is_skill else None
        board = None if is_skill else key
        val, rank = _ours(data, board, skill, agent_id)
        sc = standing(val, _leader(data, board, skill), mode)
        bright, dim = _band(sc)
        out.append((code, bright if rising(prev, agent_id, key, rank) else dim))
    return out

def _legend():
    """A 1 px spectrum of the colour bands, worst on the left.

    The scale is otherwise unguessable — nothing on a 64 x 32 display can
    carry a written key — and without it a viewer has no way to know that
    violet is bad and white is good rather than the reverse. Drawn from
    BANDS in reverse so the strip reads low-to-high, and it costs exactly
    one row of pixels.
    """
    n = len(BANDS)
    base = WIDTH // n
    extra = WIDTH - base * n
    kids = []
    for i in range(n):
        w = base + 1 if i < extra else base
        kids.append(render.Box(width = w, height = 1, color = BANDS[n - 1 - i][1]))
    return render.Row(children = kids)

def _header(name, agent, xp_rank):
    """name | XP rank | what it is doing, spread across the full width.

    Three fields at 4 px a glyph is at most 5 + 5 + 5 = 60 px in the worst
    case (a five-letter name, a four-digit rank, a five-letter activity),
    so `space_between` always has something to distribute and never
    collides."""
    left = render.Text(SHORT_NAMES.get(name, name[:5]),
                       color = GREY if agent == None else YELLOW, font = FONT)
    mid = render.Text("#" + str(int(xp_rank)) if xp_rank != None else "#-",
                      color = WHITE, font = FONT)
    act = _activity(agent)
    right = render.Text(act.upper(), color = ACTIVITY_COLOR.get(act, GREY), font = FONT)
    return render.Box(width = WIDTH, height = GLYPH_H, child = render.Row(
        expanded = True, main_align = "space_between",
        children = [left, mid, right]))

def _character_frame(name, agent_id, agent, data, prev):
    _, xp_rank = _ours(data, "experience", None, agent_id)

    rows = [
        _header(name, agent, xp_rank),
        render.Box(width = WIDTH, height = ROW_GAP),
        _legend(),
    ]
    skills = _cells(data, prev, agent_id, SKILLS, True)
    for i in range(0, len(skills), COLS):
        rows.append(render.Box(width = WIDTH, height = ROW_GAP))
        rows.append(_grid_row(skills[i:i + COLS]))
    rows.append(render.Box(width = WIDTH, height = ROW_GAP))
    rows.append(_grid_row(_cells(data, prev, agent_id, HEADLINE, False)))

    return render.Box(
        width = WIDTH, height = HEIGHT, color = BLACK,
        child = render.Column(children = rows),
    )

# ---------------------------------------------------------- alert drawing

def _drive(agent, expected):
    if agent == None:
        return "offline"
    vitals = agent.get("vitals") or {}
    hp = vitals.get("health", 100)
    hp_max = vitals.get("maxHealth", 100)
    if hp_max > 0 and hp * 2 < hp_max:
        return "hurt"
    control = agent.get("control") or {}
    if agent.get("aiMode") == "hosted" or control.get("modelId") != None:
        return "hosted"
    if control.get("state") != "active":
        return "unheld"
    return "ours"

def _alerts(rows):
    """Problems worth interrupting for, worst first. A character we expect
    the City to host is not an alert when it is hosted."""
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
            if (agent.get("hunger") or {}).get("state", "normal") == "starving":
                urgent.append((name + " STARVING", RED))
    return urgent + lesser

def _alert_frame(alerts):
    shown = alerts[:ALERT_ROWS_MAX]
    rows = []
    for text, colour in shown:
        rows.append(render.Box(
            width = ALERT_ROW_W, height = ALERT_ROW_H,
            child = render.Marquee(
                width = ALERT_ROW_W,
                child = render.Text(text, color = colour, font = FONT),
            ),
        ))
    for _ in range(ALERT_ROWS_MAX - len(shown)):
        rows.append(render.Box(width = ALERT_ROW_W, height = ALERT_ROW_H))

    worst = shown[0][1] if len(shown) > 0 else GREY
    label = "%d alert" % len(alerts) if len(alerts) == 1 else "%d alerts" % len(alerts)
    bar = render.Box(
        width = WIDTH, height = ALERT_BAR_H, color = worst,
        child = render.Padding(pad = (2, 1, 0, 0),
                               child = render.Text(label, color = BLACK, font = FONT)),
    )
    return render.Box(
        width = WIDTH, height = HEIGHT, color = BLACK,
        child = render.Column(expanded = True, main_align = "space_between",
                              children = [render.Column(children = rows), bar]),
    )

# ------------------------------------------------------------------ main

def _parse_agents(spec):
    if spec == None or spec == "":
        return DEFAULT_AGENTS
    out = []
    for chunk in spec.split(","):
        parts = chunk.strip().split(":")
        if len(parts) < 2:
            continue
        out.append((parts[0], parts[1], parts[2] if len(parts) > 2 else "ours"))
    return out if len(out) > 0 else DEFAULT_AGENTS

def _error_view(message):
    return render.Root(child = render.Box(
        color = "#222222",
        child = render.Text(message, color = WHITE, font = FONT)))

def main(config):
    agents = _parse_agents(config.get("agents"))
    if len(agents) == 0:
        return _error_view("NO AGENTS")

    rows = []
    for name, agent_id, expected in agents:
        rows.append((name, agent_id, fetch_agent(name, agent_id), expected))

    data = fetch_boards([a[1] for a in rows])
    prev = parse_prev(config.get("prev"))

    frames = []
    for name, agent_id, agent, _expected in rows:
        frames.extend([_character_frame(name, agent_id, agent, data, prev)] * FRAMES_PER_CHARACTER)
        _, r = _ours(data, "experience", None, agent_id)
        print("[render] %s xp_rank=%s trend=%s" % (
            name, r, "on" if prev.get(agent_id) != None else "off"))

    alerts = _alerts(rows)
    print("[render] alerts=%d %s" % (
        len(alerts), ", ".join([a[0] for a in alerts]) if len(alerts) > 0 else "-"))
    if len(alerts) > 0:
        frames.extend([_alert_frame(alerts)] * ALERT_FRAMES)

    return render.Root(child = render.Box(
        color = BLACK, child = render.Animation(children = frames)))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "agents", name = "Characters",
                desc = "Comma-separated Name:agentId:ours|hosted. Blank uses the built-in three.",
                icon = "user", default = "",
            ),
            schema.Text(
                id = "prev", name = "Last week's ranks",
                desc = "Set by the push daemon: <agentId>;<board>=<rank>,...|... Blank disables the trend shading.",
                icon = "clockRotateLeft", default = "",
            ),
        ],
    )
