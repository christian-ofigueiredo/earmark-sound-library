# Sound Library

An open-source Mac app, in progress, for organising sound-effect and music
libraries. It groups similar sounds (all your whooshes, by how they sound),
fills in missing categories with on-device AI, and finds the tempo and key of
every song in a folder. It never changes your original files.

- **[docs/PLAN.md](docs/PLAN.md)**: the build plan, decisions, and what Phase 0 has shown so far.
- **[phase0/](phase0/README.md)**: test tools you run on your own Mac and files today:
  - metadata inspection
  - AI model comparison
  - Soundly-style grouping with a sound map
  - music tempo and key

  Start with `phase0/README.md`.

Original sound and music files are only ever read, never changed.

## Automated checks

- **Checks** (every push): lint plus fast tests that need no AI models (`phase0/tests/`).
- **Mac install test** (run by hand from the Actions tab): runs `setup.sh` and the quick self-test with real models on a GitHub Apple Silicon Mac.

Run the tests locally with `cd phase0 && .venv/bin/python -m pytest`.

## License

MIT (see `LICENSE`). AI models and libraries are downloaded separately under
their own licenses; see `THIRD_PARTY_NOTICES.md`.
