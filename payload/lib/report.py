#!/usr/bin/env python3
"""RigCheck report engine.

Usage:
    report.py finalize <rigcheck.conf> <run_dir>     build+sign report, render HTML,
                                                     print console summary, email, LLM
    report.py notify-start <rigcheck.conf> <run_dir> send "test started" email
Exit codes (finalize): 0=PASS 1=WARN 2=FAIL
"""
import glob, hashlib, hmac, html, json, os, re, socket, sys, time, urllib.request

C_G, C_Y, C_R, C_B, C_0 = "\033[1;32m", "\033[1;33m", "\033[1;31m", "\033[1;36m", "\033[0m"
STATUS_ORDER = {"PASS": 0, "INFO": 0, "SKIP": 0, "WARN": 1, "FAIL": 2}

# ------------------------------------------------------------------ small parsers
def read_conf(path):
    conf = {}
    if path and os.path.exists(path):
        for line in open(path, errors="replace"):
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.strip())
            if m:
                v = m.group(2).strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1].replace("'\\''", "'")
                conf[m.group(1)] = v
    return conf

def read_env(path):
    return read_conf(path)

def raw(run, name):
    p = os.path.join(run, "raw", name)
    return open(p, errors="replace").read() if os.path.exists(p) else ""

def load_json_file(path):
    try:
        return json.load(open(path, errors="replace"))
    except Exception:
        return {}

def parse_kv_block(text):
    """dmidecode-style 'Key: value' lines -> list of blocks split on unindented headers."""
    blocks, cur = [], None
    for line in text.splitlines():
        if re.match(r"^[A-Z]", line) and "Information" in line or line.startswith("Memory Device"):
            cur = {"_title": line.strip()}
            blocks.append(cur)
        m = re.match(r"^\s+([A-Za-z ()/-]+):\s*(.*)$", line)
        if m and cur is not None:
            cur[m.group(1).strip()] = m.group(2).strip()
    return blocks

def parse_lscpu(text):
    d = {}
    for line in text.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            d[k.strip()] = v.strip()
    return d

def none_if_placeholder(v):
    if not v or v.lower() in ("to be filled by o.e.m.", "not specified", "default string", "none", "unknown", "n/a", "not available"):
        return None
    return v

# ------------------------------------------------------------------ build report
def build_identity(run):
    ident = {}
    sysb = parse_kv_block(raw(run, "dmi_system.txt"))
    if sysb:
        b = sysb[0]
        ident["system_manufacturer"] = none_if_placeholder(b.get("Manufacturer"))
        ident["system_product"] = none_if_placeholder(b.get("Product Name"))
        ident["system_serial"] = none_if_placeholder(b.get("Serial Number"))
        ident["system_uuid"] = none_if_placeholder(b.get("UUID"))
    base = parse_kv_block(raw(run, "dmi_baseboard.txt"))
    if base:
        b = base[0]
        ident["board_vendor"] = none_if_placeholder(b.get("Manufacturer"))
        ident["board_model"] = none_if_placeholder(b.get("Product Name"))
        ident["board_serial"] = none_if_placeholder(b.get("Serial Number"))
    bios = parse_kv_block(raw(run, "dmi_bios.txt"))
    if bios:
        b = bios[0]
        ident["bios_vendor"] = none_if_placeholder(b.get("Vendor"))
        ident["bios_version"] = none_if_placeholder(b.get("Version"))
        ident["bios_date"] = none_if_placeholder(b.get("Release Date"))
    cpu = parse_lscpu(raw(run, "lscpu.txt"))
    ident["cpu_model"] = cpu.get("Model name")
    ident["cpu_cores"] = cpu.get("Core(s) per socket")
    ident["cpu_threads"] = cpu.get("CPU(s)")
    ident["cpu_max_mhz"] = cpu.get("CPU max MHz")

    dimms = []
    for b in parse_kv_block(raw(run, "dmi_memory.txt")):
        if b.get("_title", "").startswith("Memory Device") and b.get("Size") and "No Module" not in b.get("Size", ""):
            dimms.append({
                "slot": b.get("Locator"), "size": b.get("Size"), "type": b.get("Type"),
                "speed": b.get("Speed"), "configured_speed": b.get("Configured Memory Speed") or b.get("Configured Clock Speed"),
                "manufacturer": none_if_placeholder(b.get("Manufacturer")),
                "part_number": none_if_placeholder(b.get("Part Number")),
                "serial": none_if_placeholder(b.get("Serial Number")),
            })
    ident["dimms"] = dimms
    mem_kb = 0
    m = re.search(r"MemTotal:\s+(\d+)", raw(run, "meminfo.txt"))
    if m: mem_kb = int(m.group(1))
    ident["ram_total_gb"] = round(mem_kb / 1048576, 1)

    drives = []
    lb = load_json_file(os.path.join(run, "raw", "lsblk.json"))
    for d in lb.get("blockdevices", []):
        if d.get("type") == "disk" and not str(d.get("name", "")).startswith(("loop", "zram", "sr")):
            drives.append({"name": d.get("name"), "model": d.get("model"), "serial": d.get("serial"),
                           "size_gb": round((d.get("size") or 0) / 1e9, 1),
                           "bus": d.get("tran"), "rotational": bool(d.get("rota"))})
    ident["drives"] = drives

    macs = []
    ipj = load_json_file(os.path.join(run, "raw", "ip_addr.json"))
    if isinstance(ipj, list):
        for itf in ipj:
            if itf.get("ifname") != "lo" and itf.get("address") and itf.get("link_type") != "loopback":
                macs.append({"ifname": itf.get("ifname"), "mac": itf.get("address")})
    ident["macs"] = macs

    gpus = []
    for line in raw(run, "lspci.txt").splitlines():
        if re.search(r"vga|3d controller|display controller", line, re.I):
            gpus.append(re.sub(r"^\S+\s+", "", line).strip())
    ident["gpus"] = gpus
    return ident

def smart_extract(j):
    """Pull the fields our rules need from smartctl -xj output."""
    if not j: return {}
    out = {
        "model": j.get("model_name"), "serial": j.get("serial_number"),
        "smart_passed": (j.get("smart_status") or {}).get("passed"),
        "temp_c": (j.get("temperature") or {}).get("current"),
        "power_on_hours": ((j.get("power_on_time") or {}).get("hours")),
        "power_cycles": j.get("power_cycle_count"),
    }
    attrs = {}
    for a in ((j.get("ata_smart_attributes") or {}).get("table") or []):
        try: attrs[int(a.get("id"))] = int((a.get("raw") or {}).get("value", 0))
        except Exception: pass
    if attrs:
        out["ata"] = {
            "realloc": attrs.get(5), "spin_retry": attrs.get(10),
            "reported_uncorrect": attrs.get(187), "command_timeout": attrs.get(188),
            "pending": attrs.get(197), "offline_uncorrect": attrs.get(198),
            "crc_errors": attrs.get(199),
        }
    nv = j.get("nvme_smart_health_information_log")
    if nv:
        out["nvme"] = {
            "critical_warning": nv.get("critical_warning"), "percentage_used": nv.get("percentage_used"),
            "media_errors": nv.get("media_errors"), "err_log_entries": nv.get("num_err_log_entries"),
            "available_spare": nv.get("available_spare"),
        }
    st = ((j.get("ata_smart_data") or {}).get("self_test") or {}).get("status") or {}
    if st: out["selftest"] = {"passed": st.get("passed"), "string": st.get("string")}
    return out

def fio_read_mbs(path, iops=False):
    j = load_json_file(path)
    try:
        job = j["jobs"][0]["read"]
        return round(job["iops"]) if iops else round(job["bw"] / 1024, 1)  # bw is KiB/s
    except Exception:
        return None

def build_storage(run):
    disks = []
    for envp in sorted(glob.glob(os.path.join(run, "storage_*.env"))):
        name = os.path.basename(envp)[len("storage_"):-len(".env")]
        if name == "none": continue
        e = read_env(envp)
        after = smart_extract(load_json_file(os.path.join(run, "raw", f"smart_after_{name}.json"))) \
                or smart_extract(load_json_file(os.path.join(run, "raw", f"smart_before_{name}.json")))
        d = {"name": name, **after}
        d["selftest_kind"] = e.get(f"STORAGE_{name}_SELFTEST_KIND")
        d["selftest_status"] = e.get(f"STORAGE_{name}_SELFTEST_STATUS") or e.get(f"STORAGE_{name}_LONGTEST")
        d["bench_tool"] = e.get(f"STORAGE_{name}_BENCH_TOOL")
        seq = fio_read_mbs(os.path.join(run, "raw", f"fio_seq_{name}.json"))
        rnd = fio_read_mbs(os.path.join(run, "raw", f"fio_rand_{name}.json"), iops=True)
        if seq: d["seq_read_mbs"] = seq
        elif e.get(f"STORAGE_{name}_SEQ_READ_MBS"):
            try: d["seq_read_mbs"] = float(e[f"STORAGE_{name}_SEQ_READ_MBS"])
            except ValueError: pass
        if rnd: d["rand_read_iops"] = rnd
        disks.append(d)
    return disks

def temps_series(run):
    pts = []
    p = os.path.join(run, "temps.csv")
    if os.path.exists(p):
        for line in open(p).readlines()[1:]:
            try:
                ts, cpu, nv = line.strip().split(",")
                pts.append([int(ts), int(cpu), int(nv)])
            except Exception: pass
    # downsample to <=300 points
    if len(pts) > 300:
        stepn = len(pts) / 300.0
        pts = [pts[int(i * stepn)] for i in range(300)]
    return pts

# ------------------------------------------------------------------ rules
def apply_rules(rep):
    comp = {}
    def emit(name, status, reasons): comp[name] = {"status": status, "reasons": reasons}

    # RAM
    r = rep["tests"].get("ram", {})
    res, errs = r.get("RAM_RESULT", "skipped"), int(r.get("RAM_ERRORS", 0) or 0)
    reasons = []
    if res == "fail" or errs > 0:
        emit("RAM", "FAIL", [f"{errs} memory error(s) detected — likely bad RAM stick/slot"] + ([r["RAM_NOTES"]] if r.get("RAM_NOTES") else []))
    elif res == "pass":
        emit("RAM", "PASS", [f"{r.get('RAM_TESTED_MB','?')}MB tested clean ({r.get('RAM_TOOL','?')}); full coverage needs Memtest86+ boot entry"])
    elif res == "partial":
        emit("RAM", "PASS", [f"time-capped: no errors in tested portion ({r.get('RAM_TESTED_MB','?')}MB); run 'detailed' or Memtest86+ for certainty"])
    elif res == "aborted":
        emit("RAM", "WARN", ["test aborted before completion — no verdict"])
    else:
        emit("RAM", "SKIP", [r.get("RAM_NOTES", "not run")])

    # CPU
    c = rep["tests"].get("cpu", {})
    if c:
        verrs = int(c.get("CPU_VERIFY_ERRORS", 0) or 0)
        throttle = int(c.get("CPU_THROTTLE_EVENTS", 0) or 0)
        maxt = float(c.get("CPU_MAX_TEMP_C", 0) or 0)
        res = c.get("CPU_RESULT", "skipped"); reasons = []
        status = "PASS"
        if res == "fail":
            status = "FAIL"; reasons.append(c.get("CPU_NOTES", "stress failure"))
        elif res == "aborted":
            ar = rep["meta"].get("abort_reason", "")
            if "THERMAL" in ar:
                status = "FAIL"; reasons.append(f"watchdog thermal abort ({ar}) — cooling insufficient (fan/paste/dust/airflow)")
            else:
                status = "WARN"; reasons.append("aborted by user — no verdict")
        if verrs > 0: status = "FAIL"; reasons.append(f"{verrs} computation verification error(s) — instability (CPU/RAM/VRM/PSU)")
        if throttle > 0 and status != "FAIL":
            status = "WARN"; reasons.append(f"thermal throttling occurred ({throttle} events) — cooling is marginal")
        if maxt >= 90 and status == "PASS":
            status = "WARN"; reasons.append(f"peak CPU temp {maxt:.0f}°C is high under load")
        if status == "PASS":
            reasons.append(f"stable for {int(c.get('CPU_SECS',0))//60} min on {c.get('CPU_THREADS','?')} threads, peak {maxt:.0f}°C, no throttling")
        emit("CPU", status, reasons)
    else:
        emit("CPU", "SKIP", ["not run"])

    # Storage
    stor = rep["tests"].get("storage", [])
    if stor:
        worst, reasons = "PASS", []
        for d in stor:
            nm = f"/dev/{d.get('name')}({d.get('model') or '?'})"
            ata, nv = d.get("ata") or {}, d.get("nvme") or {}
            bad, warnr = [], []
            if d.get("smart_passed") is False: bad.append("SMART overall: FAILING")
            for k, label in (("realloc", "reallocated sectors"), ("pending", "pending sectors"),
                             ("offline_uncorrect", "uncorrectable sectors"), ("reported_uncorrect", "reported uncorrectable errors")):
                v = ata.get(k)
                if v and v > 0: bad.append(f"{v} {label}")
            if nv.get("critical_warning") not in (None, 0): bad.append(f"NVMe critical warning={nv['critical_warning']}")
            if nv.get("media_errors") not in (None, 0): bad.append(f"{nv['media_errors']} NVMe media errors")
            if d.get("selftest_status") == "failed" or (d.get("selftest") or {}).get("passed") is False:
                bad.append("SMART self-test FAILED")
            if ata.get("crc_errors"): warnr.append(f"{ata['crc_errors']} CRC errors (check SATA cable)")
            pu = nv.get("percentage_used")
            if pu is not None and pu >= 90: warnr.append(f"SSD {pu}% worn")
            if d.get("temp_c") and d["temp_c"] >= 65: warnr.append(f"drive temp {d['temp_c']}°C")
            if bad: worst = "FAIL"; reasons.append(f"{nm}: " + "; ".join(bad))
            elif warnr:
                if worst != "FAIL": worst = "WARN"
                reasons.append(f"{nm}: " + "; ".join(warnr))
            else:
                extra = f", {d['seq_read_mbs']}MB/s seq read" if d.get("seq_read_mbs") else ""
                reasons.append(f"{nm}: healthy (self-test {d.get('selftest_status') or 'n/a'}{extra})")
        emit("Storage", worst, reasons)
    else:
        emit("Storage", "SKIP", ["no internal drives found"])

    # GPU
    g = rep["tests"].get("gpu", {})
    if int(g.get("GPU_COUNT", 0) or 0) > 0:
        if g.get("GPU_TEST") == "glmark2":
            emit("GPU", "PASS" if g.get("GPU_TEST_OUTCOME") in ("completed", "timeout") else "WARN",
                 [f"glmark2 score {g.get('GPU_SCORE','?')}"])
        else:
            emit("GPU", "INFO", ["detected; stress test deferred to full RigCheck ISO"])
    else:
        emit("GPU", "SKIP", ["no GPU detected"])

    # System events / thermals
    dm = rep.get("dmesg_flags", {})
    sens = rep.get("sensors", {})
    reasons, status = [], "PASS"
    if dm.get("mce", 0) > 0:
        status = "FAIL"; reasons.append(f"{dm['mce']} Machine Check / hardware error lines in kernel log")
    if rep["meta"].get("aborted") and "THERMAL" in rep["meta"].get("abort_reason", ""):
        status = "FAIL"; reasons.append(f"thermal abort: {rep['meta']['abort_reason']}")
    if not reasons:
        reasons.append(f"max CPU {sens.get('max_cpu_c','?')}°C / max NVMe {sens.get('max_nvme_c','?')}°C during run; no hardware errors in kernel log")
    emit("System", status, reasons)

    overall = "PASS"
    for v in comp.values():
        if STATUS_ORDER.get(v["status"], 0) > STATUS_ORDER.get(overall, 0):
            overall = v["status"]
    rep["components"] = comp
    rep["summary"] = {
        "overall": overall,
        "issues": [f"{k}: {r}" for k, v in comp.items() if v["status"] in ("FAIL", "WARN") for r in v["reasons"]],
    }

# ------------------------------------------------------------------ outputs
def svg_chart(pts, abort_c):
    if len(pts) < 2:
        return "<p><em>No temperature series recorded.</em></p>"
    W, H, P = 840, 220, 34
    t0, t1 = pts[0][0], pts[-1][0]
    span = max(t1 - t0, 1)
    vmax = max(max(p[1] for p in pts), abort_c) + 6
    def x(ts): return P + (ts - t0) / span * (W - 2 * P)
    def y(v): return H - P - (v / vmax) * (H - 2 * P)
    cpu_pl = " ".join(f"{x(p[0]):.1f},{y(p[1]):.1f}" for p in pts)
    nv_pts = [p for p in pts if p[2] > 0]
    nv_pl = " ".join(f"{x(p[0]):.1f},{y(p[2]):.1f}" for p in nv_pts)
    ay = y(abort_c)
    parts = [
        f'<svg viewBox="0 0 {W} {H}" style="width:100%;max-width:{W}px;background:#fafafa;border:1px solid #ddd;border-radius:6px">',
        f'<line x1="{P}" y1="{ay:.1f}" x2="{W-P}" y2="{ay:.1f}" stroke="#d33" stroke-dasharray="6,4"/>',
        f'<text x="{P+4}" y="{ay-5:.1f}" fill="#d33" font-size="11">abort {abort_c}°C</text>',
        f'<polyline points="{cpu_pl}" fill="none" stroke="#0a6" stroke-width="2"/>',
    ]
    if nv_pl:
        parts.append(f'<polyline points="{nv_pl}" fill="none" stroke="#06c" stroke-width="1.5" stroke-dasharray="3,3"/>')
    parts.append(f'<text x="{P}" y="16" font-size="12" fill="#333">CPU °C (green) / NVMe °C (blue dashed) over {span//60} min — peak {max(p[1] for p in pts)}°C</text>')
    parts.append(f'<text x="{P-26}" y="{y(0)+4:.0f}" font-size="10" fill="#666">0</text><text x="{P-30}" y="{y(vmax-6)+10:.0f}" font-size="10" fill="#666">{vmax-6}</text>')
    parts.append("</svg>")
    return "".join(parts)

CHIP = {"PASS": "#0a7d33", "INFO": "#0a5bd3", "SKIP": "#777", "WARN": "#c77700", "FAIL": "#c0201f"}

def render_html(rep, svg, llm_text=None):
    e = html.escape
    ident, m = rep["identity"], rep["meta"]
    fp = rep["_fingerprint"]
    def chip(s): return f'<span style="background:{CHIP.get(s,"#777")};color:#fff;padding:2px 10px;border-radius:10px;font-weight:600;font-size:13px">{s}</span>'
    rows = []
    for k, v in rep["components"].items():
        rs = "<br>".join(e(r) for r in v["reasons"])
        rows.append(f'<tr><td style="font-weight:600">{e(k)}</td><td>{chip(v["status"])}</td><td>{rs}</td></tr>')
    dimms = "".join(f'<tr><td>{e(str(d.get("slot") or "?"))}</td><td>{e(str(d.get("size") or ""))}</td><td>{e(str(d.get("type") or ""))}</td>'
                    f'<td>{e(str(d.get("configured_speed") or d.get("speed") or ""))}</td><td>{e(str(d.get("manufacturer") or ""))} {e(str(d.get("part_number") or ""))}</td>'
                    f'<td class="mono">{e(str(d.get("serial") or ""))}</td></tr>' for d in ident.get("dimms", []))
    drv = "".join(f'<tr><td>/dev/{e(str(d.get("name")))}</td><td>{e(str(d.get("model") or ""))}</td><td>{d.get("size_gb")}GB</td>'
                  f'<td>{e(str(d.get("bus") or ""))}</td><td class="mono">{e(str(d.get("serial") or ""))}</td></tr>' for d in ident.get("drives", []))
    bench = rep["tests"].get("cpu", {})
    bench_bits = []
    if bench.get("BENCH_7Z_MIPS"): bench_bits.append(f"7-Zip: {e(bench['BENCH_7Z_MIPS'])} MIPS")
    if bench.get("BENCH_SHA256_16K"): bench_bits.append(f"OpenSSL SHA-256(16KB): {e(bench['BENCH_SHA256_16K'])}")
    if bench.get("CPU_BOGO_OPS"): bench_bits.append(f"stress-ng bogo-ops: {e(bench['CPU_BOGO_OPS'])}")
    llm_html = ""
    if llm_text:
        llm_html = f'<h2>AI analysis</h2><div style="background:#f4f7fb;border:1px solid #cdd9ea;border-radius:6px;padding:14px;white-space:pre-wrap">{e(llm_text)}</div>'
    nonce = m.get("challenge_nonce") or ""
    nonce_html = f'<tr><td>Challenge nonce</td><td class="mono">{e(nonce)}</td></tr>' if nonce else ""
    aborted = '<p style="color:#c0201f;font-weight:600">⚠ Run was aborted before completion — results are partial.</p>' if m.get("aborted") else ""
    return f"""<!DOCTYPE html><html><head><meta charset="utf-8"><title>RigCheck report — {e(str(ident.get('system_product') or 'PC'))}</title>
<style>
 body{{font-family:-apple-system,'Segoe UI',Roboto,Arial,sans-serif;margin:0;color:#1c2733;background:#fff}}
 .wrap{{max-width:960px;margin:0 auto;padding:28px 5%}}
 header{{background:#101820;color:#fff;padding:26px 5%}}
 header h1{{margin:0;font-size:26px}} header .fp{{font-family:ui-monospace,monospace;color:#8fd3a7;font-size:13px}}
 h2{{border-bottom:2px solid #e5e9ef;padding-bottom:6px;margin-top:34px;font-size:19px}}
 table{{border-collapse:collapse;width:100%;font-size:14px}} td,th{{border:1px solid #e0e5ec;padding:7px 10px;text-align:left;vertical-align:top}}
 th{{background:#f2f5f9}} .mono{{font-family:ui-monospace,monospace;font-size:12.5px}}
 .big{{font-size:38px;font-weight:800;margin:8px 0}}
 details{{margin-top:10px}} summary{{cursor:pointer;color:#365}}
</style></head><body>
<header><h1>RigCheck hardware report</h1>
<div>{e(str(ident.get('system_manufacturer') or ''))} {e(str(ident.get('system_product') or ''))} · mode: <b>{e(m.get('mode','?'))}</b> · {e(m.get('timestamp_utc',''))} UTC · {int(m.get('duration_s',0))//60} min</div>
<div class="fp">fingerprint {fp} · key {e(rep['_key_id'] or 'unsigned')}</div></header>
<div class="wrap">
<div class="big" style="color:{CHIP.get(rep['summary']['overall'],'#777')}">{rep['summary']['overall']}</div>
{aborted}
<h2>Component results</h2>
<table><tr><th>Component</th><th>Status</th><th>Details</th></tr>{''.join(rows)}</table>
{llm_html}
<h2>Temperatures during run</h2>{svg}
<h2>System identity (cross-check against the physical machine)</h2>
<table>
<tr><td>CPU</td><td>{e(str(ident.get('cpu_model') or '?'))} ({e(str(ident.get('cpu_cores') or '?'))}c/{e(str(ident.get('cpu_threads') or '?'))}t)</td></tr>
<tr><td>Motherboard</td><td>{e(str(ident.get('board_vendor') or '?'))} {e(str(ident.get('board_model') or '?'))} — serial <span class="mono">{e(str(ident.get('board_serial') or '?'))}</span></td></tr>
<tr><td>BIOS</td><td>{e(str(ident.get('bios_vendor') or ''))} {e(str(ident.get('bios_version') or '?'))} ({e(str(ident.get('bios_date') or '?'))})</td></tr>
<tr><td>System UUID</td><td class="mono">{e(str(ident.get('system_uuid') or '?'))}</td></tr>
<tr><td>RAM total</td><td>{ident.get('ram_total_gb','?')} GB</td></tr>
<tr><td>GPU(s)</td><td>{e('; '.join(ident.get('gpus') or ['none detected']))}</td></tr>
<tr><td>MAC(s)</td><td class="mono">{e(', '.join(f"{x['ifname']} {x['mac']}" for x in ident.get('macs', [])) or '?')}</td></tr>
{nonce_html}
</table>
<h3>RAM modules</h3>
<table><tr><th>Slot</th><th>Size</th><th>Type</th><th>Speed</th><th>Module</th><th>Serial</th></tr>{dimms or '<tr><td colspan=6>no DIMM data (dmidecode unavailable?)</td></tr>'}</table>
<h3>Drives</h3>
<table><tr><th>Device</th><th>Model</th><th>Size</th><th>Bus</th><th>Serial</th></tr>{drv or '<tr><td colspan=5>none</td></tr>'}</table>
{('<h2>Benchmarks</h2><p>' + ' · '.join(bench_bits) + '</p>') if bench_bits else ''}
<h2>Integrity</h2>
<p class="mono">sha256 {e(rep['_sha256'])}<br>hmac {e(rep['_hmac'] or 'not signed — no key configured')}</p>
<p>Verify: <span class="mono">python3 verify.py report.json --key-file ~/.rigcheck/keys/{e(rep['_key_id'] or '&lt;id&gt;')}.key</span></p>
<p style="color:#666;font-size:12.5px;margin-top:36px">Generated by RigCheck {e(m.get('rig_version','phase0'))}. Userspace RAM tests cannot cover memory occupied by the OS — use the Memtest86+ boot entry for full coverage. GPU stress and PSU rail analysis arrive with the full ISO.</p>
</div></body></html>"""

def console_summary(rep):
    col = {"PASS": C_G, "INFO": C_B, "SKIP": C_B, "WARN": C_Y, "FAIL": C_R}
    print()
    print(f"{C_B}================ RigCheck summary ================{C_0}")
    o = rep["summary"]["overall"]
    print(f"  Overall: {col.get(o,'')}{o}{C_0}   mode={rep['meta'].get('mode')}  duration={int(rep['meta'].get('duration_s',0))//60}min")
    print(f"  Fingerprint: {C_B}{rep['_fingerprint']}{C_0}  (read this out to the owner if asked)")
    print()
    for k, v in rep["components"].items():
        print(f"  {col.get(v['status'],'')}{v['status']:<5}{C_0} {k}")
        for r in v["reasons"]:
            print(f"         - {r}")
    print(f"{C_B}=================================================={C_0}")

# ------------------------------------------------------------------ email / llm
def smtp_send(conf, subject, body, attachments=()):
    import smtplib
    from email.message import EmailMessage
    host, to = conf.get("SMTP_HOST"), conf.get("EMAIL_TO")
    if not host or not to: return False
    msg = EmailMessage()
    msg["Subject"], msg["From"], msg["To"] = subject, conf.get("EMAIL_FROM") or conf.get("SMTP_USER"), to
    msg.set_content(body)
    for path in attachments:
        if os.path.exists(path):
            with open(path, "rb") as f:
                data = f.read()
            if path.endswith(".html"):
                msg.add_attachment(data.decode(errors="replace"), subtype="html",
                                   filename=os.path.basename(path))
            else:
                msg.add_attachment(data, maintype="application", subtype="json",
                                   filename=os.path.basename(path))
    port = int(conf.get("SMTP_PORT") or 587)
    if port == 465:
        s = smtplib.SMTP_SSL(host, port, timeout=30)
    else:
        s = smtplib.SMTP(host, port, timeout=30); s.starttls()
    if conf.get("SMTP_USER"): s.login(conf["SMTP_USER"], conf.get("SMTP_PASSWORD", ""))
    s.send_message(msg); s.quit()
    return True

def llm_analyze(conf, rep):
    key = conf.get("LLM_API_KEY")
    if not key: return None
    slim = {k: v for k, v in rep.items() if not k.startswith("_")}
    slim.get("sensors", {}).pop("series", None)
    prompt = ("You are a PC hardware diagnostics expert. Below is a JSON report from RigCheck, a bootable "
              "hardware test USB. Analyze it: list detected issues by severity (CRITICAL/WARNING/INFO), likely "
              "root causes, and concrete next steps. If everything is healthy, say so and note anything worth "
              "monitoring. Be concise and practical.\n\n" + json.dumps(slim, default=str)[:60000])
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps({"model": conf.get("LLM_MODEL") or "claude-sonnet-4-6", "max_tokens": 1500,
                         "messages": [{"role": "user", "content": prompt}]}).encode(),
        headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        j = json.load(r)
    return "".join(b.get("text", "") for b in j.get("content", []))

def is_online():
    try:
        socket.create_connection(("1.1.1.1", 443), timeout=4).close(); return True
    except OSError:
        return False

# ------------------------------------------------------------------ commands
def canonical(rep): return json.dumps(rep, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str).encode()

def cmd_finalize(conf_path, run):
    conf = read_conf(conf_path)
    meta_env = read_env(os.path.join(run, "meta.env"))
    rep = {
        "meta": {
            "rig_version": meta_env.get("RIG_VERSION", "phase0"), "mode": meta_env.get("MODE"),
            "timestamp_utc": meta_env.get("START_UTC"), "start_ts": int(meta_env.get("START_TS", 0) or 0),
            "duration_s": int(meta_env.get("DURATION_S", 0) or 0),
            "aborted": meta_env.get("ABORTED") == "1", "abort_reason": meta_env.get("ABORT_REASON", ""),
            "challenge_nonce": meta_env.get("CHALLENGE_NONCE", ""),
            "abort_temp_c": int(meta_env.get("ABORT_TEMP_C", 95) or 95),
        },
        "identity": build_identity(run),
        "tests": {
            "ram": read_env(os.path.join(run, "ram.env")),
            "cpu": read_env(os.path.join(run, "cpu.env")),
            "gpu": read_env(os.path.join(run, "gpu.env")),
            "storage": build_storage(run),
        },
    }
    pts = temps_series(run)
    rep["sensors"] = {
        "max_cpu_c": max((p[1] for p in pts), default=0),
        "max_nvme_c": max((p[2] for p in pts), default=0),
        "series": pts,
    }
    dmesg_txt = raw(run, "dmesg_err.txt")
    rep["dmesg_flags"] = {"mce": len(re.findall(r"mce|machine check|hardware error", dmesg_txt, re.I)),
                          "thermal": len(re.findall(r"thermal|throttl", dmesg_txt, re.I))}
    apply_rules(rep)

    canon = canonical(rep)
    sha = hashlib.sha256(canon).hexdigest()
    key, key_id = conf.get("SIGNING_KEY", ""), conf.get("SIGNING_KEY_ID", "")
    mac = hmac.new(bytes.fromhex(key), canon, hashlib.sha256).hexdigest() if key else ""
    rep["_sha256"], rep["_hmac"], rep["_key_id"], rep["_fingerprint"] = sha, mac, key_id, sha[:12]

    envelope = {"report": rep_strip(rep), "integrity": {
        "sha256": sha, "hmac_sha256": mac, "key_id": key_id,
        "algo": "HMAC-SHA256 over canonical JSON of .report"}}
    jpath = os.path.join(run, "report.json")
    with open(jpath, "w") as f: json.dump(envelope, f, indent=2, default=str)

    llm_text = None
    online = is_online()
    if online and conf.get("LLM_API_KEY"):
        print(f"{C_B}[rigcheck]{C_0} Requesting LLM analysis...")
        try: llm_text = llm_analyze(conf, rep)
        except Exception as ex: print(f"{C_Y}[warn]{C_0} LLM analysis failed: {ex}")
        if llm_text:
            with open(os.path.join(run, "analysis.txt"), "w") as f: f.write(llm_text)

    hpath = os.path.join(run, "report.html")
    with open(hpath, "w") as f:
        f.write(render_html(rep, svg_chart(pts, rep["meta"]["abort_temp_c"]), llm_text))

    console_summary(rep)

    if online and conf.get("EMAIL_TO") and conf.get("SMTP_HOST"):
        try:
            body = f"RigCheck {rep['summary']['overall']} — {rep['identity'].get('system_product') or 'PC'} " \
                   f"(board {rep['identity'].get('board_serial')})\nfingerprint {rep['_fingerprint']}\n\n" + \
                   "\n".join(rep["summary"]["issues"] or ["No issues found."])
            smtp_send(conf, f"[RigCheck] {rep['summary']['overall']} — {rep['identity'].get('system_product') or 'PC'} ({rep['meta'].get('mode')})",
                      body, attachments=(hpath, jpath))
            print(f"{C_G}[ok]{C_0} Report emailed to {conf['EMAIL_TO']}")
        except Exception as ex:
            print(f"{C_Y}[warn]{C_0} Email failed: {ex} (report is still on the USB)")
    elif conf.get("EMAIL_TO"):
        print(f"{C_Y}[warn]{C_0} Offline — report not emailed (it is on the USB)")

    return {"PASS": 0, "INFO": 0, "SKIP": 0, "WARN": 1, "FAIL": 2}.get(rep["summary"]["overall"], 1)

def rep_strip(rep):
    return {k: v for k, v in rep.items() if not k.startswith("_")}

def cmd_notify_start(conf_path, run):
    conf = read_conf(conf_path)
    meta = read_env(os.path.join(run, "meta.env"))
    ident = build_identity(run) if os.path.exists(os.path.join(run, "raw", "lscpu.txt")) else {}
    host = ident.get("system_product") or "unknown PC"
    try:
        smtp_send(conf, f"[RigCheck] test STARTED — {host} ({meta.get('MODE')})",
                  f"RigCheck {meta.get('MODE')} test started at {meta.get('START_UTC')} UTC on {host}.\n"
                  f"Board serial: {ident.get('board_serial')}\nReport will follow when done.")
        print("start notification sent")
    except Exception as ex:
        print(f"start notification failed: {ex}")

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__); sys.exit(1)
    cmd, conf_path, run = sys.argv[1], sys.argv[2], sys.argv[3]
    if cmd == "finalize": sys.exit(cmd_finalize(conf_path, run))
    elif cmd == "notify-start": cmd_notify_start(conf_path, run)
    else: print(__doc__); sys.exit(1)
