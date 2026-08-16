#!/usr/bin/env bash
#
# THE single place every macOS compile and link decision is written (CAP-7M1).
#
# SOURCED, never executed:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../tools/macos-buildenv.sh"
#
# WHY THIS FILE EXISTS. Before CAP-7M1 every macOS flag except one was written
# inline at its call site: `-WM` at twelve places, `-mmacosx-version-min` at
# four, `-arch` at four, `-Fl` / `-k-L` / `-k-lwebview` / `-k-rpath` /
# `-framework` at two to four more, with only `-k-no_fixup_chains` centralized.
# The deployment target was fetched from the lock four separate times and the
# arch -> mORMot-static-dir map existed twice. Adding a production adapter on
# top of that would have inherited twenty independent places for the floor to
# drift. One file, or the deployment target drifts across twenty.
#
# WHY IT LIVES UNDER tools/ AND NOT test/. tools/build-webview-dylib.sh is a
# BUILD tool: sourcing anything under test/ would invert the dependency and
# mean the dylib could not be built without the test tree present. That is the
# same reason build-webview-dylib.sh keeps its own copy of the deletion guard,
# and that duplication is deliberately left alone here - this file centralizes
# BUILD FLAGS, not working-directory policy.
#
# WHAT IS AND IS NOT A "macOS DECISION". Only flags whose value is a statement
# about the Apple toolchain or the ratified support floor belong here: -arch,
# -mmacosx-version-min, -WM, -Fl, -k*, -framework, -Wl,-rpath, -L, -l and the
# CMake OSX cache variables. Portable warning/optimisation switches (-Wall,
# -Werror, -O1, -Wno-type-limits) are shared conveniences, not platform
# decisions; they are provided here too so a caller writes one array instead of
# six words, but a caller adding one of those at a call site is not the defect
# this file exists to prevent.
#
# Provides:
#   pweb_macos_lock_read <file> <key>     strict `key = value` reader
#   pweb_macos_init [arch]                lock + host facts (no fpc needed)
#   pweb_macos_init_fpc                   fpc-derived facts (static dir, arch
#                                         link flags); requires fpc on PATH
#   pweb_macos_assert_macho <file> [...]  arch/minos/load-command assertions
#
# and the resolved values and flag arrays documented at each assignment below.
#
# It is committed executable like every other *.sh in this repository (the
# Linux job asserts the index mode of all of them), even though it is only
# ever sourced.

# shellcheck shell=bash

# Sourcing twice must not re-resolve or double-append anything.
if [ -n "${PWEB_MACOS_BUILDENV_LOADED:-}" ]; then
    return 0
fi
PWEB_MACOS_BUILDENV_LOADED=1

pweb_macos_tools_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PWEB_MACOS_REPO_ROOT="$(cd -- "${pweb_macos_tools_dir}/.." && pwd)"

PWEB_MACOS_LOCK_FILE="${PWEB_MACOS_REPO_ROOT}/webview.lock"
PWEB_MACOS_FPC_LOCK_FILE="${PWEB_MACOS_REPO_ROOT}/fpc.lock"

# Its own die, deliberately: every caller already has one with its own tag, and
# a helper that silently depended on the caller having defined `die` would fail
# with "command not found" at the exact moment it was trying to explain itself.
pweb_macos_die() { printf '[macos-buildenv] %s\n' "$*" >&2; exit 1; }

# --- the ONE strict lock reader ----------------------------------------------
#
# Behaviour is identical to the three hand-rolled copies it replaces (in
# test/cap7m/cap7m_common.sh, tools/build-webview-dylib.sh and
# tools/build-webview-so.sh's macOS-free sibling): one `key = value` per
# non-comment line, CR tolerated, duplicate key or missing key is a refusal.
pweb_macos_lock_read() {
    local file="$1" wanted="$2" line key value found='' result=''
    [ -f "${file}" ] || pweb_macos_die "lock file missing: ${file}"
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%$'\r'}"
        line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${line}" ] && continue
        case "${line}" in '#'*) continue ;; esac
        case "${line}" in
            *=*) ;;
            *) pweb_macos_die "$(basename "${file}") line is malformed: ${line}" ;;
        esac
        key="$(printf '%s' "${line%%=*}" | sed -e 's/[[:space:]]*$//')"
        value="$(printf '%s' "${line#*=}" | sed -e 's/^[[:space:]]*//')"
        if [ "${key}" = "${wanted}" ]; then
            [ -n "${found}" ] &&
                pweb_macos_die "$(basename "${file}") contains duplicate key '${wanted}'"
            found=1
            result="${value}"
        fi
    done < "${file}"
    [ -n "${found}" ] || pweb_macos_die "$(basename "${file}") has no '${wanted}' entry"
    printf '%s' "${result}"
}

# --- lock- and host-derived facts --------------------------------------------
#
# pweb_macos_init [expected-arch]
#
# Resolves everything that does NOT need a compiler. Idempotent. The optional
# argument is the architecture the caller believes it is building for; it must
# equal the host, because nothing in this project cross-builds and a fat
# artifact would let one architecture masquerade as proof of the other.
pweb_macos_init() {
    if [ -n "${PWEB_MACOS_INIT_DONE:-}" ]; then
        # The expected-architecture check is re-run on EVERY call, deliberately.
        # A caller that names an architecture is making an ASSERTION, and an
        # assertion skipped because someone else initialised first is not an
        # assertion at all - which is exactly the shape of the vacuous-guard
        # defect this shard is elsewhere busy removing.
        if [ -n "${1:-}" ] && [ "$1" != "${PWEB_MACOS_HOST_ARCH}" ]; then
            pweb_macos_die "job expects $1 but this host is ${PWEB_MACOS_HOST_ARCH}"
        fi
        return 0
    fi

    [ "$(uname -s)" = 'Darwin' ] ||
        pweb_macos_die "macOS only, host is $(uname -s)"

    PWEB_MACOS_HOST_ARCH="$(uname -m)"
    PWEB_MACOS_DEPLOYMENT_TARGET="$(pweb_macos_lock_read "${PWEB_MACOS_LOCK_FILE}" macos-deployment-target)"
    PWEB_MACOS_DYLIB="$(pweb_macos_lock_read "${PWEB_MACOS_LOCK_FILE}" macos-dylib)"
    PWEB_MACOS_DYLIB_VERSIONED="$(pweb_macos_lock_read "${PWEB_MACOS_LOCK_FILE}" macos-dylib-versioned)"
    PWEB_MACOS_DYLIB_REAL="$(pweb_macos_lock_read "${PWEB_MACOS_LOCK_FILE}" macos-dylib-real)"
    PWEB_MACOS_INSTALL_NAME_PREFIX="$(pweb_macos_lock_read "${PWEB_MACOS_LOCK_FILE}" macos-install-name-prefix)"
    PWEB_MACOS_ARCH_X64="$(pweb_macos_lock_read "${PWEB_MACOS_LOCK_FILE}" macos-arch-x64)"
    PWEB_MACOS_ARCH_ARM64="$(pweb_macos_lock_read "${PWEB_MACOS_LOCK_FILE}" macos-arch-arm64)"

    case "${PWEB_MACOS_HOST_ARCH}" in
        "${PWEB_MACOS_ARCH_X64}"|"${PWEB_MACOS_ARCH_ARM64}") ;;
        *) pweb_macos_die "unsupported host architecture '${PWEB_MACOS_HOST_ARCH}'" ;;
    esac
    if [ -n "${1:-}" ] && [ "$1" != "${PWEB_MACOS_HOST_ARCH}" ]; then
        pweb_macos_die "job expects $1 but this host is ${PWEB_MACOS_HOST_ARCH} (nothing here cross-builds)"
    fi

    # The staged webview artifacts and the compiled bridge object. Both are
    # named here so nothing else spells the paths.
    PWEB_MACOS_DIST="${PWEB_MACOS_REPO_ROOT}/build/cap7m/webview-dist"
    PWEB_MACOS_BRIDGE_DIR="${PWEB_MACOS_REPO_ROOT}/build/cap7m/bridge"
    PWEB_MACOS_BRIDGE_OBJ="${PWEB_MACOS_BRIDGE_DIR}/pweb_cocoa_bridge.o"
    PWEB_MACOS_BRIDGE_SRC="${PWEB_MACOS_REPO_ROOT}/src/platform/macos/pweb_cocoa_bridge.mm"

    # --- clang ---------------------------------------------------------------
    # THE macOS decisions, and nothing else. -arch pins one native slice;
    # -mmacosx-version-min pins the ratified floor on every compile so no
    # produced Mach-O ever inherits the runner SDK's idea of a minimum.
    PWEB_MACOS_CLANG_FLAGS=(
        -arch "${PWEB_MACOS_HOST_ARCH}"
        "-mmacosx-version-min=${PWEB_MACOS_DEPLOYMENT_TARGET}"
    )
    # Portable, shared, NOT platform decisions - see the header note.
    PWEB_MACOS_CLANG_WARNINGS=( -O1 -Wall -Wextra -Werror )
    # Objective-C++ translation units (the probe and the production bridge).
    # -DWEBVIEW_SHARED is MANDATORY and easy to miss: macros.h defines
    # WEBVIEW_API as `inline` for a C++ translation unit that declares neither
    # WEBVIEW_SHARED nor WEBVIEW_STATIC, so without it every one of the 17
    # prototypes becomes an inline function with no definition.
    # -fno-objc-arc: ownership of the +new return value, of the retained tasks
    # and of the response buffers is explicit here exactly as it is in Pascal.
    PWEB_MACOS_CLANGXX_OBJCXX_FLAGS=(
        -std=c++17 -fno-objc-arc -DWEBVIEW_SHARED
    )
    PWEB_MACOS_FRAMEWORKS=( -framework Cocoa -framework WebKit )
    PWEB_MACOS_CLANG_LINK_WEBVIEW=(
        -Wl,-rpath,@executable_path
        -L"${PWEB_MACOS_DIST}"
        -lwebview
    )
    PWEB_MACOS_CMAKE_FLAGS=(
        "-DCMAKE_OSX_ARCHITECTURES=${PWEB_MACOS_HOST_ARCH}"
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=${PWEB_MACOS_DEPLOYMENT_TARGET}"
    )

    PWEB_MACOS_INIT_DONE=1
}

# --- the aarch64-only Pascal link flag (MEASURED, run 31904189177) -----------
#
# Moved here from test/cap7m/cap7m_common.sh by CAP-7M1, unchanged in
# behaviour: it was the ONE macOS flag that was already centralized, and the
# whole point of this file is that it stops being the only one.
#
# FPC 3.2.2 cannot link on aarch64-darwin at a deployment target of 12.0 or
# later. Measured on macos-15 (macOS 15.7.7, Xcode 16.4, Apple clang 17.0.0),
# linking the plain console test/core/abi_probe.pas:
#
#     ld: pointer not aligned in 'FPC_THREADVARTABLES'+0x4 (abi_probe.o)
#
# CAUSE: Apple turns on the chained-fixups format for every binary whose
# deployment target is macOS 12+. Chained fixups store the next-fixup offset
# inside the pointer word itself, so on arm64 the pointer data must be 8-byte
# aligned; FPC 3.2.2 emits FPC_THREADVARTABLES 4-byte aligned. Under the old
# ld64 that was a warning (FPC issue 31696, 2017); under ld_prime - the linker
# in every Xcode from 15 onward - it is a hard error. It is unconditional:
# FPC_THREADVARTABLES is RTL data emitted for every program, threads or not.
# It is also arm64-only, which is exactly why the x86_64 leg linked cleanly.
#
# (This is NOT Lazarus issue 41570, `ld` exit -11 on FPC 3.3.1 - a different
# bug with a different fix. Do not conflate the two when re-reading this.)
#
# THE FIX TAKEN: -no_fixup_chains, the remedy the linker's own message names.
# It reverts to classic rebase/bind opcodes, which every supported macOS
# loads, and it leaves -WM12.0 alone - so LC_BUILD_VERSION minos stays 12.0
# and the ratified floor survives intact.
#
# THE FIX DELIBERATELY NOT TAKEN: -WM11.0. Lowering the deployment target
# below the chained-fixups threshold is the better-sourced remedy for this
# exact FPC 3.2.2 error (MacPorts ticket 68368), but it CONTRADICTS the
# ratified floor. 12.0 was chosen because WebKit's "custom scheme handled
# origins should be considered secure" change first ships in the macOS 12
# branch, and that is the entire basis for pweb://app being a secure context.
#
# APPLIED TO aarch64 ONLY. x86_64 links cleanly without it, and passing a flag
# an architecture does not need would contaminate that architecture's
# measurement with a workaround for the other one's defect.
#
# CAVEAT, recorded rather than hidden: -no_fixup_chains is an ld_prime flag
# with no guaranteed lifetime. -ld_classic is NOT a fallback - deprecated in
# Xcode 16 and removed in Xcode 27 - so if this flag ever goes away the
# answer is a newer FPC, not an older linker.
#
# A space-separated STRING, not an array, so it expands to nothing at all when
# empty: macOS still ships bash 3.2, where "${arr[@]}" under `set -u` on an
# empty array is an error. The single member never contains whitespace.
PWEB_MACOS_FPC_ARCH_LINK_FLAGS=''

# pweb_macos_init_fpc
#
# Everything that needs the compiler on PATH: the arch-conditional link flag,
# the arch -> mORMot static directory map (which existed twice before), and
# the FPC flag arrays every Pascal compile and link uses. Idempotent.
pweb_macos_init_fpc() {
    if [ -n "${PWEB_MACOS_INIT_FPC_DONE:-}" ]; then
        return 0
    fi
    pweb_macos_init "${1:-}"

    command -v fpc >/dev/null 2>&1 || pweb_macos_die 'required tool not found: fpc'

    PWEB_MACOS_FPC_CPU="$(fpc -iTP | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "${PWEB_MACOS_FPC_CPU}" in
        x86_64)
            PWEB_MACOS_STATIC_DIR="${PWEB_MACOS_REPO_ROOT}/deps/mormot2/static/x86_64-darwin"
            PWEB_MACOS_FPC_ARCH_LINK_FLAGS=''
            ;;
        aarch64)
            PWEB_MACOS_STATIC_DIR="${PWEB_MACOS_REPO_ROOT}/deps/mormot2/static/aarch64-darwin"
            PWEB_MACOS_FPC_ARCH_LINK_FLAGS='-k-no_fixup_chains'
            printf '[macos-buildenv] aarch64 Pascal link: adding %s (chained fixups vs FPC_THREADVARTABLES alignment)\n' \
                "${PWEB_MACOS_FPC_ARCH_LINK_FLAGS}"
            ;;
        *) pweb_macos_die "unsupported FPC target CPU ${PWEB_MACOS_FPC_CPU}" ;;
    esac

    # -WM<version> is FPC's deployment target. Passed on EVERY compile, never
    # left to the SDK: an executable whose LC_BUILD_VERSION disagrees with the
    # dylib's is a support matrix nobody ratified.
    PWEB_MACOS_FPC_FLAGS=( "-WM${PWEB_MACOS_DEPLOYMENT_TARGET}" )

    # EVERY LINK ARRAY BELOW ENDS WITH ${PWEB_MACOS_FPC_ARCH_LINK_FLAGS},
    # UNQUOTED, AND THAT IS NOT A STYLE CHOICE.
    #
    # It is a space-separated STRING rather than an array precisely so that an
    # unquoted expansion contributes NO argument at all when it is empty:
    # macOS still ships bash 3.2, where "${arr[@]}" under `set -u` on an empty
    # array is an error. Its single member never contains whitespace.
    #
    # The first draft of this file set the variable and then wired it into
    # nothing, which meant every aarch64 Pascal link silently lost
    # -no_fixup_chains and died with the exact `ld: pointer not aligned in
    # 'FPC_THREADVARTABLES'+0x4` the 40-line block above documents. The
    # assertion at the end of this function exists so that cannot recur
    # quietly: on aarch64 every link array must CONTAIN the flag, checked, not
    # assumed.

    # A Pascal PROGRAM that needs only the mORMot Darwin statics (the URI
    # oracle references no webview symbol at all).
    # shellcheck disable=SC2206
    PWEB_MACOS_FPC_LINK_MORMOT=(
        "-Fl${PWEB_MACOS_STATIC_DIR}"
        ${PWEB_MACOS_FPC_ARCH_LINK_FLAGS}
    )

    # A Pascal PROGRAM that CALLS into the dylib, WITHOUT the explicit -l.
    # Used by exactly one caller: the `fpc -va` instrument that deliberately
    # withholds it in order to record what FPC puts on the link line unaided
    # (CAP7M_LINKLINE, constraint 11). It exists here rather than being
    # written inline at that call site so that the diagnostic and the real
    # link differ by ONE documented element instead of by whatever a caller
    # happened to retype.
    # shellcheck disable=SC2206
    PWEB_MACOS_FPC_LINK_WEBVIEW_UNAIDED=(
        "-Fl${PWEB_MACOS_STATIC_DIR}"
        "-Fl${PWEB_MACOS_DIST}"
        -k-rpath
        -k@executable_path
        ${PWEB_MACOS_FPC_ARCH_LINK_FLAGS}
    )

    # A Pascal PROGRAM that CALLS into the dylib.
    #
    # MEASURED, run 31909456486: without the explicit -k-L/-k-lwebview, every
    # FPC binary that actually REFERENCES a webview symbol fails to link with
    # "symbol(s) not found", while abi_probe - which references nothing -
    # links cleanly. `-Fl` is a search PATH only; something has to put the
    # library itself on the line. -lwebview resolves libwebview.dylib, whose
    # install name is @rpath/libwebview.0.12.dylib, so the resulting
    # LC_LOAD_DYLIB is the one the Mach-O gate already asserts.
    # shellcheck disable=SC2206
    PWEB_MACOS_FPC_LINK_WEBVIEW=(
        "-Fl${PWEB_MACOS_STATIC_DIR}"
        "-Fl${PWEB_MACOS_DIST}"
        -k-rpath
        -k@executable_path
        "-k-L${PWEB_MACOS_DIST}"
        -k-lwebview
        ${PWEB_MACOS_FPC_ARCH_LINK_FLAGS}
    )

    # A Pascal PROGRAM that also links the production Objective-C++ bridge:
    # the one compiled object, the two frameworks it needs and the C++/ObjC
    # runtimes clang++ would have supplied itself. There is no second dylib -
    # the bridge is an object file linked into each binary that uses it.
    # (It inherits the arch flag through LINK_WEBVIEW.)
    PWEB_MACOS_FPC_LINK_BRIDGE=(
        "${PWEB_MACOS_FPC_LINK_WEBVIEW[@]}"
        "-k${PWEB_MACOS_BRIDGE_OBJ}"
        -k-framework -kCocoa
        -k-framework -kWebKit
        -k-lc++
        -k-lobjc
    )

    # THE GATE. On aarch64 the flag is not optional and its absence is not a
    # style defect - it is a link failure on one architecture only, which is
    # exactly the shape of thing a two-architecture project discovers late.
    if [ "${PWEB_MACOS_FPC_CPU}" = 'aarch64' ]; then
        local _set _found
        for _set in FPC_LINK_MORMOT FPC_LINK_WEBVIEW_UNAIDED FPC_LINK_WEBVIEW \
                    FPC_LINK_BRIDGE; do
            _found=0
            case " $(eval "printf '%s ' \"\${PWEB_MACOS_${_set}[@]}\"")" in
                *' -k-no_fixup_chains '*) _found=1 ;;
            esac
            [ "${_found}" = '1' ] ||
                pweb_macos_die "PWEB_MACOS_${_set} does not carry -k-no_fixup_chains on aarch64 -- every Pascal link would fail with 'pointer not aligned in FPC_THREADVARTABLES'"
        done
        printf '[macos-buildenv] aarch64: -k-no_fixup_chains present in all 4 link sets\n'
    fi

    PWEB_MACOS_INIT_FPC_DONE=1
}

# --- the shared measurement record -------------------------------------------
#
# Appends one fact to build/cap7m/measurements.txt and echoes it. It lives
# here, beside the flags, for the same reason the lock reader does: a BUILD
# tool must be able to record a measurement without depending on the test
# tree, and two implementations of "append to the record" is one more than
# this shard can justify. test/cap7m/cap7m_common.sh's record_measurement
# delegates to it.
PWEB_MACOS_MEASUREMENTS="${PWEB_MACOS_REPO_ROOT}/build/cap7m/measurements.txt"

pweb_macos_record() {
    mkdir -p -- "$(dirname -- "${PWEB_MACOS_MEASUREMENTS}")"
    printf '%s\n' "$*" >> "${PWEB_MACOS_MEASUREMENTS}"
    printf '%s\n' "$*"
}

# --- pweb_macos_assert_macho -------------------------------------------------
#
#   pweb_macos_assert_macho <file> [--object] [--require-rpath] [--require-dylib]
#
# THE one place a produced Mach-O is inspected. Asserts, in order:
#
#   arch   exactly one slice, and it is the job's architecture. A universal
#          binary fails here: Universal 2 is deliberately not a CAP-7
#          requirement, and a fat artifact would let an arm64 run masquerade
#          as an x86_64 proof.
#   minos  LC_BUILD_VERSION minos, or LC_VERSION_MIN_MACOSX version on an
#          older toolchain, equals the ratified deployment target. The
#          fallback matters: FPC 3.2.2 is the oldest toolchain here and
#          therefore the likeliest to emit the old load command; without it
#          the read-back returns '' and the gate dies with "minos is ''",
#          which reads as a floor violation when the floor is in fact correct.
#          Absent entirely is fatal unless --object.
#   dylib  MEASURED (run 31905105454): Mach-O records an LC_LOAD_DYLIB only
#          when a symbol from that dylib is actually referenced - ELF's
#          --as-needed behaviour, unconditionally. So "carries a load command"
#          is a property of what a binary USES, not of what it was linked
#          against, and demanding it everywhere would assert a Linux property
#          that does not exist here. Wherever one EXISTS it must name
#          @rpath/<versioned dylib>; --require-dylib additionally makes its
#          absence fatal, for the binaries that genuinely call in.
#   rpath  --require-rpath asserts LC_RPATH @executable_path, i.e. that the
#          binary resolves the dylib from its own location and not from the
#          working directory or a DYLD_* hint.
#
# --object means "this is a relocatable .o": it carries no load commands and no
# rpath, so those two are not asked of it. It does NOT excuse the build
# version - acceptance says EVERY produced Mach-O carries minos 12.0, and the
# bridge object is the only artifact inspected this way, so tolerating an
# absent one would make that criterion unprovable exactly where it is hardest
# to see.
#
# Exports, for callers that need the MEASURED values rather than the ones they
# asked for:
#   PWEB_MACOS_MACHO_ARCH   the slice list lipo actually reported
#   PWEB_MACOS_MACHO_MINOS  the minimum the load command actually carries
#   PWEB_MACOS_MACHO_LOAD   the libwebview load command, or '' if there is none
#   PWEB_MACOS_MACHO_RPATH  '@executable_path' or ''
#   PWEB_MACOS_MACHO_FACT   the one-line record
# In a shard whose deliverable IS a set of measurements, a caller that records
# what it requested instead of what was observed has recorded nothing.
pweb_macos_assert_macho() {
    local file='' object=0 want_rpath=0 want_dylib=0 arg
    for arg in "$@"; do
        case "${arg}" in
            --object) object=1 ;;
            --require-rpath) want_rpath=1 ;;
            --require-dylib) want_dylib=1 ;;
            -*) pweb_macos_die "pweb_macos_assert_macho: unknown option ${arg}" ;;
            *) file="${arg}" ;;
        esac
    done
    [ -n "${file}" ] || pweb_macos_die 'pweb_macos_assert_macho: no file given'
    [ -f "${file}" ] || pweb_macos_die "expected Mach-O missing: ${file}"
    pweb_macos_init

    local slices minos loaded rpath name
    name="$(basename -- "${file}")"

    slices="$(lipo -archs "${file}" 2>/dev/null || printf '')"
    [ "${slices}" = "${PWEB_MACOS_HOST_ARCH}" ] ||
        pweb_macos_die "${file} carries slices '${slices}', expected exactly '${PWEB_MACOS_HOST_ARCH}'"

    minos="$(otool -l "${file}" |
        awk '/LC_BUILD_VERSION/ { b = 1 } b && /^ *minos / { print $2; exit }')"
    if [ -z "${minos}" ]; then
        minos="$(otool -l "${file}" |
            awk '/LC_VERSION_MIN_MACOSX/ { b = 1 } b && /^ *version / { print $2; exit }')"
    fi
    # Fatal whether or not this is an object file: see the --object note above.
    [ -n "${minos}" ] ||
        pweb_macos_die "${file} carries neither LC_BUILD_VERSION nor LC_VERSION_MIN_MACOSX -- its deployment target is whatever the SDK decided"
    # "12.0" and "12.0.0" are the same floor written two ways.
    case "${minos}" in
        "${PWEB_MACOS_DEPLOYMENT_TARGET}"|"${PWEB_MACOS_DEPLOYMENT_TARGET}".0) ;;
        *) pweb_macos_die "${file} minos is '${minos}', expected '${PWEB_MACOS_DEPLOYMENT_TARGET}'" ;;
    esac

    # `tail -n +2`, and it is load-bearing: otool -L prints the INSPECTED
    # FILE's own path as its first line. Without the skip, inspecting
    # libwebview.0.12.0.dylib itself matches /libwebview/ on line 1, `loaded`
    # becomes the local build-tree path with a trailing colon, and the
    # @rpath/* case falls through - failing the first macOS gate of both jobs
    # on a perfectly correct artifact.
    loaded="$(otool -L "${file}" 2>/dev/null | tail -n +2 |
        awk '/libwebview/ { print $1; exit }')"
    if [ -n "${loaded}" ]; then
        case "${loaded}" in
            @rpath/*"${PWEB_MACOS_DYLIB_VERSIONED}") ;;
            *) pweb_macos_die "${file} loads '${loaded}', expected @rpath/${PWEB_MACOS_DYLIB_VERSIONED}" ;;
        esac
    elif [ "${want_dylib}" = '1' ]; then
        pweb_macos_die "${file} records no libwebview load command -- it calls into the dylib, so the reference has gone missing"
    fi

    rpath="$(otool -l "${file}" 2>/dev/null |
        awk '/LC_RPATH/ { r = 1 } r && /^ *path / { print $2; r = 0 }' |
        grep -x '@executable_path' || true)"
    if [ "${want_rpath}" = '1' ] && [ "${rpath}" != '@executable_path' ]; then
        pweb_macos_die "${file} has no LC_RPATH @executable_path (CWD dependence)"
    fi

    # The MEASURED values, exported individually. A caller that wants to
    # record what the artifact actually is must not have to scrape it back out
    # of a human-readable string whose format could change under it.
    PWEB_MACOS_MACHO_ARCH="${slices}"
    PWEB_MACOS_MACHO_MINOS="${minos}"
    PWEB_MACOS_MACHO_LOAD="${loaded}"
    PWEB_MACOS_MACHO_RPATH="${rpath}"
    PWEB_MACOS_MACHO_FACT="CAP7M_MACHO binary=${name} arch=${slices} minos=${minos} references_dylib=$([ -n "${loaded}" ] && printf 'yes' || printf 'no') load=${loaded:-<none>} rpath=${rpath:-<none>}"
    printf '[macos-buildenv] %s\n' "${PWEB_MACOS_MACHO_FACT}"
}
