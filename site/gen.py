#!/usr/bin/env python3
"""Website of the repository: index.html and packages.json from the staged repodata.

Run by repo.sh after every upload (publish, remove) and by `repo.sh site`. It reads only
<arch>-repodata in --repo, so the page shows exactly what clients get, and takes the key
fingerprint from the public key the repodata carries, as xbps-install shows it.
Needs Python 3.14+ (tarfile reads zstd) and ssh-keygen.
"""

import argparse
import datetime
import html
import json
import os
import re
import plistlib
import subprocess
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def read_repodata(path):
    """(index, meta) of one <arch>-repodata archive."""
    with tarfile.open(path, "r:*") as tar:
        index = plistlib.load(tar.extractfile("index.plist"))
        try:
            meta = plistlib.load(tar.extractfile("index-meta.plist"))
        except (KeyError, plistlib.InvalidFileException):
            meta = {}  # unsigned repository: no or an empty index-meta.plist
    return index, meta


def fingerprint(pubkey_pem):
    """MD5 fingerprint of a PEM public key in xbps form (aa:bb:...), '' if there is none."""
    if not pubkey_pem:
        return ""
    if isinstance(pubkey_pem, bytes):
        pubkey_pem = pubkey_pem.decode()
    with tempfile.NamedTemporaryFile("w", suffix=".pem") as f:
        f.write(pubkey_pem)
        f.flush()
        ssh = subprocess.run(["ssh-keygen", "-i", "-m", "PKCS8", "-f", f.name],
                             check=True, capture_output=True, text=True).stdout
    out = subprocess.run(["ssh-keygen", "-l", "-E", "md5", "-f", "-"], input=ssh,
                         check=True, capture_output=True, text=True).stdout
    return out.split()[1].removeprefix("MD5:")


def source_of(name, srcpkgs):
    """Source package from the overlay when the repodata lacks sourcepkg: a subpackage is a
    symlink srcpkgs/<name> -> <source>"""
    link = os.path.join(srcpkgs or "", name)
    if srcpkgs and os.path.islink(link):
        return os.path.basename(os.readlink(link))
    return name


def collect(repo, archs, srcpkgs=None):
    """Packages merged over the arches: one entry per name, version per arch."""
    pkgs, meta = {}, {}
    for arch in archs:
        path = os.path.join(repo, f"{arch}-repodata")
        if not os.path.isfile(path):
            continue
        index, m = read_repodata(path)
        meta = meta or m
        for name, p in index.items():
            pkg_arch = p.get("architecture", arch)
            e = pkgs.setdefault(name, {
                "name": name,
                "desc": p.get("short_desc", ""),
                "homepage": p.get("homepage", ""),
                "license": p.get("license", ""),
                "source": p.get("sourcepkg") or source_of(name, srcpkgs),
                "installed_size": p.get("installed_size", 0),
                "depends": p.get("run_depends", []),
                "archs": [],
                "versions": {},
            })
            if pkg_arch not in e["versions"]:
                e["versions"][pkg_arch] = p["pkgver"][len(name) + 1:]
                e["archs"].append(pkg_arch)
            # when it was published: mtime of the package file, kept by publish and rsync -t
            f = os.path.join(repo, f'{p["pkgver"]}.{pkg_arch}.xbps')
            if os.path.isfile(f):
                t = datetime.datetime.fromtimestamp(int(os.path.getmtime(f)), datetime.UTC)
                e["updated"] = max(e.get("updated", ""), t.isoformat())
    return sorted(pkgs.values(), key=lambda e: e["name"]), meta


def render_pkg(p, source_url):
    """One <li>: name, version(s) and arches, description, licence, links."""
    e = html.escape
    versions = set(p["versions"].values())
    if len(versions) == 1:
        ver = f'{e(versions.pop())} ({e(", ".join(p["archs"]))})'
    else:
        ver = ", ".join(f"{e(v)} ({e(a)})" for a, v in p["versions"].items())
    if p.get("updated"):
        ver += f', {p["updated"][:10]}'
    links = []
    if p["homepage"]:
        links.append(f'<a href="{e(p["homepage"])}" target="_blank">homepage</a>')
    links.append(f'<a href="{e(source_url)}/tree/master/srcpkgs/{e(p["source"])}" '
                 f'target="_blank">template</a>')
    lic = f' {e(p["license"])}.' if p["license"] else ""
    return (f'<li id="{e(p["name"])}"><b>{e(p["name"])}</b> {ver}: {e(p["desc"])}.{lic} '
            f'{" · ".join(links)}</li>')


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True, help="directory with <arch>-repodata")
    ap.add_argument("--archs", required=True, help="space separated arches")
    ap.add_argument("--repo-url", required=True, help="URL clients put into xbps.d")
    ap.add_argument("--source-url", required=True, help="GitHub URL of this repository")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--srcpkgs", help="overlay srcpkgs/, for packages without sourcepkg")
    ap.add_argument("--latest", type=int, default=5,
                    help="how many recently published packages to show; the rest are collapsed")
    a = ap.parse_args()

    archs = a.archs.split()
    pkgs, meta = collect(a.repo, archs, a.srcpkgs)
    fp = fingerprint(meta.get("public-key"))
    signed_by = meta.get("signature-by", "")
    now = datetime.datetime.now(datetime.UTC).replace(microsecond=0)
    source_url = a.source_url.rstrip("/")

    data = {
        "generated": now.isoformat(),
        "repository": a.repo_url,
        "archs": archs,
        "signed_by": signed_by,
        "fingerprint": fp,
        "packages": pkgs,
    }
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "packages.json"), "w") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
        f.write("\n")

    e = html.escape
    latest = sorted(pkgs, key=lambda p: p.get("updated", ""), reverse=True)[:a.latest]
    rest = [p for p in pkgs if p not in latest]
    more = ""
    if rest:
        items = "\n".join(render_pkg(p, source_url) for p in rest)
        more = f'<details id="more"><summary>All other packages ({len(rest)})</summary>\n<ul>\n{items}\n</ul>\n</details>'
    values = {
        "REPO_URL": e(a.repo_url),
        "SOURCE_URL": e(source_url),
        "REQUEST_URL": e(f"{source_url}/issues/new?template=package-request.yml"),
        "FINGERPRINT": e(fp or "(not signed yet)"),
        "SIGNED_BY": e(signed_by or "(not signed yet)"),
        "ARCHS": e(", ".join(archs)),
        "COUNT": str(len(pkgs)),
        "GENERATED": e(now.strftime("%Y-%m-%d %H:%M UTC")),
        "LATEST": "\n".join(render_pkg(p, source_url) for p in latest),
        "MORE": more,
    }
    with open(os.path.join(HERE, "index.html")) as f:
        page = f.read()
    # one pass, so text inserted from package data is never taken for a placeholder
    page = re.sub(r"@([A-Z_]+)@", lambda m: values[m[1]], page)
    with open(os.path.join(a.out, "index.html"), "w") as f:
        f.write(page)


if __name__ == "__main__":
    main()
