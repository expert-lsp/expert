# Expert

Expert is the official language server implementation for the Elixir programming language.

## Installation

You can download Expert from the [releases page](https://github.com/expert-lsp/expert/releases) for your
operating system and architecture. Put the executable somewhere on your `$PATH`, like `~/.local/bin/expert`

For editor specific installation instructions, please refer to the [Installation Instructions](pages/installation.md)

### Nightly Builds

If you want to try out the latest features, you can download a nightly build.

Using the GH CLI, you can run the following command to download the latest nightly build:

```sh
gh release download nightly --pattern 'expert_linux_amd64' --repo expert-lsp/expert
```

Then point your editor to the downloaded binary.

### Building from source

Expert can be built in two ways: building a regular release for your own system (a
"plain" release), or building a "burrito" release that works on multiple systems.

To build Expert for your system, run the following command:

```sh
just release
```

You can then point your editor to the `start_expert` executable from the generated
release (`apps/expert/_build/prod/rel/plain`). You can also run `start_expert --help`
to see all available options.

> [!IMPORTANT]
>
> If your editor doesn't do it automatically, make sure to pass the `--stdio` flag to Expert.

To build Expert using burrito, you need Zig `0.15.2` installed on your system.
Later versions will not work.

Then you can run the following command:

```sh
just burrito-local
```

This will build the Expert binary and place it in the `apps/expert/burrito_out`
directory. You can then point your editor to this binary.

You can find more information in the [Installation Instructions](pages/installation.md).

## Sponsorship

Thank you to our corporate sponsors! Expert is currently in alpha and [we have organized all future work, including the first release, as milestones](https://github.com/expert-lsp/expert/milestones). If you'd like to start sponsoring the project, please read more below.

<div>
  <img height="100" src="./assets/sponsors/tauspace.png">
</div>
<div>
  <img height="100" src="./assets/sponsors/river.png">
</div>
<div>
  <img height="100" src="./assets/sponsors/logo-enigmatic-original.webp">
</div>
<div>
  <img height="100" src="./assets/sponsors/fresha.png">
</div>

### Corporate

For companies wanting to directly sponsor full time work on Expert, please reach out
to Dan Janowski: EEF Chair of Sponsorship WG at sponsor+expert (at) erlef (dot) org.

### Individual

Individuals can donate using GitHub sponsors. Team members are listed in the sidebar.

## Other resources

- [Architecture](pages/architecture.md)
- [Development Guide](pages/development.md)
- [Glossary](pages/glossary.md)
- [Installation Instructions](pages/installation.md)

## LICENSE

Expert source code is released under Apache License 2.0.

Check LICENSE file for more information.
