#!/usr/bin/env bash
# VERSION: 1.8
set -Eeuo pipefail

SCRIPT_NAME="ha-localtime-view"
SOURCE_ROOT="${SOURCE_ROOT:-/mnt/hdexterno/frigate/recordings}"
DEST_ROOT="${DEST_ROOT:-/mnt/hdexterno/Gravações CFTV}"
TZ_LOCAL="${TZ_LOCAL:-America/Fortaleza}"
SOURCE_HOURS_ARE_UTC="${SOURCE_HOURS_ARE_UTC:-0}"
LOCK_FILE="${LOCK_FILE:-/var/lock/ha-localtime-view.lock}"
LOG_FILE="${LOG_FILE:-/var/log/ha-localtime-view.log}"
MIRROR_STDOUT=0
CLEAN_STALE=0
MAX_DAYS=0

show_help() {
  cat <<USAGE
Usage: ${SCRIPT_NAME}.sh [options]

Builds a lightweight local-time tree for HA media browser:
  DEST_ROOT/YYYY-MM-DD/HH/camNN -> symlink to SOURCE_ROOT/YYYY-MM-DD/HH/CAMERA

Options:
  --clean-stale        Remove stale links and empty dirs in DEST_ROOT
  --max-days N         Process only last N UTC day folders from source (0 = all)
  --timezone TZ        Timezone used for remap (default: ${TZ_LOCAL})
  --stdout             Mirror logs to terminal
  --help, -h           Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean-stale)
      CLEAN_STALE=1
      ;;
    --max-days)
      MAX_DAYS="${2:-}"
      shift
      ;;
    --max-days=*)
      MAX_DAYS="${1#*=}"
      ;;
    --timezone)
      TZ_LOCAL="${2:-}"
      shift
      ;;
    --timezone=*)
      TZ_LOCAL="${1#*=}"
      ;;
    --stdout)
      MIRROR_STDOUT=1
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
  shift
done

if ! [[ "$MAX_DAYS" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] --max-days invalid: $MAX_DAYS" >&2
  exit 1
fi

SOURCE_ROOT="$(readlink -f "$SOURCE_ROOT" 2>/dev/null || printf '%s' "$SOURCE_ROOT")"
mkdir -p "$DEST_ROOT"

if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || ! (: >>"$LOG_FILE") 2>/dev/null; then
  LOG_FILE="${DEST_ROOT}/.work/ha-localtime-view.log"
  mkdir -p "$(dirname "$LOG_FILE")"
  : >>"$LOG_FILE"
fi

log() {
  local msg
  msg="[$(date -Is)] [${SCRIPT_NAME}] $*"
  echo "$msg" >>"$LOG_FILE"
  if [[ "$MIRROR_STDOUT" == "1" || -t 1 ]]; then
    echo "$msg"
  fi
}

# Keep lexical order in HA by using 24h padded labels: 00..23.
hour_label_from_24() {
  local hour24="$1"
  printf '%02d' "$((10#$hour24))"
}

# Normalize camera folder names to sortable aliases (cam01..cam99).
camera_label_from_name() {
  local cam_name="$1"
  local cam_num

  if [[ "$cam_name" =~ (^|_)cam([0-9]+)$ ]]; then
    cam_num="$((10#${BASH_REMATCH[2]}))"
    printf 'cam%02d' "$cam_num"
    return 0
  fi

  printf '%s' "$cam_name"
}

if ! mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || ! (: >>"$LOCK_FILE") 2>/dev/null; then
  LOCK_FILE="${DEST_ROOT}/.work/ha-localtime-view.lock"
  mkdir -p "$(dirname "$LOCK_FILE")"
  : >>"$LOCK_FILE"
fi
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Lock busy, exiting."
  exit 0
fi

if [[ ! -d "$SOURCE_ROOT" ]]; then
  log "Source not found: $SOURCE_ROOT"
  exit 0
fi

created=0
updated=0
kept=0
skipped=0
stale_removed=0

log "Start: source=$SOURCE_ROOT dest=$DEST_ROOT tz=$TZ_LOCAL max_days=$MAX_DAYS clean_stale=$CLEAN_STALE"

DAY_FILTER_FILE=""
if (( MAX_DAYS > 0 )); then
  DAY_FILTER_FILE="$(mktemp)"
  find "$SOURCE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | grep -E '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$' \
    | sort | tail -n "$MAX_DAYS" > "$DAY_FILTER_FILE" || true
fi

while IFS= read -r cam_dir; do
  rel="${cam_dir#${SOURCE_ROOT}/}"
  IFS='/' read -r utc_day utc_hour cam extra <<< "$rel"

  [[ -z "${extra:-}" ]] || continue
  [[ "$utc_day" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [[ "$utc_hour" =~ ^[0-2][0-9]$ ]] || continue

  if [[ -n "$DAY_FILTER_FILE" ]]; then
    grep -qx "$utc_day" "$DAY_FILTER_FILE" || continue
  fi

  if [[ "$SOURCE_HOURS_ARE_UTC" == "1" ]]; then
    local_key="$(TZ="$TZ_LOCAL" date -d "${utc_day} ${utc_hour}:00:00 UTC" '+%Y-%m-%d|%H' 2>/dev/null || true)"
    [[ -n "$local_key" ]] || continue
    local_day="${local_key%|*}"
    local_hour="${local_key#*|}"
  else
    local_day="$utc_day"
    local_hour="$utc_hour"
  fi
  local_hour_label="$(hour_label_from_24 "$local_hour")"
  cam_label="$(camera_label_from_name "$cam")"

  out_dir="$DEST_ROOT/$local_day/$local_hour_label"
  link_path="$out_dir/$cam_label"
  mkdir -p "$out_dir"

  desired_target="$(realpath --relative-to="$out_dir" "$cam_dir" 2>/dev/null || true)"
  if [[ -z "$desired_target" ]]; then
    # Fallback: keep absolute if relative cannot be computed
    desired_target="$cam_dir"
  fi

  if [[ -L "$link_path" ]]; then
    current_target="$(readlink "$link_path" || true)"
    if [[ "$current_target" == "$desired_target" ]]; then
      ((kept+=1))
    else
      ln -sfn "$desired_target" "$link_path"
      ((updated+=1))
    fi
  elif [[ -e "$link_path" ]]; then
    ((skipped+=1))
    log "WARN skip existing non-symlink: $link_path"
  else
    ln -s "$desired_target" "$link_path"
    ((created+=1))
  fi

  # Remove legacy camera link name (e.g., Km386_cam10) if it points to same target.
  legacy_link="$out_dir/$cam"
  if [[ "$legacy_link" != "$link_path" && -L "$legacy_link" ]]; then
    legacy_target="$(readlink "$legacy_link" || true)"
    if [[ "$legacy_target" == "$desired_target" ]]; then
      rm -f "$legacy_link"
      ((stale_removed+=1))
    fi
  fi

done < <(find "$SOURCE_ROOT" -mindepth 3 -maxdepth 3 -type d | sort)

if [[ -n "$DAY_FILTER_FILE" ]]; then
  rm -f "$DAY_FILTER_FILE"
fi

if [[ "$CLEAN_STALE" == "1" ]]; then
  while IFS= read -r link; do
    resolved="$(readlink -f "$link" 2>/dev/null || true)"
    if [[ -z "$resolved" || ! -d "$resolved" ]]; then
      rm -f "$link"
      ((stale_removed+=1))
    fi
  done < <(find "$DEST_ROOT" -type l)

  # Drop old hour folders from previous naming scheme (00am..23pm).
  find "$DEST_ROOT" -mindepth 2 -maxdepth 2 -type d -regextype posix-extended \
    -regex '.*/[0-2][0-9](am|pm)' -exec rm -rf {} + 2>/dev/null || true

  find "$DEST_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi

log "Summary: created=$created updated=$updated kept=$kept skipped=$skipped stale_removed=$stale_removed"
