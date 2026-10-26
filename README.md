# php-forgejo-runner

Self-hosted **Forgejo Actions** runner with the PHP/Laravel CI toolchain. Built on Ubuntu 24.04 with **PHP (8.3, 8.4 or 8.5), Composer, Node, git** and the system libraries Playwright's Chromium needs.

This is not the GitHub runner image renamed. Forgejo's runner is a single Go binary with its own lifecycle, so there is no `actions-runner` tarball, no PAT-to-registration-token exchange and no `config.sh`/`run.sh`. See [php-github-runner](https://github.com/rhurup/php-github-runner) if you need the GitHub one.

- **Host mode.** Jobs run as processes inside the container, sharing its filesystem, ports and toolchain. No Docker socket, no privileged container, no Docker API.
- **One job per container.** Host mode means two parallel jobs would collide on port 8000 and on the shared caches. Scale out with more containers, not with `capacity`.
- **Checksum-verified runner binary.** The build fails rather than installing a download that doesn't match the checksum Forgejo publishes beside it.
- **PHP security floor.** Pass `PHP_MIN_VERSION` and the build fails rather than publishing an image with an older, vulnerable PHP.
- Published for `linux/amd64` and `linux/arm64`.

## Usage

```bash
docker run -d --restart always \
  -v ./config.yaml:/etc/runner-config.yaml:ro \
  -v ./data-1:/data \
  -v ./cache:/cache \
  rhuruphansen/php-forgejo-runner:8.4
```

The default command is `daemon --config /etc/runner-config.yaml`; the entrypoint is the runner binary itself, so any other subcommand works too (`one-job`, `exec`, `generate-config`).

Start from [config.example.yaml](config.example.yaml) — it is the configuration running in production. The line that matters most:

```yaml
runner:
  labels:
    - "self-hosted:host"
```

Without the `:host` suffix the runner expects a Docker daemon it does not have, and every job fails to start.

See [docker-compose.example.yml](docker-compose.example.yml) for the real six-runner deployment with MySQL and Mailpit.

### Registration

Registration happens once. Supply a runner registration token from Forgejo (*Settings → Actions → Runners*) the first time a container starts, or pre-create `/data/.runner`. The identity is then persisted on the data volume, so restarts rejoin as the same runner and no token needs to stay in the environment.

### Caches

`COMPOSER_CACHE_DIR`, `npm_config_cache` and `PLAYWRIGHT_BROWSERS_PATH` point into `/cache`, which is shared between runners. They are exported from `/etc/profile.d/99-ci-cache.sh`, so **a job only sees them in a login shell**. Workflows must set:

```yaml
defaults:
  run:
    shell: bash -l {0}
```

Without that line the caches are silently bypassed and every job re-downloads its dependencies.

### Set `init: true`

`forgejo-runner` becomes PID 1 in the container and does not reap its grandchildren, so the `php` and
`node` processes a job leaves behind accumulate as zombies — on a runner left up for days they were
measured at nearly two days old, alongside stray `esbuild` and `chrome_crashpad` processes. Docker's
`init: true` (or `--init`) puts a small init in front of the runner to reap them. The process list
otherwise grows until the container is restarted.

### Jobs run as root

In host mode the runner process *is* the job environment, so jobs run as root. Two consequences worth knowing:

- Anything a job writes to a mounted web root is root-owned. Deploy steps need `rsync --chown=1000:1000` (or equivalent) if the web server runs as another user.
- A job can read everything mounted into the container. Mount `/publish/...` web roots only on the runners that are supposed to deploy.

### Images and tags

Published to Docker Hub as `rhuruphansen/php-forgejo-runner`.

| Tag | |
|---|---|
| `8.3`, `8.4`, `8.5` | Latest build of that PHP version |
| `8.4-20261026` | Fixed build (date-stamped) |
| `latest` | Same as `8.4` |

## Build

```bash
docker build --build-arg PHP_VERSION=8.4 -t php-forgejo-runner:8.4 .

# Pin the runner release, and refuse to build on a vulnerable PHP:
docker build \
  --build-arg PHP_VERSION=8.4 \
  --build-arg RUNNER_VERSION=13.2.0 \
  --build-arg PHP_MIN_VERSION=8.4.26 \
  --build-arg APT_CACHE_BUST="$(date +%F)" \
  -t php-forgejo-runner:8.4 .
```

## Licence

MIT. See [LICENSE](LICENSE).
