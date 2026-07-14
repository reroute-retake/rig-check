#!/usr/bin/env python3
"""RigCheck — detect NEW SMART errors appearing during a stress run.

    smartwatch.py baseline <run>   read raw/smart_before_*.json -> smart_baseline.json
    smartwatch.py check <run>      re-query smartctl now, compare against baseline
                                   exit 0 = no new errors; exit 2 = NEW errors (message on stdout)

A drive that grows reallocated/pending sectors or media errors *while under
load* is actively degrading — the watchdog aborts the run so it can be
reported before more damage is done.
"""
import glob, json, os, shutil, subprocess, sys

ATA_KEYS = {5: "reallocated_sectors", 187: "reported_uncorrectable", 197: "pending_sectors", 198: "offline_uncorrectable"}

def extract(j):
    out = {"smart_passed": (j.get("smart_status") or {}).get("passed"), "counters": {}}
    for a in ((j.get("ata_smart_attributes") or {}).get("table") or []):
        if a.get("id") in ATA_KEYS:
            try:
                out["counters"][ATA_KEYS[a["id"]]] = int((a.get("raw") or {}).get("value", 0))
            except (TypeError, ValueError):
                pass
    nv = j.get("nvme_smart_health_information_log") or {}
    if nv:
        out["counters"]["media_errors"] = int(nv.get("media_errors") or 0)
        out["counters"]["critical_warning"] = int(nv.get("critical_warning") or 0)
    return out

def cmd_baseline(run):
    base = {}
    for f in glob.glob(os.path.join(run, "raw", "smart_before_*.json")):
        disk = os.path.basename(f)[len("smart_before_"):-len(".json")]
        try:
            base[disk] = extract(json.load(open(f)))
        except Exception:
            pass
    json.dump(base, open(os.path.join(run, "smart_baseline.json"), "w"))
    print(f"smartwatch: baseline captured for {len(base)} drive(s)")

def cmd_check(run):
    bp = os.path.join(run, "smart_baseline.json")
    if not os.path.exists(bp) or not shutil.which("smartctl"):
        return 0
    base = json.load(open(bp))
    msgs = []
    for disk, b in base.items():
        try:
            p = subprocess.run(["smartctl", "-xj", f"/dev/{disk}"], capture_output=True, text=True, timeout=25)
            cur = extract(json.loads(p.stdout or "{}"))
        except Exception:
            continue
        if b.get("smart_passed") is True and cur.get("smart_passed") is False:
            msgs.append(f"{disk}: SMART overall status flipped to FAILING")
        for k, v in cur["counters"].items():
            b0 = b.get("counters", {}).get(k, 0)
            if v > b0:
                msgs.append(f"{disk}: {k} grew {b0} -> {v} during run")
    if msgs:
        print("; ".join(msgs))
        return 2
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    cmd, run = sys.argv[1], sys.argv[2]
    if cmd == "baseline":
        cmd_baseline(run); sys.exit(0)
    elif cmd == "check":
        sys.exit(cmd_check(run))
    print(__doc__); sys.exit(1)
