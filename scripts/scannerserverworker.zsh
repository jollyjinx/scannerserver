#!/bin/zsh

set -u

readonly LAUNCHD_LABEL="eu.jinx.scannerserver-worker"
readonly LOGIN_ARGUMENT="--login"
readonly SCRIPT_PATH="${0:A}"
readonly COMMAND_NAME="${0:t}"
readonly USER_HOME="${HOME:-/Users/Shared}"
readonly HOST_UID="$UID"
readonly HOST_GID="$(/usr/bin/id -g)"
readonly CONTAINER_CONFIG_PATH="/home/scansnap/.config/scannerserver-worker"
readonly CONTAINER_WORKSPACE_PATH="/tmp/scannerserver-worker/jobs"

typeset detected_cpu_count
detected_cpu_count="$(/usr/sbin/sysctl -n hw.activecpu 2>/dev/null || print 4)"
if ! [[ "$detected_cpu_count" == <-> ]] || (( detected_cpu_count < 1 )); then
  detected_cpu_count=4
fi
if (( detected_cpu_count > 1 )); then
  (( detected_cpu_count -= 1 ))
fi

typeset worker_name="${SCANNERSERVER_WORKER_NAME:-}"
if [[ -z "$worker_name" ]]; then
  worker_name=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true)
fi
if [[ -z "$worker_name" ]]; then
  worker_name=$(/bin/hostname -s 2>/dev/null || true)
fi

readonly WORKER_NAME="$worker_name"
readonly SERVER_URL="${SCANNERSERVER_WORKER_SERVER_URL:-}"
readonly CONTAINER_NAME="${SCANNERSERVER_WORKER_CONTAINER_NAME:-scannerserver-worker}"
readonly CONTAINER_IMAGE="${SCANNERSERVER_WORKER_IMAGE:-ghcr.io/jollyjinx/scannerserver:latest}"
readonly WORKER_CPUS="${SCANNERSERVER_WORKER_CPUS:-$detected_cpu_count}"
readonly WORKER_MEMORY="${SCANNERSERVER_WORKER_MEMORY:-8G}"
readonly HOST_STATE_DIRECTORY="${SCANNERSERVER_WORKER_STATE_DIRECTORY:-$USER_HOME/Library/Application Support/scannerserver-worker/$WORKER_NAME}"
readonly CONTAINER_MOUNT="$HOST_STATE_DIRECTORY:$CONTAINER_CONFIG_PATH"
readonly LOCK_DIRECTORY="/tmp/$LAUNCHD_LABEL.lock"

typeset CONTAINER_BIN="${CONTAINER_BIN_OVERRIDE:-}"
if [[ -z "$CONTAINER_BIN" ]]; then
  for candidate in /usr/local/bin/container /opt/homebrew/bin/container; do
    if [[ -x "$candidate" ]]; then
      CONTAINER_BIN="$candidate"
      break
    fi
  done
fi
if [[ -z "$CONTAINER_BIN" ]]; then
  CONTAINER_BIN="$(whence -p container 2>/dev/null || true)"
fi

typeset dry_run=0

usage() {
  print -u2 "Usage: $COMMAND_NAME [--install|--login|--dry-run|--print-plist]"
  print -u2 ""
  print -u2 "Required environment:"
  print -u2 "  SCANNERSERVER_WORKER_SERVER_URL   Scanner server base URL"
  print -u2 ""
  print -u2 "Optional environment:"
  print -u2 "  SCANNERSERVER_WORKER_NAME         Display name; defaults to the Mac host name"
  print -u2 "  SCANNERSERVER_WORKER_CPUS         CPU allowance; defaults to active CPUs minus one"
  print -u2 "  SCANNERSERVER_WORKER_MEMORY       Container memory allowance; defaults to 8G"
  print -u2 "  SCANNERSERVER_WORKER_IMAGE        Worker image; defaults to the GHCR latest image"
  print -u2 "  SCANNERSERVER_WORKER_CONTAINER_NAME  Apple Container name"
  print -u2 "  SCANNERSERVER_WORKER_STATE_DIRECTORY Persistent identity directory"
  print -u2 "  CONTAINER_BIN_OVERRIDE            Path to Apple's container executable"
  print -u2 ""
  print -u2 "Actions:"
  print -u2 "  no option      Pull the image and recreate the worker"
  print -u2 "  --install      Install or refresh its login LaunchAgent"
  print -u2 "  --login        Start the container system and worker if needed"
  print -u2 "  --dry-run      Show refresh actions without running them"
  print -u2 "  --print-plist  Print the generated LaunchAgent"
}

log() {
  print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*"
}

require_container() {
  if [[ -z "$CONTAINER_BIN" || ! -x "$CONTAINER_BIN" ]]; then
    log "ERROR: Apple Container CLI is missing or not executable"
    return 1
  fi
}

require_configuration() {
  if [[ -z "$SERVER_URL" ]] || ! [[ "$SERVER_URL" =~ '^https?://[^[:space:]]+$' ]]; then
    log "ERROR: set SCANNERSERVER_WORKER_SERVER_URL to an http:// or https:// scanner server URL"
    return 1
  fi
  if [[ -z "$WORKER_NAME" ]] || ! [[ "$WORKER_NAME" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]]; then
    log "ERROR: worker name must contain only letters, numbers, dots, underscores, and hyphens"
    return 1
  fi
  if [[ -z "$CONTAINER_NAME" ]] || ! [[ "$CONTAINER_NAME" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]]; then
    log "ERROR: container name must contain only letters, numbers, dots, underscores, and hyphens"
    return 1
  fi
  if ! [[ "$WORKER_CPUS" == <-> ]] || (( WORKER_CPUS < 1 )); then
    log "ERROR: SCANNERSERVER_WORKER_CPUS must be a positive integer"
    return 1
  fi
  if [[ -z "$WORKER_MEMORY" || -z "$CONTAINER_IMAGE" || -z "$HOST_STATE_DIRECTORY" ]]; then
    log "ERROR: memory, image, and state-directory settings must not be empty"
    return 1
  fi
  if [[ "$HOST_STATE_DIRECTORY" == *:* ]]; then
    log "ERROR: the worker state directory must not contain a colon"
    return 1
  fi
}

typeset -a worker_run_arguments=(
  run
  -c "$WORKER_CPUS"
  -d
  --name "$CONTAINER_NAME"
  --user "$HOST_UID:$HOST_GID"
  --memory "$WORKER_MEMORY"
  --env SCAN_OUTPUT_DIR=/tmp/scannerserver-worker
  -v "$CONTAINER_MOUNT"
  "$CONTAINER_IMAGE"
  scannerserver-worker
  --workspace "$CONTAINER_WORKSPACE_PATH"
  --server "$SERVER_URL"
  --name "$WORKER_NAME"
)

container_exists() {
  "$CONTAINER_BIN" list --all --quiet 2>/dev/null | /usr/bin/grep -Fxq "$CONTAINER_NAME"
}

container_is_running() {
  "$CONTAINER_BIN" list --quiet 2>/dev/null | /usr/bin/grep -Fxq "$CONTAINER_NAME"
}

start_container_system() {
  local kernel_option="${1:---disable-kernel-install}"

  if (( dry_run )); then
    log "DRY RUN: $CONTAINER_BIN system start $kernel_option"
    return 0
  fi

  require_container || return 1
  "$CONTAINER_BIN" system start "$kernel_option"
}

ensure_host_state_directory() {
  if (( dry_run )); then
    log "DRY RUN: create host state directory $HOST_STATE_DIRECTORY"
    return 0
  fi

  /bin/mkdir -p "$HOST_STATE_DIRECTORY"
}

wait_for_scanner_server() {
  local attempt

  for attempt in {1..30}; do
    if /usr/bin/curl --silent --show-error --output /dev/null \
      --connect-timeout 2 --max-time 5 "$SERVER_URL"; then
      log "Scanner server is reachable at $SERVER_URL"
      return 0
    fi
    /bin/sleep 2
  done

  log "ERROR: scanner server is not reachable after 60 seconds: $SERVER_URL"
  return 1
}

start_worker_for_login() {
  require_configuration || return 1
  start_container_system --disable-kernel-install || {
    log "ERROR: could not start Apple Container; run 'container system start' manually once"
    return 1
  }

  wait_for_scanner_server || return 1

  if container_is_running; then
    log "Scanner worker $WORKER_NAME is already running"
    return 0
  fi

  if container_exists; then
    ensure_host_state_directory || return 1
    log "Starting existing scanner worker $WORKER_NAME"
    "$CONTAINER_BIN" start "$CONTAINER_NAME"
    return $?
  fi

  ensure_host_state_directory || return 1
  log "Creating scanner worker $WORKER_NAME from the locally available image"
  "$CONTAINER_BIN" "${worker_run_arguments[@]}"
}

recreate_worker() {
  require_configuration || return 1
  start_container_system --enable-kernel-install || return 1

  if (( dry_run )); then
    log "DRY RUN: $CONTAINER_BIN image pull $CONTAINER_IMAGE"
    log "DRY RUN: worker name is $WORKER_NAME"
    log "DRY RUN: state directory is $HOST_STATE_DIRECTORY"
    log "DRY RUN: bind mount is $CONTAINER_MOUNT"
    log "DRY RUN: delete $CONTAINER_NAME if it exists"
    log "DRY RUN: $CONTAINER_BIN ${worker_run_arguments[*]}"
    return 0
  fi

  log "Pulling $CONTAINER_IMAGE"
  "$CONTAINER_BIN" image pull "$CONTAINER_IMAGE" || return 1

  if container_exists; then
    log "Deleting existing scanner worker container"
    "$CONTAINER_BIN" delete --force "$CONTAINER_NAME" || return 1
  fi

  ensure_host_state_directory || return 1
  log "Creating scanner worker $WORKER_NAME"
  "$CONTAINER_BIN" "${worker_run_arguments[@]}"
}

render_launch_agent() {
  local plist_path="$1"

  /usr/bin/plutil -create xml1 "$plist_path" || return 1
  /usr/bin/plutil -insert Label -string "$LAUNCHD_LABEL" "$plist_path" || return 1
  /usr/bin/plutil -insert ProgramArguments -json '[]' "$plist_path" || return 1
  /usr/bin/plutil -insert ProgramArguments.0 -string "$SCRIPT_PATH" "$plist_path" || return 1
  /usr/bin/plutil -insert ProgramArguments.1 -string "$LOGIN_ARGUMENT" "$plist_path" || return 1
  /usr/bin/plutil -insert RunAtLoad -bool true "$plist_path" || return 1
  /usr/bin/plutil -insert KeepAlive -json '{}' "$plist_path" || return 1
  /usr/bin/plutil -insert KeepAlive.SuccessfulExit -bool false "$plist_path" || return 1
  /usr/bin/plutil -insert ProcessType -string Background "$plist_path" || return 1
  /usr/bin/plutil -insert StandardOutPath -string "$USER_HOME/Library/Logs/$LAUNCHD_LABEL.log" "$plist_path" || return 1
  /usr/bin/plutil -insert StandardErrorPath -string "$USER_HOME/Library/Logs/$LAUNCHD_LABEL.log" "$plist_path" || return 1
  /usr/bin/plutil -insert EnvironmentVariables -json '{}' "$plist_path" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.SCANNERSERVER_WORKER_SERVER_URL -string "$SERVER_URL" "$plist_path" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.SCANNERSERVER_WORKER_NAME -string "$WORKER_NAME" "$plist_path" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.SCANNERSERVER_WORKER_CPUS -string "$WORKER_CPUS" "$plist_path" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.SCANNERSERVER_WORKER_MEMORY -string "$WORKER_MEMORY" "$plist_path" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.SCANNERSERVER_WORKER_IMAGE -string "$CONTAINER_IMAGE" "$plist_path" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.SCANNERSERVER_WORKER_CONTAINER_NAME -string "$CONTAINER_NAME" "$plist_path" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.SCANNERSERVER_WORKER_STATE_DIRECTORY -string "$HOST_STATE_DIRECTORY" "$plist_path" || return 1
}

install_launch_agent() {
  require_configuration || return 1

  local launch_agents_directory="$USER_HOME/Library/LaunchAgents"
  local logs_directory="$USER_HOME/Library/Logs"
  local plist_path="$launch_agents_directory/$LAUNCHD_LABEL.plist"
  local temporary_plist

  temporary_plist=$(/usr/bin/mktemp "/tmp/$LAUNCHD_LABEL.XXXXXX") || return 1
  if ! render_launch_agent "$temporary_plist"; then
    /bin/rm -f "$temporary_plist"
    return 1
  fi
  if ! /usr/bin/plutil -lint "$temporary_plist" >/dev/null; then
    log "ERROR: generated LaunchAgent is invalid"
    /bin/rm -f "$temporary_plist"
    return 1
  fi

  /bin/mkdir -p "$launch_agents_directory" "$logs_directory" || {
    /bin/rm -f "$temporary_plist"
    return 1
  }
  /usr/bin/install -m 644 "$temporary_plist" "$plist_path" || {
    /bin/rm -f "$temporary_plist"
    return 1
  }
  /bin/rm -f "$temporary_plist"

  /bin/launchctl bootout "gui/$UID/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
  if /bin/launchctl bootstrap "gui/$UID" "$plist_path"; then
    log "Installed $LAUNCHD_LABEL to start the scanner worker at login"
  else
    log "ERROR: failed to load $plist_path"
    return 1
  fi
}

case "${1:-}" in
  "")
    if ! /bin/mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
      log "ERROR: another scanner worker refresh is already running"
      exit 1
    fi
    trap '/bin/rmdir "$LOCK_DIRECTORY"' EXIT
    recreate_worker
    ;;
  --dry-run)
    dry_run=1
    recreate_worker
    ;;
  --install)
    install_launch_agent
    ;;
  --login)
    start_worker_for_login
    ;;
  --print-plist)
    require_configuration || exit 1
    temporary_plist=$(/usr/bin/mktemp "/tmp/$LAUNCHD_LABEL.XXXXXX") || exit 1
    render_launch_agent "$temporary_plist" && /bin/cat "$temporary_plist"
    plist_status=$?
    /bin/rm -f "$temporary_plist"
    exit $plist_status
    ;;
  --help|-h)
    usage
    ;;
  *)
    usage
    exit 64
    ;;
esac
