# Langflow (per-client single-tenant VM)

Visual builder for AI agents and RAG pipelines, with MCP support — shipped as a turnkey
product on a dedicated VM. One VM = one client. The web UI is served over HTTPS on the
client's own subdomain; the LLM backend is **avots.ai** and the client uses **their own
avots key**.

Upstream: [github.com/langflow-ai/langflow](https://github.com/langflow-ai/langflow) ·
[docs.langflow.org](https://docs.langflow.org). License: **MIT** — brand this to the client
as **"powered by Langflow"**.

## What the client gets

- The full Langflow visual editor (drag-and-drop flows, agents, RAG, MCP) on
  `https://{domain}/`, behind login.
- A pre-wired connection to avots.ai so models like `anthropic/claude-opus-4.8` work out of
  the box once they drop an OpenAI / Language Model component into a flow.
- Their avots API key pre-loaded as a masked **Credential** global variable (`AVOTS_API_KEY`).

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Langflow (internal :7860 + loopback bind) + Caddy (:80/:443). Named volume for the SQLite DB. Hardened. |
| `Caddyfile` | `{$DOMAIN}` → `reverse_proxy langflow:7860`, automatic TLS. |
| `.env.example` | Template for the per-client `.env`. |
| `first-boot.sh` | Idempotent: brings the stack up and does one superuser login to materialize env-sourced globals. |
| `autoinstall-snippet.yaml` | cloud-init `write_files` (`.env`) + `runcmd` (compose up + first-boot). |

## Run steps (manual / dev)

```bash
cp .env.example .env
# Edit .env: set DOMAIN, AVOTS_API_KEY, LANGFLOW_SUPERUSER(_PASSWORD), and generate a secret:
#   LANGFLOW_SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
./first-boot.sh
```

Then open `https://{domain}/` and log in with the superuser credentials from `.env`.
(In production this is all done by `autoinstall-snippet.yaml` at first boot.)

## avots wiring (exact)

The avots gateway is OpenAI-compatible:

- Base URL: `https://api.avots.ai/openai/v1`
- Auth: `Authorization: Bearer av_mcp_<key>`
- Default model: `anthropic/claude-opus-4.8` (lazy alias `claude` also works)

There are two layers, and the build uses both:

1. **Global default base URL.** `OPENAI_API_BASE=https://api.avots.ai/openai/v1` is set in the
   container env, so OpenAI-compatible components default to the avots gateway.
2. **Per-component, inside a flow.** In the **OpenAI** component set:
   - **`api_key`** → the `AVOTS_API_KEY` global variable (Credential type — see below).
   - **"OpenAI API Base"** (the component's `base_url` field) → `https://api.avots.ai/openai/v1`.
     Setting this per-component is the most explicit/portable wiring even though the global
     `OPENAI_API_BASE` already points there.

### Key injection as a global variable

`LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT=AVOTS_API_KEY` tells Langflow to import the
`AVOTS_API_KEY` environment variable into its database as a **Credential-type global
variable** (masked in the editor). Both the env var and this list are required:
`AVOTS_API_KEY` is also passed into the container env in `docker-compose.yml`. In a flow,
pick `AVOTS_API_KEY` from the global-variable dropdown on the component's `api_key` field.

## Caveats (verify on the pinned version)

### #11119 — env-sourced globals don't sync until first superuser login

Variables listed in `LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT` are **not written to the DB
at startup** — they are materialized only on the **first superuser login**
([issue #11119](https://github.com/langflow-ai/langflow/issues/11119)). So on a fresh VM the
`AVOTS_API_KEY` global may not exist until someone logs in.

**Workaround (built in):** `first-boot.sh` performs one authenticated
`POST /api/v1/login` (OAuth2 password form: `username`/`password`) right after the stack is
up, which triggers the sync. After that the global variable is present in the DB. The client
then logs in normally through the UI. (Alternative if you ever go fully headless: pre-seed
the variable in the DB.)

### #6096 — OpenAI component model picker may reject custom model ids

The OpenAI component's model dropdown is tied to OpenAI's own model list, so a custom id like
`anthropic/claude-opus-4.8` may not be selectable from the picker
([issue #6096](https://github.com/langflow-ai/langflow/issues/6096)). 

**Workarounds:**
- On the pinned version, verify whether the model field accepts a **typed/custom** value
  (newer versions allow typing an arbitrary model name). If it does, just type
  `anthropic/claude-opus-4.8` (or `claude`).
- Otherwise use a **custom Language Model / Python component** that calls the OpenAI-compatible
  endpoint with an explicit `model`, `base_url`, and `api_key`. This bypasses the picker
  entirely and is the most reliable path for arbitrary avots model ids.
- `/v1/models` on the avots gateway returns the full list of valid ids to choose from.

## Ports / TLS

- Public: **80 and 443 only** (Caddy). 443/udp is also opened for HTTP/3.
- Langflow's 7860 is **not published publicly** — it's only on the internal compose network
  plus a `127.0.0.1:7860` loopback bind for on-box debugging.
- Caddy obtains and renews a Let's Encrypt cert for `{$DOMAIN}` automatically. Requirements:
  DNS for the domain points at the VM, and 80/443 are reachable from the internet. First-boot
  TLS issuance takes ~30-60s. The `caddy-data` volume persists the cert/ACME account.

## Security checklist

- [x] `LANGFLOW_AUTO_LOGIN=False` — no anonymous access (Langflow flows can run **arbitrary
      Python** via custom components; there is **no sandbox**).
- [x] Unique, strong `LANGFLOW_SUPERUSER_PASSWORD` per VM.
- [x] Unique, **stable** `LANGFLOW_SECRET_KEY` per VM (encrypts stored secrets + signs JWTs;
      rotating it makes existing stored secrets undecryptable).
- [x] 7860 kept off the public interface — Caddy is the only public entry point.
- [x] `security_opt: no-new-privileges` on both services; **no `docker.sock` mounted** anywhere.
- [x] Pin a **patched** image tag (never `:latest`); keep a re-bake pipeline for upstream CVEs
      (Langflow has a history of RCE-class issues).
- [ ] Consider restricting outbound egress to the avots gateway + package/registry hosts.

## Version pin

`docker-compose.yml` pins **`langflowai/langflow:1.9.6`** (newest stable as of 2026-06-05).
This is well clear of the **1.6.0–1.6.3** range to avoid. **Re-verify the tag before baking**
the golden image and bump to the latest patched release. Check Docker Hub tags:
[hub.docker.com/r/langflowai/langflow/tags](https://hub.docker.com/r/langflowai/langflow/tags).
