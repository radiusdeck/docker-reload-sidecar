# docker-reload-sidecar

Tiny Docker sidecar (~25 MB) that restarts or sends signals to other Docker containers via the Docker Engine API. Zero external dependencies — pure Python stdlib.

Perfect for reloading configuration in containers like FreeRADIUS, nginx, HAProxy, etc.

## Quick Start

```yaml
services:
  reload-sidecar:
    image: ghcr.io/your-org/docker-reload-sidecar:1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      TARGET_CONTAINER: freeradius
      RELOAD_TOKEN: my-secret
```

Trigger reload:

```bash
curl -X POST http://localhost:9090/reload \
  -H "Authorization: Bearer my-secret"
```

## API

| Endpoint   | Method | Description                        |
|------------|--------|------------------------------------|
| `/health`  | GET    | Sidecar + target container status  |
| `/reload`  | POST   | Restart or signal target container |

## Environment Variables

| Variable           | Default      | Description                              |
|--------------------|--------------|------------------------------------------|
| `TARGET_CONTAINER` | `freeradius` | Container name or id to reload           |
| `RELOAD_MODE`      | `restart`    | `restart` — full restart, `signal` — send signal |
| `RELOAD_SIGNAL`    | `HUP`        | Signal name (only when mode=signal)      |
| `RELOAD_TOKEN`     | _(empty)_    | Bearer token for auth (empty = no auth)  |
| `PORT`             | `9090`       | HTTP listen port                         |
| `RESTART_TIMEOUT`  | `10`         | Seconds to wait before SIGKILL on restart|

## Examples

### Restart mode (default)

```yaml
environment:
  TARGET_CONTAINER: nginx
  RELOAD_MODE: restart
```

### Signal mode (graceful, no downtime)

```yaml
environment:
  TARGET_CONTAINER: nginx
  RELOAD_MODE: signal
  RELOAD_SIGNAL: HUP
```

### With authentication

```yaml
environment:
  RELOAD_TOKEN: super-secret-token
```

```bash
# Without valid token → 403
curl -X POST http://sidecar:9090/reload
# {"ok": false, "error": "forbidden"}

# With valid token → 200
curl -X POST http://sidecar:9090/reload \
  -H "Authorization: Bearer super-secret-token"
# {"ok": true, "detail": "container restarted", "container": "nginx"}
```

## Security

- Mount docker.sock as **read-only** (`:ro`)
- Do **not** expose port 9090 to the internet
- Use `RELOAD_TOKEN` in production
- The sidecar can only restart the single container specified in `TARGET_CONTAINER`

## Testing

Requirements: Docker, curl, python3.

```bash
# Run from any directory
./tests/test.sh
```

The script will:
1. Build the image locally
2. Spin up temporary containers (auto-cleaned on exit)
3. Test restart mode, signal mode, auth, and error cases

```
=== Test 1: restart mode ===
  ✅ health returns ok
  ✅ target is running
  ✅ no token → 403
  ✅ reload succeeds
  ✅ container was restarted (StartedAt changed)

=== Test 2: signal mode ===
  ✅ signal reload succeeds
  ✅ detail says HUP

=== Test 3: missing target ===
  ✅ missing target → not running
  ✅ reload fails for missing target

===================================
  Passed: 9
  Failed: 0
===================================
```

## License

MIT