#!/usr/bin/env bash
# rank-history.sh — maintain a rank history and emit the app's `prev` parameter.
#
#   ./scripts/rank-history.sh            # record now, print `prev` for pixlet
#   ./scripts/rank-history.sh --show     # same, but also print a readable table
#
# Why this exists outside the app. main.star shades each cell by whether its
# rank has improved over the past week, and a Pixlet applet has no memory: the
# push daemon spawns a fresh `pixlet render` every cycle, so any in-process
# cache dies with it. The daemon's own shell loop is the only durable thing in
# the system, so the history lives here and is handed to the applet as a render
# parameter. No server, no database.
#
# Output format, consumed by parse_prev() in main.star:
#
#   <agentId>;<board>=<rank>,<board>=<rank>,...|<agentId>;...
#
# State file: one row per (sample, agent, board). Keeping every sample rather
# than only the newest means the window can be changed later without losing
# history, and it stays small — 20 boards x 3 characters x 4 samples a day is
# ~240 rows a day.
set -uo pipefail
cd "$(dirname "$0")/.."

OBSERVER="${MCITY_OBSERVER_URL:-https://midnight.city/observer}"
STATE="${MCITY_RANK_STATE:-/tmp/mcity-ranks.tsv}"
WINDOW_DAYS="${MCITY_TREND_WINDOW_DAYS:-7}"
KEEP_DAYS="${MCITY_RANK_KEEP_DAYS:-21}"
SHOW=0
SEED_DIR=""
while (( $# )); do
  case "$1" in
    --show) SHOW=1 ;;
    --seed) SEED_DIR="${2:-}"; shift ;;
    *) echo "usage: $0 [--show] [--seed <snapshot-dir>]" >&2; exit 2 ;;
  esac
  shift
done

NOW=$(date -u +%s)

# --seed imports rank history from the parent project's hourly snapshots
# (tmp/boards/history/*.json), so the trend shading is live immediately
# instead of after the window has elapsed. Optional and project-specific:
# the app works fine without it, just uniformly bright for the first week.
# Snapshots key characters by display name, so they are mapped to ids here.
seed_from_snapshots() {
  local dir="$1" f ts
  [[ -d "${dir}" ]] || { echo "rank-history: no snapshot dir ${dir}" >&2; return 1; }
  local map=""
  for row in "${AGENTS[@]}"; do
    IFS=',' read -r n i _ <<<"${row}"
    map+="${n// /},${i// /} "
  done
  local n_before
  n_before=$(wc -l < "${STATE}" 2>/dev/null || echo 0)
  for f in "${dir}"/*.json; do
    [[ -s "${f}" ]] || continue
    ts=$(basename "${f}" .json)
    ts=$(date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z" +%s 2>/dev/null) || continue
    for pair in ${map}; do
      local who="${pair%%,*}" aid="${pair##*,}"
      jq -r --arg w "${who,,}" --arg a "${aid}" --argjson t "${ts}" '
        .rows[]? | select(.who == $w and .rank != null)
        | [$t, $a, (.board
            | if . == "XP" then "experience"
              elif . == "Work" then "completedContracts"
              elif . == "Crystal" then "richest"
              elif . == "Renown" then "mostLiked"
              elif . == "Reach" then "mostPopular"
              else . end), .rank] | @tsv' "${f}" 2>/dev/null
    done
  done >> "${STATE}"
  echo "rank-history: seeded $(( $(wc -l < "${STATE}") - n_before )) rows from ${dir}" >&2
}

# Character list parsed out of main.star, exactly as check.sh does it, so the
# two can never disagree about who is tracked.
mapfile -t AGENTS < <(sed -n '/^DEFAULT_AGENTS = \[/,/^\]/p' main.star \
  | grep -oE '\("[^"]+", "[^"]+", "[^"]+"\)' | tr -d '()"')
if (( ${#AGENTS[@]} == 0 )); then
  echo "rank-history: could not parse DEFAULT_AGENTS out of main.star" >&2
  exit 1
fi

IDS="$(printf '%s\n' "${AGENTS[@]}" | cut -d, -f2 | tr -d ' ' | paste -sd,)"

# One call carries every board for every character we track.
touch "${STATE}"
[[ -n "${SEED_DIR}" ]] && seed_from_snapshots "${SEED_DIR}"

RESP="$(curl -fsS --max-time 45 "${OBSERVER}/api/leaderboards?agentIds=${IDS}" 2>/dev/null)"
if [[ -z "${RESP}" ]]; then
  echo "rank-history: leaderboard fetch failed; emitting the previous window unchanged" >&2
else
  # Skills live under experienceBySkill keyed by skill; the five headline
  # boards sit at the top level of requestedAgents keyed by board name.
  jq -r --argjson now "${NOW}" '
      .requestedAgents as $r
      | ( ($r.experienceBySkill // {}) | to_entries[]
          | .key as $b | .value[] | select(.entry.rank != null)
          | [$now, .agentId, $b, .entry.rank] )
        ,
        ( ["experience","completedContracts","richest","mostLiked","mostPopular"][] as $b
          | ($r[$b] // [])[] | select(.entry.rank != null)
          | [$now, .agentId, $b, .entry.rank] )
      | @tsv' <<<"${RESP}" >> "${STATE}" 2>/dev/null
fi

[[ -s "${STATE}" ]] || { echo ""; exit 0; }

# Prune, then pick per (agent, board) the NEWEST sample at least WINDOW_DAYS
# old — the closest thing we have to "a week ago". A board with no sample that
# old is simply left out, and main.star renders it bright.
CUTOFF_KEEP=$(( NOW - KEEP_DAYS * 86400 ))
CUTOFF_WIN=$(( NOW - WINDOW_DAYS * 86400 ))

TMP="$(mktemp)"
awk -F'\t' -v c="${CUTOFF_KEEP}" '$1 >= c' "${STATE}" > "${TMP}" && mv "${TMP}" "${STATE}"

mapfile -t PAIRS < <(
  awk -F'\t' -v c="${CUTOFF_WIN}" '$1 <= c { key = $2 SUBSEP $3; if ($1 >= seen[key]) { seen[key] = $1; rank[key] = $4 } }
       END { for (k in rank) { split(k, p, SUBSEP); print p[1] "\t" p[2] "\t" rank[k] } }' "${STATE}" | sort
)

if (( ${#PAIRS[@]} == 0 )); then
  echo ""
  (( SHOW )) && echo "no sample is ${WINDOW_DAYS} days old yet — the grid renders bright until one is" >&2
  exit 0
fi

declare -A BY_AGENT
for row in "${PAIRS[@]}"; do
  IFS=$'\t' read -r aid board rank <<<"${row}"
  BY_AGENT["${aid}"]+="${board}=${rank},"
done

OUT=""
for aid in "${!BY_AGENT[@]}"; do
  [[ -n "${OUT}" ]] && OUT+="|"
  OUT+="${aid};${BY_AGENT[$aid]%,}"
done
echo "${OUT}"

if (( SHOW )); then
  {
    echo
    echo "state ${STATE}: $(wc -l < "${STATE}") rows, window ${WINDOW_DAYS}d, keep ${KEEP_DAYS}d"
    printf '%-26s %-20s %6s %6s %7s\n' AGENT BOARD THEN NOW DELTA
    jq -r --argjson now "${NOW}" '
        .requestedAgents as $r
        | ( ($r.experienceBySkill // {}) | to_entries[] | .key as $b | .value[]
            | select(.entry.rank != null) | [.agentId, $b, .entry.rank] )
          ,
          ( ["experience","completedContracts","richest","mostLiked","mostPopular"][] as $b
            | ($r[$b] // [])[] | select(.entry.rank != null) | [.agentId, $b, .entry.rank] )
        | @tsv' <<<"${RESP}" 2>/dev/null \
    | while IFS=$'\t' read -r aid board now_rank; do
        then_rank=$(printf '%s\n' "${PAIRS[@]}" | awk -F'\t' -v a="${aid}" -v b="${board}" '$1==a && $2==b {print $3}')
        [[ -n "${then_rank}" ]] || continue
        printf '%-26s %-20s %6s %6s %+7d\n' "${aid:0:26}" "${board}" "${then_rank}" "${now_rank}" "$(( then_rank - now_rank ))"
      done
  } >&2
fi
