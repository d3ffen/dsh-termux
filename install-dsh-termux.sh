#!/data/data/com.termux/files/usr/bin/bash
# install-dsh-termux.sh — run @deepseek-ai/dsh natively on Termux (Android aarch64),
# with no proot-distro, no Ubuntu, no glibc emulation.
#
# Verified on: Termux, Android 17 (SDK 37), arm64-v8a, Node 24.22.2 (Termux
# nodejs-lts), npm 12.2.1, libvips 8.18.7 — dsh 0.2.1-rc.5 boots `dsh web`,
# serves the UI/asset bundle, and reaches api.deepseek.com over TLS.
#
# Why this script exists: `npm i -g @deepseek-ai/dsh` installs fine on Termux but
# cannot run. Eight independent things are wrong on Android, and each one has a
# targeted fix here (see README.md for the full table):
#
#   1. node-gyp  — Termux's Node reports process.config.variables.OS=android, so
#                  gyp takes the Android-NDK branch and dies on android_ndk_path.
#   2. koffi     — calls statx(), hidden by bionic below API 30; clang must target
#                  android30 instead of the default android24.
#   3. sharp     — ships no android-arm64 binding; build against Termux libvips.
#   4. node-addon-require-builtin — no android prebuild and it cannot be compiled
#                  without Node's internal headers; shim it over --expose-internals.
#   5. flock     — @deepseek-ai/node-addon-system has no android prebuild; call
#                  bionic's flock(2) through koffi instead.
#   6. session-persistence-jsonl — publishes logs with link(2), which Android
#                  refuses for app files (EACCES); rename(2) is equally atomic.
#   7. attachment-local — fsyncs every ancestor up to "/" (SELinux forbids
#                  opening /data/data) and also publishes blobs with link(2).
#   8. fs-local  — `write`/`edit` publish new files with link(2) for no-replace
#                  semantics; fall back to rename(2) on EACCES.
#
# Usage:  bash install-dsh-termux.sh
#         DEEPSEEK_API_KEY=sk-... bash install-dsh-termux.sh   # non-interactive
set -euo pipefail

DSH_VERSION="${DSH_VERSION:-0.2.1-rc.5}"
NDK_TARGET="aarch64-unknown-linux-android30"
ANDROID_MIN_SDK=30
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
DSH_LIB="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
WORK="${TMPDIR:-$PREFIX/tmp}/dsh-termux-install"

log() { printf '\033[1;36m[%s/%s]\033[0m %s\n' "$1" "$2" "$3"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight ---
log 1 10 "Checking the host"
[ -n "${TERMUX_VERSION:-}" ] || [ "${PREFIX#*/com.termux/}" != "$PREFIX" ] || \
  die "this installer is for Termux; PREFIX is $PREFIX"
[ "$(uname -m)" = "aarch64" ] || die "only aarch64 Termux is supported (found $(uname -m))"
if command -v getprop >/dev/null 2>&1; then
  SDK="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
  [ "${SDK:-0}" -ge "$ANDROID_MIN_SDK" ] || die "Android API >= $ANDROID_MIN_SDK required (koffi needs statx); found $SDK"
fi
[ "$(id -u)" -ne 0 ] || die "run as the normal Termux user, not root"
mkdir -p "$WORK"

# --------------------------------------------------------------- packages ----
log 2 10 "Installing prerequisites (nodejs-lts npm build-essential cmake ninja python pkg-config libvips patchelf)"
pkg install -y nodejs-lts npm build-essential cmake ninja python pkg-config libvips patchelf >/dev/null

NODE_BIN="$(command -v node)" || die "node missing after pkg install (is 'pkg' working?)"
NPM_BIN="$(command -v npm)" || die "npm missing after pkg install"
NPM_MAJOR="$(npm --version | cut -d. -f1)"
NODE_GYP="$PREFIX/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js"
[ -f "$NODE_GYP" ] || die "node-gyp not found at $NODE_GYP"

NODE_PLATFORM="$(node -p 'process.platform')"
[ "$NODE_PLATFORM" = "android" ] || die "expected Termux Node (process.platform=android), got $NODE_PLATFORM"
log 2 10 "Node $(node --version), npm $(npm --version), gyp ABI $(node -p 'process.versions.modules')"

# ------------------------------------------------------- node-gyp OS=android --
log 3 10 "Patching node-gyp (drop the bogus OS=android variable)"
python3 - "$PREFIX/lib/node_modules/npm/node_modules/node-gyp/lib/create-config-gypi.js" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
if "delete variables.OS" in src:
    print("    already patched")
    raise SystemExit
anchor = "const variables = config.variables\n"
if anchor not in src:
    sys.exit("anchor moved in create-config-gypi.js; node-gyp changed")
block = anchor + (
    "\n  // Termux: Node reports OS=android, but gyp must treat the host as linux\n"
    "  // (the sysroot is Termux's, not the NDK's). Without this, gyp takes the\n"
    "  // android branch and references the undefined android_ndk_path.\n"
    "  delete variables.OS\n"
)
open(path, "w", encoding="utf-8").write(src.replace(anchor, block, 1))
print("    patched")
PY

# ------------------------------------------------------------------ install --
log 4 10 "Installing @deepseek-ai/dsh@$DSH_VERSION (native modules compile here; takes a few minutes)"
export CFLAGS="--target=$NDK_TARGET"
export CXXFLAGS="--target=$NDK_TARGET"
export npm_config_nodedir="$PREFIX"

# npm >= 12 blocks install scripts unless they are allow-listed; node-pty and
# koffi need theirs to compile.
SCRIPTS="@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs"
if [ "$NPM_MAJOR" -ge 12 ]; then
  ALLOW="--allow-scripts=$SCRIPTS"
else
  ALLOW="--foreground-scripts"
fi
npm install -g --prefix "$PREFIX" "$ALLOW" "@deepseek-ai/dsh@$DSH_VERSION" --no-fund --no-audit
[ -f "$DSH_LIB/lib/bin.js" ] || die "dsh did not install to $DSH_LIB"

# ------------------------------------------------------------------- sharp ---
log 5 10 "Building sharp against system libvips"
SHARP_SRC="$DSH_LIB/node_modules/sharp/src"
if compgen -G "$SHARP_SRC/build/Release/sharp-android-arm64-*.node" >/dev/null; then
  echo "    already built"
else
  # A stale/partial object tree yields a binding that loads but segfaults when
  # sharp enumerates libvips formats, so always build from a clean directory.
  rm -rf "$SHARP_SRC/build"
  ( cd "$DSH_LIB/node_modules/sharp" && \
    SHARP_FORCE_GLOBAL_LIBVIPS=1 \
    CFLAGS="--target=$NDK_TARGET" CXXFLAGS="--target=$NDK_TARGET" \
    "$NODE_BIN" "$NODE_GYP" rebuild --directory=src --jobs max )
fi

# ---------------------------------------------------------- JS port patches --
log 6 10 "Patching link(2) publishers and the internal-durability walk"
cat > "$WORK/patch-dsh.py" <<'PY'
import os, re, sys

DSH = os.environ["DSH_ROOT"]
NODE_BIN = os.environ["NODE_BIN"]


def load(path):
    return open(path, encoding="utf-8").read()


def save(path, src):
    open(path, "w", encoding="utf-8").write(src)


def once(src, old, new, label):
    n = src.count(old)
    if n != 1:
        sys.exit(f"anchor moved ({n} matches) in {label}; dsh changed, review the patch")
    return src.replace(old, new, 1)


def fs_local():
    path = f"{DSH}/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js"
    src = load(path)
    if "termux-noreplace-fallback" in src:
        return "fs-local: already patched"
    old = (
        "\t\tif (createIfAbsent !== void 0) try {\n"
        "\t\t\tawait linkFile(tempPath, absolutePath);\n"
        "\t\t} catch (error) {\n"
        "\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);\n"
        "\t\t}"
    )
    new = (
        "\t\tif (createIfAbsent !== void 0) try {\n"
        "\t\t\ttry {\n"
        "\t\t\t\tawait linkFile(tempPath, absolutePath);\n"
        "\t\t\t} catch (error) {\n"
        "\t\t\t\t/* termux-noreplace-fallback -- Android refuses link(2) for app files (EACCES). */\n"
        "\t\t\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EACCES\")) throw error;\n"
        "\t\t\t\tawait rename(tempPath, absolutePath);\n"
        "\t\t\t}\n"
        "\t\t} catch (error) {\n"
        "\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);\n"
        "\t\t}"
    )
    save(path, once(src, old, new, "fs-local"))
    return "fs-local: link->rename fallback"


def session_persistence():
    path = f"{DSH}/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
    src = load(path)
    if "termux-rename-publish" in src:
        return "session-persistence: already patched"
    src = once(
        src,
        "\t\tlet linked = false;\n\t\ttry {\n\t\t\tawait link(tmp, finalPath);\n\t\t\tlinked = true;",
        "\t\tlet linked = false;\n\t\ttry {\n\t\t\t/* termux-rename-publish -- link(2) is EACCES on Android; rename is equally atomic. */\n\t\t\tawait rename(tmp, finalPath);\n\t\t\tlinked = true;",
        "session-persistence publish",
    )
    # The publish call now needs rename(2); add it to the fs/promises import
    # when the shipped module does not import it yet.
    match = re.search(r'import \{([^}]*)\} from "node:fs/promises";', src)
    if match is None:
        sys.exit("session-persistence: fs/promises import not found")
    names = [n.strip() for n in match.group(1).split(",") if n.strip()]
    if "rename" not in names:
        new_import = "import { " + ", ".join(sorted(set(names) | {"rename"})) + ' } from "node:fs/promises";'
        src = src.replace(match.group(0), new_import, 1)
    save(path, src)
    return "session-persistence: rename publish"


def attachment_local():
    path = f"{DSH}/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js"
    src = load(path)
    if "termux-hardlink-fallback" in src:
        return "attachment-local: already patched"
    src = once(
        src,
        "\tconst handle = await open(path, constants.O_RDONLY);",
        "\tlet handle;\n"
        "\ttry {\n"
        "\t\thandle = await open(path, constants.O_RDONLY);\n"
        "\t} catch (error) {\n"
        "\t\t/* termux-durability-guard -- app sandboxes cannot open ancestors like /data. */\n"
        "\t\tif (error.code === \"EACCES\" || error.code === \"EPERM\" || error.code === \"ENOENT\") return;\n"
        "\t\tthrow error;\n"
        "\t}",
        "attachment-local durability walk",
    )
    helpers = (
        "/* termux-hardlink-fallback -- Android refuses link(2) for app files (EACCES). */\n"
        "async function publishStagedName(source, target) {\n"
        "\ttry {\n"
        "\t\tawait link(source, target);\n"
        "\t} catch (error) {\n"
        "\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EACCES\")) throw error;\n"
        "\t\tawait rename(source, target);\n"
        "\t}\n"
        "}\n"
        "async function removeStagedName(path) {\n"
        "\ttry {\n"
        "\t\tawait unlink(path);\n"
        "\t} catch (error) {\n"
        "\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"ENOENT\")) throw error;\n"
        "\t}\n"
        "}\n"
        "async function publishStagedObject(root, target, staged) {"
    )
    src = once(src, "async function publishStagedObject(root, target, staged) {", helpers, "attachment-local helpers")
    src = once(src, "\t\t\tawait link(staged.path, target);", "\t\t\tawait publishStagedName(staged.path, target);", "attachment-local staged publish")
    src = once(src, "\t\t\tawait link(source, target);", "\t\t\tawait publishStagedName(source, target);", "attachment-local alias publish")
    src = once(src, "\t\tawait unlink(staged.path);", "\t\tawait removeStagedName(staged.path);", "attachment-local staging cleanup")
    save(path, src)
    return "attachment-local: durability guard + link->rename"


def shebang():
    path = f"{DSH}/lib/bin.js"
    src = load(path)
    first, _, rest = src.partition("\n")
    want = f"#!{NODE_BIN} --expose-internals"
    if first == want:
        return "shebang: already patched"
    if not first.startswith("#!"):
        sys.exit("bin.js has no shebang")
    save(path, want + "\n" + rest)
    return f"shebang: {want}"


for step in (fs_local, session_persistence, attachment_local, shebang):
    print("    " + step())
PY

DSH_ROOT="$DSH_LIB" NODE_BIN="$NODE_BIN" python3 "$WORK/patch-dsh.py"

# Plugin shims (dsh-purge and friends) rewrite lib/bin.js and lose the exec bit,
# which makes `dsh` fail with "Permission denied" on Android. Restore it.
chmod 755 "$DSH_LIB/lib/bin.js"

# ------------------------------------------- node-addon-require-builtin shim --
log 7 10 "Shimming node-addon-require-builtin over --expose-internals"
RBL_DIR="$DSH_LIB/node_modules/node-addon-require-builtin/lib"
if [ -f "$RBL_DIR/index.js" ] && ! grep -q "expose-internals fallback" "$RBL_DIR/index.js"; then
  cp "$RBL_DIR/index.js" "$RBL_DIR/index.native.js"
  cat > "$RBL_DIR/index.js" <<'JS'
"use strict";
// Termux/Android: there is no android-arm64 prebuilt for this addon and it
// cannot be compiled without Node's internal headers. Node's own
// --expose-internals flag exposes the same `internal/...` modules, so use it
// when the native binding is unavailable (expose-internals fallback).
const path = require("node:path");

let native = null;
try {
  native = require("node-addon-native-custom-loader").createEntryApi(path.resolve(__dirname, ".."));
} catch {
  native = null;
}

const INTERNAL_ID = /^internal\/[A-Za-z0-9_./-]+$/;

function requireBuiltin(moduleId) {
  if (native) return native.requireBuiltin(moduleId);
  if (typeof moduleId !== "string" || !INTERNAL_ID.test(moduleId)) {
    throw new Error(`node-addon-require-builtin: refusing non-internal id ${String(moduleId)}`);
  }
  if (!process.execArgv.includes("--expose-internals")) {
    throw new Error("node-addon-require-builtin: native binding missing and Node was not started with --expose-internals");
  }
  return require(moduleId);
}

function isAllowedInternalId(moduleId) {
  if (native) return native.isAllowedInternalId(moduleId);
  return typeof moduleId === "string" && INTERNAL_ID.test(moduleId);
}

function getBindingInfo() {
  if (native) return native.getBindingInfo();
  return { backend: "expose-internals", abi: process.versions.modules, platform: process.platform };
}

const api = { requireBuiltin, isAllowedInternalId, getBindingInfo };
Object.defineProperty(api, "default", { value: api, enumerable: false });
module.exports = api;
JS
  echo "    shim installed"
else
  echo "    already shimmed"
fi

# ------------------------------------------------------------- flock (koffi) --
log 8 10 "Wiring flock(2) through koffi for android-arm64"
FLOCK_JS="$DSH_LIB/node_modules/@deepseek-ai/node-addon-system/lib/flock.js"
if grep -q "loadKoffiBinding" "$FLOCK_JS"; then
  echo "    already patched"
else
  cp "$FLOCK_JS" "$FLOCK_JS.orig"
  python3 - "$FLOCK_JS" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
old = """    if (platform !== 'linux' && platform !== 'darwin') {
        throw Object.assign(new Error(`flock is not supported on ${platform}-${arch}`), {
            code: 'ERR_FLOCK_UNSUPPORTED_PLATFORM',
            syscall: 'flock',
        });
    }"""
new = """    if (platform === 'android') {
        return loadKoffiBinding();
    }
    if (platform !== 'linux' && platform !== 'darwin') {
        throw Object.assign(new Error(`flock is not supported on ${platform}-${arch}`), {
            code: 'ERR_FLOCK_UNSUPPORTED_PLATFORM',
            syscall: 'flock',
        });
    }"""
if "loadKoffiBinding" in src:
    print("    already patched")
    raise SystemExit
assert old in src, "anchor moved in flock.js"
src = src.replace(old, new, 1)
helper = """
/**
 * Termux/Android: no @deepseek-ai/node-addon-system-android-* prebuilt exists,
 * but bionic exports flock(2) and koffi can call it. Same contract as the
 * native binding: non-blocking exclusive lock, callback receives 0 or errno.
 */
function loadKoffiBinding() {
    const require = createRequire(import.meta.url);
    const koffi = require('koffi');
    const libc = koffi.load('libc.so');
    const flockNative = libc.func('int flock(int fd, int operation)');
    const LOCK_EX = 2;
    const LOCK_NB = 4;
    return {
        tryLock(fd, done) {
            try {
                done(flockNative(fd, LOCK_EX | LOCK_NB) === 0 ? 0 : koffi.errno());
            } catch (error) {
                done(typeof error.errno === 'number' && error.errno > 0 ? error.errno : 5);
            }
        },
    };
}
"""
anchor = "/**\n * Attempt an exclusive, nonblocking POSIX flock"
assert anchor in src, "flock doc anchor moved"
src = src.replace(anchor, helper + anchor, 1)
open(path, "w", encoding="utf-8").write(src)
print("    patched")
PY
fi

# ------------------------------------------------------- permission defaults --
log 9 10 "Setting Android defaults (danger-full-access, no browser hand-off)"

# Append one YAML block to a profile patch file unless its marker is present.
# The template ships `[]`, and a block list cannot follow a flow sequence, so the
# empty marker is dropped first.
ensure_patch_block() {
  local profile="$1" marker="$2" body="$3"
  local dir="$HOME/.dsh/profiles/$profile"
  local patch="$dir/cordis.patch.yml"
  mkdir -p "$dir"
  touch "$patch"
  if grep -q "$marker" "$patch"; then
    return 0
  fi
  grep -vE '^[[:space:]]*\[\][[:space:]]*$' "$patch" > "$patch.tmp"
  mv "$patch.tmp" "$patch"
  printf '\n%s\n' "$body" >> "$patch"
}

for profile in web headless; do
  # Let dsh materialize the profile template first; a patch written into a
  # directory that is about to be auto-initialized would be overwritten.
  ( cd "$HOME" && dsh --profile "$profile" --dump-default-config >/dev/null 2>&1 ) || true
  ensure_patch_block "$profile" "sandbox-policy" "# Termux: Android has neither Landlock nor bubblewrap, so workspace-write
# sessions cannot confine anything and every command refuses to run. The only
# usable mode is the unconfined one, so make it the default.
- id: sandbox-policy
  config:
    mode: danger-full-access
- id: approval
  config:
    policy: never"
done

# `dsh web` hands the UI to the default browser on start. On a phone that steals
# focus from Termux and is useless over SSH, so print the URL and never open one
# (the config keys mirror the shipped entry, since a patch replaces the object).
ensure_patch_block web "id: web-runtime" "# Print the URL instead of handing the UI to a browser on launch.
- id: web-runtime
  config:
    openBrowser: false
    printUrl: true
    publicUrl: !!js ctx.webStartup.publicUrl
    surfaceContext: true"

# ----------------------------------------------------------------- verify ----
log 10 10 "Verifying the native stack"
FAIL=0
for mod in node-pty koffi sharp; do
  if ( cd "$DSH_LIB" && node -e "require('$mod')" ) >/dev/null 2>&1; then
    echo "    $mod: OK"
  else
    echo "    $mod: FAILED"
    FAIL=1
  fi
done
( cd "$HOME" && dsh --version >/dev/null ) || FAIL=1
echo "    dsh --version: $(cd "$HOME" && dsh --version 2>/dev/null || echo FAILED)"
# The profile patch is the difference between "boots" and "can actually run a
# command", so fail here rather than at the first tool call.
if ( cd "$HOME" && dsh --profile web --dump-config 2>/dev/null | grep -A3 "id: sandbox-policy" | grep -q "danger-full-access" ); then
  echo "    default sandbox mode: danger-full-access"
else
  echo "    default sandbox mode: NOT APPLIED"
  FAIL=1
fi
[ "$FAIL" -eq 0 ] || die "verification failed; re-run with 'bash -x' and check README.md"

# ------------------------------------------------------------------ API key --
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  printf '    DeepSeek API key (hidden, Enter to skip): '
  IFS= read -r -s KEY || true
  echo
  if [ -n "${KEY:-}" ]; then
    export DEEPSEEK_API_KEY="$KEY"
    touch "$HOME/.bashrc"
    grep -v '^export DEEPSEEK_API_KEY=' "$HOME/.bashrc" > "$HOME/.bashrc.tmp" || true
    printf "export DEEPSEEK_API_KEY='%s'\n" "$KEY" >> "$HOME/.bashrc.tmp"
    mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"
    echo "    saved to ~/.bashrc"
  else
    echo "    skipped — set it later in the web UI (Models page) or export DEEPSEEK_API_KEY"
  fi
fi

printf '\n\033[1;32mDone.\033[0m Try:\n'
printf '  dsh web                 # browser UI on 127.0.0.1:3080\n'
printf '  dsh --profile headless "summarize this repo"\n'
