#!/usr/bin/env bash
# bc250-wgp-bisect.sh - crash-safe per-WGP bisection for the BC-250 40-CU unlock.
#
# Stock BC-250 ships with 24/40 CUs: WGP0-2 routed on every SE/SH row, while
# WGP3 (CU6,7) and WGP4 (CU8,9) are factory-disabled - 8 candidate pairs in all.
# Turning all 8 on at once ("enable all") can instantly black-screen the box if
# even one pair is defective, telling you nothing about which one.
#
# This script enables ONE candidate pair at a time on top of the stock 24-CU
# baseline, runs the compute verifier, then disables it again. A synced marker
# is written BEFORE each register write, so if a defective WGP hard-locks or
# black-screens the machine, the next run knows which pair was in flight and
# records it as defective instead of retrying it forever.
#
# All writes go through bc250-cu-live-manager.sh (umr, runtime, VOLATILE), so a
# hang is recovered by a simple power-cycle: the stock 24-CU config returns on
# reboot and you re-run "start" to continue from where it crashed.

set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIVE="${BC250_LIVE_MANAGER:-$DIR/bc250-cu-live-manager.sh}"
VERIFY="${BC250_CU_VERIFY:-$DIR/scripts/bc250-compute-verify.sh}"
STATEDIR="${BC250_WGP_BISECT_STATE:-/var/lib/bc250-wgp-bisect}"
RESULTS="$STATEDIR/results.tsv"
INFLIGHT="$STATEDIR/inflight"

# Verifier sizing (override via env). Matches the known-good quick run.
ELEMENTS="${BC250_WGP_BISECT_ELEMENTS:-16777216}"
PASSES="${BC250_WGP_BISECT_PASSES:-2}"
ITERS="${BC250_WGP_BISECT_ITERS:-64}"

# The 8 factory-disabled WGP pairs on a stock BC-250 (WGP3+WGP4 of each SE.SH).
CANDIDATES=(0.0.3 0.0.4 0.1.3 0.1.4 1.0.3 1.0.4 1.1.3 1.1.4)

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = "0" ] || die "must run as root (use sudo)"; }

usage() {
	cat <<EOF
Usage: sudo $0 start|status|reset

Commands:
  start   Bisect all factory-disabled WGP pairs one at a time, resuming after a
          crash. Re-run this after a power-cycle if a pair black-screened the box.
  status  Print recorded per-WGP results and the recommended stable config.
  reset   Clear bisection state and return the GPU to the stock 24-CU baseline.

Environment:
  BC250_WGP_BISECT_ELEMENTS=$ELEMENTS  PASSES=$PASSES  ITERS=$ITERS

Results: $RESULTS
EOF
}

recorded_status() {
	local pair="$1"
	[ -f "$RESULTS" ] || return 0
	awk -F'\t' -v p="$pair" '$1==p{s=$2} END{print s}' "$RESULTS"
}

record() {
	local pair="$1" status="$2" note="${3:-}"
	printf '%s\t%s\t%s\t%s\n' "$pair" "$status" "$note" "$(date -Iseconds)" >>"$RESULTS"
	sync
}

baseline_24() {
	# Force the stock 24-CU config: disable every candidate pair.
	"$LIVE" --yes disable-wgp "${CANDIDATES[@]}" >/dev/null 2>&1 || true
}

test_pair() {
	local pair="$1" rc=0

	echo "==> Testing WGP $pair (enabling on top of stock 24 CUs)..."
	# Crash marker BEFORE any register write. If the box dies here, the next
	# run reads this and records the pair as defective rather than retrying.
	echo "$pair" >"$INFLIGHT"
	sync

	if ! "$LIVE" --yes enable-wgp "$pair" >/dev/null; then
		record "$pair" "FAIL" "enable-wgp returned an error"
		rm -f "$INFLIGHT"; sync
		return
	fi
	sync

	set +e
	"$VERIFY" --elements "$ELEMENTS" --passes "$PASSES" --iters "$ITERS"
	rc=$?
	set -e

	"$LIVE" --yes disable-wgp "$pair" >/dev/null 2>&1 || true
	rm -f "$INFLIGHT"; sync

	case "$rc" in
		0) record "$pair" "PASS" "verifier clean"; echo "    PASS" ;;
		2) record "$pair" "FAIL" "compute mismatches"; echo "    FAIL (bad compute results)" ;;
		3) die "verifier could not run (missing build deps); fix then re-run" ;;
		*) record "$pair" "FAIL" "verifier rc=$rc"; echo "    FAIL (verifier rc=$rc)" ;;
	esac
}

summary() {
	[ -f "$RESULTS" ] || { echo "No results yet."; return; }
	local pair st good=() bad=()
	echo
	echo "Per-WGP bisection results:"
	printf '  %-9s %-6s %s\n' "WGP" "STATUS" "NOTE"
	for pair in "${CANDIDATES[@]}"; do
		st="$(recorded_status "$pair")"
		[ -n "$st" ] || st="(untested)"
		case "$st" in
			PASS) good+=("$pair") ;;
			FAIL|BAD) bad+=("$pair") ;;
		esac
		printf '  %-9s %-6s %s\n' "$pair" "$st" \
			"$(awk -F'\t' -v p="$pair" '$1==p{n=$3} END{print n}' "$RESULTS")"
	done
	echo
	echo "Stable extra pairs: ${good[*]:-none}   Defective/unstable: ${bad[*]:-none}"
	echo "Recommended max stable config: $((24 + ${#good[@]} * 2))/40 CUs"
	if [ "${#good[@]}" -gt 0 ]; then
		echo
		echo "To apply that config now (runtime, volatile):"
		echo "  sudo $LIVE --yes enable-wgp ${good[*]}"
		echo "To persist it across reboots via the live-manager boot service:"
		echo "  sudo $LIVE --yes enable-wgp ${good[*]}"
		echo "  sudo $LIVE write-service-table && sudo $LIVE install-service"
	fi
}

cmd="${1:-}"
case "$cmd" in
	start)
		need_root
		[ -x "$LIVE" ] || die "live manager not executable: $LIVE"
		[ -x "$VERIFY" ] || die "verifier not executable: $VERIFY"
		"$VERIFY" --check-deps >/dev/null || die "verifier build deps missing; install them first (glslang, gcc, vulkan-loader-devel)"
		mkdir -p "$STATEDIR"
		[ -f "$RESULTS" ] || printf '#pair\tstatus\tnote\ttime\n' >"$RESULTS"

		# Crash recovery: a pair was mid-test when the box went down.
		if [ -s "$INFLIGHT" ]; then
			crashed="$(cat "$INFLIGHT")"
			echo "Detected an interrupted test of WGP $crashed - it almost certainly"
			echo "hard-locked/black-screened the GPU. Recording it as defective and"
			echo "continuing with the remaining pairs."
			record "$crashed" "BAD" "hung/black-screened the machine"
			rm -f "$INFLIGHT"; sync
		fi

		baseline_24
		for pair in "${CANDIDATES[@]}"; do
			st="$(recorded_status "$pair")"
			if [ -n "$st" ]; then
				echo "Skipping WGP $pair (already recorded: $st)."
				continue
			fi
			test_pair "$pair"
		done
		baseline_24
		summary
		;;
	status)
		summary
		;;
	reset)
		need_root
		[ -x "$LIVE" ] && baseline_24
		rm -rf "$STATEDIR"
		echo "Cleared bisection state and restored the stock 24-CU baseline."
		;;
	-h|--help|"")
		usage
		;;
	*)
		die "unknown command: $cmd"
		;;
esac
