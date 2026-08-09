#!/usr/bin/env python3
"""Extract per-repetition metrics from a pcap into results.csv.

Reads every TCP packet — via tshark field extraction when tshark is
installed (robust across tshark versions, unlike parsing `-z conv,tcp`
tables), else via a built-in classic-pcap parser — aggregates per TCP
stream, and appends one CSV row for the repetition. Also writes a
per-stream JSON next to the pcap for per-message analysis. Both readers
produce identical rows, so results are tool-independent and can be
cross-checked in Wireshark.

Byte metrics:
  bytes_ab / bytes_ba   frame bytes on the wire sent by the local / remote
                        side, across all matching streams
  bytes_total           bytes_ab + bytes_ba
  tls_bytes_total       sum of TCP payload bytes (TLS record bytes)

Time metrics:
  t_first_syn           epoch of the first SYN (fallback: first packet)
  t_last_fin            epoch of the last FIN (fallback: last packet)
  duration_s            t_last_fin - t_first_syn

The "local" side is --local if given, otherwise the initiator of the
earliest stream in the capture. --remote-cidr (repeatable) keeps only
streams whose non-local endpoint falls inside one of the CIDRs (used for
the email capture to exclude unrelated production mail).
"""

import argparse
import csv
import ipaddress
import json
import os
import shutil
import struct
import subprocess
import sys

CSV_COLUMNS = [
    "system", "scenario", "rep", "conversations",
    "bytes_ab", "bytes_ba", "bytes_total", "tls_bytes_total",
    "t_first_syn", "t_last_fin", "duration_s",
    "baseline_adjusted_bytes", "notes",
]

TSHARK_FIELDS = [
    "frame.time_epoch", "tcp.stream",
    "ip.src", "ip.dst", "ipv6.src", "ipv6.dst",
    "frame.len", "tcp.len",
    "tcp.flags.syn", "tcp.flags.ack", "tcp.flags.fin",
    "tcp.srcport", "tcp.dstport",
    "udp.srcport", "udp.dstport", "udp.length",
]


def truthy(field: str) -> bool:
    return field in ("1", "True", "true")


def run_tshark(pcap: str, ports: list[int]) -> list[list[str]]:
    display_filter = "(tcp || udp) && (ip || ipv6)"
    if ports:
        port_expr = " || ".join(f"tcp.port=={p} || udp.port=={p}" for p in ports)
        display_filter += f" && ({port_expr})"
    cmd = ["tshark", "-r", pcap, "-Y", display_filter,
           "-T", "fields", "-E", "separator=\t"]
    for f in TSHARK_FIELDS:
        cmd += ["-e", f]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True)
    rows = []
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        r = line.split("\t")
        r += [""] * (len(TSHARK_FIELDS) - len(r))
        # Normalise tshark rows to the shared shape: UDP rows have no
        # tcp.stream/flags; synthesise stream ids from the 4-tuple and
        # treat udp payload (length - 8B header) as the transport payload.
        (t, stream, ip4s, ip4d, ip6s, ip6d, frame_len, tcp_len,
         syn, ack, fin, sport, dport, usport, udport, ulen) = r
        if stream == "" and (usport or udport):
            src = ip4s or ip6s
            dst = ip4d or ip6d
            key = "udp:" + "|".join(sorted([f"{src}:{usport}", f"{dst}:{udport}"]))
            payload = str(max(0, int(ulen or 8) - 8))
            rows.append([t, key, ip4s, ip4d, ip6s, ip6d, frame_len, payload,
                         "0", "0", "0", usport, udport])
        else:
            rows.append([t, "tcp:" + stream, ip4s, ip4d, ip6s, ip6d, frame_len,
                         tcp_len, syn, ack, fin, sport, dport])
    return rows


def read_pcap_pure(pcap_path: str, ports: list[int]) -> list[list[str]]:
    """Classic-pcap fallback reader; emits rows shaped like run_tshark's.

    Supports linktypes EN10MB (1), RAW (101), LINUX_SLL (113) and
    NULL/loopback (0). TCP streams are keyed by 4-tuple, matching
    tshark's tcp.stream grouping closely enough for these captures
    (one connection per 4-tuple within a repetition's window).
    """
    with open(pcap_path, "rb") as f:
        data = f.read()
    if len(data) < 24:
        return []

    magic = data[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
    else:
        raise ValueError(f"{pcap_path}: not a classic pcap file (pcapng? install tshark)")
    nano = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
    linktype = struct.unpack(endian + "I", data[20:24])[0] & 0x0FFFFFFF

    rows: list[list[str]] = []
    streams: dict[tuple, int] = {}
    off = 24
    while off + 16 <= len(data):
        ts_sec, ts_frac, incl_len, orig_len = struct.unpack(endian + "IIII", data[off:off + 16])
        off += 16
        pkt = data[off:off + incl_len]
        off += incl_len
        ts = ts_sec + ts_frac / (1e9 if nano else 1e6)

        if linktype == 1:      # Ethernet
            if len(pkt) < 14:
                continue
            eth_type = struct.unpack("!H", pkt[12:14])[0]
            payload = pkt[14:]
            if eth_type == 0x8100 and len(payload) >= 4:  # 802.1Q
                eth_type = struct.unpack("!H", payload[2:4])[0]
                payload = payload[4:]
        elif linktype == 113:  # Linux cooked (SLL)
            if len(pkt) < 16:
                continue
            eth_type = struct.unpack("!H", pkt[14:16])[0]
            payload = pkt[16:]
        elif linktype == 101:  # raw IP
            eth_type = 0x0800 if pkt and (pkt[0] >> 4) == 4 else 0x86DD
            payload = pkt
        elif linktype == 0:    # NULL/loopback
            if len(pkt) < 4:
                continue
            fam = struct.unpack(endian + "I", pkt[:4])[0]
            eth_type = 0x0800 if fam == 2 else 0x86DD
            payload = pkt[4:]
        else:
            raise ValueError(f"{pcap_path}: unsupported linktype {linktype} (install tshark)")

        if eth_type == 0x0800:  # IPv4
            if len(payload) < 20:
                continue
            ihl = (payload[0] & 0x0F) * 4
            proto = payload[9]
            if proto not in (6, 17):  # TCP or UDP
                continue
            total_len = struct.unpack("!H", payload[2:4])[0]
            src = str(ipaddress.ip_address(payload[12:16]))
            dst = str(ipaddress.ip_address(payload[16:20]))
            ip4s, ip4d, ip6s, ip6d = src, dst, "", ""
            l4 = payload[ihl:total_len if 0 < total_len <= len(payload) else len(payload)]
        elif eth_type == 0x86DD:  # IPv6 (no extension-header walk; fine for these captures)
            if len(payload) < 40 or payload[6] not in (6, 17):
                continue
            proto = payload[6]
            plen = struct.unpack("!H", payload[4:6])[0]
            src = str(ipaddress.ip_address(payload[8:24]))
            dst = str(ipaddress.ip_address(payload[24:40]))
            ip4s, ip4d, ip6s, ip6d = "", "", src, dst
            l4 = payload[40:40 + plen]
        else:
            continue

        if proto == 6:
            if len(l4) < 20:
                continue
            sport, dport = struct.unpack("!HH", l4[:4])
            data_off = (l4[12] >> 4) * 4
            flags = l4[13]
            transport_payload = max(0, len(l4) - data_off)
            syn = "1" if flags & 0x02 else "0"
            ack = "1" if flags & 0x10 else "0"
            fin = "1" if flags & 0x01 else "0"
            proto_label = "tcp"
        else:
            if len(l4) < 8:
                continue
            sport, dport, ulen = struct.unpack("!HHH", l4[:6])
            transport_payload = max(0, ulen - 8)
            syn = ack = fin = "0"
            proto_label = "udp"

        if ports and sport not in ports and dport not in ports:
            continue

        key = (proto_label,) + tuple(sorted([(src, sport), (dst, dport)]))
        stream_id = streams.setdefault(key, len(streams))

        rows.append([f"{ts:.9f}", f"{proto_label}:{stream_id}", ip4s, ip4d, ip6s, ip6d,
                     str(orig_len), str(transport_payload), syn, ack, fin,
                     str(sport), str(dport)])
    return rows


def read_packets(pcap: str, ports: list[int]) -> list[list[str]]:
    if shutil.which("tshark"):
        return run_tshark(pcap, ports)
    return read_pcap_pure(pcap, ports)


def aggregate_streams(rows: list[list[str]]) -> dict[str, dict]:
    NORMALISED_FIELDS = 13   # both readers emit this row shape
    streams: dict[str, dict] = {}
    for row in rows:
        # Pad in case trailing empty fields were trimmed.
        row += [""] * (NORMALISED_FIELDS - len(row))
        (t, stream, ip4s, ip4d, ip6s, ip6d,
         frame_len, tcp_len, syn, ack, fin, sport, dport) = row
        src = ip4s or ip6s
        dst = ip4d or ip6d
        if not src or not stream:
            continue
        t = float(t)
        s = streams.setdefault(stream, {
            "stream": stream,
            "endpoints": [],
            "ports": {},
            "initiator": None,
            "first_ts": t,
            "last_ts": t,
            "first_syn_ts": None,
            "last_fin_ts": None,
            "frame_bytes": {},
            "tcp_payload_bytes": 0,
            "packets": 0,
        })
        s["first_ts"] = min(s["first_ts"], t)
        s["last_ts"] = max(s["last_ts"], t)
        for ep, port in ((src, sport), (dst, dport)):
            if ep not in s["endpoints"]:
                s["endpoints"].append(ep)
            if ep not in s["ports"] and port:
                s["ports"][ep] = int(port)
        s["frame_bytes"][src] = s["frame_bytes"].get(src, 0) + int(frame_len or 0)
        s["tcp_payload_bytes"] += int(tcp_len or 0)
        s["packets"] += 1
        if truthy(syn) and not truthy(ack):
            if s["first_syn_ts"] is None or t < s["first_syn_ts"]:
                s["first_syn_ts"] = t
                s["initiator"] = src
        if truthy(fin):
            if s["last_fin_ts"] is None or t > s["last_fin_ts"]:
                s["last_fin_ts"] = t
    return streams


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("pcap")
    ap.add_argument("--csv", required=True, help="results.csv to append to")
    ap.add_argument("--system", required=True)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--rep", required=True, type=int)
    ap.add_argument("--port", action="append", type=int, default=[],
                    help="restrict to TCP port (repeatable)")
    ap.add_argument("--local", help="IP of the local side (default: initiator of earliest stream)")
    ap.add_argument("--remote-cidr", action="append", default=[],
                    help="keep only streams whose remote endpoint is in CIDR (repeatable)")
    ap.add_argument("--keep-remote-port", action="append", type=int, default=[],
                    help="also keep streams whose remote endpoint uses this port, "
                         "regardless of --remote-cidr (e.g. a smarthost relay port)")
    ap.add_argument("--baseline-bps", type=float, default=None,
                    help="idle background bytes/s to subtract (whatsapp)")
    ap.add_argument("--notes", default="")
    args = ap.parse_args()

    rows = read_packets(args.pcap, args.port)
    streams = aggregate_streams(rows)
    if not streams:
        print(f"ERROR: no TCP packets matched in {args.pcap}", file=sys.stderr)
        return 1

    ordered = sorted(streams.values(), key=lambda s: s["first_ts"])

    local = args.local
    if not local:
        first = ordered[0]
        local = first["initiator"] or first["endpoints"][0]

    if args.remote_cidr or args.keep_remote_port:
        nets = [ipaddress.ip_network(c) for c in args.remote_cidr]
        keep_ports = set(args.keep_remote_port)

        def keep(s: dict) -> bool:
            remotes = [ep for ep in s["endpoints"] if ep != local]
            if any(s["ports"].get(r) in keep_ports for r in remotes):
                return True
            return any(ipaddress.ip_address(r) in n for r in remotes for n in nets)

        ordered = [s for s in ordered if keep(s)]
        if not ordered:
            print("ERROR: no streams matched --remote-cidr/--keep-remote-port filter",
                  file=sys.stderr)
            return 1

    bytes_ab = sum(s["frame_bytes"].get(local, 0) for s in ordered)
    bytes_total = sum(sum(s["frame_bytes"].values()) for s in ordered)
    bytes_ba = bytes_total - bytes_ab
    tls_bytes_total = sum(s["tcp_payload_bytes"] for s in ordered)

    syn_times = [s["first_syn_ts"] for s in ordered if s["first_syn_ts"] is not None]
    fin_times = [s["last_fin_ts"] for s in ordered if s["last_fin_ts"] is not None]
    t_first_syn = min(syn_times) if syn_times else min(s["first_ts"] for s in ordered)
    t_last_fin = max(fin_times) if fin_times else max(s["last_ts"] for s in ordered)
    duration_s = t_last_fin - t_first_syn

    baseline_adjusted = ""
    if args.baseline_bps is not None:
        baseline_adjusted = max(0, round(bytes_total - args.baseline_bps * duration_s))

    row = {
        "system": args.system,
        "scenario": args.scenario,
        "rep": args.rep,
        "conversations": len(ordered),
        "bytes_ab": bytes_ab,
        "bytes_ba": bytes_ba,
        "bytes_total": bytes_total,
        "tls_bytes_total": tls_bytes_total,
        "t_first_syn": f"{t_first_syn:.6f}",
        "t_last_fin": f"{t_last_fin:.6f}",
        "duration_s": f"{duration_s:.6f}",
        "baseline_adjusted_bytes": baseline_adjusted,
        "notes": args.notes,
    }

    write_header = not os.path.exists(args.csv) or os.path.getsize(args.csv) == 0
    os.makedirs(os.path.dirname(os.path.abspath(args.csv)), exist_ok=True)
    with open(args.csv, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        if write_header:
            writer.writeheader()
        writer.writerow(row)

    streams_out = os.path.splitext(args.pcap)[0] + ".streams.json"
    with open(streams_out, "w") as f:
        json.dump({
            "local": local,
            "streams": [{
                "stream": s["stream"],
                "endpoints": s["endpoints"],
                "ports": s["ports"],
                "initiator": s["initiator"],
                "first_ts": s["first_ts"],
                "last_ts": s["last_ts"],
                "first_syn_ts": s["first_syn_ts"],
                "last_fin_ts": s["last_fin_ts"],
                "frame_bytes": s["frame_bytes"],
                "tcp_payload_bytes": s["tcp_payload_bytes"],
                "packets": s["packets"],
            } for s in ordered],
        }, f, indent=2)

    print(f"{args.system}/{args.scenario} rep{args.rep}: "
          f"{len(ordered)} conv, {bytes_total} bytes "
          f"({bytes_ab} ->, {bytes_ba} <-), {duration_s:.3f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
