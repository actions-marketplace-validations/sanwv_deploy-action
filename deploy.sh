#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'deploy-action: %s\n' "$*" >&2; exit 1; }
for cmd in bash ssh rsync base64 realpath; do command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"; done

workspace=$(cd -- "${GITHUB_WORKSPACE:-$PWD}" && pwd -P)
source_input=${INPUT_SOURCE:?source is required}
if [[ "$source_input" = /* ]]; then source_dir=$source_input; else source_dir=$workspace/$source_input; fi
[[ -d "$source_dir" ]] || fail "source directory does not exist: $source_input"
source_dir=$(cd -- "$source_dir" && pwd -P)
host=${INPUT_REMOTE_HOST:?remote_host is required}; user=${INPUT_REMOTE_USER:?remote_user is required}
port=${INPUT_REMOTE_PORT:-22}; target=${INPUT_TARGET:?target is required}; keep=${INPUT_RELEASES_TO_KEEP:-5}
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || fail 'remote_port must be between 1 and 65535'
[[ "$keep" =~ ^[0-9]+$ ]] && ((keep >= 1 && keep <= 100)) || fail 'releases_to_keep must be between 1 and 100'
[[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || fail 'remote_host contains unsupported characters'
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'remote_user contains unsupported characters'
[[ "$target" = /* && "$target" != / && "$target" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail 'target must be an absolute path containing only letters, digits, dot, underscore, slash, and hyphen'
[[ "$target" != *'/../'* && "$target" != */.. && "$target" != */./* && "$target" != */. ]] || fail 'target may not contain dot path components'

umask 077
tmpdir=$(mktemp -d)
cleanup() { rm -rf -- "$tmpdir"; }
trap cleanup EXIT
key_file=$tmpdir/id; known_file=$tmpdir/known_hosts
printf '%s\n' "${INPUT_SSH_PRIVATE_KEY:?ssh_private_key is required}" > "$key_file"
chmod 600 "$key_file"
ssh_opts=(-i "$key_file" -p "$port" -o BatchMode=yes -o ConnectTimeout=20)
if [[ -n "${INPUT_SSH_KNOWN_HOSTS:-}" ]]; then
  printf '%s\n' "$INPUT_SSH_KNOWN_HOSTS" > "$known_file"
  chmod 600 "$known_file"
  ssh_opts+=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_file")
  rsync_ssh="ssh -i $key_file -p $port -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_file -o ConnectTimeout=20"
else
  ssh_opts+=(-o StrictHostKeyChecking=accept-new)
  rsync_ssh="ssh -i $key_file -p $port -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"
fi
ssh_run() { ssh "${ssh_opts[@]}" "$user@$host" "$@"; }

upload_hook() {
  local name=$1 body=$2 path
  [[ -n "$body" ]] || { printf ''; return 0; }
  path="$target/.deploy-action-hook-$release_id-$name"
  printf '%s\n' "$body" > "$tmpdir/hook-$name"
  rsync -a -e "$rsync_ssh" -- "$tmpdir/hook-$name" "$user@$host:$path"
  printf '%s' "$path"
}

run_remote_hook() {
  local name=$1 hook_path=$2 workdir=$3 previous=$4 script
  [[ -n "$hook_path" ]] || return 0
  script=$(cat <<'REMOTE'
set -Eeuo pipefail
target=$1; id=$2; release_path=$3; previous=$4; hook=$5; workdir=$6; name=$7
[[ "$previous" != __STATIC_DEPLOY_EMPTY__ ]] || previous=''
cleanup_hook() { rm -f -- "$hook"; }
trap cleanup_hook EXIT
cd -- "$workdir"
export DEPLOY_TARGET="$target" DEPLOY_RELEASE_ID="$id" DEPLOY_RELEASE_PATH="$release_path" DEPLOY_PREVIOUS_RELEASE="$previous" DEPLOY_HOOK="$name"
bash -Eeuo pipefail -- "$hook"
REMOTE
)
  ssh_run bash -s -- "$target" "$release_id" "$target/releases/$release_id" "${previous:-__STATIC_DEPLOY_EMPTY__}" "$hook_path" "$workdir" "$name" <<< "$script"
}

declare -a types=() paths=() modes=() froms=() syncs=()
declare -A seen=()
line_no=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ((line_no+=1)); [[ -z "${line//[[:space:]]/}" ]] && continue
  [[ "$line" != *$'\r'* ]] || fail "shared_items line $line_no: carriage returns are not allowed"
  declare -A fields=()
  IFS=',' read -r -a pairs <<< "$line"
  for pair in "${pairs[@]}"; do
    [[ "$pair" == *=* ]] || fail "shared_items line $line_no: expected key=value"
    key=${pair%%=*}; value=${pair#*=}
    [[ -n "$key" && -n "$value" && "$value" != *=* ]] || fail "shared_items line $line_no: malformed key=value field"
    case "$key" in type|path|mode|from|sync) ;; *) fail "shared_items line $line_no: unknown field '$key'";; esac
    [[ -z "${fields[$key]+x}" ]] || fail "shared_items line $line_no: duplicate field '$key'"
    fields[$key]=$value
  done
  type=${fields[type]-}; path=${fields[path]-}; mode=${fields[mode]-}; from=${fields[from]-}; sync=${fields[sync]-never}
  [[ "$type" == directory || "$type" == file ]] || fail "shared_items line $line_no: type must be directory or file"
  [[ -n "$path" ]] || fail "shared_items line $line_no: path is required"
  [[ "$path" != .shared-copy && "$path" != .shared-copy/* ]] || fail "shared_items line $line_no: path is reserved for the deployment cache"
  for value in "$path"; do
    [[ "$value" != /* && "$value" != *$'\n'* && "$value" != *$'\t'* ]] || fail "shared_items line $line_no: paths must be safe relative paths"
    [[ "$value" != *'..'* && "$value" != '.' && "$value" != */./* && "$value" != ./* && "$value" != */. && "$value" != */../* && "$value" != ../* && "$value" != */.. ]] || fail "shared_items line $line_no: dot path components are not allowed"
    [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "shared_items line $line_no: path contains unsupported characters"
  done
  if [[ -n "$from" ]]; then
    [[ "$from" != /* && "$from" != *$'\n'* && "$from" != *$'\t'* && "$from" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "shared_items line $line_no: from must be a safe relative path"
    [[ "$from" != *'..'* && "$from" != '.' && "$from" != */./* && "$from" != ./* && "$from" != */. && "$from" != */../* && "$from" != ../* && "$from" != */.. ]] || fail "shared_items line $line_no: from may not contain dot path components"
  fi
  if [[ -n "$mode" ]]; then [[ "$mode" =~ ^[0-7]{3,4}$ ]] || fail "shared_items line $line_no: mode must be 3 or 4 octal digits"; fi
  if [[ "$type" == directory ]]; then
    [[ -z "$from" && -z "${fields[sync]+x}" ]] || fail "shared_items line $line_no: directory does not accept from or sync"
    sync=never
  else
    [[ "$sync" == never || "$sync" == if-missing || "$sync" == always ]] || fail "shared_items line $line_no: invalid sync mode"
    [[ "$sync" == never || -n "$from" ]] || fail "shared_items line $line_no: sync=$sync requires from"
    if [[ "$sync" != never ]]; then
      from_path=$workspace/$from
      [[ -f "$from_path" && ! -L "$from_path" ]] || fail "shared_items line $line_no: from must be a regular file inside GITHUB_WORKSPACE"
      from_real=$(cd -- "$(dirname -- "$from_path")" && pwd -P)/$(basename -- "$from_path")
      [[ "$from_real" == "$workspace"/* ]] || fail "shared_items line $line_no: from escapes GITHUB_WORKSPACE"
    fi
  fi
  [[ -z "${seen[$path]+x}" ]] || fail "shared_items line $line_no: duplicate path '$path'"
  for existing in "${paths[@]}"; do
    [[ "$path" != "$existing"/* && "$existing" != "$path"/* ]] || fail "shared_items line $line_no: shared paths may not be parent/child"
  done
  seen[$path]=1; types+=("$type"); paths+=("$path"); modes+=("$mode"); froms+=("$from"); syncs+=("$sync")
done <<< "${INPUT_SHARED_ITEMS:-}"

release_id="$(date -u +%Y%m%dT%H%M%SZ)-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
[[ "$release_id" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'generated release ID is invalid'
remote_records="$target/.deploy-action-shared-$release_id"
remote_cache="$target/shared/.shared-copy"
records=$tmpdir/shared.records
: > "$records"
for i in "${!paths[@]}"; do
  # Bash treats tab as IFS whitespace and collapses empty fields while reading.
  # Use a sentinel for the optional mode column so later fields stay aligned.
  printf '%s\t%s\t%s\t%s\t%s\n' "${types[$i]}" "${paths[$i]}" "${modes[$i]:-__STATIC_DEPLOY_EMPTY__}" "${syncs[$i]}" "$(printf '%s' "${froms[$i]}" | base64 -w0)" >> "$records"
done

activated=0
release_created=0
cleanup_release() {
  ((activated || !release_created)) && return 0
  local script
  script=$(cat <<'REMOTE'
set -Eeuo pipefail
target=$1; id=$2; release="$target/releases/$id"
active=$(readlink -f -- "$target/current" 2>/dev/null || true)
release_real=$(realpath -m -- "$release")
if [[ -d "$release" && ! -L "$release" && "$active" != "$release_real" ]]; then rm -rf -- "$release"; fi
rm -f -- "$target/.deploy-action-shared-$id"
REMOTE
)
  ssh_run bash -s -- "$target" "$release_id" <<< "$script" >/dev/null 2>&1 || true
}
trap 'cleanup_release; cleanup' EXIT

prepare_script=$(cat <<'REMOTE'
set -Eeuo pipefail
target=$1; id=$2
mkdir -p -- "$target/releases" "$target/shared"
[[ ! -e "$target/releases/$id" ]] || { echo 'release already exists' >&2; exit 1; }
if [[ -L "$target/current" ]]; then
  previous=$(realpath -e -- "$target/current")
  releases_root=$(realpath -e -- "$target/releases")
  [[ "$previous" == "$releases_root"/* && -d "$previous" ]] || { echo 'current does not point to a release directory' >&2; exit 1; }
elif [[ -e "$target/current" ]]; then
  echo 'current exists but is not a symlink' >&2; exit 1
else
  previous=''
fi
  cache="$target/shared/.shared-copy"
  [[ ! -L "$cache" ]] || { echo 'deployment cache may not be a symlink' >&2; exit 1; }
  [[ ! -e "$cache" || -d "$cache" ]] || { echo 'deployment cache is not a directory' >&2; exit 1; }
  mkdir -p -- "$cache"
printf '%s\n' "${previous:-}"
REMOTE
)
previous_release=$(ssh_run bash -s -- "$target" "$release_id" <<< "$prepare_script")
release_created=1
before_hook=$(upload_hook before "${INPUT_SCRIPT_BEFORE:-}")
run_remote_hook before "$before_hook" "$target" "$previous_release"
ssh_run mkdir -p -- "$target/releases/$release_id"
rsync_path="flock -x $target/.deploy.lock bash -c 'rsync \"\$@\" && cp -a -- \"$remote_cache/.\" \"$target/releases/$release_id/\"' deploy-rsync"
rsync -a --delete --checksum --compress --rsync-path="$rsync_path" -e "$rsync_ssh" -- "$source_dir/" "$user@$host:$remote_cache/"
rsync -a -e "$rsync_ssh" -- "$records" "$user@$host:$remote_records"

prepare_shared=$(cat <<'REMOTE'
set -Eeuo pipefail
target=$1; records=$2; shared="$target/shared"
[[ ! -L "$shared" ]] || { echo 'shared root may not be a symlink' >&2; exit 1; }
root=$(realpath -m -- "$shared")
while IFS=$'\t' read -r type path mode sync from_b64; do
  [[ "$mode" != __STATIC_DEPLOY_EMPTY__ ]] || mode=''
  [[ -n "$path" ]] || continue
  dest="$shared/$path"; parent=$(dirname -- "$dest")
  prospective=$(realpath -m -- "$parent")
  [[ "$prospective" == "$root" || "$prospective" == "$root"/* ]] || { echo "shared parent escapes shared root: $path" >&2; exit 1; }
  mkdir -p -- "$parent"
  resolved=$(realpath -e -- "$parent")
  [[ "$resolved" == "$root" || "$resolved" == "$root"/* ]] || { echo "shared parent escapes shared root: $path" >&2; exit 1; }
  [[ ! -L "$dest" ]] || { echo "shared target is a symlink: $path" >&2; exit 1; }
  if [[ "$type" == directory ]]; then
    [[ ! -e "$dest" || -d "$dest" ]] || { echo "shared target is not a directory: $path" >&2; exit 1; }
    mkdir -p -- "$dest"; [[ -z "$mode" ]] || chmod "$mode" -- "$dest"
  else
    [[ ! -e "$dest" || -f "$dest" ]] || { echo "shared target is not a regular file: $path" >&2; exit 1; }
    [[ ! -e "$dest" || -z "$mode" ]] || chmod "$mode" -- "$dest"
  fi
done < "$records"
REMOTE
)
ssh_run bash -s -- "$target" "$remote_records" <<< "$prepare_shared"

for i in "${!paths[@]}"; do
  [[ "${types[$i]}" == file && "${syncs[$i]}" != never ]] || continue
  path=${paths[$i]}; sync=${syncs[$i]}; from=${froms[$i]}; mode=${modes[$i]}
  remote_tmp="$target/shared/$(dirname -- "$path")/.deploy-action-$(basename -- "$path").${release_id}.tmp"
  if [[ "$sync" == if-missing ]]; then
    exists_script=$(cat <<'REMOTE'
set -Eeuo pipefail
if [[ -e "$1/shared/$2" ]]; then echo PRESENT; else echo MISSING; fi
REMOTE
)
    state=$(ssh_run bash -s -- "$target" "$path" <<< "$exists_script")
    [[ "$state" == PRESENT ]] && continue
  fi
  rsync -a -e "$rsync_ssh" -- "$workspace/$from" "$user@$host:$remote_tmp"
  finish_sync=$(cat <<'REMOTE'
set -Eeuo pipefail
target=$1; path=$2; tmp=$3; sync=$4; mode=$5; dest="$target/shared/$path"
[[ "$mode" != __STATIC_DEPLOY_EMPTY__ ]] || mode=''
[[ ! -L "$dest" ]] || { echo 'shared destination is a symlink' >&2; exit 1; }
if [[ "$sync" == if-missing && -e "$dest" ]]; then rm -f -- "$tmp"; exit 0; fi
mv -f -- "$tmp" "$dest"
[[ -z "$mode" ]] || chmod "$mode" -- "$dest"
REMOTE
)
  ssh_run bash -s -- "$target" "$path" "$remote_tmp" "$sync" "${mode:-__STATIC_DEPLOY_EMPTY__}" <<< "$finish_sync"
done

link_shared=$(cat <<'REMOTE'
set -Eeuo pipefail
target=$1; records=$2; shared="$target/shared"; root=$(realpath -e -- "$shared"); release="$target/releases/$3"
while IFS=$'\t' read -r type path mode sync from_b64; do
  [[ "$mode" != __STATIC_DEPLOY_EMPTY__ ]] || mode=''
  [[ -n "$path" ]] || continue
  dest="$shared/$path"; parent=$(dirname -- "$dest")
  prospective=$(realpath -m -- "$parent")
  [[ "$prospective" == "$root" || "$prospective" == "$root"/* ]] || { echo "shared link escapes shared root: $path" >&2; exit 1; }
  mkdir -p -- "$parent"
  resolved=$(realpath -e -- "$parent")
  [[ "$resolved" == "$root" || "$resolved" == "$root"/* ]] || { echo "shared link escapes shared root: $path" >&2; exit 1; }
  [[ ! -L "$dest" ]] || { echo "shared target is a symlink: $path" >&2; exit 1; }
  release_parent="$release/$(dirname -- "$path")"
  prospective_release_parent=$(realpath -m -- "$release_parent")
  [[ "$prospective_release_parent" == "$release" || "$prospective_release_parent" == "$release"/* ]] || { echo "release path parent escapes release: $path" >&2; exit 1; }
  mkdir -p -- "$release_parent"
  release_parent_real=$(realpath -e -- "$release_parent")
  [[ "$release_parent_real" == "$release" || "$release_parent_real" == "$release"/* ]] || { echo "release path parent escapes release: $path" >&2; exit 1; }
  if [[ "$type" == file && -e "$dest" && -n "$mode" ]]; then chmod "$mode" -- "$dest"; fi
  rm -rf -- "$release/$path"
  ln -s -- "$dest" "$release/$path"
done < "$records"
REMOTE
)
ssh_run bash -s -- "$target" "$remote_records" "$release_id" <<< "$link_shared"
before_activate_hook=$(upload_hook before-activate "${INPUT_SCRIPT_BEFORE_ACTIVATE:-}")
run_remote_hook before-activate "$before_activate_hook" "$target/releases/$release_id" "$previous_release"

finalize=$(cat <<'REMOTE'
set -Eeuo pipefail
target=$1; id=$2; keep=$3; records=$4; previous=$5; hook=$6
[[ "$previous" != __STATIC_DEPLOY_EMPTY__ ]] || previous=''
[[ "$hook" != __STATIC_DEPLOY_EMPTY__ ]] || hook=''
release="$target/releases/$id"
exec 9>"$target/.deploy.lock"
flock -x 9
if [[ -L "$target/current" ]]; then
  active=$(readlink -f -- "$target/current" 2>/dev/null || true)
else
  active=''
fi
[[ "$active" == "$previous" ]] || { echo 'current changed during deployment; refusing to activate this release' >&2; exit 1; }
link="$target/.current.$id"; ln -s -- "releases/$id" "$link"; mv -Tf -- "$link" "$target/current"
if [[ -n "$hook" ]]; then
  hook_failed=0
  (cd -- "$release" && DEPLOY_TARGET="$target" DEPLOY_RELEASE_ID="$id" DEPLOY_RELEASE_PATH="$release" DEPLOY_PREVIOUS_RELEASE="$previous" DEPLOY_HOOK=after bash -Eeuo pipefail -- "$hook") || hook_failed=1
  rm -f -- "$hook"
  if ((hook_failed)); then
    rollback="$target/.current.rollback.$id"
    if [[ -n "$previous" ]]; then
      ln -s -- "$previous" "$rollback"
      mv -Tf -- "$rollback" "$target/current"
    else
      rm -f -- "$target/current"
    fi
    echo 'post-activation script failed; current was rolled back' >&2
    exit 1
  fi
fi
current=$(readlink -f -- "$target/current")
mapfile -t old < <(find "$target/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | awk '{print $2}')
count=0
for dir in "${old[@]}"; do
  [[ "$dir" == "$current" ]] && continue
  ((count+=1)); ((count >= keep)) && rm -rf -- "$dir"
done
rm -f -- "$records"
REMOTE
)
after_hook=$(upload_hook after "${INPUT_SCRIPT_AFTER:-}")
ssh_run bash -s -- "$target" "$release_id" "$keep" "$remote_records" "${previous_release:-__STATIC_DEPLOY_EMPTY__}" "${after_hook:-__STATIC_DEPLOY_EMPTY__}" <<< "$finalize"
activated=1
trap cleanup EXIT
printf 'deploy-action: activated release %s\n' "$release_id"
