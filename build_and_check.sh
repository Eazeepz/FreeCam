#!/usr/bin/env bash
# Build and verify the FreeCamHelp native half, then stage the DLL.
#
# Run from the repo root:
#     bash modding/mods/FreeCam/build_and_check.sh
#
# Checks the three things that fail silently in game:
#   1. it compiles at all
#   2. the export is unmangled -- the loader resolves wml_mod_init with
#      GetProcAddress, so a C++-mangled export means the mod never loads and
#      there is no log line to explain it
#   3. the DLL imports KERNEL32 only, so a player without the VC++
#      redistributable still gets the mod instead of a silent load failure
#
# Stages into dist/mods/FreeCam/ but does not deploy into the game folder.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VCVARS="C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\VC\\Auxiliary\\Build\\vcvars64.bat"
# A native Windows path: the generated .bat is run by cmd, which does not
# understand $TMPDIR or /tmp and writes the .obj somewhere that does not exist.
OUT="${FREECAM_BUILD_DIR:-C:/Users/chris/AppData/Local/Temp/fchelp}"
DIST="$ROOT/dist/mods/FreeCam"

fail=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

mkdir -p "$OUT" "$DIST"

step "building"
cat > "$OUT.bat" <<BAT
@echo off
call "$VCVARS" >nul 2>&1
cd /d "$ROOT"
rem /LD builds a DLL; without it cl produces an exe and link fails with
rem "entry point must be defined" because there is no wml_mod_init.
cl /nologo /W3 /std:c++17 /O2 /EHsc /MT /GS- /LD /D_CRT_SECURE_NO_WARNINGS ^
   /I modding/include /Fo:"$OUT/dll_" /Fe:"$OUT/FreeCamHelp.dll" ^
   modding/mods/FreeCam/FreeCamHelp.cpp
exit /b %errorlevel%
BAT
if ! MSYS_NO_PATHCONV=1 "$OUT.bat"; then
  bad "compile failed"
  exit 1
fi
ok "compiled"

step "export"
# wml_mod_init must be exported unmangled, or the loader's GetProcAddress never
# finds it and the mod is skipped with nothing in the log to say why. This
# failed silently once: a C++-mangled export still shows up in a plain grep of
# the binary, so grep is not enough -- ask the linker what it actually exports.
cat > "$OUT/dump.bat" <<BAT
@echo off
call "$VCVARS" >nul 2>&1
dumpbin /nologo /exports "$OUT/FreeCamHelp.dll"
dumpbin /nologo /dependents "$OUT/FreeCamHelp.dll"
exit /b 0
BAT
MSYS_NO_PATHCONV=1 "$OUT/dump.bat" > "$OUT/dump.txt" 2>&1

if grep -qE '^ +1 +[0-9]+ [0-9A-F]{8} wml_mod_init$' "$OUT/dump.txt"; then
  ok "wml_mod_init is exported, unmangled"
else
  bad "wml_mod_init is not exported unmangled -- is it still extern \"C\" WML_EXPORT?"
  grep -E 'wml_mod_init|ordinal +hint' "$OUT/dump.txt" | sed 's/^/        /'
  exit 1
fi

step "imports"
# KERNEL32 only: a player without the VC++ redistributable should still get the
# mod rather than a silent load failure.
# $1, not $0: dumpbin indents these lines, and the indent defeats the
# anchored grep below, which then flags KERNEL32 itself as unexpected.
deps=$(awk '/Image has the following dependencies/{f=1;next} /Summary/{f=0} f && /\.dll/{print tolower($1)}' "$OUT/dump.txt" | tr -d '\r[:space:]' | sort -u)
extra=$(printf '%s\n' "$deps" | grep -v '^kernel32\.dll$' || true)
if [ -z "$deps" ]; then
  bad "could not read the dependency list"
elif [ -z "$extra" ]; then
  ok "imports KERNEL32 only"
else
  bad "unexpected imports: $(printf '%s' "$extra" | tr '\n' ' ')"
fi

step "staging"
cp -f "$OUT/FreeCamHelp.dll" "$DIST/FreeCamHelp.dll"
ok "staged into dist/mods/FreeCam/"

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf 'FAILED\n'
  exit 1
fi
printf 'all checks passed\n'