# Contributing

Thanks for considering a contribution.

## How to contribute
1. Fork the repo and create a feature branch.
2. Keep changes small and focused.
3. Update docs when behavior or config changes.
4. Run any relevant tests or manual checks.
5. Open a PR with a clear description.

## Style
- Prefer small, readable shell scripts.
- Avoid heavy dependencies; keep the image minimal.
- Document new env vars in `README.md` and `SETUP.md`.

## Reporting issues
Provide:
- Host OS and Docker version
- Exact `docker run` command
- Logs (`docker logs --tail=200 lightmail`)
