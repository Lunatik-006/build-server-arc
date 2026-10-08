#!/usr/bin/env bash
# Node-local tool cache and dependency caches shared by the runner pods.
#
# Every job used to start in an empty pod and rebuild the same things on the one
# VPS disk: setup-node downloaded Node, subosito downloaded the Flutter SDK, pub
# and npm pulled their packages from the GitHub cache over the internet. On bld1
# that was 6.7% (setup-node) and 9.1% (Flutter) of all runner pod-minutes over
# 2026-10-05..07, and the disk sat at its ~1.5k writes/s ceiling.
#
# The runner takes its tool cache from RUNNER_TOOL_CACHE (actions/runner
# HostContext.cs); setup-node looks there first (tc.find → <tool>/<ver>/<arch> +
# <arch>.complete) and subosito skips the download when
# <cache>/flutter/stable-<ver>-x64/flutter/bin/flutter exists. A version that is
# not preinstalled here is downloaded once by the first job and kept.
#
# npm (cacache: lockless, verified on read) and pub (download to a temp dir, then
# rename) are safe to share between concurrent pods. So is the Dart analyzer
# result cache (FileByteStore: temp file + rename); the analyzer plugin directory
# is not — it is recompiled in place on every start — and stays per pod.
#
#   install-ci-host-cache.sh [NODE_VERSION] [FLUTTER_VERSION]
set -euo pipefail

NODE_VERSION="${1:-24.21.0}"
FLUTTER_VERSION="${2:-3.44.2}"
# uid/gid of `runner` in ghcr.io/actions/actions-runner.
RUNNER_UID=1001

# One copy per trust tier (deploy-scale-set.sh CACHE_TIER): PR jobs never write what
# main/release jobs execute. <tier>/toolcache is the pods' /opt/hostedtoolcache,
# <tier>/cache their /ci-cache; <tier>-containers is the /ci-cache of `container:` jobs,
# which run as root.
for tier in pr trusted; do
  root=/opt/ci-tier/$tier
  toolcache=$root/toolcache
  node_dir=$toolcache/node/$NODE_VERSION/x64
  flutter_dir=$toolcache/flutter/stable-$FLUTTER_VERSION-x64
  install -d -o "$RUNNER_UID" -g "$RUNNER_UID"     "$root" "$toolcache" "$node_dir" "$flutter_dir"     "$root/cache" "$root/cache/npm" "$root/cache/pub" "$root/cache/dart-analysis-driver"     "$root/cache/vitest-crm" "$root/cache/jest-api" "$root/cache/build-runner" "$root/cache/node_modules"
  install -d "/opt/ci-tier/$tier-containers" "/opt/ci-tier/$tier-containers/npm"     "/opt/ci-tier/$tier-containers/node_modules"

  if [ ! -f "$node_dir.complete" ]; then
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"       | tar -xJ --strip-components=1 -C "$node_dir"
    touch "$node_dir.complete"
  fi
  if [ ! -x "$flutter_dir/flutter/bin/flutter" ]; then
    curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"       | tar -xJ -C "$flutter_dir"
  fi
  chown -R "$RUNNER_UID:$RUNNER_UID" "$toolcache"
  # Pull the engine artifacts once, as the user the jobs run as. flutter inspects the
  # working directory for a project, so run it from one the runner user can read.
  (cd /tmp && setpriv --reuid="$RUNNER_UID" --regid="$RUNNER_UID" --clear-groups     env HOME=/tmp PUB_CACHE="$root/cache/pub" "$flutter_dir/flutter/bin/flutter" precache)
done
