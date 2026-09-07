# CAP-11A: ONE auto-close window for every GUI smoke, sized from a measurement.
#
# WHAT THE WINDOW IS. `PWEB_SMOKE_AUTOCLOSE_MS` tells a GUI example host to
# close itself after N milliseconds so a headless runner can run a windowed
# smoke unattended. The page reports its verdict through the SDK while the
# window is open; if the window closes first the host prints
# `FAIL: page/runtime verdict was not successful (state=0; 0=no report
# received)` and the smoke fails. The window is therefore a DEADLINE ON THE
# PAGE, and until this file it was the number 8000 typed into six places.
#
# ---------------------------------------------------------------------------
# THE MEASUREMENTS. This is not "longer because it flaked".
# ---------------------------------------------------------------------------
#
# 1. WHAT THE PAGE ACTUALLY NEEDS, measured on a dev host by sweeping this very
#    variable until the report stops landing - cold profile (the WebView2
#    user-data directory removed first) and warm, three hosts:
#
#      reactapp     PASS at 200 ms   (cold and warm)
#      pas2jsapp    PASS at 200 ms   (cold and warm)
#      releaseapp   state=0 at 200 ms, PASS at 300 ms   (cold and warm)
#
#    So the whole handshake - navigate over pweb://app, render, call through
#    the scheduler into mORMot, report - completes inside 300 ms when nothing
#    is contending, and a cold engine profile costs nothing measurable.
#
#    CORROBORATED BY A SECOND, INDEPENDENT MEASUREMENT. The observer now
#    timestamps the engine's first write into `Code Cache/js` - the moment
#    JavaScript was COMPILED - and a cold-profile CAP-5 run measured
#    `script_compiled_ms=253` (React) and `241` (Pas2JS). Two different
#    instruments, one sweeping the deadline from outside and one reading the
#    engine's own filesystem trace, agree on a couple of hundred milliseconds.
#
# 2. WHAT THE HOSTED RUNNER NEEDED, hosted run 34127608923, Windows leg. The
#    first attempt failed at the Pas2JS smoke with `state=0`; the four
#    `[cap11a] smoke observation` lines of that attempt were
#
#      assetsapp[folder]  engine_max=6 profile=true script_cache=true  samples=33
#      assetsapp[zip]     engine_max=4 profile=true script_cache=false samples=32
#      reactapp           engine_max=6 profile=true script_cache=true  samples=40
#      pas2jsapp          engine_max=5 profile=true script_cache=true  samples=36
#
#    - the last one immediately followed by the `state=0` line. At the
#    observer's 250 ms poll those are host lifetimes of about 8250, 8000,
#    10000 and 9000 ms against an 8000 ms window. `script_cache=true` means the
#    engine COMPILED JavaScript during the run: the page ran and its report did
#    not arrive in time.
#
# 3. WHY THE LIFETIME IS NOT THE THING TO SIZE FROM, which is the measurement
#    that matters most here. The re-run of the same job passed with
#    `elapsed_ms` of 9252, 9012, 8950, 8930 and 8857 - and the Pas2JS smoke
#    that FAILED lived about 9000 ms while the one that PASSED lived 9012 ms.
#    The React smoke that lived the LONGEST on the failing attempt (about
#    10000 ms) passed. Lifetime is window + teardown and it does not
#    discriminate at all; the difference is entirely INSIDE the window.
#
# ---------------------------------------------------------------------------
# THE SIZE, AND THE MARGIN, STATED
# ---------------------------------------------------------------------------
#
# The requirement is measured at <= 300 ms uncontended. On the hosted runner it
# is known only as a LOWER BOUND - it exceeded 8000 ms on the run that failed -
# so the hosted contention factor is measured at more than 26x and has no
# measured upper bound. The window is set to fifty times the measured 300 ms
# deadline:
#
#      15000 ms = 50 x 300 ms      (~1.9x the bound that was measured failing)
#
# The margin is deliberately stated as a multiple of a measurement rather than
# as "double it": if a later run fails at 15000 ms, the thing to look at is the
# contention factor, and the arithmetic above says what that factor would have
# to have been.
#
# WHAT IT COSTS. Every example host's auto-close thread is a plain
# `Sleep(window)` which the teardown then joins, so the window is a FLOOR on
# process lifetime, not a ceiling: each GUI smoke gains 7 s. The Windows leg
# runs eight of them (hello, jsbinding, mormotrpc, assetsapp x2, reactapp,
# pas2jsapp, releaseapp), so the leg gains about 56 s against a 135-minute
# budget.
#
# WHY THERE IS NO CLOSE-ON-REPORT, measured rather than assumed. A driver that
# could see the report arrive would not need the window at all. It cannot:
#
#   - MEASURED: a driver that starts the host with stdout redirected to a file
#     and polls that file every 100 ms sees nothing for the whole run - the
#     report line appears only after the process exits. FPC buffers `Output`
#     when it is not a console, and the examples never flush it.
#   - Even an observable report could not shorten the run, because the closer
#     thread is that `Sleep` and the teardown joins it before anything else.
#   - The SDK host in `src/webview/pweb.webview.host.pas` is the one that
#     WOULD exit at once - its closer waits on a TSynEvent that the teardown
#     signals - but a driver learns its verdict from the `--pweb-verdict` file,
#     which is written on the way out.
#   - Closing on the engine's `Code Cache/js` write instead is rejected on
#     purpose: that says the script was COMPILED, which happens before the
#     report, so a driver closing on it would cut off the very thing it waits
#     for.
#
# `examples/` and `src/` are frozen for this shard, so the change that would
# make close-on-report possible - flush the report line, or close the window on
# the first report - is owed to whoever next touches them, beside the
# page-side progress report already recorded at B1-10.

# WHICH SITES THIS GOVERNS, and which keep their own windows on purpose. This is
# the window of the INSTRUMENTED GUI SMOKE - the drivers that carry the
# non-report observer, and the CI step bodies that run a GUI example. Those are
# exactly where the flake was sighted (B1-10, B2-16, D1-15 and the CAP-4
# dual-mode driver) and exactly what the gate sweeps.
#
# Deliberately NOT moved: the windows that ARE the thing under test - 55000 ms
# in the host-argument gates, where the point is that argv beats the
# environment; 45000 and 20000 in the supervision gates, where the window has to
# outlive a supervised stop; 5000 in the CAP-6b4 profile matrix; and the 8000 ms
# windows in the CAP-6b clean-machine, CAP-7L GUI-matrix and CAP-10E long-path
# gates, which drive the same host for a different question and whose own
# requirement nobody has measured. Copying this number into them unmeasured
# would repeat exactly the mistake this file exists to end.
#
# THE ONE VALUE. Every governed driver and CI step reads it from here;
# `test/cap11a/check_flake_instrumentation.ps1` refuses a site that types a
# number instead.
$PWebSmokeAutocloseMs = 15000

# The measured dev-host deadline the size above is a multiple of, kept beside
# the value so the gate can check the arithmetic rather than trust the comment.
$PWebSmokeMeasuredReportMs = 300
$PWebSmokeWindowMultiple = 50

function Set-PWebSmokeWindow {
    <#
      Sets the environment variable the example hosts read and returns the
      value, so a caller can write both the env and the observer's
      `-AutocloseMs` from one place.
    #>
    $env:PWEB_SMOKE_AUTOCLOSE_MS = "$PWebSmokeAutocloseMs"
    return $PWebSmokeAutocloseMs
}
