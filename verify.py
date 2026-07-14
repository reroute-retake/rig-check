#!/usr/bin/env python3
"""RigCheck report verifier — run on any machine with Python 3.

Checks that a report.json was produced by a stick holding your signing key
and has not been modified since. Usage:
    python3 verify.py report.json --key-file ~/.rigcheck/keys/<stick-id>.key
    python3 verify.py report.json --key <hex>
"""
import argparse, hashlib, hmac, json, sys

def canonical(report: dict) -> bytes:
    return json.dumps(report, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--key", help="signing key as hex")
    ap.add_argument("--key-file", help="file containing the hex signing key")
    args = ap.parse_args()

    key = args.key
    if args.key_file:
        key = open(args.key_file).read().strip()

    with open(args.report) as f:
        envelope = json.load(f)
    report = envelope.get("report")
    integ = envelope.get("integrity", {})
    if report is None:
        print("INVALID: file has no .report section"); sys.exit(2)

    canon = canonical(report)
    sha = hashlib.sha256(canon).hexdigest()
    print(f"sha256 fingerprint : {sha[:12]}  (full: {sha})")
    if integ.get("sha256") != sha:
        print("INVALID: sha256 mismatch — the report content was MODIFIED after generation.")
        sys.exit(2)
    print("sha256             : matches embedded value")

    if not key:
        print("NOTE: no key given — integrity hash OK, but authenticity NOT verified (anyone can recompute a hash). Pass --key/--key-file.")
        sys.exit(0)
    want = hmac.new(bytes.fromhex(key), canon, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(want, integ.get("hmac_sha256", "")):
        print("INVALID: HMAC mismatch — report was NOT signed with this key (tampered or wrong key).")
        sys.exit(2)

    m = report.get("meta", {}); ident = report.get("identity", {})
    print("HMAC signature     : VALID — genuine report from stick", integ.get("key_id", "?"))
    print(f"generated (UTC)    : {m.get('timestamp_utc','?')}   mode: {m.get('mode','?')}   overall: {report.get('summary',{}).get('overall','?')}")
    print(f"machine            : {ident.get('system_manufacturer','?')} {ident.get('system_product','?')}  board serial: {ident.get('board_serial','?')}")
    if m.get("challenge_nonce"):
        print(f"challenge nonce    : {m['challenge_nonce']}  (confirm this matches the code you issued)")
    drives = ident.get("drives", [])
    if drives:
        print("drive serials      : " + ", ".join(f"{d.get('model','?')}[{d.get('serial','?')}]" for d in drives))
    print("Cross-check the serials above against the physical machine.")

if __name__ == "__main__":
    main()
