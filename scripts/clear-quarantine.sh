#!/bin/bash
# Remove only com.apple.quarantine (never other attributes) from every path in
# the given bundles; symlinks are handled as links (-s). Exit 1 if any remains.
set -uo pipefail
remaining=0; checked=0
for root in "$@"; do
  [ -e "$root" ] || { echo "missing: $root" >&2; exit 1; }
  while IFS= read -r -d '' f; do
    checked=$((checked+1))
    if [ -L "$f" ]; then flag=-s; else flag=; fi
    attrs=$(/usr/bin/xattr $flag "$f") || { echo "xattr read failed: $f" >&2; exit 1; }
    if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then
      # A concurrent cleaner may delete it first; the recheck below decides success.
      /usr/bin/xattr $flag -d com.apple.quarantine "$f" 2>/dev/null || true
    fi
    attrs=$(/usr/bin/xattr $flag "$f") || { echo "xattr read failed: $f" >&2; exit 1; }
    if printf '%s\n' "$attrs" | grep -qx com.apple.quarantine; then echo "quarantine remains: $f" >&2; remaining=$((remaining+1)); fi
  done < <(find "$root" \( -type d -o -type f -o -type l \) -print0)
done
[ "$remaining" -eq 0 ] || exit 1
echo "quarantine verified absent on $checked paths: $*"
