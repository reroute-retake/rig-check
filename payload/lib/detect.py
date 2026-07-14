#!/usr/bin/env python3
"""RigCheck Phase 2 — structured hardware inventory + capability probing.

Reads the raw captures produced by detect.sh and emits:
    <run>/hardware.json     structured component inventory (with flat 'identity')
    <run>/capability.json   machine class, applicable tests, scaled tier parameters
    <run>/capability.env    bash-sourceable parameters for the selected mode

Usage: detect.py <run_dir> <mode> <configured_abort_temp_c>
Scaling philosophy: each tier keeps its wall-clock promise (coffee ~15min,
standard ~40min, detailed = hours) — but weak machines get gentler working sets
and strong machines get heavier ones within that budget.
"""
import json, os, re, sys

# ------------------------------------------------------------------ raw parsers
def raw(run, name):
    p = os.path.join(run, "raw", name)
    return open(p, errors="replace").read() if os.path.exists(p) else ""

def load_json_file(path):
    try:
        return json.load(open(path, errors="replace"))
    except Exception:
        return {}

def parse_kv_block(text, header_re=r"^[A-Z].*Information|^Memory Device"):
    blocks, cur = [], None
    for line in text.splitlines():
        if re.match(header_re, line):
            cur = {"_title": line.strip()}
            blocks.append(cur)
            continue
        m = re.match(r"^\s+([A-Za-z ()/-]+):\s*(.*)$", line)
        if m and cur is not None:
            cur[m.group(1).strip()] = m.group(2).strip()
    return blocks

def parse_lscpu(text):
    d, vulns = {}, {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        k, v = k.strip(), v.strip()
        if k.startswith("Vulnerability "):
            vulns[k[len("Vulnerability "):]] = v
        else:
            d[k] = v
    return d, vulns

def nn(v):  # none-if-placeholder
    if not v or str(v).lower() in ("to be filled by o.e.m.", "not specified", "default string",
                                   "none", "unknown", "n/a", "not available", "not present"):
        return None
    return v

# ------------------------------------------------------------------ hardware inventory
def build_hardware(run):
    hw = {}
    lscpu, vulns = parse_lscpu(raw(run, "lscpu.txt"))
    flags = set((lscpu.get("Flags") or "").split())
    def num(s, default=None):
        try: return float(str(s).replace(",", "."))
        except (TypeError, ValueError): return default
    hw["cpu"] = {
        "model": lscpu.get("Model name"),
        "vendor": lscpu.get("Vendor ID"),
        "sockets": int(num(lscpu.get("Socket(s)"), 1) or 1),
        "cores": int(num(lscpu.get("Core(s) per socket"), 0) or 0) * int(num(lscpu.get("Socket(s)"), 1) or 1),
        "threads": int(num(lscpu.get("CPU(s)"), 0) or 0),
        "max_mhz": num(lscpu.get("CPU max MHz")),
        "features": {f: (f in flags) for f in ("sse4_2", "avx", "avx2", "avx512f", "aes")},
        "virtualization": lscpu.get("Virtualization"),
        "vulnerabilities": vulns,
    }

    # memory
    mem_kb = avail_kb = 0
    m = re.search(r"MemTotal:\s+(\d+)", raw(run, "meminfo.txt"))
    if m: mem_kb = int(m.group(1))
    m = re.search(r"MemAvailable:\s+(\d+)", raw(run, "meminfo.txt"))
    if m: avail_kb = int(m.group(1))
    dimms, ecc = [], None
    for b in parse_kv_block(raw(run, "dmi_memory.txt")):
        if b.get("_title", "").startswith("Physical Memory Array"):
            ecc = (b.get("Error Correction Type") or "").lower() not in ("", "none", "unknown")
        if b.get("_title", "").startswith("Memory Device") and b.get("Size") and "No Module" not in b["Size"]:
            dimms.append({"slot": b.get("Locator"), "size": b.get("Size"), "type": b.get("Type"),
                          "speed": b.get("Speed"),
                          "configured_speed": b.get("Configured Memory Speed") or b.get("Configured Clock Speed"),
                          "manufacturer": nn(b.get("Manufacturer")), "part_number": nn(b.get("Part Number")),
                          "serial": nn(b.get("Serial Number"))})
    hw["memory"] = {"total_gb": round(mem_kb / 1048576, 1), "available_mb": avail_kb // 1024,
                    "ecc": ecc, "dimms": dimms}

    # platform
    sysb = parse_kv_block(raw(run, "dmi_system.txt"))
    base = parse_kv_block(raw(run, "dmi_baseboard.txt"))
    bios = parse_kv_block(raw(run, "dmi_bios.txt"))
    chas = parse_kv_block(raw(run, "dmi_chassis.txt"))
    chassis_type = (chas[0].get("Type") if chas else None) or ""
    hw["platform"] = {
        "system_manufacturer": nn(sysb[0].get("Manufacturer")) if sysb else None,
        "system_product": nn(sysb[0].get("Product Name")) if sysb else None,
        "system_serial": nn(sysb[0].get("Serial Number")) if sysb else None,
        "system_uuid": nn(sysb[0].get("UUID")) if sysb else None,
        "board_vendor": nn(base[0].get("Manufacturer")) if base else None,
        "board_model": nn(base[0].get("Product Name")) if base else None,
        "board_serial": nn(base[0].get("Serial Number")) if base else None,
        "bios_vendor": nn(bios[0].get("Vendor")) if bios else None,
        "bios_version": nn(bios[0].get("Version")) if bios else None,
        "bios_date": nn(bios[0].get("Release Date")) if bios else None,
        "chassis": chassis_type or None,
        "is_laptop": chassis_type.lower() in ("laptop", "notebook", "portable", "sub notebook", "convertible", "detachable"),
        "boot_mode": raw(run, "boot_mode.txt").strip() or None,
        "on_battery_capable": "BAT" in raw(run, "power_supply.txt"),
    }

    # storage
    drives = []
    lb = load_json_file(os.path.join(run, "raw", "lsblk.json"))
    for d in lb.get("blockdevices", []):
        if d.get("type") == "disk" and not str(d.get("name", "")).startswith(("loop", "zram", "sr")):
            name = d.get("name")
            sj = load_json_file(os.path.join(run, "raw", f"smart_before_{name}.json"))
            drives.append({
                "name": name, "model": d.get("model"), "serial": d.get("serial"),
                "size_gb": round((d.get("size") or 0) / 1e9, 1), "bus": d.get("tran"),
                "rotational": bool(d.get("rota")), "nvme": str(name).startswith("nvme"),
                "smart_healthy": (sj.get("smart_status") or {}).get("passed"),
                "temp_c": (sj.get("temperature") or {}).get("current"),
                "power_on_hours": (sj.get("power_on_time") or {}).get("hours"),
            })
    hw["storage"] = drives

    # gpu
    gpus, cur = [], None
    for line in raw(run, "lspci.txt").splitlines():
        if re.search(r"vga|3d controller|display controller", line, re.I):
            cur = {"description": re.sub(r"^\S+\s+", "", line).strip(), "driver": None}
            gpus.append(cur)
        m = re.match(r"\s+Kernel driver in use:\s*(\S+)", line)
        if m and cur is not None:
            cur["driver"] = m.group(1)
    for g in gpus:
        g["class"] = ("full" if g.get("driver") in ("i915", "xe", "amdgpu", "radeon", "nvidia")
                      else "basic" if g.get("driver") else "none")
    hw["gpu"] = gpus

    # network
    ifaces = []
    ipj = load_json_file(os.path.join(run, "raw", "ip_addr.json"))
    if isinstance(ipj, list):
        for itf in ipj:
            if itf.get("ifname") != "lo" and itf.get("link_type") != "loopback":
                ifaces.append({"ifname": itf.get("ifname"), "mac": itf.get("address")})
    hw["network"] = {"interfaces": ifaces,
                     "wifi_present": any(str(i["ifname"]).startswith(("wl", "wlan")) for i in ifaces),
                     "ethernet_present": any(str(i["ifname"]).startswith(("en", "eth")) for i in ifaces)}

    # sensors: chips + most conservative CPU critical temp
    chips, crits, cur_chip = [], [], None
    for line in raw(run, "hwmon.txt").splitlines():
        if line.startswith("chip "):
            cur_chip = line[5:].strip(); chips.append(cur_chip)
        else:
            m = re.match(r"temp\d+_(crit|max)\s+(\d+)", line.strip())
            if m and cur_chip in ("coretemp", "k10temp", "zenpower", "cpu_thermal", "soc_thermal"):
                v = int(m.group(2)) // 1000
                if 70 <= v <= 120: crits.append(v)
    hw["sensors"] = {"chips": chips, "cpu_temp_readable": any(c in ("coretemp", "k10temp", "zenpower", "cpu_thermal") for c in chips),
                     "cpu_crit_c": min(crits) if crits else None}

    # flat identity block (shape report.py/HTML expects)
    p = hw["platform"]
    hw["identity"] = {
        "system_manufacturer": p["system_manufacturer"], "system_product": p["system_product"],
        "system_serial": p["system_serial"], "system_uuid": p["system_uuid"],
        "board_vendor": p["board_vendor"], "board_model": p["board_model"], "board_serial": p["board_serial"],
        "bios_vendor": p["bios_vendor"], "bios_version": p["bios_version"], "bios_date": p["bios_date"],
        "cpu_model": hw["cpu"]["model"], "cpu_cores": str(hw["cpu"]["cores"] or ""), "cpu_threads": str(hw["cpu"]["threads"] or ""),
        "cpu_max_mhz": str(hw["cpu"]["max_mhz"] or ""),
        "dimms": dimms, "ram_total_gb": hw["memory"]["total_gb"],
        "drives": [{k: d[k] for k in ("name", "model", "serial", "size_gb", "bus", "rotational")} for d in drives],
        "macs": ifaces, "gpus": [g["description"] for g in gpus],
    }
    return hw

# ------------------------------------------------------------------ capability probing
def probe_capability(hw, conf_abort_c):
    cpu, mem = hw["cpu"], hw["memory"]
    threads = cpu["threads"] or 2
    ram_gb = mem["total_gb"] or 0
    avail = mem["available_mb"] or 1024
    notes, reasons = [], []

    # machine class
    if threads <= 2 or ram_gb <= 4:
        cls = "weak"; reasons.append(f"{threads} threads / {ram_gb}GB RAM — scaling tests down")
    elif threads >= 12 and ram_gb >= 16:
        cls = "strong"; reasons.append(f"{threads} threads / {ram_gb}GB RAM — scaling tests up")
    else:
        cls = "mid"; reasons.append(f"{threads} threads / {ram_gb}GB RAM")
    if any(d.get("nvme") for d in hw["storage"]): reasons.append("NVMe present")

    # effective abort temperature: respect the chip's own critical limit
    abort_c = int(conf_abort_c)
    crit = hw["sensors"].get("cpu_crit_c")
    if crit:
        abort_c = max(80, min(abort_c, crit - 7))
        if abort_c != int(conf_abort_c):
            notes.append(f"abort temp adjusted to {abort_c}°C (chip critical limit {crit}°C)")
    if not hw["sensors"]["cpu_temp_readable"]:
        notes.append("CPU temperature not readable on this platform — thermal watchdog will be blind; stress durations reduced")

    # informational notes
    if not cpu["features"].get("avx2"):
        notes.append("older CPU (no AVX2): expect modest benchmark scores")
    if any("Mitigation" in v for v in cpu["vulnerabilities"].values()):
        notes.append("Spectre/Meltdown-era mitigations active — compare benchmarks within CPU class, not across eras")
    if hw["platform"]["is_laptop"]:
        notes.append("laptop chassis: sustained-load thermals are expected to be tighter than desktop")
    if mem["ecc"]: notes.append("ECC memory present")
    if len(hw["storage"]) == 0: notes.append("no internal drives detected")

    # applicable tests
    gpu_capable = any(g["class"] == "full" for g in hw["gpu"])
    applicable = {
        "cpu_stress": True,
        "ram_userspace": avail >= 1800,
        "storage_smart": len(hw["storage"]) > 0,
        "storage_bench": len(hw["storage"]) > 0,
        "gpu_stress": gpu_capable,
    }
    if not applicable["ram_userspace"]:
        notes.append(f"only {avail}MB free RAM — userspace RAM test skipped; use the Memtest86+ boot entry")
    if not gpu_capable and hw["gpu"]:
        notes.append(f"GPU driver '{hw['gpu'][0].get('driver') or 'none'}' is not stress-capable — GPU stays detect-only")

    # tier parameters (wall-clock promise per tier; intensity scales by class)
    mult = {"weak": 0.7, "mid": 1.0, "strong": 1.4}[cls]
    blind = not hw["sensors"]["cpu_temp_readable"]
    def cpu_secs(base):
        s = int(base * mult)
        return int(s * 0.6) if blind else s
    ram_pct = {"weak": 40, "mid": 60, "strong": 70}[cls]
    tiers = {
        "coffee": {
            "RAM_WANT_MB": max(512, min(1024 if cls == "weak" else 2048, int(avail * 0.30))),
            "RAM_TIMEOUT": 420, "RAM_LOOPS": 1,
            "CPU_SECS": cpu_secs(300), "FIO_SECS": 60 if cls == "strong" else 40, "SMART_KIND": "short",
        },
        "standard": {
            "RAM_WANT_MB": max(512, int(avail * ram_pct / 100)),
            "RAM_TIMEOUT": int(900 * mult), "RAM_LOOPS": 1,
            "CPU_SECS": cpu_secs(720), "FIO_SECS": int(90 * mult), "SMART_KIND": "short",
        },
        "detailed": {
            "RAM_WANT_MB": max(1024, avail - 2048),
            "RAM_TIMEOUT": int(5400 * mult), "RAM_LOOPS": {"weak": 2, "mid": 4, "strong": 6}[cls],
            "CPU_SECS": cpu_secs(3600), "FIO_SECS": int(240 * mult), "SMART_KIND": "long",
        },
    }
    return {"machine_class": cls, "class_reasons": reasons, "abort_temp_c": abort_c,
            "applicable_tests": applicable, "notes": notes, "tiers": tiers}

# ------------------------------------------------------------------ outputs
def emit_env(cap, mode, path):
    t = cap["tiers"].get(mode, cap["tiers"]["standard"])
    with open(path, "w") as f:
        for k, v in t.items():
            f.write(f"{k}={v}\n")
        f.write(f"ABORT_TEMP_C={cap['abort_temp_c']}\n")
        f.write(f"MACHINE_CLASS={cap['machine_class']}\n")
        f.write(f"SKIP_RAM={0 if cap['applicable_tests']['ram_userspace'] else 1}\n")

B, G, Y, Z = "\033[1;36m", "\033[1;32m", "\033[1;33m", "\033[0m"
def print_summary(hw, cap, mode):
    c, m, p = hw["cpu"], hw["memory"], hw["platform"]
    feats = "+".join(f.upper() for f in ("avx2", "avx512f") if c["features"].get(f)) or "no-AVX2"
    dimm_s = ", ".join(f"{d['size']} {d.get('type') or ''}@{(d.get('configured_speed') or d.get('speed') or '?')}"
                       for d in m["dimms"]) or "DIMM info unavailable"
    print(f"\n{B}──── Detected hardware ────{Z}")
    print(f"  CPU      {c['model'] or '?'}  ({c['cores']}c/{c['threads']}t, {feats})")
    print(f"  RAM      {m['total_gb']}GB total, {m['available_mb']}MB free  [{dimm_s}]" + ("  ECC" if m["ecc"] else ""))
    print(f"  Board    {p['board_vendor'] or '?'} {p['board_model'] or '?'}  BIOS {p['bios_version'] or '?'} ({p['bios_date'] or '?'})")
    print(f"  System   {p['system_manufacturer'] or '?'} {p['system_product'] or '?'}  [{p['chassis'] or '?'}{', laptop' if p['is_laptop'] else ''}, {p['boot_mode'] or '?'} boot]")
    for d in hw["storage"]:
        health = {True: "SMART ok", False: "SMART FAILING", None: "SMART n/a"}[d["smart_healthy"]]
        print(f"  Drive    /dev/{d['name']}  {d['model'] or '?'}  {d['size_gb']}GB  [{d['bus'] or '?'}, {health}]")
    for g in hw["gpu"]:
        print(f"  GPU      {g['description']}  [driver: {g.get('driver') or 'none'}, {g['class']}]")
    net = hw["network"]
    print(f"  Net      {', '.join(i['ifname'] for i in net['interfaces']) or 'none'}"
          f"  [wifi:{'yes' if net['wifi_present'] else 'no'} eth:{'yes' if net['ethernet_present'] else 'no'}]")
    print(f"  Sensors  {', '.join(hw['sensors']['chips']) or 'none'}  → abort at {cap['abort_temp_c']}°C")
    t = cap["tiers"][mode]
    print(f"\n{G}Class: {cap['machine_class'].upper()}{Z} — {'; '.join(cap['class_reasons'])}")
    print(f"  {mode} tier scaled: RAM test {t['RAM_WANT_MB']}MB, CPU stress {t['CPU_SECS']//60}min, disk bench {t['FIO_SECS']}s")
    for n in cap["notes"]:
        print(f"  {Y}note:{Z} {n}")
    print()

def main():
    if len(sys.argv) < 4:
        print(__doc__); sys.exit(1)
    run, mode, conf_abort = sys.argv[1], sys.argv[2], sys.argv[3]
    hw = build_hardware(run)
    cap = probe_capability(hw, int(conf_abort or 95))
    with open(os.path.join(run, "hardware.json"), "w") as f:
        json.dump(hw, f, indent=2, default=str)
    with open(os.path.join(run, "capability.json"), "w") as f:
        json.dump(cap, f, indent=2, default=str)
    emit_env(cap, mode, os.path.join(run, "capability.env"))
    print_summary(hw, cap, mode)

if __name__ == "__main__":
    main()
