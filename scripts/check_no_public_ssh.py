#!/usr/bin/env python3
"""Fail if any google_compute_firewall ALLOWs tcp/22 or tcp/3389 from 0.0.0.0/0.

A tiny policy guard that runs in CI with no credentials. It is deliberately
conservative: a rule that allows "all" protocols, or tcp with no port list,
from 0.0.0.0/0 is treated as public SSH too.
"""
from __future__ import annotations

import pathlib
import re
import sys

PUBLIC = {"0.0.0.0/0", "::/0"}
ADMIN_PORTS = {"22", "3389"}
RESOURCE_RE = re.compile(r'resource\s+"google_compute_firewall"\s+"([^"]+)"\s*\{')


def blocks(text: str):
    """Yield (name, body) for every google_compute_firewall resource."""
    for m in RESOURCE_RE.finditer(text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        yield m.group(1), text[m.end() : i - 1]


def port_is_admin(port: str) -> bool:
    if "-" in port:
        lo, hi = (int(x) for x in port.split("-", 1))
        return any(lo <= int(p) <= hi for p in ADMIN_PORTS)
    return port in ADMIN_PORTS


def offending(body: str) -> bool:
    if "0.0.0.0/0" not in body and "::/0" not in body:
        return False
    if 'direction = "EGRESS"' in body.replace("  ", " "):
        return False
    for allow in re.finditer(r"allow\s*\{(.*?)\}", body, re.S):
        a = allow.group(1)
        proto = re.search(r'protocol\s*=\s*"([^"]+)"', a)
        ports = re.search(r"ports\s*=\s*\[(.*?)\]", a, re.S)
        if proto and proto.group(1) == "all":
            return True
        if proto and proto.group(1) == "tcp":
            if not ports:
                return True
            for p in re.findall(r'"([^"]+)"', ports.group(1)):
                if port_is_admin(p):
                    return True
    return False


def main() -> int:
    bad = []
    for tf in pathlib.Path("terraform").rglob("*.tf"):
        if ".terraform" in tf.parts:
            continue
        for name, body in blocks(tf.read_text()):
            if offending(body):
                bad.append(f"{tf}: google_compute_firewall.{name}")
    if bad:
        print("Public SSH/RDP ingress is forbidden in this landing zone:")
        print("\n".join(f"  - {b}" for b in bad))
        return 1
    print("OK: no firewall rule allows 22/3389 from 0.0.0.0/0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
