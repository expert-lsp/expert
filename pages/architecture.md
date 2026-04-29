# Architecture

## Overview

Expert solves several Elixir-specific code intelligence problems:

- Macros and compile-time code can generate functions, override definitions, and change a module's final shape. Static analysis alone cannot always see the code that will exist after compilation.
- Existing code-intelligence libraries often rely on compiler and runtime APIs such as `Code` and `:application`. Those APIs were not designed for language-server isolation, and they can observe modules loaded in the same VM as the tool itself.
- Projects may use different Elixir and Erlang/OTP versions than the Expert release.

Expert addresses these problems by splitting responsibilities between two nodes:

- Manager node: runs the language server, owns the LSP transport, tracks editor state, and routes requests.
- Engine node: runs ElixirSense, indexes the project, compiles project code, and executes code-intelligence work in the project's context.

Before an engine node starts, Expert also:

- Builds the engine with the project's Elixir and Erlang/OTP versions.
- Namespaces the engine and shared Expert modules so they do not collide with or pollute the project being analyzed.

## Project Structure

Expert is structured as a [poncho-style project](https://embedded-elixir.com/post/2017-05-19-poncho-projects/), with these applications under `apps`:

- `forge`: Shared project, document, AST, search-entry, namespacing, and node-discovery utilities.
- `engine`: The project-side application that provides compilation, indexing, search, and code-intelligence APIs inside the project node.
- `expert`: The manager and language-server application that owns the LSP transport, project supervision, and request dispatch.
- `expert_credo`: A Credo diagnostics plugin exposed through the Forge plugin API.

By separating Expert into applications, the release and engine builder can place only the required code in each VM. The engine runtime dependency set is intentionally smaller than the manager's because engine code runs beside the project and must be namespaced and filtered out of analysis. Keeping engine dependencies to the minimum needed for project-side work is a design goal of this architecture.

## LSP Implementation

Expert uses [GenLSP](https://github.com/elixir-tools/gen_lsp) for the core LSP implementation. GenLSP provides transport implementations, protocol structs, and other utilities for implementing a language server. Expert's LSP-specific behavior lives in the `expert` application, primarily in the [`Expert`](https://github.com/expert-lsp/expert/blob/main/apps/expert/lib/expert.ex) and `Expert.State` modules.

At startup, `expert --stdio` uses stdio as the transport, while `expert --port <port>` uses TCP.

The `Expert` module handles LSP messages. Lifecycle requests and notifications are handled directly in the manager state, including document open, change, save, close, workspace folder changes, initialization, and shutdown. They are used to:

- Keep open document contents and analysis in `Forge.Document.Store`. Code that needs document contents should prefer the document store over reading from disk so open editor buffers stay synchronized with the language server.
- Start project engines, broadcast file changes to engines, and request document or project compilation.

Other LSP requests are delegated to provider handlers under `Expert.Provider.Handlers`. A provider handler implements `Expert.Provider.Handler.handle/2`, receives the native request plus an `Expert.Document.Context` for document requests, and returns `{:ok, response}` or `{:error, reason}`. Notifications that do not need a response return `{:ok, nil}`.

## Code Intelligence

Expert combines several sources of code-intelligence data:

- ElixirSense provides request-time suggestions, hover information, and fallback definition lookup.
- Compiled BEAM metadata provides docs, specs, callbacks, and type information for loaded modules.
- The search index provides persistent, project-wide lookup for modules, functions, structs, variables, and references.

The indexer analyzes Elixir source files and stores entries in `Engine.Search.Store`. At a high level, indexing works as follows:

1. Each source file is wrapped in a `Forge.Document` struct.
2. `Forge.Ast.analyze/1` derives a `Forge.Ast.Analysis` from the document.
3. The AST is traversed with `Macro.prewalk/3`, and a series of extractors emits `Forge.Search.Indexer.Entry` values.
4. The search store persists those entries in the project's `.expert/indexes/ets` directory.

On the first run, the indexer scans every `.ex` and `.exs` file outside the project's build directory. After that, it refreshes changed files and removes deleted files from the index. Dependency files are indexed for definitions only.

The results of the indexer can be queried through `Engine.Search.Store`.

### The `Entry` Struct

Entries have a `type`, which describes what kind of information they represent, and a `subtype`, which is either a definition or a reference.

For example, in this code:

```elixir
defmodule MyApp.User do
  def new(x), do: x
end
```

The indexer emits separate definition entries for:

- Module definition `MyApp.User`
- Function definition `MyApp.User.new/1`

If another file calls `MyApp.User.new("hello")`, that call becomes another entry with the reference subtype.

### The `Forge.Ast.Analysis` Struct

The `Forge.Ast.Analysis` struct holds the AST for a document and extra information about source context. In particular, it includes:

- The AST of the document
- The original `Forge.Document`
- Comments grouped by line
- Any parse error found in the document
- A list of scopes in the document

Scopes are the most important part of the analysis. Each scope describes which module, aliases, imports, requires, and uses are active in a source range. This is critical for context-aware features like code actions and alias expansion.

## Project Compilation

Expert performs two kinds of compilation:

- Document compilation for eligible open documents after `textDocument/didChange`.
- Full project compilation when an engine starts, when a project build is explicitly triggered, or when a file in a Mix project is saved.

Document compilation runs through `Engine.Build.Document` and compiles only the changed document. It is used to provide file-level diagnostics without waiting for a full project build.

Full project compilation runs in the engine node. For Mix projects, Expert runs `mix compile` in the project context with Expert's versioned `MIX_BUILD_PATH`, which stores build artifacts under `.expert/build`. After compilation, Expert runs `mix loadpaths`, refreshes loaded module data, emits compilation events, and enables the search store after the first project build. File compilation and explicit reindex events refresh search index entries after that.

Compilation and indexing events are produced by the engine node. The manager node consumes those events and turns them into LSP diagnostics, logs, and progress notifications.

### The Need For Compilation

Many languages can provide code-intelligence features by analyzing source code alone. Elixir also has compile-time code execution and metaprogramming, so a significant portion of a module's final shape may only be available after compilation.

Take this code for example:

```elixir
defmodule SomeServer do
  use GenServer
end
```

The `use GenServer` macro injects functions such as `child_spec/1`, `code_change/3`, and other overridable callbacks into `SomeServer`. If Expert only analyzed the source without compiling it, features like "Go to definition" or "Find all references" would not have accurate information about those generated functions.

This applies to macros from the standard library, dependencies, and the user's own codebase. Expert compiles code so it can:

- Introspect loaded code with ElixirSense and project runtime APIs.
- Read final BEAM files and extract docs, specs, callbacks, and type information.

## Namespacing

The engine node has its own modules and dependencies. If the user project has modules with the same names, Expert could analyze the wrong module or create dependency conflicts while compiling the project.

To avoid this, Expert namespaces its release and engine build artifacts. The namespace task rewrites Expert applications and their loaded dependencies with an `XP` prefix, so `Engine` becomes `XPEngine`, `Forge` becomes `XPForge`, and so on. The prefix is also used to filter Expert's own modules out of code intelligence results.

The manager code is also namespaced because it shares data structures with the engine. For example, `Forge.Document` structs are passed between the manager and engine. Namespacing both sides with the same prefix keeps those shared struct names consistent across nodes.

## Manager-Engine Distribution

Expert starts the engine node as a separate OS process and communicates with it through distributed Erlang RPC.

Some distributed Erlang setups rely on the Erlang Port Mapper Daemon (EPMD), but Expert uses an EPMDless setup. `Forge.EPMD` avoids the system EPMD daemon, and `Forge.NodePortMapper` lets project nodes register their distribution ports with the manager node. This prevents stale EPMD entries and prevents nodes from different Expert instances from discovering each other accidentally.

## Project Versions

Expert releases are built with the Elixir and Erlang/OTP versions configured in `.github/workflows/release.yaml`. A project using Expert may run different versions, and those differences can affect compiler internals, special forms, generated code, and loaded BEAM metadata.

For that reason, Expert builds and runs the engine with the project's Elixir and Erlang/OTP versions. At a high level, the process is:

1. Find the project's `elixir` and `erl` executables and spawn a build VM with them.
2. Run `priv/build_engine.exs`, which builds the engine with `Mix.install/2`, namespaces the compiled engine into a separate build path, and returns the namespaced ebin paths plus the build `MIX_HOME`.
3. Spawn a separate project engine VM with the project's `elixir` executable, add the namespaced engine ebin paths, and bootstrap the `Engine` application.

Expert uses separate VMs for building and running the engine so code loaded by `Mix.install/2` during the build does not pollute the runtime engine node.

To avoid polluting the user's Mix, Hex, and Rebar caches, the engine build script sets private `MIX_INSTALL_DIR`, `MIX_HOME`, `HEX_HOME`, and `REBAR_CACHE_DIR` directories under Expert's user cache directory.

Compiled engine applications are stored under the directory returned by `Forge.Path.expert_cache_dir/0`, which uses [`:filename.basedir(:user_cache, "expert")`](https://www.erlang.org/doc/apps/stdlib/filename.html#basedir/3).
