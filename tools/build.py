"""Build the driver package.

    python tools/build.py              ->  dist/DirectorLink-PIMA-Force.c4z
                                           dist/SHA256SUMS.txt
    python tools/build.py --no-tests   (skip the Lua tests)

The Lua tests run first when lua5.1 (or lua, luajit) is found. driver.lua gets
src/pima_force.lua, src/x25519.lua and src/base64.lua inlined in place of their
require() lines, so the package holds a single script, and DRIVER_SEMVER set from the VERSION file (1.0.0, or 1.0.0-beta.2
for a beta). The packaged driver.xml gets <version> = major*1000000 + minor*10000 +
patch*100 + build, where build is the beta number (1-98) or 99 for the release
itself, so every beta and the release that follows it count up (1.0.0-beta.1 ->
1000001, 1.0.0 -> 1000099, 1.0.1 -> 1000199). Every property the Lua handles must
exist in driver.xml. The files in src/ are not modified. Never rename the package:
Composer updates a driver by its file name.

dist/driver.lua keeps a copy of the packaged script for inspection
(DRIVER_LUA=dist/driver.lua lua5.1 tests/test_driver.lua tests it).
"""
import datetime
import hashlib
import os
import re
import shutil
import subprocess
import sys
import xml.dom.minidom
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
DIST = os.path.join(ROOT, "dist")
PACKAGE = "DirectorLink-PIMA-Force.c4z"
# Each module is inlined in place of its require() line, so the package holds a single script.
MODULES = (
    ('local F = require("pima_force")', "pima_force.lua", "F"),
    ('local X25519 = require("x25519")', "x25519.lua", "X25519"),
    ('local Base64 = require("base64")', "base64.lua", "Base64"),
)
TESTS = ("tests/test_force_protocol.lua", "tests/test_driver.lua", "tests/test_sia.lua")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def parse_version(semver):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?", semver)
    if not m:
        sys.exit(f"VERSION '{semver}' must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N")
    major, minor, patch = (int(x) for x in m.groups()[:3])
    beta = int(m.group(4)) if m.group(4) else None
    if minor > 99 or patch > 99 or (beta is not None and not 1 <= beta <= 98):
        sys.exit("minor and patch must be 0-99 and the beta number 1-98")
    return major * 1000000 + minor * 10000 + patch * 100 + (beta if beta is not None else 99)


def read_version():
    semver = read(os.path.join(ROOT, "VERSION")).strip()
    return semver, parse_version(semver)


def run_tests():
    lua = shutil.which("lua5.1") or shutil.which("lua") or shutil.which("luajit")
    if not lua:
        print("! no Lua interpreter found, skipping tests")
        return
    for test in TESTS:
        result = subprocess.run([lua, test], cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
        summary = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
        print(f"  {test}: {summary}")
        if result.returncode != 0:
            print(result.stdout + result.stderr)
            sys.exit("tests failed, not building")


def check_xml(xml_text, lua_text):
    doc = xml.dom.minidom.parseString(xml_text.encode("utf-8"))
    names = {p.getElementsByTagName("name")[0].firstChild.nodeValue
             for p in doc.getElementsByTagName("property")}
    used = set(re.findall(r'PROPERTY_HANDLERS\["([^"]+)"\]', lua_text))
    used |= set(re.findall(r'SetReadOnlyProperty\("([^"]+)"', lua_text))
    order = re.search(r"PROPERTY_ORDER = \{(.*?)\}", lua_text, re.S).group(1)
    used |= set(re.findall(r'"([^"]+)"', order))
    missing = sorted(u for u in used if u not in names)
    if missing:
        sys.exit(f"properties used in Lua but missing from driver.xml: {missing}")


def assemble_lua(semver):
    lua = read(os.path.join(SRC, "driver.lua"))
    for line, name, var in MODULES:
        if line not in lua:
            sys.exit(f"'{line}' not found in driver.lua")
        module = read(os.path.join(SRC, name))
        inlined = (f"local {var} = (function()\n-- ===== {name} (inlined by tools/build.py) =====\n"
                   + module.rstrip() + f"\nend)()\n-- ===== end {name} =====")
        lua = lua.replace(line, inlined, 1)
    if re.search(r"\brequire\s*\(", re.sub(r"--[^\n]*", "", lua)):
        sys.exit("driver.lua still requires a module: Control4 loads only the one script")
    lua, n = re.subn(r'^DRIVER_SEMVER = "[^"]*"', f'DRIVER_SEMVER = "{semver}"', lua, count=1, flags=re.M)
    if n != 1:
        sys.exit("DRIVER_SEMVER line not found in driver.lua")
    return lua


def stamp_xml(xml_text, number):
    now = datetime.datetime.now().strftime("%m/%d/%Y %H:%M")
    xml_text, n1 = re.subn(r"<version>\d+</version>", f"<version>{number}</version>", xml_text, count=1)
    xml_text, n2 = re.subn(r"<modified>[^<]*</modified>", f"<modified>{now}</modified>", xml_text, count=1)
    if n1 != 1 or n2 != 1:
        sys.exit("driver.xml: <version> or <modified> not found")
    return xml_text


def check_runtime(xml_text):
    # Under LuaJIT on the controller (jit="1"), the X25519 of a sealed command took 14 s (1.2.0).
    script = re.search(r"<script\b[^>]*>", xml_text)
    if not script or re.search(r"\bjit\s*=", script.group(0)):
        sys.exit('driver.xml: <script> must run on standard Lua (no jit="1"): X25519 takes 14 s under LuaJIT')


def build(semver, number):
    xml_text = read(os.path.join(SRC, "driver.xml"))
    check_xml(xml_text, read(os.path.join(SRC, "driver.lua")))
    check_runtime(xml_text)
    lua = assemble_lua(semver)
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, PACKAGE)
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("driver.xml", stamp_xml(xml_text, number))
        z.writestr("driver.lua", lua)
        for base, _, files in os.walk(os.path.join(SRC, "www")):
            for name in sorted(files):
                full = os.path.join(base, name)
                z.write(full, os.path.relpath(full, SRC).replace(os.sep, "/"))
        z.write(os.path.join(ROOT, "LICENSE"), "www/LICENSE.txt")
        z.write(os.path.join(ROOT, "NOTICE"), "www/NOTICE.txt")
    with open(os.path.join(DIST, "driver.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(lua)
    with zipfile.ZipFile(out) as z:
        listing = ", ".join(z.namelist())
    print(f"built dist/{PACKAGE} ({os.path.getsize(out)} bytes): {listing}")
    return out


def main():
    semver, number = read_version()
    print(f"version {semver} (driver.xml version {number})")
    if "--no-tests" not in sys.argv:
        run_tests()
    out = build(semver, number)
    with open(os.path.join(DIST, "SHA256SUMS.txt"), "w", newline="\n") as sums:
        digest = hashlib.sha256(open(out, "rb").read()).hexdigest()
        sums.write(f"{digest}  {PACKAGE}\n")
    print("wrote dist/SHA256SUMS.txt")


if __name__ == "__main__":
    main()
