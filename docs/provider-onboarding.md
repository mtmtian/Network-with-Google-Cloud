# Provider Onboarding

Use one profile per server. A profile name is a local namespace for the server's address, generated credentials, client YAML, and optional SSH key; it is not a provider account password.

## Existing Debian/Ubuntu VPS

1. Install Debian 12/13 64-bit or Ubuntu 24.04 LTS.
2. Confirm root SSH access with a public key. Keep the private key on the local machine only.
3. Run the generic VPS entry point with an explicit, unique profile name:

```bash
VPS_PROFILE=frantech \
VPS_SSH_KEY="$HOME/.ssh/frantech_ed25519" \
./deploy-vps.sh <VPS_PUBLIC_IP>
```

Use a different profile for every server, for example `dmit`, `frantech`, or `new-york-01`. Do not run `./deploy-vps.sh` without `VPS_PROFILE`.

The first run creates `profiles/<profile>/deploy.conf` and `.secrets.env`, secures the host, creates the `mt` sudo user, installs the shared protocols, and writes:

```text
clash-configs/<profile>-mac.yaml
clash-configs/<profile>-iphone.yaml
```

After the first successful run, root login is disabled and `mt` is the maintenance user:

```bash
ssh -i "$HOME/.ssh/frantech_ed25519" mt@<VPS_PUBLIC_IP>
```

## Adding another provider lifecycle

Use `deploy-vps.sh` when the provider already exposes a reachable Debian/Ubuntu host. Add a new adapter under `providers/` only when the provider needs different lifecycle, authentication, or firewall operations. Keep shared protocol installation, secrets, routing, and client generation in `core/`.

## Profile isolation checklist

- Choose a new profile name before touching a new host.
- Keep `deploy.conf`, `.secrets.env`, and `ssh/` inside that profile only.
- Keep generated YAML in `clash-configs/`; never stage `profiles/`, SSH keys, or client YAML.
- Regenerate one profile's clients with:

```bash
NETWORK_NODE_PROFILE=<profile> python3 core/gen-clash.py
```

- Before pushing, verify:

```bash
git ls-files profiles
```

The command must print nothing.
