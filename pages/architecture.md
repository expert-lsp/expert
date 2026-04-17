# Architecture

## Overview

Expert has several challenges to solve in order to work for Elixir, most notably:

- Macros and compile time code requires an elixir compiler to get the code's final form. Without that, providing accurate information about the code is difficult.
  Functions can be dinamically generated, definitions can be overriden, etc. Static analysis of the code it not enough.
- A lot of the existing implementations for code intelligence rely on the builtin compiler, or builtin functions from `Code` or `:application`. These functions were not originally designed to be used in a language server, which often proves to be either insufficient, or with undesired side effects. For example, ElixirSense(the library used for code intelligence) relies on them to analyze the modules and other code in the node that it's running in, meaning it will also include the code from the language server itself.
- Different projects may be on different versions of Elixir and Erlang/OTP, which can lead to incompatibilities if the language server is built on a different version than the project.

Expert approaches these problems by splitting the language server responsibilities into two nodes:

- Manager node: This node is responsible for managing the language server, handling the transport, and delegating requests to the right handlers.
- Engine node: This node runs ElixirSense, performs indexing of your codebase, and executes code in the context of your project.

In addition to this, the Engine node also goes through a few extra steps before it gets started:

- It is compiled on the version of Elixir and Erlang/OTP that the project is using "on the fly", to ensure compatibility.
- It is namespaced to avoid its code from polluting the intelligence engines. A description of namespacing is provided in a later section.

## Project Structure

Expert is structured as a [poncho project](https://embedded-elixir.com/post/2017-05-19-poncho-projects/), with the following sub-apps:

- `forge`: Contains all code common to the other applications.
- `engine`: The application that's injected into a project's code, which
  gives expert an API to do things in the context of your app.
- `expert` The language server itself.

By separating expert into sub-applications, each is built as a separate archive, and we can pick and choose which of these applications (and their dependencies) are injected into the project's VM, thus reducing how much contamination the project sees. If Expert was a standard application, adding dependencies to Expert would cause those dependencies to appear in the project's VM, which might cause build issues, version conflicts in mix or other inconsistencies.

## LSP implementation

Expert uses [GenLSP](https://github.com/elixir-tools/gen_lsp) for the core LSP implementation. It provides transport implementations, struct definitions, and other utilities to make it easier to implement the language server. However, the actual logic for handling LSP requests and notifications is implemented in the `expert`.

On the Expert side, the `Expert` module is where LSP messages are handled. Lifecycle notifications(like `textDocument/didOpen`) are handled directly in the `Expert` module. They are used in two main ways:

- To keep track of the open documents and their states via the `Forge.Document.Store`. This is a central and critical piece of the architecture, and all the code should preferrably ask the document store for the document contents rather than reading the files from disk: this avoid a desync between the language server and the editor.
- To start a project engine or tell it to trigger a project recompilation

LSP requests on the other hand are delegated to _Provider Handlers_, which are the modules that implement the actual logic for handling the requests. For example, there is a _Provider Handler_ for handling `textDocument/completion` requests. When adding support for a new LSP request, a new _Provider Handler_ should be created to handle it.

## Code Intelligence

Expert has two main sources of information for code intelligence: [ElixirSense](https://github.com/elixir-lsp/elixir_sense) and the _indexer_.

ElixirSense is used to get completions for modules, for hover docs, and other similar features. It provides the information the moment it is requested but it does not store the information anywhere, so every time Expert is restarted, ElixirSense will have to analyze everything again.

The indexer on the other hand analyzes your codebase and stores the information in an index cache on disk. At a high level it works as follows:

1. Files to be indexed are wrapped in a `Forge.Document` struct. Most of the operations we perform on files are done through standardized data structures rather than ad-hoc maps or other types, and we have a whole suite of functions to work on them in the `Forge` application.
2. A `Force.Analysis` is derived from the document
3. Its AST is traversed and a series of "extractors" is applied to each node, and emits Entries for the index. There are several extractors for different purposes, for example there is an extractor for function definitions, one for module definitions, one for struct definitions, etc.

On the first run the indexer will run against every .ex and .exs file in your project, then it will incrementally update the index as files are changed. The index files are stored in the `.expert/indexes` directory in the project folder.

The results of the indexer can be queried via the `Engine.Search.Store` module.

It is worth noting that the indexer runs inside the engine node, meaning that if you have a monorepo project, an index will be generated for each individual project, and the information will not be shared between them.

### The `Entry` struct

Entries have a `type`, that is what kind of information they represent(a module, a function, a struct, etc), and a `subtype` that can be one of two things: a definition or a reference.

For example, in this code:

```elixir
defmodule MyApp.User do
  def new(x), do: x
end
```

The indexer will emit separate entries for:
- Module definition `MyApp.User`
- Function definition `MyApp.User.new/1`

If another file calls `MyApp.User.new("hello")`, that call becomes another entry, this time as a reference.


### The `Forge.Ast.Analysis` struct

The `Analysis` struct holds the AST for a document, and extra information about the scopes of the different expressions in its code. In particular, it provides the following information:

- The AST of the document
- The comments in the document, and their positions
- Any parse errors that were found in the document
- A list of scopes in the document

Scopes are the most important part of the analysis. Each scope describes what module/aliases/imports/requires/uses are active in a particular source range. This information is critical for context-aware features like code actions.

## Project compilation

Expert performs two kinds of compilations:

- As-you-type document compilation
- Full project compilation

The former is triggered whenever you type, and it's used to provide instant feedback on the code you're writing. It compiles *only* the document you're working on, which is expected to be fast enough to run on every keystroke.

The latter is scheduled when the engine node starts or when a file is saved.

Full project compilations use `mix compile` in the project directory, and the compilation output is stored in the `.expert/build` directory.

Once the project is compiled, the code paths are updated with `mix loadpaths`, the project is reindexed, and events are emitted.

The compilation events are produced by the engine node, and the manager node consumes them and turns them into LSP diagnostics or progress notifications.

### The need for compilation

Many languages allow for code intelligence features to work just by analyzing the source code. Elixir however allows compile time code execution and metaprogramming, meaning a significant portion of the code's final form is only available after compilation.

Take this code for example:

```elixir
defmodule SomeServer do
  use GenServer
end
```

That will inject a lot of functions into `SomeServer` like `child_spec/1`, `code_change/3` and a bunch of other overridable functions. If we were to analyze the code without compiling it, we would not be able to provide accurate information about the functions that are available in `SomeServer`, and features like "Go to definition" or "Find all references" would not work for those functions.

This is a simple example using a macro from the standard library, but the same applies to any macro or compile time code execution in the user's codebase, and it's not uncommon for projects to have their own macros that generate a significant portion of the code.

Thus, we need to compile the code to get the final form of it for two important code paths:

- To be able to introspect the loaded code with ElixirSense
- To be able to read the final `.beam` files and extract information from them

## Namespacing

The engine node has dependencies, and defines modules itself. If the user project would have modules with the same name as the engine's modules, it would be hard to determine which is the user modules and which should be left out of the code analysis, or it would cause issues by causing us to analyze the wrong module. Moreover, since the engine needs to compile the user code, if both the engine and the user project share a dependency but require incompatible versions of it, it would cause compilation issues.

To solve this, the engine code is namespaced. This means that all of the modules defined in the engine app and its dependencies are prefixed with a unique namespace(`Engine` would become `XPEngine`). This prefix is then used to filter out the engine's modules from the code analysis, and to avoid any potential conflicts with the user project's code. This also allows the engine to have dependencies without worrying about version conflicts with the user project.

The Expert server code is also namespaced, not because it would conflict with user code, but because it needs to share data structures with the engine. For example, the `Forge.Document` struct is used both in the manager and in the engine node. If only the engine were namespaced, the manager node would expect to receive `Forge.Document` structs from the engine, but it would actually receive `XPForge.Document` structs, which would cause issues. By namespacing both the manager and the engine with the same prefix, we can ensure that they can communicate with each other without any issues.

## Manager-Engine distribution

Expert starts the engine node as a separate OS process and communicates with it via RPC using distributed Erlang. To make the manager and the engine node know about eachother, some common setups rely on the Erlang Port Mapper Daemon(EPMD), but we found that in some environments EPMD can cause connection issues between the nodes, or that its mapping cache would get stale.

To avoid that we use an EPMDless setup, with a custom `Forge.EPMD` module, and a `Forge.NodePortMapper` process that helps the nodes from the same expert instance to discover eachother and prevent them from interacting with other expert instances that might be running on the same machine, or even against the same projects.


## Project Versions

Expert releases are built on a specific version of Elixir and Erlang/OTP(specified at `.github/workflows/release.yml`). However, the project that Expert is being used in may be on a different version of Elixir and Erlang/OTP. This can lead to incompatibilities - one particular example is that the `quote` special form may call internal functions in elixir that are not present in the version of Elixir that Expert is built on and viceversa, leading to crashes.

For this reason, Expert compiles the `engine` application on the version of Elixir and Erlang/OTP that the project is using. At a high level the process is as follows:

1. Find the project's elixir executable, and spawn a vm with it that compiles the `engine` application.
2. Namespace the compiled `engine` app, return the path to the compiled `engine` to the `expert` manager node, and exit.
3. Gather the paths to the compiled `engine` app files, spawn a new vm with the project's elixir executable, and load the `engine` app into that vm.

We use two separate vms(one for compilation, one for actually running the `engine` app) to ensure that the engine node is not polluted by any engine code that might have been loaded during compilation. We currently use `Mix.install` to compile the `engine` app, which loads the `engine` code into the compilation vm. Spawning a new vm for the engine node ensures that the engine node is clean.

To avoid polluting the user's Hex archives, Expert uses its own mix and rebar caches when compiling the engine. It does however use the same `HEX_HOME` as the user, which is required if the user project is using private repositories. Otherwise Expert would be unable to fetch private dependencies.

The compiled `engine` application will be stored in the user's "user cache" directory via [`:filename.basedir`](https://www.erlang.org/doc/apps/stdlib/filename.html#basedir/3).
