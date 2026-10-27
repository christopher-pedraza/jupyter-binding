#!/usr/bin/env bash
# jupyter-binding: run JupyterLab on a Slurm compute node and tunnel it to this machine.
#
# Submits a Slurm job over SSH, waits for it to start, forwards the Jupyter port to a
# local port and prints a URL (with token) for VS Code's "Select Kernel > Existing
# Jupyter Server" or a browser. Ctrl-C cancels the job and closes the tunnel.
#
# Settings come from (lowest to highest priority): built-in defaults, a config file,
# JB_* environment variables, command-line flags. Run with --help for details.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "bash >= 4.4 required (on macOS: brew install bash)." >&2
    exit 1
fi

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: bind-jupyter.sh [options] [-- extra sbatch args]

Connection
  --target USER@HOST     SSH target of the cluster login node (required)   [JB_TARGET]
  --ssh-key FILE         SSH identity file                                  [JB_SSH_KEY]
  --ssh-extra "OPTS"     extra options passed to ssh, e.g. "-J jumphost"    [JB_SSH_EXTRA]

Local side
  --local-port N         port to listen on locally (default 8080)           [JB_LOCAL_PORT]
  --bind-address ADDR    127.0.0.1 = this machine only (default),
                         0.0.0.0 = reachable from the LAN                   [JB_BIND_ADDRESS]

Job resources (omit to use cluster defaults)
  --gres SPEC            e.g. gpu:v100:1 (empty = no GPU)                   [JB_GRES]
  --time HH:MM:SS        wall time (default 02:00:00)                       [JB_TIME]
  --mem SIZE             e.g. 32G                                           [JB_MEM]
  --cpus N               CPUs per task                                      [JB_CPUS]
  --partition NAME                                                          [JB_PARTITION]
  --account NAME                                                            [JB_ACCOUNT]
  --job-name NAME        (default jupyter_binding)                          [JB_JOB_NAME]

Environment on the compute node
  --conda-env NAME       conda environment to activate                      [JB_CONDA_ENV]
  --setup-cmd "CMD"      any shell code run before Jupyter starts, e.g.
                         "module load python; source ~/venv/bin/activate"   [JB_SETUP_CMD]
  --jupyter-cmd "CMD"    default "jupyter lab"                              [JB_JUPYTER_CMD]

Other
  --config FILE          config file (KEY=VALUE shell syntax, see
                         jupyter-binding.env.example). Default: first found of
                         <script dir>/jupyter-binding.env,
                         ~/.config/jupyter-binding/config.env               [JB_CONFIG]
  --poll-secs N          queue polling interval while waiting (default 5)   [JB_POLL_SECS]
  --check-secs N         how often to check the running job (default 30);
                         one tiny squeue call over the open connection      [JB_CHECK_SECS]
  --warn-minutes N       print a warning (and ring the terminal bell) when N
                         minutes remain. 0 = off (default). Costs no extra
                         remote calls: uses the end time fetched at startup [JB_WARN_MINUTES]
  --dry-run              print the generated Slurm script and exit (no SSH)
  -h, --help             show this help

Anything after "--" is passed to sbatch verbatim, e.g.:
  bind-jupyter.sh --target me@login.hpc.edu -- --qos=debug --exclusive
EOF
}

# ---- settings: defaults < config file < JB_* env < flags --------------------------
VARS=(TARGET SSH_KEY SSH_EXTRA LOCAL_PORT BIND_ADDRESS GRES TIME MEM CPUS PARTITION
      ACCOUNT JOB_NAME CONDA_ENV SETUP_CMD JUPYTER_CMD POLL_SECS CHECK_SECS WARN_MINUTES)
declare -A FLAG_MAP=(
    [--target]=TARGET [--ssh-key]=SSH_KEY [--ssh-extra]=SSH_EXTRA
    [--local-port]=LOCAL_PORT [--bind-address]=BIND_ADDRESS [--gres]=GRES
    [--time]=TIME [--mem]=MEM [--cpus]=CPUS [--partition]=PARTITION
    [--account]=ACCOUNT [--job-name]=JOB_NAME [--conda-env]=CONDA_ENV
    [--setup-cmd]=SETUP_CMD [--jupyter-cmd]=JUPYTER_CMD [--poll-secs]=POLL_SECS
    [--check-secs]=CHECK_SECS [--warn-minutes]=WARN_MINUTES
    [--config]=CONFIG
)
declare -A FROM_ENV=() FROM_FLAGS=()
CONFIG_FILE="${JB_CONFIG:-}"
DRY_RUN=0
SBATCH_ARGS=()

for v in "${VARS[@]}"; do
    name=JB_$v
    if [[ -v $name ]]; then FROM_ENV[$v]=${!name}; fi
done

while (( $# )); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --dry-run) DRY_RUN=1; shift; continue ;;
        --) shift; SBATCH_ARGS=("$@"); break ;;
    esac
    flag=${1%%=*}
    key=${FLAG_MAP[$flag]-}
    [[ -n $key ]] || die "unknown option: $flag (see --help)"
    if [[ $1 == --*=* ]]; then
        val=${1#*=}; shift
    else
        (( $# >= 2 )) || die "$flag needs a value (see --help)"
        val=$2; shift 2
    fi
    if [[ $key == CONFIG ]]; then CONFIG_FILE=$val; else FROM_FLAGS[$key]=$val; fi
done

if [[ -z $CONFIG_FILE ]]; then
    for c in "$SCRIPT_DIR/jupyter-binding.env" \
             "${XDG_CONFIG_HOME:-$HOME/.config}/jupyter-binding/config.env"; do
        if [[ -f $c ]]; then CONFIG_FILE=$c; break; fi
    done
elif [[ ! -f $CONFIG_FILE ]]; then
    die "config file not found: $CONFIG_FILE"
fi
if [[ -n $CONFIG_FILE ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi
for v in "${!FROM_ENV[@]}"; do printf -v "JB_$v" %s "${FROM_ENV[$v]}"; done
for v in "${!FROM_FLAGS[@]}"; do printf -v "JB_$v" %s "${FROM_FLAGS[$v]}"; done

default() { if [[ ! -v $1 ]]; then printf -v "$1" %s "$2"; fi; }
default JB_TARGET ""
default JB_SSH_KEY ""
default JB_SSH_EXTRA ""
default JB_LOCAL_PORT 8080
default JB_BIND_ADDRESS 127.0.0.1
default JB_GRES ""
default JB_TIME 02:00:00
default JB_MEM ""
default JB_CPUS ""
default JB_PARTITION ""
default JB_ACCOUNT ""
default JB_JOB_NAME jupyter_binding
default JB_CONDA_ENV ""
default JB_SETUP_CMD ""
default JB_JUPYTER_CMD "jupyter lab"
default JB_POLL_SECS 5
default JB_CHECK_SECS 30
default JB_WARN_MINUTES 0

# Values are interpolated into #SBATCH lines and ssh arguments: keep them boring.
for v in GRES TIME MEM CPUS PARTITION ACCOUNT JOB_NAME; do
    name=JB_$v
    [[ ${!name} =~ ^[A-Za-z0-9_.:,+=/-]*$ ]] || die "invalid characters in $name"
done
[[ $JB_LOCAL_PORT =~ ^[0-9]+$ && $JB_POLL_SECS =~ ^[0-9]+$ && $JB_CHECK_SECS =~ ^[1-9][0-9]*$ \
   && $JB_WARN_MINUTES =~ ^[0-9]+$ ]] || die "port, poll/check seconds and warn minutes must be numeric"
[[ $JB_BIND_ADDRESS =~ ^[0-9A-Za-z.:-]+$ ]] || die "invalid JB_BIND_ADDRESS"

# ---- the Slurm job script ---------------------------------------------------------
make_job_script() {
    echo '#!/bin/bash'
    echo "#SBATCH --job-name=$JB_JOB_NAME"
    echo "#SBATCH --time=$JB_TIME"
    [[ -z $JB_GRES ]]      || echo "#SBATCH --gres=$JB_GRES"
    [[ -z $JB_MEM ]]       || echo "#SBATCH --mem=$JB_MEM"
    [[ -z $JB_CPUS ]]      || echo "#SBATCH --cpus-per-task=$JB_CPUS"
    [[ -z $JB_PARTITION ]] || echo "#SBATCH --partition=$JB_PARTITION"
    [[ -z $JB_ACCOUNT ]]   || echo "#SBATCH --account=$JB_ACCOUNT"
    # --output is set on the sbatch command line (needs $HOME expanded remotely).
    printf 'JB_CONDA_ENV=%q\nJB_SETUP_CMD=%q\nJB_JUPYTER_CMD=%q\n' \
        "$JB_CONDA_ENV" "$JB_SETUP_CMD" "$JB_JUPYTER_CMD"
    cat <<'BODY'

umask 077
STATE="$HOME/.jupyter_binding"
READY="$STATE/$SLURM_JOB_ID.ready"
LOG="$STATE/$SLURM_JOB_ID.jupyter.log"
mkdir -p "$STATE"

# .bashrc often returns early in non-interactive shells, so also init conda directly.
# shellcheck disable=SC1090
source ~/.bashrc 2>/dev/null || true
if [[ -n $JB_CONDA_ENV ]]; then
    if command -v conda >/dev/null 2>&1; then eval "$(conda shell.bash hook)"; fi
    conda activate "$JB_CONDA_ENV" || { echo "conda activate $JB_CONDA_ENV failed" >&2; exit 1; }
fi
if [[ -n $JB_SETUP_CMD ]]; then
    eval "$JB_SETUP_CMD" || { echo "setup command failed: $JB_SETUP_CMD" >&2; exit 1; }
fi

set -u   # only after env setup: conda/module scripts reference unset variables

# shellcheck disable=SC2086
command -v ${JB_JUPYTER_CMD%% *} >/dev/null 2>&1 \
    || { echo "'${JB_JUPYTER_CMD%% *}' not found on the compute node" >&2; exit 1; }

# The node is shared: pick a free random port, and make our own token.
PORT=""
for _ in $(seq 1 100); do
    p=$(( 20000 + RANDOM % 40000 ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT=$p; break; fi
done
[[ -n $PORT ]] || { echo "no free port found" >&2; exit 1; }
JUPYTER_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
export JUPYTER_TOKEN
NODE=$(hostname -f 2>/dev/null || hostname)

# port_retries=0: fail instead of silently moving to another port.
# shellcheck disable=SC2086
$JB_JUPYTER_CMD --no-browser --ip=0.0.0.0 --port="$PORT" --ServerApp.port_retries=0 \
    > "$LOG" 2>&1 &
JUPYTER_PID=$!

for _ in $(seq 1 90); do
    kill -0 "$JUPYTER_PID" 2>/dev/null || { echo "jupyter exited early:" >&2; tail -n 20 "$LOG" >&2; exit 1; }
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
    sleep 2
done

echo "$NODE $PORT $JUPYTER_TOKEN" > "$READY"

trap 'rm -f "$READY"; kill "$JUPYTER_PID" 2>/dev/null' EXIT TERM
wait "$JUPYTER_PID"
BODY
}

if (( DRY_RUN )); then
    make_job_script
    exit 0
fi

[[ -n $JB_TARGET ]] || die "no SSH target. Use --target USER@HOST or set JB_TARGET (see --help)."
[[ $JB_TARGET =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$ ]] || die "invalid target: $JB_TARGET"

# ---- SSH plumbing -----------------------------------------------------------------
CTL="$(mktemp -u "${XDG_RUNTIME_DIR:-/tmp}/jupyter-binding.XXXXXX")"
TARGET=$JB_TARGET
JOBID=""

# ControlMaster=auto: if the shared connection dies, the next call reopens one
# (silent with an SSH key). One login per run, then everything reuses it.
read -ra SSH_EXTRA_ARR <<< "$JB_SSH_EXTRA"
SSH_OPTS=(-S "$CTL" -o ControlMaster=auto -o ControlPersist=30m
          -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ConnectTimeout=20)
if [[ -n $JB_SSH_KEY ]]; then SSH_OPTS+=(-i "$JB_SSH_KEY" -o IdentitiesOnly=yes); fi
SSH_OPTS+=("${SSH_EXTRA_ARR[@]}")
rssh() { ssh -T "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# Retries when the SSH connection itself fails (exit 255). Idempotent commands only.
rssh_retry() {
    local rc=0
    for _ in 1 2 3; do
        rssh "$@" && return 0 || rc=$?
        (( rc == 255 )) || return "$rc"
        sleep 3
    done
    return "$rc"
}

# (Re)create the local forward; reconnects first if the master connection is gone.
open_tunnel() {
    ssh "${SSH_OPTS[@]}" -O check "$TARGET" 2>/dev/null || rssh true
    ssh "${SSH_OPTS[@]}" -O forward \
        -L "${JB_BIND_ADDRESS}:${JB_LOCAL_PORT}:${NODE}:${PORT}" "$TARGET"
}

cleanup() {
    trap - EXIT INT TERM
    echo
    if [[ -n $JOBID ]]; then
        echo "Cancelling job $JOBID..."
        rssh "scancel $JOBID; rm -f ~/.jupyter_binding/$JOBID.ready" 2>/dev/null || true
    fi
    ssh "${SSH_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if (exec 3<>"/dev/tcp/127.0.0.1/$JB_LOCAL_PORT") 2>/dev/null; then
    die "local port $JB_LOCAL_PORT is already in use (use --local-port)."
fi

echo "1. Connecting to $TARGET (authenticate once)..."
rssh true

echo "2. Submitting job..."
extra=""; if (( ${#SBATCH_ARGS[@]} )); then printf -v extra ' %q' "${SBATCH_ARGS[@]}"; fi
JOBID=$(make_job_script | rssh "mkdir -p ~/.jupyter_binding && sbatch --parsable \
    --output=\$HOME/.jupyter_binding/%j.slurm.log$extra")
JOBID=${JOBID%%;*}   # --parsable may append ";cluster"
[[ $JOBID =~ ^[0-9]+$ ]] || { JOBID=""; die "sbatch did not return a job id"; }
echo "   job $JOBID submitted, waiting for a node..."

# Sets STATE ("RUNNING node01", "COMPLETED", ... or "UNKNOWN") and READY ("node port token").
poll() {
    local out
    out=$(rssh_retry "s=\$(squeue -h -j $JOBID -o '%T %R' 2>/dev/null | head -n1)
                [ -z \"\$s\" ] && s=\$(sacct -n -X -P -j $JOBID -o State 2>/dev/null | head -n1)
                echo \"STATE \${s:-UNKNOWN}\"
                cat ~/.jupyter_binding/$JOBID.ready 2>/dev/null | sed 's/^/READY /'") || return 1
    STATE=$(sed -n 's/^STATE //p' <<< "$out")
    READY=$(sed -n 's/^READY //p' <<< "$out")
}

dump_logs() {
    rssh_retry "tail -n 30 ~/.jupyter_binding/$JOBID.slurm.log ~/.jupyter_binding/$JOBID.jupyter.log 2>&1" >&2 || true
}

NODE="" PORT="" TOKEN="" STATE="" READY="" last="" unknown=0
while [[ -z $TOKEN ]]; do
    sleep "$JB_POLL_SECS"
    poll || { echo "Lost SSH connection." >&2; exit 1; }

    if [[ $READY =~ ^([^ ]+)\ ([0-9]+)\ ([A-Za-z0-9]+)$ ]]; then
        NODE=${BASH_REMATCH[1]} PORT=${BASH_REMATCH[2]} TOKEN=${BASH_REMATCH[3]}
        break
    fi
    case $STATE in
        UNKNOWN*)  # squeue/sacct hiccup: tolerate a few in a row
            if (( ++unknown >= 6 )); then echo "Cannot get state of job $JOBID." >&2; exit 1; fi ;;
        FAILED*|CANCELLED*|TIMEOUT*|NODE_FAIL*|OUT_OF_MEMORY*|COMPLETED*|BOOT_FAIL*|DEADLINE*)
            echo "Job $JOBID ended ($STATE) before Jupyter came up. Logs:" >&2
            dump_logs; exit 1 ;;
        *) unknown=0
           [[ $STATE == "$last" ]] || { echo "   $STATE"; last=$STATE; } ;;
    esac
done

echo "3. Jupyter is up on $NODE:$PORT. Opening tunnel on port $JB_LOCAL_PORT..."
open_tunnel
rssh_retry "rm -f ~/.jupyter_binding/$JOBID.ready"

# Sets TIME_INFO (printed in the banner) from Slurm's own start/end/limit for the job.
# Uses the cluster's clock only to measure "elapsed" and "remaining", so clock or
# timezone differences between the cluster and this machine don't matter.
END_LOCAL=""; WARNED=0
fmt_ts() { date -d "@$1" '+%a %d %b %H:%M' 2>/dev/null || date -r "$1" '+%a %d %b %H:%M'; }
fmt_dur() { local m=$(( $1 / 60 )); printf '%dh %02dm' $(( m / 60 )) $(( m % 60 )); }
show_times() {
    local out start end now limit here
    TIME_INFO=""; END_LOCAL=""
    out=$(rssh_retry "r=\$(squeue -h -j $JOBID -o '%S|%e|%l' 2>/dev/null | head -n1)
                IFS='|' read -r s e l <<< \"\$r\"
                echo \"TIMES \$(date -d \"\$s\" +%s 2>/dev/null || echo 0) \$(date -d \"\$e\" +%s 2>/dev/null || echo 0) \$(date +%s) \${l:-unknown}\"") \
        || return 0
    read -r _ start end now limit <<< "$out"
    [[ $start =~ ^[0-9]+$ && $end =~ ^[0-9]+$ && $now =~ ^[0-9]+$ ]] || return 0
    if (( end > now && start > 0 )); then
        here=$(date +%s)
        END_LOCAL=$(( here + (end - now) ))
        TIME_INFO=$(printf 'Started : %s\nEnds    : %s  (limit %s)' \
            "$(fmt_ts $(( here - (now - start) )))" \
            "$(fmt_ts $(( here + (end - now) )))" "$limit")
    else
        TIME_INFO="Ends    : no end time reported (limit: $limit)"
    fi
}

show_times

# Terminal helpers. The countdown redraws one line in place, so clear it before other output.
clear_line() { if [[ -t 1 ]]; then printf '\r\033[K'; fi; }
countdown() {
    local left
    [[ -t 1 && -n $END_LOCAL ]] || return 0
    left=$(( END_LOCAL - $(date +%s) ))
    (( left > 0 )) || left=0
    printf '\r\033[K%s left - Ctrl-C to stop' "$(fmt_dur "$left")"
}

# Local-only check (no network): warn once when JB_WARN_MINUTES or less remain.
maybe_warn() {
    local left
    (( JB_WARN_MINUTES > 0 && WARNED == 0 )) || return 0
    [[ -n $END_LOCAL ]] || return 0
    left=$(( END_LOCAL - $(date +%s) ))
    (( left <= JB_WARN_MINUTES * 60 )) || return 0
    WARNED=1
    clear_line
    printf '\a'
    echo "!! Session ends at $(fmt_ts "$END_LOCAL") (~$(( (left + 59) / 60 )) min left). Save your work."
}

case $JB_BIND_ADDRESS in
    0.0.0.0)
        URL_HOST=$(ip route get 1.1.1.1 2>/dev/null \
            | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}') || true
        URL_HOST=${URL_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}
        URL_HOST=${URL_HOST:-$(ipconfig getifaddr en0 2>/dev/null || true)}
        URL_HOST=${URL_HOST:-127.0.0.1} ;;
    *) URL_HOST=$JB_BIND_ADDRESS ;;
esac

echo
echo "================================================="
echo "Jupyter URL (VS Code: Select Kernel > Existing Jupyter Server):"
printf '\033[1;33mhttp://%s:%s/?token=%s\033[0m\n' "$URL_HOST" "$JB_LOCAL_PORT" "$TOKEN"
[[ -z $TIME_INFO ]] || echo "$TIME_INFO"
echo "Keep this terminal open. Ctrl-C cancels the job and closes the tunnel."
echo "================================================="

# Hold the tunnel open until the job ends; re-create it if the connection drops.
# The local display (countdown, warning) ticks every 15 s at no cost; the job itself is
# only checked remotely every JB_CHECK_SECS.
unknown=0 next_check=$SECONDS
countdown
while sleep 15; do
    maybe_warn
    countdown
    (( SECONDS >= next_check )) || continue
    next_check=$(( SECONDS + JB_CHECK_SECS ))
    if ! ssh "${SSH_OPTS[@]}" -O check "$TARGET" 2>/dev/null; then
        clear_line; echo "SSH connection dropped, reconnecting..." >&2
        open_tunnel || { echo "Reconnect failed; will retry." >&2; continue; }
    fi
    poll || continue
    case $STATE in
        UNKNOWN*) if (( ++unknown >= 6 )); then clear_line; echo "Lost track of job $JOBID." >&2; break; fi ;;
        RUNNING*|PENDING*|COMPLETING*) unknown=0 ;;
        *) clear_line; echo "Job ended ($STATE)."; break ;;
    esac
done
