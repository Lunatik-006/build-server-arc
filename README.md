# build-server

Self-hosted GitHub Actions runner pool on a single host, powered by upstream [actions-runner-controller](https://github.com/actions/actions-runner-controller) (ARC) on k3s. ARC uses GitHub's **Just-in-Time runner configs** — each pod is bound to one specific job, so there is no shared org pool and no spawn race.

This repo provides:
- Deploy scaffolding (`setup.sh`, `scripts/deploy-scale-set.sh`).
- A reference generic runner image at `ghcr.io/jakwuh/actions-runner:latest` (Dockerfile in `runner-image/`). It's an upstream `actions-runner` + the minimum CLI toolkit (`gh`, `aws`, `jq`, `git`, `curl`, `unzip`, `zip`, `xz`, `rsync`, `gnupg`) — everything else (Node, Java, Flutter, Playwright, Android SDK, Python …) is installed on demand by workflow steps via `setup-*` actions, cached through `actions/cache`. Use this for every scale-set unless you have a reason not to.

## Architecture

```
GitHub Actions broker ──long-poll──► ARC listener ─► ARC controller ─► k8s pod (JIT runner) ──► job
```

One **scale-set** per `(GitHub org, runner image)` pair. The scale-set's name becomes the `runs-on:` label workflows use.

## Bootstrap a host

```bash
# Fresh host (24+ vCPU, 16+ GB RAM recommended for production load):
ssh root@<HOST>
bash <(curl -fsSL https://raw.githubusercontent.com/jakwuh/build-server/main/setup.sh)
```

`setup.sh` installs k3s + helm + the ARC controller into namespace `arc-systems`. Then deploy one scale-set per `(org, image)` you need.

## Deploy a scale-set

```bash
APP_ID=<github-app-id> \
INSTALL_ID=<github-app-installation-id> \
ORG=<github-org-or-user> \
NAME=<scale-set-name>           # = the runs-on: label \
IMAGE=ghcr.io/your-org/your-runner:tag \
MAX=20 \
PRIVATE_KEY_FILE=/path/to/app-private-key.pem \
scripts/deploy-scale-set.sh
```

The GitHub App webhook URL is **not used** — ARC pulls from GitHub's runner broker via long-polling with the App credentials.

### The two scale-sets on `bld1`

Written down because the sizing is not the defaults, and re-running the script without
these would quietly shrink the pools and drop miraj's local registry mirror. `PRIVATE_KEY_FILE`
is the **jakwuh-build-server** App PEM; App id `3743839` for both.

```bash
# izi-x org — the product CI pool
APP_ID=3743839 INSTALL_ID=133105803 ORG=izi-x NAME=izi-x-linux MAX=20 \
  CPU_REQUEST=500m MEM_REQUEST=2Gi DIND_CPU_REQUEST=250m DIND_MEM_REQUEST=1Gi \
  IMAGE=ghcr.io/jakwuh/actions-runner:<sha> \
  PRIVATE_KEY_FILE=<app>.pem scripts/deploy-scale-set.sh

# Miraj-OS org — `runs-on: self-hosted`; also pulls through the in-cluster registry cache
APP_ID=3743839 INSTALL_ID=133143010 ORG=Miraj-OS NAME=self-hosted MAX=8 \
  MEM_REQUEST=2Gi DIND_MEM_REQUEST=1Gi \
  REGISTRY_MIRRORS=http://10.43.104.17:5000 \
  IMAGE=ghcr.io/jakwuh/actions-runner:<sha> \
  PRIVATE_KEY_FILE=<app>.pem scripts/deploy-scale-set.sh
```

Pin `IMAGE` to a commit sha, never `:latest` — a scale-set is only rolled when its pod
template changes, so a moving tag means the pool keeps running whatever it pulled first.

## Runner image contract

The reference image (`runner-image/`) and any custom image you want to use must satisfy ARC's DinD container mode:

1. **Base on `ghcr.io/actions/actions-runner:latest`** (or any image that ships the upstream runner layout). That gets you everything below for free.
2. **`/home/runner/{run.sh,config.sh,bin,externals,k8s,env.sh,...}`** must be present. The chart's `init-dind-externals` init container `cp -r`s from `/home/runner/externals`; the runner container `exec`s `/home/runner/run.sh`. Missing either → `Init:Error` or `OCI runtime ... no such file or directory`.
3. **`runner` user must be in a group with GID 123.** The chart hardcodes `DOCKER_GROUP_GID=123` for the dind sidecar, so the docker socket ends up owned `root:123` — the runner needs that group to use it. The upstream image already puts `runner` in `docker:123`. Without it: `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`.

`myoung34/github-runner` does **not** satisfy any of the above. It has no `run.sh`, no `externals/`, and its `docker` group is GID 500. Don't use it as a base — there's no clean ARC-DinD adapter that doesn't end up being a wrapper image with the missing pieces re-copied in.

## Not in this repo

`setup.sh` gets a fresh box to a working pool, but it cannot produce these. Check them off by
hand when you rebuild or move the host, or the box will come up looking healthy and quietly
serving nothing:

| What | Where it comes from |
|---|---|
| Tailnet membership + the `tag:buildsrv` tag | `tailscale up --authkey` with an auth key from 1Password; the tag is what the tailnet policy grants on |
| Tailnet grants to reach the clusters | the tailnet ACL (`tag:buildsrv` → `tag:k8s-operator`, impersonating a group that RBAC binds inside the target cluster) |
| `github-app` secret in each `arc-*` namespace | GitHub App **jakwuh-build-server** (app id, installation id, private key) — the same App the runner healthcheck mints tokens from |
| `ghcr-pull` secret in each `arc-*` namespace | a ghcr read token, for the custom runner image |
| `/etc/arc-watchdog/{tg-token,config}` | alerts bot token + chat id; without them the watchdog heals silently |
| Anything izi-x-specific | lives in `izi-x/izi-x-infra`, not here — e.g. `ops/pr-stand-janitor` |

The rule for what belongs where: this repo is the **build server as a machine** — the pool,
the image, the things that keep the pool alive. Anything that knows about a particular
product's clusters, namespaces or databases belongs to that product's repo, even when it
physically runs on this host.

## Self-heal watchdog

`scripts/arc-watchdog.sh` (installed by `setup.sh` as an `arc-watchdog.timer` firing every
3 minutes) exists because ARC can die in ways that produce **no red check anywhere** — jobs
simply queue forever. Both of these happened for real on 2026-08-06/07 after a GitHub Actions
outage and cost ~12 hours:

- the `AutoscalingListener` CR keeps pointing at a deleted `EphemeralRunnerSet`, so the
  listener pod crash-loops on `could not patch ephemeral runner set ... not found`;
- the controller wedges outright (log frozen mid `deleting runner scale set`) and no listener
  is created at all.

The watchdog heals on the second consecutive unhealthy check — deleting the stale listener CR
in the first case, restarting the controller in the second — and announces what it did to
Telegram if `/etc/arc-watchdog/tg-token` (chmod 600) and `TG_CHAT=` in `/etc/arc-watchdog/config`
are present. Without those it heals silently.

```bash
systemctl list-timers arc-watchdog.timer arc-runner-janitor.timer
journalctl -u arc-watchdog.service --since -1h
/opt/build-server/arc-watchdog.sh          # run once by hand; silence == healthy
```

`scripts/arc-runner-janitor.sh` (every 5 minutes) covers the neighbouring failure: the dind
sidecar exits while the runner container keeps running, so the pod sits at `1/2 Error`
forever — taking no work, holding its CPU requests. Enough of them and the node hits its
requests ceiling, the next dind's containerd misses its startup window and becomes another
zombie. That loop stalled CI on 2026-08-06 after a reboot: 23 queued runs against a pool that
looked healthy. Deleting the pod is safe — ARC recreates it, GitHub re-assigns the job.

## Operations

```bash
# List scale-sets and pods
kubectl get autoscalingrunnerset -A
kubectl get pods -A | grep -E '^arc-'

# Tail listener logs
kubectl -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener -f

# Bump max runners on an existing release
helm upgrade <release> -n <namespace> --reuse-values --set maxRunners=50 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

## Tuning

- **Per-host capacity**: `maxRunners` per scale-set + pod template resource *requests* decide how many pods the scheduler admits. They do not decide how much a pod may then take — that is the *limits*, and a pool without memory limits will eventually take the node down instead of failing one job. `MEM_LIMIT` / `DIND_MEM_LIMIT` in `scripts/deploy-scale-set.sh` are not optional tuning.
- **Never put the job tree in tmpfs.** `emptyDir: { medium: Memory }` is RAM the scheduler cannot account for — it is charged to nobody's request, and `sizeLimit` is per volume, so `maxRunners: 20` with a 16 GiB `work` volume promises 320 GiB on the box. It ends in swap thrash, not in an eviction. `work` and `dind-externals` are node disk; only the 32 KB `dind-sock` stays in memory.
- **Burst latency**: first pull of a runner image is slow (~1-2 min for multi-GB images). Subsequent spawns hit local cache and start in ~30s.
