#!/bin/bash
# Checks every file git would publish for things that must never go public: account and job IDs (UUIDs),
# personal paths, email addresses, secrets, and hidden metadata in images and models. Prints each hit and
# exits 1 if there is any, then lists every image and 3D model file to be looked at by eye. Extra private
# patterns can live in tools/check-public.local.sh (git-ignored); it is loaded when present.
#   tools/check-public.sh
set -uo pipefail
cd "$(dirname "$0")/.."
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
git ls-files -co --exclude-standard | grep -v -E '^(tools/check-public\.sh|tools/check-public\.local\.sh|Resources/web/vendor/|package-lock\.json)' > "$LIST"
fail=0
check() {   # check <what> <grep options...>
  local what=$1; shift
  local out
  # Known safe: a workflow's "id-token: write" (the permission GitHub Pages needs, not a secret).
  out=$(tr '\n' '\0' < "$LIST" | xargs -0 grep -I -n "$@" 2>/dev/null |
    grep -v -E '^\.github/workflows/[^:]+\.ya?ml:[0-9]+: +id-token: write$')
  if [[ -n "$out" ]]; then echo "LEAK: $what"; echo "$out" | sed 's/^/    /' | cut -c1-160; fail=1; fi
}
check "UUIDs (job or workspace IDs)" -i -E -e '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
check "short job IDs"                -E -e '`[0-9a-f]{8}`'
check "personal paths"               -E -e '/Users/'
check "email addresses"              -E -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z.]{2,}'
check "secrets"                      -i -E -e 'api[_-]?key|secret|password|bearer |token'
bins=$(grep -E -i '\.(png|jpe?g|webp|gif|glb|gltf|fbx)$' "$LIST")
if [[ -n "$bins" ]]; then
  out=$(echo "$bins" | tr '\n' '\0' | xargs -0 grep -a -l -i -E -e '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -e 'hf-job-id' -e '/Users/' 2>/dev/null)
  if [[ -n "$out" ]]; then echo "LEAK: IDs or paths inside images and models"; echo "$out" | sed 's/^/    /'; fail=1; fi
  pyerr=$(mktemp)
  out=$(echo "$bins" | grep -i '\.png$' | tr '\n' '\0' | xargs -0 python3 -I -c '
import sys, struct
bad = {b"tEXt", b"iTXt", b"zTXt", b"eXIf", b"caBX"}
for f in sys.argv[1:]:
    d = open(f, "rb").read(); i = 8; found = []
    while i + 8 <= len(d):
        n, t = struct.unpack(">I4s", d[i:i+8])
        if t in bad: found.append(t.decode())
        i += 12 + n
    if found: print(f + ": " + " ".join(found))
' 2>"$pyerr")
  rc=$?
  if [[ $rc -ne 0 ]]; then echo "LEAK: could not read PNG chunks"; sed 's/^/    /' "$pyerr" | cut -c1-160; fail=1; fi
  rm -f "$pyerr"
  if [[ -n "$out" ]]; then echo "LEAK: metadata chunks in PNG files"; echo "$out" | sed 's/^/    /'; fail=1; fi
fi
if [[ -f tools/check-public.local.sh ]]; then
  # shellcheck disable=SC1091
  source tools/check-public.local.sh
  echo "private checks: loaded (tools/check-public.local.sh)"
else
  echo "private checks: none (tools/check-public.local.sh not found)"
fi
echo "Images and models to look at by eye:"
grep -E -i '\.(png|jpe?g|webp|gif|glb|gltf|fbx)$' "$LIST" | sed 's/^/    /'
if [[ $fail -eq 0 ]]; then echo "check-public: OK"; else echo "check-public: FAIL"; fi
exit $fail
