#!/usr/bin/env bash
# Measure the opening animation with the development preview's autoplay.
#
# What it runs: a copy of the release app, assembled in the output directory
# (never dist/, which a running app may be using), with a throwaway data root
# and preferences suite. The preview result is synthetic and is never written
# anywhere, so the real profile is not opened.
#
# What it records, per run: wall-clock time of every opening stage (from the
# preview's PACKTRACE_OPENING_TRACE lines), CPU used by the process during the
# opening (from `ps` cputime deltas), and the physical footprint and its peak
# (`vmmap -summary`, taken after the summary). `ps` RSS is not used for memory:
# it counts shared system framework pages (~700 MB of __TEXT on this machine).
# One extra run, not counted in the numbers above it, takes a 3 s `sample` of
# the process during the card reveals, since attaching a sampler changes the
# process it measures.
#
# Frame rate is not measured: the Command Line Tools have no Instruments and
# the app has no frame counter, so there is no honest FPS number to report.
#
# Run it with the screen unlocked and the window visible: macOS stops drawing
# an occluded or locked window, and the memory and CPU numbers then describe a
# scene that was never rendered. The script says so when the screen is locked.
#
# Usage:
#   ./scripts/profile-opening.sh [output-dir] [runs]
#   PACKTRACE_PROFILE_MUTE=1 ./scripts/profile-opening.sh ...   # no sound from the probe
# Run 1 starts with an empty image cache (cold: card art comes from the
# network); later runs reuse the same data root (warm: art from the disk cache).
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:-$(mktemp -d -t packtrace-profile)}"
RUNS="${2:-3}"
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"

echo "== swift build -c release =="
swift build -c release >/dev/null
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="${OUT}/PackTraceProbe.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/PackTrace" "${APP}/Contents/MacOS/PackTrace"
# Own bundle identifier, so the probe never shares state with the real app.
sed 's#<string>io.github.packtrace</string>#<string>io.github.packtrace.profile-probe</string>#' \
  packaging/Info.plist > "${APP}/Contents/Info.plist"
for bundle in "${BIN_DIR}"/*.bundle; do cp -R "${bundle}" "${APP}/Contents/Resources/"; done
codesign --force --sign - --timestamp=none "${APP}" >/dev/null 2>&1

DATA_ROOT="${OUT}/data"
SUITE="packtrace.profile-probe"
mkdir -p "${DATA_ROOT}"
# Sound is on by default, as in normal use. PACKTRACE_PROFILE_MUTE=1 turns it off
# in the probe's own preferences suite (never the real one).
if [ "${PACKTRACE_PROFILE_MUTE:-0}" = "1" ]; then
  defaults write "${SUITE}" packtrace.settings.sound -bool false
  echo "sound:     muted for the probe"
fi
echo "probe app: ${APP}"
echo "data root: ${DATA_ROOT} (throwaway)"
echo "machine:   $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
if ioreg -r -d 1 -k IOConsoleUsers 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
  echo "WARNING:   the screen is locked; the window is not drawn, so memory and CPU are not representative"
fi
echo

/usr/bin/python3 - "${APP}" "${DATA_ROOT}" "${SUITE}" "${OUT}" "${RUNS}" <<'PY'
import ctypes, os, shutil, subprocess, sys, time

app, data_root, suite, out, runs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
exe = os.path.join(app, "Contents", "MacOS", "PackTrace")

def cputime(pid):
    # ps cputime is [[dd-]hh:]mm:ss.cc
    text = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not text:
        return None
    seconds = 0.0
    for part in text.replace("-", ":").split(":"):
        seconds = seconds * 60 + float(part)
    return seconds

def footprint(pid):
    text = subprocess.run(["vmmap", "-summary", str(pid)], capture_output=True, text=True).stdout
    now = peak = None
    for line in text.splitlines():
        if line.startswith("Physical footprint (peak):"):
            peak = line.split(":", 1)[1].strip()
        elif line.startswith("Physical footprint:"):
            now = line.split(":", 1)[1].strip()
    return now, peak

# proc_pid_rusage(RUSAGE_INFO_V2): ri_phys_footprint is the same number
# vmmap reports as "Physical footprint", cheap enough to read every 100 ms.
class RUsageInfoV2(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
        "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups",
        "ri_child_interrupt_wkups", "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
        "ri_diskio_byteswritten")]

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")

def rss_mb(pid):
    info = RUsageInfoV2()
    if libproc.proc_pid_rusage(pid, 2, ctypes.byref(info)) != 0:
        return None
    return info.ri_phys_footprint / 1048576

def stages(path):
    result = []
    with open(path, errors="replace") as handle:
        for line in handle:
            if line.startswith("[opening-trace]"):
                _, ms, state = line.split()
                if not state.startswith("image-"):
                    result.append((int(ms), state))
    return result

# The probe's own URL cache (its bundle identifier, not the real app's): cleared
# so that run 1 really fetches the art from the network.
shutil.rmtree(os.path.expanduser("~/Library/Caches/io.github.packtrace.profile-probe"), ignore_errors=True)

for run in range(1, runs + 2):
    sampled_run = run == runs + 1
    label = "extra run for the main-thread sample (numbers not comparable)" if sampled_run else f"run {run} ({'cold' if run == 1 else 'warm'} images)"
    trace_path = os.path.join(out, f"run-{run}.trace")
    env = dict(os.environ)
    env.update({
        "PACKTRACE_DATA_ROOT": data_root,
        "PACKTRACE_SETTINGS_SUITE": suite,
        "PACKTRACE_OPENING_PREVIEW": "1",
        "PACKTRACE_OPENING_AUTOPLAY": "1",
        "PACKTRACE_OPENING_TRACE": "1",
    })
    with open(trace_path, "w") as trace_file:
        process = subprocess.Popen([exe], env=env, stderr=trace_file, stdout=subprocess.DEVNULL)
    samples = []          # (wall seconds, footprint MB, cpu seconds, opening under way)
    sampler = None
    summary_at = None
    started = time.monotonic()
    while process.poll() is None:
        now = time.monotonic()
        rss, cpu = rss_mb(process.pid), cputime(process.pid)
        seen = stages(trace_path)
        names = [s for _, s in seen]
        if rss is not None and cpu is not None:
            # Whether the opening (tear -> summary) was under way at this sample.
            opening = "pack-opening" in names and "summary" not in names
            samples.append((now, rss, cpu, opening))
        if sampled_run and sampler is None and "card-revealing" in names:
            sampler = subprocess.Popen(
                ["sample", str(process.pid), "3", "-file", os.path.join(out, f"run-{run}.main-thread-sample.txt")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        if summary_at is None and "summary" in names:
            summary_at = now
        if summary_at is not None and now - summary_at >= 1.5:
            break
        if now - started > 60:
            print("  timeout")
            break
        time.sleep(0.1)
    if sampler is not None:
        sampler.wait()
    memory = footprint(process.pid) if process.poll() is None else (None, None)
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()

    print(f"== {label} ==")
    seen = stages(trace_path)
    if not seen:
        print("  no trace lines (did the preview start?)")
        continue
    first = lambda name: next((ms for ms, s in seen if s == name), None)
    tear, rise, summary = first("pack-opening"), first("cards-rise"), first("summary")
    reveals = [ms for ms, s in seen if s == "card-revealing"]
    print(f"  stages: {len(seen)} transitions, {len(reveals)} card reveals")
    if tear is not None and summary is not None:
        print(f"  tear -> summary: {summary - tear} ms (scene start -> tear {tear} ms, includes autoplay's 40 ms input poll)")
    if rise is not None and reveals:
        print(f"  cards-rise -> first reveal: {reveals[0] - rise} ms")
    if reveals and summary is not None:
        spans = [b - a for a, b in zip(reveals, reveals[1:] + [summary])]
        print(f"  per card (reveal start -> next reveal/summary): min {min(spans)} ms, max {max(spans)} ms, total {sum(spans)} ms")
    print(f"  physical footprint after the summary: {memory[0]}, peak over the run: {memory[1]}")
    with open(os.path.join(out, f"run-{run}.footprint.tsv"), "w") as handle:
        t0 = samples[0][0] if samples else 0
        for when, mb, cpu, opening in samples:
            handle.write(f"{(when - t0) * 1000:.0f}\t{mb:.1f}\t{cpu:.2f}\t{int(opening)}\n")
    if samples:
        during = [s[1] for s in samples if s[3]]
        before = [s[1] for s in samples if not s[3] and s[0] < (next((x[0] for x in samples if x[3]), samples[-1][0]))]
        if before and during:
            print(f"  footprint: {before[-1]:.1f} MB before the tear, {max(during):.1f} MB peak during the opening, {samples[-1][1]:.1f} MB at the end")
    images = {}
    with open(trace_path, errors="replace") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) == 3 and parts[2].startswith("image-"):
                _, quality, outcome, _, latency = parts[2].split("-")
                images.setdefault((quality, outcome), []).append(int(latency.rstrip("ms")))
    for (quality, outcome), latencies in sorted(images.items()):
        name = {"low": "thumbnail", "high": "full"}.get(quality, quality)
        latencies.sort()
        print(f"  images {name} {outcome}: {len(latencies)} loads, median {latencies[len(latencies) // 2]} ms, max {latencies[-1]} ms")
    if len(samples) >= 2:
        window = [s for s in samples if s[3]]
        if len(window) >= 2:
            busy = window[-1][2] - window[0][2]
            span = window[-1][0] - window[0][0]
            peak = max(((b[2] - a[2]) / (b[0] - a[0]) * 100) for a, b in zip(window, window[1:]) if b[0] > a[0])
            print(f"  CPU during the opening: {busy:.2f} s over {span:.1f} s = {busy / span * 100:.0f}% of one core on average, peak {peak:.0f}% (100 ms windows; ps cputime has 10 ms resolution)")
        tail = [s for s in samples if s[0] >= samples[-1][0] - 1.2]
        if len(tail) >= 2 and tail[-1][0] > tail[0][0]:
            print(f"  CPU on the summary (last ~1.2 s): {(tail[-1][2] - tail[0][2]) / (tail[-1][0] - tail[0][0]) * 100:.0f}% of one core")
PY

# Leave nothing of the probe behind: its preferences suite, the defaults AppKit
# keeps under its own bundle identifier, and its URL cache.
defaults delete "${SUITE}" >/dev/null 2>&1 || true
defaults delete io.github.packtrace.profile-probe >/dev/null 2>&1 || true
rm -rf "${HOME}/Library/Caches/io.github.packtrace.profile-probe"
echo
echo "outputs: ${OUT}"
