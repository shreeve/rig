# pup-lib.sh: shared by pup.sh, pup-gates.sh and pup-base.sh (sourced,
# not run). Runs bash scripts on pup, the Linux test machine.
#
# pup's login shell is zsh, which reads `$x:r` and similar differently
# from bash, so nothing is ever handed to it as shell code: the script
# and each argument travel base64-encoded (a shell-safe alphabet) and
# remote bash decodes them.

PUP_HOST=${PUP_HOST:-pup}
PUP_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)   # the Mac's rig checkout
PUP_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)

pup_die() { echo "${0##*/}: $*" >&2; exit 125; }

pup_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# pup_bash SCRIPT [ARG...]: run SCRIPT with bash on pup, ARGs as "$@",
# streaming its output; returns its exit code (255 if ssh itself fails).
# The remote prelude puts Zig 0.17.0 and cpuq on PATH (no shell profile
# is changed) and decodes the arguments.
pup_bash() {
    local script=$1; shift
    local prelude='set -u
export PATH=$HOME/.local/zig-0.17.0:$HOME/.local/bin:$PATH
ROOT=$HOME/Data/Code; MAIN=$ROOT/rig; WTS=/zfs/rig/rig-wt   # worktrees on the ZFS pool, not the root disk
mkdir -p "$WTS"
# Packages that bin/rig builds outside the test runner go to the ZFS pool,
# not the shared root disk; entries unused for two days are pruned.
export XDG_CACHE_HOME=/zfs/rig/xdg-cache
mkdir -p "$XDG_CACHE_HOME/rig"
find "$XDG_CACHE_HOME/rig" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} + 2>/dev/null
a=(); for x in "$@"; do a+=("$(printf %s "${x#x}" | base64 -d)"); done
set -- "${a[@]}"
'
    local words=() x
    for x in "$@"; do words+=("x$(pup_b64 "$x")"); done   # x: an empty argument survives
    ssh "${PUP_SSH_OPTS[@]}" "$PUP_HOST" \
        "bash -c \"\$(printf %s $(pup_b64 "$prelude$script") | base64 -d)\" pup ${words[*]}"
}

# pup_push SRC DST: push a local commit or ref to pup's bare repo, by URL,
# so the Mac keeps no remote-tracking refs for pup.
PUP_URL=${PUP_URL:-ssh://$PUP_HOST/home/shreeve/Data/Code/rig.git}

pup_push() {
    git -C "$PUP_REPO" push --quiet --no-follow-tags --force "$PUP_URL" "$1:$2" ||
        pup_die "push of $1 to pup failed"
}
