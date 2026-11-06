#!/usr/bin/env bash
#
# Instabox keepalive for the free plan.
#
# Free Instabox machines do not have a fixed 8-hour limit. Each run starts
# with a 2-hour window; five minutes before the deadline Instabox checks the
# preceding 30 minutes of work and extends it by 2 hours when there are at
# least 5 distinct minutes with activity, up to an absolute 8 hours. A pause
# for maximum runtime starts a cooldown, and back-to-back max-run pauses get
# longer cooldowns (5-20 min, then 60-75, then 120-135).
#
# A manual pause ends the run with no cooldown owed, and the next resume
# starts a fresh 2-hour window. This script reads the current deadline
# (maxRunMinutes, measured from runStartedAt) and does a quick pause + resume
# when five minutes or less remain, after Instabox has made the extension
# decision. Downtime is usually 30-60 seconds. Run it every 5 minutes from
# OUTSIDE the machine (GitHub Actions or another always-on host) because the
# machine cannot act while paused.
#
# Usage:
#   INSTABOX_API_KEY=ibk_... ./scripts/instabox-keepalive.sh [--dry-run] [--force]
#
# Environment:
#   INSTABOX_API_KEY          required. Instabox API key with machines:read + machines:write.
#   INSTABOX_MACHINE_ID       default: m_agqwaleqeg6hzdoppoerxokgwa (production).
#   PUBLIC_READY_URL          default: https://whatsapp.oppertunity.xyz/ready
#   RESET_AFTER_MINUTES       default: 360 (also reset after 6 h of a run).
#   SAFETY_MARGIN_MINUTES     default: 5 (reset this close to the deadline; the
#                             extension decision happens 5 minutes before it).
#   MIN_AGE_BEFORE_RESET      default: 60 (never reset a run younger than this).
#   READY_TIMEOUT_SECONDS     default: 300 (how long to wait for /ready after resume).
#   OP_TIMEOUT_SECONDS        default: 180 (per Instabox operation).
#   ALERT_WEBHOOK_URL         optional Slack/Discord-style webhook for failures.
#   MOCK_MACHINE_JSON         test-only: use this JSON instead of GET /v1/machines.
#   DRY_RUN                   1 = print what would happen, change nothing.
#   FORCE                     1 = reset now, regardless of age.
#
# Exit codes: 0 ok/nothing to do, 1 failure, 2 cooldown already active.

set -euo pipefail

API_BASE="${INSTABOX_API_BASE:-https://api.instabox.sh}"
API_KEY="${INSTABOX_API_KEY:-}"
MACHINE_ID="${INSTABOX_MACHINE_ID:-m_agqwaleqeg6hzdoppoerxokgwa}"
PUBLIC_READY_URL="${PUBLIC_READY_URL:-https://whatsapp.oppertunity.xyz/ready}"
RESET_AFTER_MINUTES="${RESET_AFTER_MINUTES:-360}"
SAFETY_MARGIN_MINUTES="${SAFETY_MARGIN_MINUTES:-5}"
MIN_AGE_BEFORE_RESET="${MIN_AGE_BEFORE_RESET:-60}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
OP_TIMEOUT_SECONDS="${OP_TIMEOUT_SECONDS:-180}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
MOCK_MACHINE_JSON="${MOCK_MACHINE_JSON:-}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

usage() {
  awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

TMP_DIR="$(mktemp -d)"
SUSPENDED_BY_US=0

cleanup() {
  local rc=$?
  if [ "$SUSPENDED_BY_US" = "1" ] && [ "$DRY_RUN" != "1" ]; then
    log "cleanup: resuming machine after an interrupted run"
    do_lifecycle resume >/dev/null 2>&1 || log "cleanup: resume failed; the next run will retry"
  fi
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap 'exit 143' TERM INT
trap cleanup EXIT

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

summary() {
  log "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

send_alert() {
  local msg="$1" payload
  [ -n "$ALERT_WEBHOOK_URL" ] || return 0
  payload="$(jq -n --arg text "$msg" '{text: $text, content: $text}')" || return 0
  curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
    -d "$payload" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
}

die() {
  log "ERROR: $*"
  send_alert "whatomate keepalive ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

new_idempotency_key() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16
  fi
}

iso_to_epoch() {
  local iso="$1" norm
  norm="$(printf '%s' "$iso" | sed -E 's/\.[0-9]+//; s/\+00:00$/Z/')"
  if date -u -d "$norm" +%s >/dev/null 2>&1; then
    date -u -d "$norm" +%s
  else
    # BSD/macOS date (manual runs from a Mac).
    date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$norm" +%s 2>/dev/null
  fi
}

api() {
  local method="$1" path="$2" idem="${3:-}" out="$TMP_DIR/api.out" code
  local args=(-sS -X "$method" -H "X-API-Key: $API_KEY" -H 'Accept: application/json' --max-time 30)

  if [ -n "$idem" ]; then
    args+=(-H "Idempotency-Key: $idem")
  fi
  if [ "$method" = "POST" ]; then
    args+=(-H 'Content-Type: application/json' -d '{}')
  fi

  code="$(curl "${args[@]}" -o "$out" -w '%{http_code}' "$API_BASE$path" 2>/dev/null || true)"
  if [ "${code#2}" = "$code" ]; then
    log "API $method $path -> HTTP ${code:-no-response}"
    [ -s "$out" ] && cat "$out" >&2
    return 1
  fi
  cat "$out"
}

get_machine() {
  if [ -n "$MOCK_MACHINE_JSON" ]; then
    printf '%s\n' "$MOCK_MACHINE_JSON"
    return 0
  fi
  api GET "/v1/machines/$MACHINE_ID"
}

poll_operation() {
  local op_id="$1" timeout="${2:-$OP_TIMEOUT_SECONDS}" start now body state
  start="$(date -u +%s)"
  while :; do
    body="$(api GET "/v1/operations/$op_id")" || return 1
    state="$(jq -r '.state // empty' <<<"$body")"
    case "$state" in
      succeeded)
        log "operation $op_id succeeded"
        return 0
        ;;
      failed)
        log "operation $op_id failed: $(jq -c '.error // {}' <<<"$body")"
        return 1
        ;;
    esac
    now="$(date -u +%s)"
    if [ "$((now - start))" -ge "$timeout" ]; then
      log "operation $op_id timed out in state '${state:-unknown}'"
      return 1
    fi
    sleep 3
  done
}

do_lifecycle() {
  local action="$1" path body op_id
  path="/v1/machines/$MACHINE_ID/$action"

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would POST $path"
    return 0
  fi

  body="$(api POST "$path" "$(new_idempotency_key)")" || return 1
  op_id="$(jq -r '.id // .operation.id // empty' <<<"$body")"
  [ -n "$op_id" ] || { log "no operation id in response: $body"; return 1; }

  log "POST $path -> operation $op_id"
  poll_operation "$op_id"
}

wait_ready() {
  local timeout="${1:-$READY_TIMEOUT_SECONDS}" start now url
  if [ "$DRY_RUN" = "1" ] || [ -n "$MOCK_MACHINE_JSON" ]; then
    log "[dry-run] would wait for $PUBLIC_READY_URL"
    return 0
  fi
  [ -n "$PUBLIC_READY_URL" ] || { log "PUBLIC_READY_URL is empty; skipping readiness check"; return 0; }

  start="$(date -u +%s)"
  while :; do
    # Cache-bust so a CDN cannot serve a stale 200 while the machine is paused.
    case "$PUBLIC_READY_URL" in
      *\?*) url="$PUBLIC_READY_URL&keepalive=$(date -u +%s)" ;;
      *)    url="$PUBLIC_READY_URL?keepalive=$(date -u +%s)" ;;
    esac
    if curl -fsS -m 10 "$url" >/dev/null 2>&1; then
      log "ready: $PUBLIC_READY_URL"
      return 0
    fi
    now="$(date -u +%s)"
    if [ "$((now - start))" -ge "$timeout" ]; then
      log "not ready after ${timeout}s: $PUBLIC_READY_URL"
      return 1
    fi
    sleep 5
  done
}

main() {
  require_command curl
  require_command jq

  if [ -z "$API_KEY" ] && [ -z "$MOCK_MACHINE_JSON" ]; then
    die "INSTABOX_API_KEY is not set. Add it as a GitHub Actions secret."
  fi

  local machine state name cooldown max_run run_started auto_suspended
  local now cooldown_epoch wait_minutes run_epoch age_minutes remaining

  machine="$(get_machine)" || die "cannot read machine $MACHINE_ID"
  state="$(jq -r '.state // "unknown"' <<<"$machine")"
  name="$(jq -r '.name // ""' <<<"$machine")"
  cooldown="$(jq -r '.cooldownUntil // empty' <<<"$machine")"
  max_run="$(jq -r '.maxRunMinutes // empty' <<<"$machine")"
  run_started="$(jq -r '.runStartedAt // empty' <<<"$machine")"
  auto_suspended="$(jq -r '.autoSuspendedAt // empty' <<<"$machine")"

  now="$(date -u +%s)"

  # Already in a max-run cooldown: nothing can wake it. Report, do not fail
  # repeatedly every hour while the machine is down.
  if [ -n "$cooldown" ] && [ "$cooldown" != "null" ]; then
    cooldown_epoch="$(iso_to_epoch "$cooldown" || true)"
    if [ -n "$cooldown_epoch" ] && [ "$cooldown_epoch" -gt "$now" ]; then
      wait_minutes="$(((cooldown_epoch - now + 59) / 60))"
      summary "COOLDOWN ACTIVE: ${name:-$MACHINE_ID} is paused until $cooldown (~${wait_minutes} min). Service is down. The keepalive ran too late; wait for the cooldown or upgrade the plan."
      send_alert "whatomate: Instabox cooldown active until $cooldown (~${wait_minutes} min)."
      exit 2
    fi
  fi

  # Transitional states: wait for the machine to settle, then re-read it.
  local i
  for i in $(seq 1 20); do
    case "$state" in
      starting|stopping|suspending|resuming|creating) ;;
      *) break ;;
    esac
    log "machine is '$state'; waiting for it to settle (${i}/20)"
    sleep 5
    machine="$(get_machine)" || die "cannot re-read machine $MACHINE_ID"
    state="$(jq -r '.state // "unknown"' <<<"$machine")"
    cooldown="$(jq -r '.cooldownUntil // empty' <<<"$machine")"
    max_run="$(jq -r '.maxRunMinutes // empty' <<<"$machine")"
    run_started="$(jq -r '.runStartedAt // empty' <<<"$machine")"
    auto_suspended="$(jq -r '.autoSuspendedAt // empty' <<<"$machine")"
  done

  if [ "$state" = "suspended" ]; then
    summary "Machine '${name:-$MACHINE_ID}' is suspended (autoSuspendedAt=${auto_suspended:-none}); resuming."
    if [ -n "$auto_suspended" ] && [ "$auto_suspended" != "null" ]; then
      # Idle pause: wake is the correct call. A manual pause uses resume.
      if ! do_lifecycle wake; then
        log "wake failed; trying resume"
        do_lifecycle resume || die "wake and resume both failed"
      fi
    else
      do_lifecycle resume || die "resume failed"
    fi
    wait_ready || die "service did not become ready after resume"
    exit 0
  fi

  if [ "$state" = "error" ]; then
    summary "Machine '${name:-$MACHINE_ID}' is in the 'error' state. Manual action required."
    send_alert "whatomate: Instabox machine '${name:-$MACHINE_ID}' is in the 'error' state."
    exit 1
  fi

  if [ "$state" = "stopped" ]; then
    summary "Machine '${name:-$MACHINE_ID}' is stopped. Not starting it automatically; manual action required."
    send_alert "whatomate: Instabox machine '${name:-$MACHINE_ID}' is stopped."
    exit 1
  fi

  if [ "$state" != "running" ]; then
    summary "Machine '${name:-$MACHINE_ID}' state is '$state'; nothing to do."
    exit 0
  fi

  if [ -z "$max_run" ] || [ "$max_run" = "null" ]; then
    summary "maxRunMinutes is missing; cannot compute the run window."
    exit 0
  fi

  if ! [[ "$max_run" =~ ^-?[0-9]+$ ]]; then
    die "unexpected maxRunMinutes: $max_run"
  fi

  if [ "$max_run" -lt 0 ]; then
    summary "maxRunMinutes=$max_run (unlimited). Nothing to do."
    exit 0
  fi

  if [ -z "$run_started" ] || [ "$run_started" = "null" ]; then
    summary "runStartedAt is missing; cannot compute the run window."
    exit 0
  fi

  run_epoch="$(iso_to_epoch "$run_started" || true)"
  [ -n "$run_epoch" ] || die "cannot parse runStartedAt: $run_started"

  age_minutes="$(((now - run_epoch) / 60))"
  remaining="$((max_run - age_minutes))"

  summary "Machine '${name:-$MACHINE_ID}': state=running max_run=${max_run}m age=${age_minutes}m remaining=${remaining}m"

  local reset=0
  if [ "$FORCE" = "1" ]; then
    reset=1
  elif [ "$age_minutes" -ge "$MIN_AGE_BEFORE_RESET" ] && \
       { [ "$age_minutes" -ge "$RESET_AFTER_MINUTES" ] || [ "$remaining" -le "$SAFETY_MARGIN_MINUTES" ]; }; then
    reset=1
  fi

  if [ "$reset" != "1" ]; then
    if [ "$DRY_RUN" != "1" ] && [ -z "$MOCK_MACHINE_JSON" ] && [ -n "$PUBLIC_READY_URL" ]; then
      if ! wait_ready 30; then
        summary "WARNING: machine is running but the public /ready check failed."
        send_alert "whatomate: $PUBLIC_READY_URL is unhealthy while the Instabox machine is running."
        exit 1
      fi
    fi
    summary "No reset needed (next check when age >= ${RESET_AFTER_MINUTES}m or remaining <= ${SAFETY_MARGIN_MINUTES}m)."
    exit 0
  fi

  summary "Resetting the run window with a quick pause/resume."
  do_lifecycle suspend || die "suspend failed"
  SUSPENDED_BY_US=1
  do_lifecycle resume || die "resume failed"
  SUSPENDED_BY_US=0

  wait_ready || die "service did not become ready after pause/resume"

  local after after_start
  after="$(get_machine || true)"
  after_start="$(jq -r '.runStartedAt // "?"' <<<"$after" 2>/dev/null || echo '?')"
  summary "Reset complete. New runStartedAt=${after_start}."
}

main
