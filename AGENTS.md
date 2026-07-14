# Project Instructions

- Work from the current repository root. Do not create or maintain another local project copy.
- Resolve paths from the repository root; never hardcode the local checkout directory name.
- Keep every provider/server profile isolated under `profiles/<profile>/`; use an explicit `VPS_PROFILE` for every existing VPS.
- Treat all of `profiles/` as sensitive local state. Never stage, commit, print, or upload its contents.
- Store provider-specific client YAML in `profiles/<provider>/clients/`.
- Store a VPS login key only in `profiles/<provider>/ssh/`; never copy it to the server.
- iCloud YAML files are distribution copies for device sync, not the project source of truth.
- Shared protocols and routing rules belong in `core/`; provider lifecycle differences belong in `providers/`.
- Run Shell syntax checks and Python tests before publishing changes.
- Confirm `git ls-files profiles` is empty before every push.
