# Credential proxy

The boxes use a proxy and an internal network by default. The proxy checks
allowed hosts and injects host-side credentials into matching HTTPS requests.
Allowed HTTP requests pass through without credential injection.

## Example config

Save this as `~/.box.default.proxy.json`, or `~/.box.<profile>.proxy.json` for
a named profile. Replace the hostname and service account; remove services
and rules you do not use. Host commands need to be on PATH, or use absolute
paths inside `cmd:`.

```json
{
  "allow": [
    "llm.example.com",
    "opencode.ai",
    "api.github.com",
    "github.com",
    "bigquery.googleapis.com"
  ],
  "rules": [
    {
      "host": "llm.example.com",
      "path": "/localllm/*",
      "header": "authorization",
      "with": "Bearer {env:LOCAL_LLM_API_KEY}",
      "fake_env": ["LOCAL_LLM_API_KEY"]
    },
    {
      "host": "opencode.ai",
      "header": "authorization",
      "with": "Bearer {env:OPENCODE_API_KEY}",
      "fake_env": ["OPENCODE_API_KEY"]
    },
    {
      "host": "api.github.com",
      "header": "authorization",
      "with": "Bearer {cmd:box-gh-token get}",
      "fake_env": ["GH_TOKEN"],
      "ttl": 600
    },
    {
      "host": "bigquery.googleapis.com",
      "header": "authorization",
      "with": "Bearer {cmd:gcloud auth print-access-token --impersonate-service-account=bq-read-only@PROJECT_ID.iam.gserviceaccount.com}",
      "fake_env": ["BQ_TOKEN", "CLOUDSDK_AUTH_ACCESS_TOKEN"],
      "ttl": 600
    }
  ],
  "journal": {
    "path": "~/.local/state/agent-box/calls.jsonl",
    "calls": ["llm.example.com", "opencode.ai"]
  }
}
```

The localllm rule assumes
`LOCAL_LLM_URL=https://llm.example.com/localllm/v1`. Other allowed paths still
pass through, but do not receive that rule's credential.

## Host env and client placeholders

Export `LOCAL_LLM_URL`, `LOCAL_LLM_API_KEY`, and `OPENCODE_API_KEY` on the host
before launch. Keep secret files outside both the mounted project and the
box's home. For example, load a host-only credentials file:

```sh
set -a
source "$HOME/.config/agent-box/credentials.env"
set +a
opencode-box
```

Each rule's `fake_env` lists client variable names. At launch their union is
passed as `box-proxy-placeholder`, even if unset on the host. Declarations
override profile, wrapper, and image env values without changing the host env.
Names are not inferred from `with`: host and client names can differ, and a
command can supply credentials for several client aliases. Unlisted variables
are forwarded normally; `--no-proxy` ignores the declarations entirely.
If a profile also forwards the host's source variable, declare that name too.
Managed localllm configs use the selected env value (OCR fills its literal key
on launch). Other auth files and history are not scrubbed; remove old copies
separately and rotate previously exposed keys.

**Existing configs:** add `fake_env` to every `with` rule; use `[]` if no fake
env is needed. Rules without this field fail validation. The old automatic
service-specific masking is gone: only declared names receive placeholders.

### GitHub

Create a fine-grained PAT with only the repos and permissions needed. Store it
from the checkout you launch in; worktrees share the main checkout's entry:

```sh
cd /path/to/your/checkout
box-gh-token set
```

The rule's `fake_env: ["GH_TOKEN"]` supplies the client placeholder; no dummy
export or `--gh` flag is needed. `box-gh-token get` reads the real host keychain.
Remove old fake exports from host profiles: host commands such as
`gh auth token` prefer an env token over their saved login.

`--gh` and `--gh=host` still select host tokens. A declared `GH_TOKEN` is masked
even with those flags; without a declaration, or with `--no-proxy`, the real
token is forwarded.

This covers `gh` REST/GraphQL calls, not authenticated Git-over-HTTPS. GitHub
enforces PAT permissions; the proxy does not enforce repo-level access.
Downloads may need `release-assets.githubusercontent.com`,
`objects.githubusercontent.com`, `raw.githubusercontent.com`, or
`codeload.github.com` allowed too. Do not inject the PAT into those hosts.

### BigQuery

Authenticate `gcloud` on the host with permission to impersonate the service
account. The example renews its token every ten minutes; no host `BQ_TOKEN`
or real gcloud login inside the box is needed. Inside the box:

```sh
bq --project_id=PROJECT_ID --oauth_access_token="$BQ_TOKEN" \
  query --use_legacy_sql=false 'SELECT 1'
```

`CLOUDSDK_AUTH_ACCESS_TOKEN` supplies the fake token for `gcloud`. BigQuery
Storage clients also need `bigquerystorage.googleapis.com` allowed and its own
token rule. Keep Google credential rules scoped to exact hosts, never
`*.googleapis.com`.

## Rule reference

- `allow`: host globs, `"all"`, or `"none"`. Disallowed destinations get 403.
- `rules`: first matching `host`, optional `path` glob (without query string),
  and optional `method` wins. A non-empty `host` is required.
- `fake_env`: required list of client env names on each `with` rule; `[]`
  explicitly requests no placeholders. Names must be valid shell identifiers.
- `with`: `{env:NAME}` reads an exported host variable once at launch;
  `{name}` reads `box-secret`; `{cmd:...}` runs and refreshes a host command
  every `ttl` seconds (default 600). Empty/unset env values stop the launch.
- `header`: defaults to `authorization`. The whole value is overwritten unless
  `replace` names a literal substring to swap. Injection happens only on HTTPS.
- `respond`: returns a JSON body without contacting upstream; `status`
  defaults to 200. Useful for clients that need a synthetic token response.
- `journal`: appends model tool calls as JSONL, stamped with `BOX_SESSION`.
  `calls` accepts host globs. The `path` file's parent is mounted read-write;
  use a dedicated directory. Missing directories are created; home and its
  ancestors are refused.

## Fencing and trust

The agent joins only an internal network. Only the proxy also joins an
outbound network, listed first so macOS selects working routing and DNS.
Native Linux fencing needs `*_BOX_RUNTIME=crun`; krun and WSL2 require an
explicit `--no-fence`. Fencing refuses `--ssh`, `--docker`, and `--egress`,
which would open other paths out.

Host ports (`--host-port`, a profile's `BOX_LAUNCH_PORT`) are ports you chose
to open, so a fenced box still gets them, relayed by the proxy from its
fence-network address. The box dials `127.0.0.1:<port>` as before. On a Mac
the relay connects to the gateway, where socat serves the port to the proxy
alone. Under podman the proxy's network can't reach the host's loopback, so
socat serves each port on a Unix socket in a private directory
(`$XDG_RUNTIME_DIR/agent-box-relay.*`) that only the proxy mounts.

`--no-fence` (or `*_BOX_FENCE=0`) keeps the proxy but permits direct access;
its allow-list then controls only traffic sent through it. `--no-proxy`
disables both defaults and opts back into real-token forwarding. Explicit
`--fence` together with `--no-proxy` is an error. `--proxy=PATH` chooses another
config file.

The CA is created with host `openssl`; its key stays in
`~/.config/agent-box/mitm`. Images carry only the certificate. Rebuild images
after CA rotation or a CA-mismatch error. No host mitmproxy install is needed.

[Back to the tools guide](README.md)
