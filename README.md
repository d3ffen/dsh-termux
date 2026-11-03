# dsh on Termux — native, no proot

Run DeepSeek Harness (`@deepseek-ai/dsh`) **directly on Android/Termux** — bionic libc,
no `proot-distro`, no Ubuntu rootfs, no glibc. This is the method and the verified
record of getting it working on this device.

| | |
|---|---|
| Device / OS | Android 17 (SDK 37), aarch64 |
| Termux | native bionic prefix (`/data/data/com.termux/files/usr`) |
| Node | 24.22.2 (`nodejs-lts`), ABI 137, N-API 10 |
| npm | 12.2.1 |
| dsh | 0.2.1-rc.5, and 0.2.1-rc.2 for [dsh-purge](#pairs-with-dsh-purge) |
| libvips | 8.18.7 |
| Verified | `dsh --version`, `dsh web` (HTTP 200 + 941 KB JS bundle), headless run reaching `api.deepseek.com` over TLS (HTTP 401 with a dummy key = full stack works) |

## Install

```bash
bash install-dsh-termux.sh
# or non-interactive:
DEEPSEEK_API_KEY=sk-... bash install-dsh-termux.sh
```

The script is idempotent and fails loudly if a patch anchor moves. It takes roughly
10–15 minutes on a phone, almost all of it native compiles (`node-pty`, `koffi`,
`sharp`) and the ~85-package `libvips` dependency closure.

## Why `npm i -g @deepseek-ai/dsh` is not enough

Upstream ships prebuilt native addons for `linux-{x64,arm64}-{glibc,musl}` and
`darwin`. Termux is `android-arm64` (bionic), which matches none of them, and its
Node reports `process.platform === 'android'`, so npm fetches no optional
prebuilds. Eight independent things break — each has a targeted fix:

| # | Where | What breaks | Fix in this installer |
|---|---|---|---|
| 1 | `node-gyp` | Termux's Node reports `process.config.variables.OS = "android"`; gyp writes it into `config.gypi`, takes the NDK branch and dies on the undefined `android_ndk_path`. | Delete the `OS` variable in `create-config-gypi.js` so gyp infers `linux` and uses Termux's own sysroot. |
| 2 | `koffi` | `base.cc` calls `statx()`, which bionic hides below API 30; clang defaults to `android24`. | Compile with `--target=aarch64-unknown-linux-android30` (also required for `sharp`). |
| 3 | `sharp` | No `android-arm64` binding; the npm-shipped `@img/sharp-linux-arm64` is glibc and cannot `dlopen` on bionic. | Build from source against Termux's `libvips`: `SHARP_FORCE_GLOBAL_LIBVIPS=1 node-gyp rebuild --directory=src`. |
| 4 | `node-addon-require-builtin` | No android prebuild, and it cannot be compiled without Node's internal headers. `dsh-app-boot` requires it **eagerly**, so boot dies with *"No usable native binding found"*. `--expose-internals` alone does not help — the loader has no JS fallback. | Replace `lib/index.js` with a shim: try the native loader first, else `require(id)` for `internal/...` ids (legal under `--expose-internals`), plus `isAllowedInternalId`/`getBindingInfo`. The patched shebang (`node --expose-internals`) makes the flag always present. |
| 5 | `flock` (`@deepseek-ai/node-addon-system`) | No `android-arm64` prebuilt → `flock is not supported on android-arm64`. Kills `dsh --profile headless` at the session lock. | Call bionic's `flock(2)` through `koffi` (`libc.so`): `LOCK_EX \| LOCK_NB`, errno surfaced as `EAGAIN`/`EWOULDBLOCK`. Same contract as the native binding. |
| 6 | `dsh-session-persistence-jsonl` | Publishes session logs with `link(2)`; Android refuses hard links for app files (`EACCES`). | `rename(2)` for the publish (equally atomic inside the same private root). |
| 7 | `dsh-attachment-local` | Fsyncs every ancestor directory up to `/` for crash durability — an app cannot `open("/data/data")`; also publishes blobs with `link(2)`. | Tolerate unopenable ancestors; `link → rename` fallback for staged objects and aliases. |
| 8 | `dsh-fs-local` | `write`/`edit` publish a **new** file with `link(2)` for no-replace semantics — every create-file write fails with `FS_IO_ERROR`. | Fall back to `rename(2)` on `EACCES`; the surrounding guard still refuses to overwrite. |

Additionally: Android has **no usable process sandbox** (no bubblewrap, and
`@deepseek-ai/node-addon-system`'s Landlock launcher is glibc-only). A
`workspace-write` session therefore refuses to run any command with *"no sandbox
backend is usable on this host"*. The installer defaults both the `web` and
`headless` profiles to `danger-full-access` via `~/.dsh/profiles/<name>/cordis.patch.yml`:

```yaml
- id: sandbox-policy
  config:
    mode: danger-full-access
- id: approval
  config:
    policy: never
```

That can also be selected per session in the web UI's permission-preset menu, or
set with `DSH_PERMISSION_MODE=danger-full-access` (the profile config is what
makes it stick regardless of environment).

## Use

```bash
dsh web                                  # prints http://127.0.0.1:3080/?token=...
dsh web --port 8080                      # different port
dsh --profile headless "explain this repo"
dsh --version
```

`dsh web` does **not** open a browser on launch. The installer pins
`openBrowser: false` on the `web-runtime` entry of the web profile (the same
thing `--no-open` does, but persistent), so the authenticated URL is printed and
you paste it into whatever browser you like — useful on a phone, where the
hand-off would just steal focus from Termux, and over SSH, where there is no
browser at all. Pass `--no-open` explicitly any time if you want the flag too.

The API key comes from `DEEPSEEK_API_KEY`, or the Models page in the web UI
(stored in `~/.dsh/.credentials.yaml`). Sharing the phone's network is not
needed: bind to `127.0.0.1` and use the browser on the same device.

## Pairs with dsh-purge

[YuJunZhiXue/dsh-purge](https://github.com/YuJunZhiXue/dsh-purge) patches the
`@deepseek-ai` packages themselves, and it only targets **dsh 0.2.1-rc.2**
(`0.2.1-rc.3` and newer are explicitly unsupported). Install that version into
Termux, then add the plugin:

```bash
DSH_VERSION=0.2.1-rc.2 bash install-dsh-termux.sh

# the plugin is not on npm; use the codeload tarball URL
dsh plugin --profile web add --allow-build=dsh-purge \
  https://codeload.github.com/YuJunZhiXue/dsh-purge/tar.gz/refs/heads/master

# pnpm >= 11/12 skips the plugin's postinstall; run its own fallback
cd ~/.dsh/profiles/web && node node_modules/dsh-purge/scripts/ensure-profile-bundle.mjs
```

Restart `dsh web`, then apply the patches from the **dsh-purge → Clean → Apply**
panel (or non-interactively):

```bash
cd ~/.dsh/profiles/web
node node_modules/dsh-purge/bin/dsh-purge.js --status   # 补丁 n/86 已清洗
node node_modules/dsh-purge/bin/dsh-purge.js --apply
```

Two Termux-specific gotchas, both handled by this installer (re-run it after a
plugin upgrade):

- **`dsh: Permission denied` after Apply.** The plugin rewrites
  `lib/bin.js` to inject its shim and drops the executable bit. Fix:
  `chmod 755 "$(readlink -f "$(command -v dsh)")"`.
- **Sharp segfaults after a version switch.** A stale `sharp/src/build` object
  tree produces a binding that loads but crashes inside `format()`. Always clear
  it before rebuilding: `rm -rf …/sharp/src/build`.

Known non-fatal output from `--apply` on this setup: desktop-only patches report
`na`, optional `liangshen` patches report `文件缺失`, and one pattern may report
`漂移` (drift) because 1.1.90 is slightly ahead of the rc.2 tree. `71/86` patches
apply cleanly and `dsh web` still boots.

## What the script does, step by step

1. Checks Termux, `aarch64`, API ≥ 30, non-root.
2. `pkg install -y nodejs-lts npm build-essential cmake ninja python pkg-config libvips patchelf`
   (`libvips` pulls a large closure — imagemagick, poppler, ghostscript, … — that
   sharp's build needs).
3. Patches node-gyp (fix 1).
4. `npm install -g @deepseek-ai/dsh@0.2.1-rc.5` with `CFLAGS/CXXFLAGS=--target=...android30`
   and `npm_config_nodedir=$PREFIX`, allowing install scripts — npm ≥ 12 blocks
   them by default, so `node-pty` and `koffi` would otherwise stay unbuilt.
5. Builds sharp against the system libvips (fix 3).
6. Applies the `link → rename` and durability-walk patches (fixes 6, 7, 8) and
   the `--expose-internals` shebang.
7. Installs the `node-addon-require-builtin` shim (fix 4).
8. Patches `flock` to use koffi (fix 5).
9. Writes the profile patches: `danger-full-access` for `web` and `headless`, and
   `openBrowser: false` for `web` so launches never hand off to a browser.
10. Verifies `node-pty`, `koffi`, `sharp`, and `dsh --version`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No usable native binding found for node-addon-require-builtin-android-arm64` | Shim from step 7 missing, or dsh started without `--expose-internals`. Check `head -1 $(command -v dsh)` — the shebang must be `#!/data/data/com.termux/files/usr/bin/node --expose-internals`. |
| `flock is not supported on android-arm64` | Step 8 missing (`node-addon-system/lib/flock.js` has no `loadKoffiBinding`). |
| `Could not load the "sharp" module using the android-arm64 runtime` | Step 5 failed; `pkg install libvips` then re-run `node-gyp rebuild --directory=src` in `…/dsh/node_modules/sharp`. |
| `android_ndk_path` during any native build | node-gyp patch (step 3) not in effect. |
| `statx: undefined symbol` building koffi | built without `--target=…android30` (Android < 11 cannot run it at all). |
| `EACCES` creating files / `FS_IO_ERROR` on write | fixes 6/8 not applied. |
| `no sandbox backend is usable` on every command | session is `workspace-write`; use `danger-full-access`. |
| UI opens but assets 404 | check `dsh-web-app` is in the profile bundles (`~/.dsh/profiles/web/package.json`). |

## Caveats

- **Unconfined by design.** Without Landlock there is no kernel-enforced file
  sandbox; `danger-full-access` is the only mode that can run commands. Treat the
  agent as having the Termux app's full permissions.
- **No HMR native addon.** The shim keeps the resolver working via
  `--expose-internals`; a future dsh that requires the addon's exact ABI (not just
  `internal/...` requires) would need a real android build.
- **Disk.** `~/.dsh` plus `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai`
  is ~650 MB; the `libvips` closure adds a few hundred more.
- **Package manager bookkeeping.** `pkg`/apt works normally for a Termux user; the
  verification run inside this session had to bypass Termux's apt root guard
  (`dpkg` refuses no root, `apt-get` does), so if you ever re-install node from
  inside a root shell, use `pkg` as the normal user instead.
- **Upgrades.** Re-running the installer after `npm i -g` upgrades re-applies all
  patches; anchor checks abort instead of silently corrupting a changed tree.

## Credits

- [deepseek-ai/deepseek-harness discussion #136](https://github.com/deepseek-ai/deepseek-harness/discussions/136)
  — the "solved on Android/Termux" thread this work started from.
- [lilyco-42/dsh-termux](https://github.com/lilyco-42/dsh-termux) — community
  installer that documented the node-gyp, koffi, sharp and `link(2)` fixes.
  This repo adds the `node-addon-require-builtin` shim and the koffi-backed
  `flock`, both of which are required before `dsh --profile headless` will boot.

## Uninstall

```bash
npm uninstall -g @deepseek-ai/dsh
rm -rf ~/.dsh/profiles/web/cordis.patch.yml ~/.dsh/profiles/headless/cordis.patch.yml
pkg uninstall libvips   # only if nothing else needs it
```
