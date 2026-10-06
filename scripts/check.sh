#!/usr/bin/env bash
# Pre-deploy sanity check.
# - Reads each configured character from the observer's public endpoint
# - Prints what the device would show, plus anything that would raise an alert
# - Confirms Tidbyt creds are populated
#
# The character list is parsed out of main.star so this script and the app
# can never disagree about who is being displayed.
set -euo pipefail
cd "$(dirname "$0")/.."

OBSERVER="${MCITY_OBSERVER_URL:-https://midnight.city/observer}"

green() { printf "\033[32m%s\033[0m" "$1"; }
red()   { printf "\033[31m%s\033[0m" "$1"; }
ok()    { printf "  $(green '✓') %s\n" "$1"; }
warn()  { printf "  $(red '✗') %s\n" "$1"; }

echo "== Characters (from main.star DEFAULT_AGENTS) =="
mapfile -t AGENTS < <(sed -n '/^DEFAULT_AGENTS = \[/,/^\]/p' main.star \
  | grep -oE '\("[^"]+", "[^"]+", "[^"]+"\)' \
  | tr -d '()"' )

if (( ${#AGENTS[@]} == 0 )); then
  warn "could not parse DEFAULT_AGENTS out of main.star"
  exit 1
fi

# Ranks for every character in one request per board, same two boards and
# the same `agentIds` narrowing the app uses. `entry` is null with status
# "unranked" for a character that has not placed, which is not an error.
declare -A XP_RANK WORK_RANK
ALL_IDS="$(printf '%s\n' "${AGENTS[@]}" | cut -d, -f2 | tr -d ' ' | paste -sd,)"
for board in experience completedContracts; do
  while IFS=$'\t' read -r aid rank; do
    [[ "$board" == "experience" ]] && XP_RANK["$aid"]="$rank" || WORK_RANK["$aid"]="$rank"
  done < <(curl -sL --max-time 12 \
             "${OBSERVER}/api/leaderboards?agentIds=${ALL_IDS}&board=${board}" \
           | jq -r '.requestedAgents[]? | [.agentId, (.entry.rank // "-")] | @tsv')
done

alerts=0
printf '  %-8s %-7s %-6s %-6s %-8s %-8s %-6s %s\n' \
  NAME EXPECT XP WORK ACTIVITY DRIVE HUNGER WHERE
for row in "${AGENTS[@]}"; do
  IFS=',' read -r name id expect <<< "$row"
  name="${name// /}"; id="${id// /}"; expect="${expect// /}"

  body="$(curl -sL --max-time 12 -w '\n%{http_code}' "${OBSERVER}/api/agents/${id}")"
  code="$(printf '%s' "$body" | tail -n1)"
  json="$(printf '%s' "$body" | sed '$d')"

  if [[ "$code" != "200" ]]; then
    printf '  %-8s %-7s %-6s %-6s %-8s %s\n' \
      "$name" "$expect" "-" "-" "off" "(HTTP $code)"
    [[ "$expect" == "ours" ]] && { warn "$name is OFFLINE but we expect to drive it"; alerts=$((alerts+1)); }
    continue
  fi

  read -r drive activity hunger hstate where < <(printf '%s' "$json" | jq -r '
    [ (if (.aiMode == "hosted" or (.control.modelId != null)) then "hosted"
       elif (.control.state != "active") then "unheld" else "ours" end),
      (.activeAction.activity // .activeAction.kind // .status // "-"),
      ((.hunger.value // 0) | tostring),
      (.hunger.state // "?"),
      (.position.spaceId // "?") ] | @tsv' | tr '\t' ' ')

  # Drive and hunger are no longer rows on the device, but they still decide
  # whether the alert frame fires, so they stay in this table.
  printf '  %-8s %-7s %-6s %-6s %-8s %-8s %-6s %s\n' \
    "$name" "$expect" \
    "X${XP_RANK[$id]:--}" "W${WORK_RANK[$id]:--}" \
    "${activity:0:8}" "$drive" "${hunger}/${hstate:0:1}" "$where"

  if [[ "$expect" == "ours" && "$drive" != "ours" ]]; then
    warn "$name expected to be ours but reads '$drive'"; alerts=$((alerts+1))
  fi
  if [[ "$hstate" == "starving" ]]; then
    warn "$name is STARVING"; alerts=$((alerts+1))
  fi
done

echo
if (( alerts == 0 )); then
  ok "no alerts — the device will show the static three-column grid"
else
  echo "  $(red "$alerts alert(s)") — the device will alternate with the alert frame"
fi

echo
echo "== Tidbyt credentials =="
if [[ ! -f config.yaml ]]; then
  warn "config.yaml is missing (fine for preview/render; needed to deploy)"
  echo "      cp config-example.yaml config.yaml"
  exit 0
fi

TIDBYT_KEY="$(yq -r '.tidbyt_api_key' config.yaml)"
TIDBYT_DEVICE_ID="$(yq -r '.tidbyt_device_id' config.yaml)"
TIDBYT_INSTALLATION_ID="$(yq -r '.tidbyt_installation_id' config.yaml)"

[[ -n "$TIDBYT_KEY" && "$TIDBYT_KEY" != "null" && "$TIDBYT_KEY" != YOUR-* ]] \
  && ok "tidbyt_api_key set" || warn "tidbyt_api_key not set in config.yaml"
[[ -n "$TIDBYT_DEVICE_ID" && "$TIDBYT_DEVICE_ID" != "null" && "$TIDBYT_DEVICE_ID" != YOUR-* ]] \
  && ok "tidbyt_device_id set" || warn "tidbyt_device_id not set in config.yaml"
if [[ "$TIDBYT_INSTALLATION_ID" =~ ^[A-Za-z0-9]+$ ]]; then
  ok "tidbyt_installation_id ($TIDBYT_INSTALLATION_ID) is alphanumeric"
else
  warn "tidbyt_installation_id ($TIDBYT_INSTALLATION_ID) must be alphanumeric"
fi
