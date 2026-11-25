# xbps-fofrweb

Unofficial Void Linux package repository: my own packages and ones not in the official repo.
This repository holds the templates and the build/publish tooling. The packages are served at
**https://xbps.fofrweb.net/current**, for `x86_64` and `aarch64` (glibc).

## Using it

```sh
echo 'repository=https://xbps.fofrweb.net/current' | sudo tee /etc/xbps.d/20-fofrweb.conf
sudo xbps-install -S
```

The first sync asks to import the signing key. Accept it only if it reads:

- signed by: `fofrweb.net xbps repository <admin@fofrweb.net>`
- fingerprint: `(fill in from ./repo.sh fingerprint)`

**Order matters.** xbps reads `/etc/xbps.d` and `/usr/share/xbps.d` in alphabetical order,
and the first repository that has a package wins, whatever the version. `20-fofrweb.conf`
comes after the official `00-repository-main.conf`, so as soon as upstream ships a package,
its build is used. To override an upstream package with a patched build from here, the file
must sort first instead, e.g. `00-fofrweb.conf`; then every package found here shadows the
official one until it is removed here.

## Layout

This directory looks like a void-packages tree to xtools, see [below](#xtools).

| Path | What |
|---|---|
| `srcpkgs/<pkg>/` | Templates (with `files/`, `patches/`, subpackage symlinks). A directory here replaces upstream's whole directory of the same name in the build. |
| `common/shlibs` | Only the overlay's additions to void-packages' `common/shlibs`, for libraries packaged here; appended to the worktree's copy |
| `xbps-src` | Shim: copies `srcpkgs/` and `common/shlibs` into the build worktree and runs the real `xbps-src` there; answers `show-var XBPS_DISTDIR` with this directory |
| `repo.sh` | setup, build for all arches, publish, keys (run it without arguments for help) |
| `config.sh` | Settings for both scripts (void-packages clone, build worktree, arches, upload target, signing key) with neutral defaults |
| `config.local.sh` | Your values, gitignored; start from `config.local.sh.example`. The environment overrides both files |
| `hostdir`, `common/environment`, `common/cross-profiles` | Symlinks into the worktree made by `xbps-src`, gitignored (for `xi`, `xgensum`) |
| `tests/test.sh` | Offline test of the shim, build, publish/remove and signing |

Outside this repository (names from `config.sh`):

| Setting | What |
|---|---|
| `BUILD_DIR` | Build worktree of the void-packages clone `VOID_PACKAGES`, detached at upstream master. Owned by these scripts: every `./xbps-src` run resets its `srcpkgs/` and `common/shlibs`, so don't work in it |
| `$BUILD_DIR/hostdir/binpkgs` | Built packages (here also as `./hostdir/binpkgs`) |
| `STAGING` | Local copy of the published repository, pulled before every change |
| `REMOTE` | Where the repository is uploaded with rsync: `host:dir` over SSH, or a local directory. Any static web server serving that directory will do |
| `PASS_ENTRY` | pass entry holding the RSA signing key (PEM). It is copied to `$XDG_RUNTIME_DIR` (tmpfs) only while signing |

## One-time setup

1. Settings: `cp config.local.sh.example config.local.sh`. Set `REMOTE` and, if they differ
   from the defaults in `config.sh`, the void-packages clone and the build worktree.
2. Signing key: `./repo.sh keygen`, then put the fingerprint into this README.
3. Build worktree: `./repo.sh setup` (git worktree at upstream master + `xbps-src binary-bootstrap`).
4. A static web server for the directory `REMOTE` points at, over HTTPS.

## Workflow

```sh
./repo.sh import witr witr     # srcpkgs/witr from branch witr of the void-packages clone
                               # (or xnew, or write srcpkgs/<pkg>/template by hand)
./repo.sh build witr           # x86_64 natively, aarch64 cross-compiled
./repo.sh publish witr         # index, sign, upload; no names = all of srcpkgs/
./repo.sh list                 # what the repository holds, per arch
```

- **Changing a published package:** bump `revision` (or `version`). A pkgver that is already
  in the repository is not uploaded again, and clients wouldn't update to it anyway.
- **Upstream moves on:** `./repo.sh update` (worktree to upstream master, masterdir update)
  before building against newer dependencies.
- **Removing:** `./repo.sh remove <name>...` takes binary package names, so list
  subpackages too.
- **One arch only:** `ARCHS=x86_64 ./repo.sh build foo`, or `./xbps-src pkg foo` directly.
- **`nocross` packages** can't be cross-compiled for aarch64. Build them under qemu instead:
  install `qemu-user-static` (binfmt), run `./xbps-src -A aarch64 binary-bootstrap` once,
  then `./xbps-src -A aarch64 pkg foo` and `./repo.sh publish foo`.
- **`restricted=yes`** templates are refused by `publish`, because their licence may forbid
  redistribution. `ALLOW_RESTRICTED=yes` overrides that.
- **Signing on a machine you reach over SSH:** pass there needs your local gpg-agent
  forwarded, since the smartcard stays local. `SIGNING_KEY_FILE=<pem>` signs with a key file
  instead of pass.

## xtools

xtools find the tree with `xdistdir`. In a git repo whose top level has an executable
`xbps-src`, that is the tree, and here the shim answers with this directory. So run them
from inside this repository (any subdirectory works) and they act on `./srcpkgs` and this
repository's git, as in void-packages:

```sh
xnew foo                       # new srcpkgs/foo/template
xgensum -i foo                 # checksums: fetches foo's distfiles as written here
xlint foo                      # also: xlint : (templates staged in git)
./xbps-src pkg foo             # build (x86_64); -a aarch64 to cross-compile
xi foo                         # install the local build from ./hostdir/binpkgs
xbump foo                      # git commit "foo: update to <version>" (with common/shlibs)
xrevbump 'rebuild for X' foo   # revision + 1 and commit
```

`./xbps-src` runs one at a time (`flock` on the worktree's `hostdir/.xbps-fofrweb.lock`).
A second run, e.g. `xgensum` during a build, waits rather than rewriting the tree under
the build.

## Test

`tests/test.sh` runs offline and touches neither pass nor the server. It checks:

- against a fake worktree with a stub `xbps-src`: `xdistdir` resolves to this directory,
  the overlay replaces upstream's template directory, `common/shlibs` is appended once, the
  gitignored symlinks are made, `xlint <name>` finds the template, and `repo.sh build`
  builds per arch, noarch only once
- with dummy x86_64, aarch64 and noarch packages and a throwaway key: obsolete versions are
  removed per arch, subpackages can be removed, and an `xbps-install` client accepts the
  repository signature and the key fingerprint `repo.sh` reports
