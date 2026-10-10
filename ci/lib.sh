#!/bin/bash
# shared by both CI tiers. sourced, never run.
#
# EVIDENCE. journald is the wrong home for a CI record. this box keeps
# SystemMaxUse=500M and is already over it, so the user journal rotates inside
# a day: the full tier failed on 2026-09-17 and by the time anyone looked there
# was nothing left to read, not even the line saying which step died. worse, the
# WITNESS line the repro tier prints is meant to be a durable record of every
# chain head this machine was served -- what docs/attestation.md leans on for
# the split-view gap it cannot close from inside the repo. a record that expires
# overnight is not a record. so every run also lands in a file nothing rotates.
#
# these are per-machine facts and never claims, so they live in the same place
# the repro tier already keeps its last-verified head: outside the repo.
ci_log_open() {
	CI_SELF=$(basename "$0")
	# resolved HERE, before any cd: both runners chdir into their throwaway
	# clone, and a $0 like ./xos-repro stops naming anything the moment they
	# do -- which would make ci_selfcheck below fail to open its own file and
	# read that as drift.
	CI_PATH=$(readlink -f "$0" 2>/dev/null) || CI_PATH=$0
	CI_LOGDIR=${XOS_CI_LOGDIR:-$HOME/.local/state/xos-ci}
	mkdir -p "$CI_LOGDIR" || return 0
	exec > >(tee -a "$CI_LOGDIR/$CI_SELF.log") 2>&1
	printf -- '--- %s %s ---\n' "$CI_SELF" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# a red CI nobody is told about is not a wall, it is a decoration. shout on the
# two channels that reach a headless box and a desktop alike, then let the
# caller exit -- systemd records the code, this records the reason.
ci_shout() {
	logger -t "${CI_SELF:-xos-ci}" "FAIL: $*" 2>/dev/null || true
	notify-send -u critical -a "${CI_SELF:-xos-ci}" "xos CI failed" "$*" 2>/dev/null || true
	echo "${CI_SELF:-xos-ci}: FAIL $*"
}

# the installed runner is a COPY of ci/, and a copy drifts in silence. this is
# not hypothetical: the full tier ran for days on a `--depth 1` clone that the
# repo had already fixed, and a shallow clone turns G52 into a permanent SKIP --
# the provenance check reporting "did not run" while the summary stayed green.
# the tree under test is already cloned right here, so compare and refuse. run
# from a tree, not from the clone, this is a no-op.
ci_selfcheck() {
	[ -f "ci/$CI_SELF" ] || return 0
	[ -f "${CI_PATH:-}" ] || return 0        # cannot find myself; not evidence of drift
	cmp -s "ci/$CI_SELF" "$CI_PATH" && return 0
	ci_shout "installed $CI_SELF differs from ci/$CI_SELF at $(git rev-parse --short HEAD) -- reinstall it, see ci/README.md"
	return 1
}

# ci_workdir PREFIX -- make and print a throwaway build dir on a DISK-backed
# filesystem, not tmpfs. a full build tree is ~15G; both tiers used to clone and
# build under /tmp, which is tmpfs on this box, so a compile ran the RAM disk
# out of space and died as a baffling "cryptsetup did not build" with no hint of
# the real cause. default to the on-disk cache both tiers already use (same dir
# xos-repro keeps its last-verified head in), and refuse UP FRONT when the
# chosen filesystem cannot hold a build -- a named precondition beats a mid-build
# ENOSPC. override the location with XOS_CI_WORK and the floor with XOS_CI_MIN_GIB.
# diagnostics go to stderr so `d=$(ci_workdir ...)` captures only the path.
ci_workdir() {
	local base min_gib avail_kb need_kb
	base=${XOS_CI_WORK:-$HOME/.cache/xos-ci}
	min_gib=${XOS_CI_MIN_GIB:-20}
	mkdir -p "$base" || { ci_shout "cannot create CI work dir $base" >&2; return 1; }
	avail_kb=$(df -Pk "$base" 2>/dev/null | awk 'NR==2{print $4}')
	case "$avail_kb" in ''|*[!0-9]*) ci_shout "cannot read free space at $base" >&2; return 1 ;; esac
	need_kb=$(( min_gib * 1024 * 1024 ))
	if [ "$avail_kb" -lt "$need_kb" ]; then
		ci_shout "only $(( avail_kb / 1048576 ))G free at $base, a full build needs ${min_gib}G -- free space, or point XOS_CI_WORK at a bigger disk (XOS_CI_MIN_GIB to lower the floor)" >&2
		return 1
	fi
	mktemp -d "$base/$1.XXXXXX"
}
