#!/bin/sh

# Durable ownership records and the shared cleanup path.

fleet_manifest_error=

fleet_manifest_fail() {
  fleet_manifest_error=$1
  return 1
}

fleet_expect() {
  [ "$1" = "$2" ] || fleet_manifest_fail "$3"
}

fleet_resolve_repository_identity() {
  identity_repo=$1
  fleet_resolved_common_dir=$(git -C "$identity_repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$fleet_resolved_common_dir" in
    /*) ;;
    *) fleet_resolved_common_dir="$identity_repo/$fleet_resolved_common_dir" ;;
  esac
  fleet_resolved_common_dir=$(CDPATH= cd -- "$fleet_resolved_common_dir" 2>/dev/null && pwd -P) || return 1
  fleet_resolved_repo_id=$(printf '%s' "$fleet_resolved_common_dir" | git -C "$identity_repo" hash-object --stdin 2>/dev/null) || return 1
  fleet_resolved_repo_id=$(printf '%s' "$fleet_resolved_repo_id" | cut -c 1-12)

  repo_name=${identity_repo##*/}
  fleet_resolved_repo_name=$(printf '%s' "$repo_name" | LC_ALL=C tr -cs '[:alnum:]_-' '-')
  fleet_resolved_repo_name=${fleet_resolved_repo_name#-}
  fleet_resolved_repo_name=${fleet_resolved_repo_name%-}
  [ -n "$fleet_resolved_repo_name" ] || fleet_resolved_repo_name=repository
}

fleet_write_manifest() {
  state_file=$1
  state_dir=${state_file%/*}
  state_tmp="$state_file.tmp.$$"

  if ! mkdir -p "$state_dir" || ! chmod 700 "$state_dir"; then
    return 1
  fi
  if ! printf '%s\n' \
    'version=1' \
    "agent=$2" \
    "resource=$3" \
    "repo=$4" \
    "git_common_dir=$5" \
    "repo_id=$6" \
    "session=$7" \
    "container=$8" \
    "worktree=$9" \
    "branch=${10}" > "$state_tmp"; then
    rm -f -- "$state_tmp"
    return 1
  fi
  if ! chmod 600 "$state_tmp" || ! mv -f -- "$state_tmp" "$state_file"; then
    rm -f -- "$state_tmp"
    return 1
  fi
}

fleet_load_manifest() {
  state_file=$1
  if [ ! -f "$state_file" ]; then
    fleet_manifest_fail 'manifest is not a regular file'
    return 1
  fi
  line_count=$(wc -l < "$state_file" | tr -d '[:space:]')
  if [ "$line_count" != 10 ]; then
    fleet_manifest_fail 'manifest must contain exactly ten fields'
    return 1
  fi

  fleet_version=$(sed -n '1s/^version=//p' "$state_file")
  fleet_agent=$(sed -n '2s/^agent=//p' "$state_file")
  fleet_resource=$(sed -n '3s/^resource=//p' "$state_file")
  fleet_repo=$(sed -n '4s/^repo=//p' "$state_file")
  fleet_common_dir=$(sed -n '5s/^git_common_dir=//p' "$state_file")
  fleet_repo_id=$(sed -n '6s/^repo_id=//p' "$state_file")
  fleet_session=$(sed -n '7s/^session=//p' "$state_file")
  fleet_container=$(sed -n '8s/^container=//p' "$state_file")
  fleet_worktree=$(sed -n '9s/^worktree=//p' "$state_file")
  fleet_branch=$(sed -n '10s/^branch=//p' "$state_file")

  [ "$fleet_version" = 1 ] \
    && [ -n "$fleet_agent" ] \
    && [ -n "$fleet_resource" ] \
    && [ -n "$fleet_repo" ] \
    && [ -n "$fleet_common_dir" ] \
    && [ -n "$fleet_repo_id" ] \
    && [ -n "$fleet_session" ] \
    && [ -n "$fleet_container" ] \
    && [ -n "$fleet_worktree" ] \
    && [ -n "$fleet_branch" ] \
    || fleet_manifest_fail 'manifest has a missing or invalid field'
}

fleet_validate_manifest() {
  state_file=$1
  fleet_load_manifest "$state_file" || return 1

  state_dir=${state_file%/*}
  worktree_root=${state_dir%/*}
  fleet_expect "${state_dir##*/}" .state 'manifest is not in a .state directory' || return 1
  fleet_expect "${state_file##*/}" "$fleet_resource" 'manifest filename does not match its resource' || return 1
  fleet_expect "$fleet_session" "$fleet_resource" 'session does not match its resource' || return 1
  fleet_expect "$fleet_container" "tmux-fleet-$fleet_resource" 'container does not match its resource' || return 1
  fleet_expect "$fleet_worktree" "$worktree_root/$fleet_resource" 'worktree is outside its worktree root' || return 1
  fleet_expect "$fleet_branch" "agent/$fleet_agent" 'branch does not match its agent' || return 1

  case "$fleet_agent" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*|'')
      fleet_manifest_fail 'invalid agent name'
      return 1
      ;;
  esac
  case "$fleet_repo_id" in
    *[!0123456789abcdef]*|'')
      fleet_manifest_fail 'invalid repository identifier'
      return 1
      ;;
  esac
  fleet_expect "${#fleet_repo_id}" 12 'invalid repository identifier length' || return 1

  resolved_repo=$(CDPATH= cd -- "$fleet_repo" 2>/dev/null && pwd -P) || {
    fleet_manifest_fail 'repository is unavailable'
    return 1
  }
  fleet_expect "$resolved_repo" "$fleet_repo" 'repository path is not canonical' || return 1

  fleet_resolve_repository_identity "$fleet_repo" || {
    fleet_manifest_fail 'could not resolve repository identity'
    return 1
  }
  fleet_expect "$fleet_resolved_common_dir" "$fleet_common_dir" 'Git common directory does not match' || return 1
  fleet_expect "$fleet_resolved_repo_id" "$fleet_repo_id" 'repository identifier does not match' || return 1
  fleet_expect "$fleet_resource" "$fleet_resolved_repo_name-$fleet_agent-$fleet_repo_id" \
    'resource name does not match repository and agent'
}

fleet_cleanup_manifest() {
  state_file=$1
  clean_live_session=${2:-no}

  if ! fleet_validate_manifest "$state_file"; then
    print "Retained '$state_file': $fleet_manifest_error."
    return 1
  fi
  if [ "$clean_live_session" != yes ] \
    && tmux has-session -t "=$fleet_session" 2>/dev/null; then
    print "Retained live agent '$fleet_session'."
    return 0
  fi

  command -v podman >/dev/null 2>&1 || {
    print "Retained '$fleet_resource': Podman is unavailable."
    return 1
  }
  if podman container exists "$fleet_container" >/dev/null 2>&1; then
    container_status=0
  else
    container_status=$?
  fi
  case "$container_status" in
    0)
      labels=$(podman container inspect --format \
        '{{ index .Config.Labels "io.tmux-fleet.managed" }}|{{ index .Config.Labels "io.tmux-fleet.resource" }}|{{ index .Config.Labels "io.tmux-fleet.repo-id" }}' \
        "$fleet_container" 2>/dev/null) || {
          print "Retained '$fleet_resource': could not inspect its container."
          return 1
        }
      if [ "$labels" != "true|$fleet_resource|$fleet_repo_id" ]; then
        print "Retained '$fleet_resource': container ownership labels do not match."
        return 1
      fi
      print "Removing container '$fleet_container'..."
      podman rm --force "$fleet_container" || {
        print 'Retained worktree and branch: container removal failed.'
        return 1
      }
      ;;
    1) ;;
    *)
      print "Retained '$fleet_resource': Podman could not check its container."
      return 1
      ;;
  esac

  worktree_list=$(git -C "$fleet_repo" worktree list --porcelain 2>/dev/null) || {
    print "Retained '$fleet_resource': could not list Git worktrees."
    return 1
  }
  if printf '%s\n' "$worktree_list" | grep -Fqx "worktree $fleet_worktree"; then
    registered_branch=$(printf '%s\n' "$worktree_list" | awk -v target="$fleet_worktree" '
      $1 == "worktree" { selected = (substr($0, 10) == target); next }
      selected && $1 == "branch" { print substr($0, 8); exit }
      selected && NF == 0 { exit }
    ')
    if [ "$registered_branch" != "refs/heads/$fleet_branch" ]; then
      print "Retained '$fleet_resource': registered worktree branch does not match."
      return 1
    fi
    print "Removing worktree '$fleet_worktree'..."
    git -C "$fleet_repo" worktree remove --force "$fleet_worktree" || {
      print "Retained branch '$fleet_branch': worktree removal failed."
      return 1
    }
  elif [ -e "$fleet_worktree" ] || [ -L "$fleet_worktree" ]; then
    print "Removing incomplete worktree '$fleet_worktree'..."
    rm -rf -- "$fleet_worktree" || {
      print "Retained branch '$fleet_branch': incomplete worktree removal failed."
      return 1
    }
  fi

  if git -C "$fleet_repo" show-ref --verify --quiet "refs/heads/$fleet_branch"; then
    print "Deleting branch '$fleet_branch'..."
    git -C "$fleet_repo" branch -D --quiet -- "$fleet_branch" || {
      print "Retained manifest '$state_file': branch removal failed."
      return 1
    }
  fi

  rm -f -- "$state_file" || {
    print "Resources were removed, but manifest '$state_file' could not be deleted."
    return 1
  }
  print "Cleaned agent '$fleet_resource'."
}
