# Contributing to Expert

Thank you for your interest in contributing to Expert!

## Architecture & Development Guides

Before submitting changes, please review our core documentation:

- [Architecture Overview](pages/architecture.md) – System architecture, poncho app structure, and design principles.
- [Development Guide](pages/development.md) – Prerequisites, building releases, running tests, and debugging.
- [Configuration](pages/configuration.md) – Editor and server configuration details.

## Contribution Guidelines

- **Pull Requests**:
  - Keep pull requests focused on a single concern.
  - Link an associated issue or provide clear reproduction steps/context.
  - Test and verify your changes locally before submitting.
  - Avoid submitting Draft pull requests unless agreed upon in advance.
- **Code Style & Formatting**:
  - Format Elixir code with `mix format`.
  - Ensure strict Credo checks pass (`mix credo --strict`).
  - Follow Conventional Commits for commit messages and PR titles (e.g. `feat:`, `fix:`, `perf:`).
- **Testing**:
  - Add or update ExUnit tests covering your changes.
