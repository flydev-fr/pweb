#!/usr/bin/env bash
# CAP-3U Currency return matrix, POSIX twin of run_currency.ps1.
#
# Builds test/cap3u/cap3u_currency.pas against the PRISTINE pinned mORMot and
# runs it. The program itself decides what gates: it reads
# test/cap3u/currency-expectations.tsv and fails only on a case the table
# declares `must_pass` for THIS target. Every other case is recorded.
#
# WHY IT RUNS HERE AT ALL. The 2026-09-08 pin move took upstream 790154af,
# which changed how mORMot's SHARED x64 CallMethod reads a Currency result -
# a Win64 fix applied to an asm block that SysV x64 also executes. Windows
# measured 5/5 after the move against 0/5 before it; Linux measured 1/5 after
# and 0/5 before, i.e. a defect that predates the move and that the move
# improves. macOS was never measured at all, on either ABI. This gate is how
# it gets measured, on the legs' own toolchains, instead of inferred.
#
# Writes: build/cap3u/currency-corpus.txt (written by the program) and a log.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
cd -- "${repo_root}"

die() { printf '[CAP-3U] %s\n' "$*" >&2; exit 1; }
step() { printf '\n[CAP-3U] === %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || die 'required tool not found: fpc'

for pre in test/cap3u/cap3u_currency.pas \
           test/cap3u/currency-expectations.tsv \
           test/security/pweb.test.reporoot.pas \
           deps/mormot2/src/core/mormot.core.interfaces.pas; do
    [ -f "${pre}" ] || die "missing precondition: ${pre}"
done

work="${repo_root}/build/cap3u"
mkdir -p -- "${work}"
corpus="${work}/currency-corpus.txt"
clog="${work}/currency-posix.log"
rm -f -- "${corpus}" "${clog}"

outdir="${work}/cur-bin"
unitdir="${work}/cur-fpc"
rm -rf -- "${outdir}" "${unitdir}"
mkdir -p -- "${outdir}" "${unitdir}"

mormot_units=(
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib
    -Fudeps/mormot2/src/crypt -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db
    -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest -Fudeps/mormot2/src/soa
)

os_name="$(uname -s)"
case "${os_name}" in
Linux)
    target='linux-x86_64'
    [ -d 'deps/mormot2/static/x86_64-linux' ] ||
        die 'pinned mORMot statics missing under deps/mormot2/static/x86_64-linux'
    step "compile cap3u_currency (${target})"
    fpc -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Futest/security "${mormot_units[@]}" \
        -Fldeps/mormot2/static/x86_64-linux \
        test/cap3u/cap3u_currency.pas ||
        die 'cap3u_currency.pas compile FAILED'
    ;;
Darwin)
    # shellcheck source=tools/macos-buildenv.sh
    . "${repo_root}/tools/macos-buildenv.sh"
    pweb_macos_init_fpc
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) target='macos-x86_64' ;;
        arm64) target='macos-arm64' ;;
        *) die "unsupported macOS architecture: ${arch}" ;;
    esac
    step "compile cap3u_currency (${target})"
    fpc -Sh -B -FU"${unitdir}" -FE"${outdir}" \
        -Futest/security "${mormot_units[@]}" \
        "${PWEB_MACOS_FPC_FLAGS[@]}" "${PWEB_MACOS_FPC_LINK_MORMOT[@]}" \
        test/cap3u/cap3u_currency.pas ||
        die 'cap3u_currency.pas compile FAILED'
    ;;
*)
    die "unsupported platform for this runner: ${os_name}"
    ;;
esac

exe="${outdir}/cap3u_currency"
[ -x "${exe}" ] || die "cap3u_currency was not produced at ${exe}"

# run from an unrelated working directory: the program resolves the
# expectation table and the corpus from its own image, never from the CWD
step "run the Currency return matrix (${target})"
set +e
( cd -- "$(mktemp -d)" && "${exe}" ) > "${clog}" 2>&1
code=$?
set -e
cat -- "${clog}"

[ -f "${corpus}" ] ||
    die "the currency corpus was not written -- see ${clog}"
grep -q "^target=${target}\$" -- "${corpus}" ||
    die "the corpus does not name ${target} -- see ${corpus}"
[ "${code}" -eq 0 ] ||
    die "CAP-3U Currency matrix FAILED on ${target} (exit ${code}) -- see ${clog}"
printf '[CAP-3U] Currency matrix verdict on %s: PASS\n' "${target}"
