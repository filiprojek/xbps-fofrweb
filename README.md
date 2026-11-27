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
- fingerprint: `20:24:9a:06:48:55:ca:61:42:51:12:1b:e4:17:7f:c8`

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
| `site/` | The website: `index.html` (template) and `gen.py`, which fills it from the repodata |
| `.github/ISSUE_TEMPLATE/package-request.yml` | Issue form behind the site's "Request a package" button |
| `.github/pull_request_template.md` | Short checklist prefilled in new pull requests |
| `.github/workflows/` | GitHub CI, see [below](#github-ci) |
| `ci/` | Scripts the workflows run: build environment, changed packages, build, update check, upstream watch |
| `tests/test.sh` | Offline test of the shim, build, publish/remove/release, signing, the website and `ci/changed.sh` |

Outside this repository (names from `config.sh`):

| Setting | What |
|---|---|
| `BUILD_DIR` | Build worktree of the void-packages clone `VOID_PACKAGES`, detached at upstream master. Owned by these scripts: every `./xbps-src` run resets its `srcpkgs/` and `common/shlibs`, so don't work in it |
| `$BUILD_DIR/hostdir/binpkgs` | Built packages (here also as `./hostdir/binpkgs`) |
| `STAGING` | Local copy of the published repository, pulled before every change |
| `REMOTE` | Where the repository is uploaded with rsync: `host:dir` over SSH, or a local directory. Any static web server serving that directory will do |
| `PASS_ENTRY` | pass entry holding the RSA signing key (PEM). It is copied to `$XDG_RUNTIME_DIR` (tmpfs) only while signing |
| `SITE_REMOTE` | Where the website goes; default: the directory above `REMOTE`, so the page is the web root and the repository is below it. Empty: no website |
| `REPO_URL`, `SOURCE_URL` | The repository URL clients use and this repository on GitHub, as shown on the website |
| `GH`, `GH_REPO` | The gh CLI and `owner/name` on GitHub (default: from `SOURCE_URL`), for `release` |

## One-time setup

1. Settings: `cp config.local.sh.example config.local.sh`. Set `REMOTE` and, if they differ
   from the defaults in `config.sh`, the void-packages clone and the build worktree.
2. Signing key: `./repo.sh keygen`, then put the fingerprint into this README.
3. Build worktree: `./repo.sh setup` (git worktree at upstream master + `xbps-src binary-bootstrap`).
4. A static web server for the directory `REMOTE` points at, over HTTPS.

## Workflow

Through GitHub (CI builds, you sign and publish):

```sh
# pull request with srcpkgs/witr/template -> CI lints, tests, test-builds; merge it
./repo.sh release              # newest CI build on master: verify, sign, upload
./repo.sh release <commit>     # the CI build of a given commit on master
```

Entirely local:

```sh
./repo.sh import witr witr     # srcpkgs/witr from branch witr of the void-packages clone
                               # (or xnew, or write srcpkgs/<pkg>/template by hand)
./repo.sh build witr           # x86_64 natively, aarch64 cross-compiled
./repo.sh publish witr         # index, sign, upload; no names = all of srcpkgs/
./repo.sh list                 # what the repository holds, per arch
./repo.sh site                 # regenerate and upload only the website
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

## GitHub CI

| Workflow | When | What |
|---|---|---|
| `check.yml` | every pull request | shellcheck, `tests/test.sh`, `xlint` and a test build (x86_64, aarch64 cross) of the changed packages. Nothing is kept |
| `build.yml` | push to `master` changing `srcpkgs/`, or by hand with a package list | builds the changed packages from exactly that commit, attests their provenance, keeps them as artifacts for 30 days |
| `update-check.yml` | Mondays, or by hand | `xbps-src update-check` per package; a pull request `update/<pkg>` with the new version and checksum, or an issue when `xgensum` fails |
| `upstream-watch.yml` | Mondays, or by hand | one issue listing the packages here that void-packages now has (clients get those from the official repository) |

Builds run in `ghcr.io/void-linux/void-glibc-full` as an unprivileged user, set up like
void-packages' own CI (`ci/setup.sh`). Templates are code, so:

- **No secrets on GitHub.** CI never signs or uploads. The signing key stays in pass.
- **Pull request builds are thrown away.** They run unreviewed code, from a commit that may
  differ from what gets merged. They use `pull_request`, never `pull_request_target`, with a
  read-only token.
- **`./repo.sh release` only takes what `build.yml` built on `master`.** It downloads the
  artifacts with `gh`, and before anything is staged checks each package's attestation:
  built by `.github/workflows/build.yml` of `GH_REPO`, ref `refs/heads/master`, from that
  commit (which must be on `origin/master`), on a GitHub-hosted runner. It also refuses
  packages that `srcpkgs/` doesn't have, arches outside `ARCHS` and `restricted=yes`. Then
  it stages, signs and uploads like `publish`.
- CI builds only what a push changed. After several merges, release each commit
  (`./repo.sh release <commit>`), or run `build.yml` by hand with the package list and
  release that.

Repository settings this relies on (GitHub, Settings → Actions → General):

- **Fork pull request workflows:** require approval for all external contributors, so a
  stranger's pull request doesn't run until you've looked at it.
- **Workflow permissions:** allow GitHub Actions to create pull requests (update check).
- Optionally protect `master` and require the `Check` jobs.

## Website

Every `publish` and `remove` regenerates the website from the repodata it just uploaded and
puts it into `SITE_REMOTE`: `index.html` (what the repository is, how to add it, the signing
key, the 5 most recently published packages with the rest collapsed and a search over all of them, how to contribute, a link to request a package with a GitHub
issue) and `packages.json` (the same list for scripts). So it always shows what clients get,
and the fingerprint on it comes from the public key in the repodata. `site/gen.py` needs
Python 3.14+ (zstd in `tarfile`) and `ssh-keygen`. The page is plain HTML with a few lines of CSS and a search script, nothing external. To
change the page, edit `site/index.html` (placeholders `@NAME@`) and run `./repo.sh site`.

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

`tests/test.sh` runs offline and touches neither pass, the server nor GitHub. It checks:

- against a fake worktree with a stub `xbps-src`: `xdistdir` resolves to this directory,
  the overlay replaces upstream's template directory, `common/shlibs` is appended once, the
  gitignored symlinks are made, `xlint <name>` finds the template, and `repo.sh build`
  builds per arch, noarch only once
- with dummy x86_64, aarch64 and noarch packages and a throwaway key: obsolete versions are
  removed per arch, subpackages can be removed, and an `xbps-install` client accepts the
  repository signature and the key fingerprint `repo.sh` reports
- the website beside the repository after publish and remove: every package with its arches,
  versions and source package, the fingerprint, the request link, and markup in a
  description escaped
- `release` with a stub `gh`: a failed attestation, a package not in `srcpkgs/`, a commit not
  on `origin/master` and a missing CI run each abort with nothing uploaded; a verified build
  is published, signed and on the website, with the attestation checked for workflow, ref,
  commit and GitHub-hosted runner
- `ci/changed.sh`: changed packages between two commits, subpackage changes counted for the
  source package, deleted packages skipped
