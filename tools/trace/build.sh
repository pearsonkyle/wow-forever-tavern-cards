#!/usr/bin/env bash
# Builds tools/trace/tavern-trace against jankcraft's headless engine sources (read-only).
#
#   JANKCRAFT=~/Programs/misc/wow/jankcraft bash tools/trace/build.sh
#
# Objects go to tools/trace/.build (gitignored); nothing is written inside jankcraft.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jank="${JANKCRAFT:-${HOME}/Programs/misc/wow/jankcraft}"
mod="${jank}/server/modules/mod-tavern-sim"
out="${here}/.build"
cxx="${CXX:-c++}"
flags=(-std=c++20 -O2 -w)
jobs_max="${JOBS:-8}"

[ -d "${mod}/src/tc" ] || { echo "build.sh: no engine at ${mod} (set JANKCRAFT)" >&2; exit 2; }
mkdir -p "${out}/obj"

objs=()
running=0
for src in "${mod}"/src/simcore/*.cpp "${mod}"/src/tc/*.cpp "${mod}"/src/tc/ai/*.cpp; do
  rel="${src#"${mod}/src/"}"
  obj="${out}/obj/${rel//\//__}.o"
  objs+=("${obj}")
  if [ ! -f "${obj}" ] || [ "${src}" -nt "${obj}" ]; then
    "${cxx}" "${flags[@]}" -I"${mod}/src" -c "${src}" -o "${obj}" &
    running=$((running + 1))
    if [ "${running}" -ge "${jobs_max}" ]; then wait; running=0; fi
  fi
done
wait

"${cxx}" "${flags[@]}" -I"${mod}/src" "${objs[@]}" "${here}/tavern_trace.cpp" -o "${here}/tavern-trace"
echo "build.sh: ${here}/tavern-trace (engine at $(git -C "${jank}" rev-parse --short HEAD 2>/dev/null || echo '?'))"
