#!/bin/sh
# wwand-ipa tests. They run against a wwand source checkout, the one the plugin
# is loaded into: WWAND_SRC (default ../wwand beside this repository).
#
# An overlay directory makes the plugin reachable the way the daemon reaches
# it, as wwand.plugins.ipa and wwand.ctl.ipa, next to wwand's own modules.

set -e

TESTDIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$TESTDIR")"
WWAND_SRC="${WWAND_SRC:-$REPO/../wwand}"
WWAND_SRC="$(cd "$WWAND_SRC" && pwd)"

if [ -x "$HOME/.local/bin/ucode" ]; then
	UCODE="$HOME/.local/bin/ucode"
	export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	MODPATH="$HOME/.local/lib/ucode/*.so"
else
	UCODE=ucode
	MODPATH="/usr/lib/ucode/*.so"
fi

OVL="$(mktemp -d)"
trap 'rm -rf "$OVL"' EXIT
mkdir "$OVL/wwand"
for f in "$WWAND_SRC"/src-ucode/*; do ln -s "$f" "$OVL/wwand/"; done
ln -s "$REPO/plugins" "$OVL/wwand/plugins"
ln -s "$REPO/ctl" "$OVL/wwand/ctl"

rc=0
for t in "$TESTDIR"/test_*.uc; do
	out=$(cd "$TESTDIR" && "$UCODE" -L "$MODPATH" -L "$WWAND_SRC/io/build-host/*.so" \
		-L "$OVL/*.uc" "$t" 2>&1) || true
	printf '%s\n' "$out"
	printf '%s\n' "$out" | grep -qE '^test_[a-z_]+: [0-9]+ checks, 0 failures$' || rc=1
done

exit $rc
