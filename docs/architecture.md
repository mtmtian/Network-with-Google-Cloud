# Architecture

The repository keeps protocol behaviour and client routing rules in one shared core while isolating provider-specific lifecycle operations and credentials behind adapters and profiles.

## Entry points

- `deploy-gcp.sh` loads the Google Cloud adapter.
- `deploy-vps.sh` loads the generic Debian/Ubuntu VPS adapter and requires an explicit `VPS_PROFILE`.
- `deploy.sh` is a compatibility alias for the GCP entry point.

All entry points hand control to `core/deploy.sh`.

## Provider seam

Each provider adapter implements the same shell interface:

- `provider_init`: parse provider-specific arguments.
- `provider_preflight`: validate local tools and authentication.
- `provider_configure`: create or load provider configuration.
- `provider_provision`: obtain and secure a reachable host.
- `provider_install`: copy and execute the shared server installer.
- `provider_print_summary`: print provider-specific handoff details.

The shared pipeline owns key generation, optional Cloudflare setup, server-environment construction, Reality public-key recovery, and Clash/Mihomo configuration generation.

## Data flow

```text
entry point -> provider adapter -> shared secrets -> provider host setup
            -> shared server install -> shared client config generation
```

Provider state is isolated below `profiles/`:

```text
profiles/
├── gcloud/                    # fixed GCloud profile
│   ├── deploy.conf
│   ├── .secrets.env
│   └── ssh/                    # optional local-only key storage
├── dmit/                      # existing VPS profile
│   ├── deploy.conf
│   ├── .secrets.env
│   └── ssh/id_rsa.pem
└── <new-profile>/             # one independent bundle per new VPS
    ├── deploy.conf
    ├── .secrets.env
    └── ssh/                    # optional local-only key storage

clash-configs/
├── gcloud-{mac,iphone}.yaml
├── dmit-{mac,iphone}.yaml
└── <new-profile>-{mac,iphone}.yaml
```

The entire `profiles/` tree is gitignored. This keeps host lifecycle state and credentials separate while both providers continue to consume the same protocol installer and routing-rule template.

Each profile owns its state and optional host credentials. Generated client YAML is centralized in `clash-configs/` and the generator removes only files prefixed with the active profile name, so running one adapter cannot overwrite another adapter's outputs. The VPS entry point rejects missing or unsafe profile names to prevent accidental cross-provider writes.

The stock monitor under `tools/` is a separate read-only utility. It uses official inventory pages and recent social leads, stores its deduplication state outside the repository, and never logs into a provider account.
