# Semantic metadata

Elixir code often defines functions and macros with arguments that follow
rules the compiler does not check. A query macro accepts the keys `:where` and
`:limit`. A configuration DSL accepts a fixed set of options. An editor cannot
suggest these keys or show their documentation, because the rules exist only
inside the macro implementation.

Elixir semantic metadata lets a library describe these rules as plain data. The
library stores the data in its compiled modules. Tools such as language servers
read the data from the module files to offer completion and hover
documentation. The library code does not run when a tool reads the data.

## A first example

Suppose `My.Query.from/2` takes a source and a keyword list:

```elixir
My.Query.from(User, where: active, limit: 10)
```

With semantic metadata, an editor offers these completions:

```elixir
My.Query.from(User, |)         # where:, limit:
My.Query.from(User, where: |)  # coalesce/2, true, false
```

The editor also shows the documentation of each suggestion when the user hovers
over it.

## Publishing metadata

A module publishes metadata with the `:elixir_semantic_metadata` module
attribute. Register the attribute with `accumulate: true` and `persist: true`.
Accumulation lets a module publish more than one value. Persistence writes the
values into the compiled module file, where tools can read them.

Each value is a tuple of the version tag `:elixir_semantic_metadata_v1` and one
document. A document is a map with two keys:

- `:contexts` lists the places where the rules apply.
- `:scopes` maps a name to the rules that apply at those places.

This module publishes the metadata for the example above:

```elixir
defmodule My.Query do
  Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
    accumulate: true,
    persist: true
  )

  @elixir_semantic_metadata {
    :elixir_semantic_metadata_v1,
    %{
      contexts: [
        %{
          mfa: {My.Query, :from, 2},
          argument: 1,
          scope: :query_options
        }
      ],
      scopes: %{
        query_options: %{
          entries: [
            %{
              kind: :keyword,
              name: :where,
              doc: "Filters the query.",
              value_scope: :expressions
            },
            %{
              kind: :keyword,
              name: :limit,
              doc: "Sets the maximum result count."
            }
          ]
        },
        expressions: %{
          entries: [
            %{
              kind: :function,
              mfa: {My.Query.API, :coalesce, 2},
              doc: {My.Query.API, :function, :coalesce, 2}
            },
            %{kind: :literal, value: true},
            %{kind: :literal, value: false}
          ]
        }
      }
    }
  }
end
```

Each `@elixir_semantic_metadata` assignment adds one document. Put unrelated
rules in separate documents.

The next sections explain the three parts of a document: contexts, scopes, and
entries.

## Contexts

A context is a rule of the form: "When the cursor is in this argument of this
function, use this scope." A tool applies the rule when the cursor is inside the
matching argument of a call to that exact function or macro.

This context applies to the second argument of `My.Query.from/2`:

```elixir
%{mfa: {My.Query, :from, 2}, argument: 1, scope: :query_options}
```

The context has three fields:

- `:mfa` is a module, function, and arity tuple. The tuple
  `{My.Query, :from, 2}` names the function `My.Query.from/2`. Use the same
  tuple for macros. The arity is an integer from `0` to `255`.
- `:argument` is the position of the argument. Positions start at zero, so
  argument `1` is the second argument.
- `:scope` is the name of the scope that applies in that argument.

Tools resolve aliases and imports before they look for a context. The context
above also matches `from(User, |)` after `import My.Query` and `Q.from(User, |)`
after `alias My.Query, as: Q`.

A piped value counts as the first argument. Both calls below place
`user.active` at position `2`:

```elixir
where(query, [user], user.active)
query |> where([user], user.active)
```

### Contexts for blocks

A macro can take blocks such as `do`, `else`, `rescue`, `catch`, `after` and `else`.
A context for a block uses `:block` in place of `:argument`:

```elixir
%{mfa: {My.DSL, :run, 1}, block: :do, scope: :body}
%{mfa: {My.DSL, :run, 1}, block: :else, scope: :fallback}
```

With these contexts, the cursor in the `do` block of `My.DSL.run/1` uses the
`:body` scope. The cursor in the `else` block uses the `:fallback` scope.

A document cannot hold two contexts for the same function and the same argument
or block.

## Scopes

A scope is a named list of the things that a user can write at a position. A
context selects a scope by its name. A scope name can be any term, but atoms
are generally the easiest to read.

```elixir
scopes: %{
  query_options: %{entries: [...]},
  expressions: %{entries: [...]}
}
```

Several contexts can select the same scope. A scope name must be unique inside
one document, and every name that a context or entry uses must exist in the
same document.

A keyword entry can select another scope for its value with `:value_scope`. In
the first example, the `:where` entry selects `:expressions`. The cursor in
`where: |` therefore uses the `:expressions` scope. A tool follows each
`:value_scope` as the cursor moves into nested keyword lists and uses the scope
that it reaches at the cursor.

A scope can refer to itself or to a scope that refers back to it. This
describes recursive options, for example a `:filters` option whose value accepts
another `:filters` option.

## Entries

An entry describes one thing that a user can write at a position. The entries
of a scope are the suggestions that a tool offers there. Every entry has a
`:kind`.

### Callable entries

A callable entry describes a function or a macro that the user can call. It has
a `:kind` and an `:mfa`:

```elixir
%{kind: :function, mfa: {My.Query.API, :coalesce, 2}}
%{kind: :macro, mfa: {My.DSL, :attribute, 2}}
```

The kinds `:function`, `:macro`, `:callback`, and `:typespec` appear in
completion as items of that kind. Any other atom appears as a general item.

### Keyword entries

A keyword entry describes a key that the user can write in a keyword list:

```elixir
%{
  kind: :keyword,
  name: :mode,
  value_scope: :modes
}
```

The `:name` is an atom. The optional `:value_scope` names the scope for the
value of the key.

### Literal entries

A literal entry describes a value that the user can write as it is:

```elixir
%{kind: :literal, value: :open}
%{kind: :literal, value: "automatic"}
%{kind: :literal, value: 10}
%{kind: :literal, value: nil}
```

A literal value is an atom, a string, a number, a boolean, or `nil`.

### Documenting entries

Every entry accepts an optional `:doc` field. A tool shows the documentation
in hover and next to the completion item.

The simplest value is a Markdown string:

```elixir
%{
  kind: :keyword,
  name: :mode,
  doc: "Selects the operating mode."
}
```

A callable entry can reuse the documentation of the function or macro that it
describes. When a module defines a function with `@doc`, the Elixir compiler
stores the text in the compiled module file, in a chunk named `Docs`. The chunk
follows [EEP-48](https://www.erlang.org/doc/apps/kernel/eep48_chapter.html) format.
The function `Code.fetch_docs/1` reads this chunk.

To reuse the text, set `:doc` to a tuple of the module, the kind of
documentation, the name, and the arity. The kind is `:function` or `:macro`:

```elixir
defmodule My.Query.API do
  @doc """
  Returns `left` when it is not `nil`. Otherwise returns `right`.
  """
  def coalesce(left, right), do: if(is_nil(left), do: right, else: left)
end
```

```elixir
%{
  kind: :function,
  mfa: {My.Query.API, :coalesce, 2},
  doc: {My.Query.API, :function, :coalesce, 2}
}
```

The documentation stays in one place, next to the function. The editor shows
the same text that `h My.Query.API.coalesce/2` shows in IEx.

## Data and facets

Entries describe what a library knows when it compiles. Some answers depend on
the project that uses the library. For example, the fields of an Ecto schema
exist only in the user's project. Data and facets let a library supply these
answers.

### Data

Every scope accepts an optional `:data` field. The field holds arbitrary
information for tools. The value is a keyword list. Each key names a tool, and
each value is whatever that tool defines:

```elixir
%{
  entries: [],
  data: [
    expert: %{facets: %{completion: [{My.Plugin, :complete, 1}]}},
    another_tool: %{feature: :example}
  ]
}
```

A scope can hold data for several tools at once. Each tool reads only its own
key. A key that appears more than once holds one value for each occurrence.

Build the values from plain Elixir terms: atoms, strings, numbers, booleans,
`nil`, lists, tuples, and maps.

### Facets

A facet is one feature of a tool that a library can extend. Expert reads its
data from the `:expert` key. The value is a map with a `:facets` key. The
`:facets` map names each facet and lists its providers. A provider is a
function that the tool calls to get results. Write a provider as an
`{module, function, 1}` tuple.

Expert reads these facets:

- `:completion` - suggests completion items
- `:hover` - adds text to the hover popup
- `:signature_help` - adds signatures to the signature help popup

A provider runs when the cursor is in the scope that holds the data. This scope
registers one provider for each facet:

```elixir
expressions: %{
  entries: [
    %{kind: :function, mfa: {My.Query.API, :coalesce, 2}}
  ],
  data: [
    expert: %{
      facets: %{
        completion: [{My.Query.Expert, :complete, 1}],
        hover: [{My.Query.Expert, :hover, 1}],
        signature_help: [{My.Query.Expert, :signatures, 1}]
      }
    }
  ]
}
```

A facet can list several providers. They run in list order, and Expert
combines their results. Each facet defines how it combines results.

```elixir
facets: %{
  completion: [
    {My.Query.Fields, :complete, 1},
    {My.Query.Values, :complete, 1}
  ]
}
```

### Writing a completion provider

A completion provider is a function with one argument. It takes a request map
and returns completion items:

```elixir
defmodule My.Query.Expert do
  @events ["user.created", "user.deleted", "user.updated"]

  def complete(%{context: :string, hint: hint}) do
    for event <- @events, String.starts_with?(event, hint) do
      %{label: event, kind: :value}
    end
  end

  def complete(_request), do: []
end
```

The function runs in the user's project. It can call compiled project modules,
for example to list the fields of an Ecto schema.

All facets send the same request map. A completion provider also receives the
`:context` and `:hint` keys. A hover provider also receives `:name` and
`:range`. A signature help provider also receives `:active_argument`.

The request map has these keys:

- `:aliases` - the aliases available at the cursor
- `:ancestors` - the quoted nodes from the cursor up to the enclosing module
- `:call` - the call that holds the cursor, with its quoted `:args`, its
  quoted `:ast`, and its resolved `:target`
- `:context` - `:code`, or `:string` when the cursor is inside a string
  (completion only)
- `:hint` - the text typed so far, which the completion items should match
  (completion only)
- `:language_id` - the language of the source file
- `:module` - the enclosing module name, or `nil`
- `:path`, `:uri`, and `:position` - the location of the cursor
- `:semantic` - the selected `:scope` and the `:target` of the call
- `:source` - the current source text

Here is a request for a cursor inside `My.Query.from/2`:

```elixir
%{
  aliases: %{[:Account] => MyApp.Account},
  ancestors: [cursor_ast, call_ast, module_ast],
  call: %{
    args: [source_ast, options_ast],
    ast: call_ast,
    target: %{module: "Elixir.My.Query", name: "from", arity: 2}
  },
  context: :code,
  hint: "na",
  language_id: "elixir",
  module: "MyApp.Query",
  path: "/project/lib/my_app/query.ex",
  position: %{line: 12, character: 24},
  semantic: %{
    scope: :expressions,
    target: %{module: "Elixir.My.Query", name: "from", arity: 2}
  },
  source: "defmodule MyApp.Query do\n...\nend",
  uri: "file:///project/lib/my_app/query.ex"
}
```

In a piped call, `:call.args` starts with the piped input. In a string, `:hint`
holds the text of the string up to the cursor.

### Completion items

A provider returns a list of items:

```elixir
[
  %{
    label: "name",
    insert_text: "name",
    kind: :field,
    documentation: "The schema field."
  }
]
```

Items use `:documentation` for their text. Entries use `:doc`.

An item has these keys:

- `:label` - the string that the user sees. Required.
- `:kind` - the category of the item. Required.
- `:insert_text` - the text to insert
- `:snippet` - a snippet to insert. Choose either `:snippet` or
  `:insert_text`.
- `:filter_text` - the text that the editor uses to filter items
- `:detail` - a short description
- `:documentation` - a longer description

The `:kind` value controls the icon that the editor shows next to the item. Use
the kind that best matches the item. These kinds follow the completion item
kinds of the Language Server Protocol: `:class`, `:color`, `:constant`,
`:constructor`, `:enum`, `:enum_member`, `:event`, `:field`, `:file`,
`:folder`, `:function`, `:interface`, `:keyword`, `:method`, `:module`,
`:operator`, `:property`, `:reference`, `:snippet`, `:struct`, `:text`,
`:type_parameter`, `:unit`, `:value`, and `:variable`.

A provider can also return a map to control how its result combines with other
completions:

```elixir
%{
  mode: :override,
  incomplete?: false,
  items: [%{label: "name", kind: :field}]
}
```

The map accepts these keys:

- `:items` - the list of completion items
- `:mode` - `:augment` (the default) adds the items to the entries of the
  scope and to the general completions. `:override` makes the items and the
  entries of the scope the complete result.
- `:incomplete?` - set to `true` (the default) when the list can change as
  the user types. Set to `false` when the list is final.

When several providers answer the same request, Expert merges the items that
have the same `:label` and `:kind`. If any provider returns `mode: :override`,
the merged result uses `:override`.

Each provider call has a ten-second time limit. Expert reads the first 500 items
of a response and drops malformed items. A provider that raises an error or
exceeds the time limit contributes no items, and Expert logs a warning.

### Writing a hover provider

A hover provider takes the request map and returns Markdown text, or `nil` when
it has nothing to add:

```elixir
defmodule My.Query.Expert do
  def hover(%{name: "coalesce"}) do
    "Returns the first argument that is not `NULL`."
  end

  def hover(_request), do: nil
end
```

In addition to the shared keys, the request has these keys:

- `:name` - the name under the cursor
- `:range` - the range of that name, as a map with `:start` and `:end`
  positions. Each position has a `:line` and a `:character`.

The hover popup shows the text of each provider in list order. The text of the
scope entries follows. The built-in hover text comes last. Identical texts
appear once.

### Writing a signature help provider

A signature help provider takes the request map and returns a list of
signatures:

```elixir
defmodule My.Query.Expert do
  def signatures(%{active_argument: _index}) do
    [
      %{
        label: "coalesce(value, fallback)",
        parameters: ["value", "fallback"],
        doc: "Returns the first argument that is not `NULL`."
      }
    ]
  end
end
```

In addition to the shared keys, the request has the `:active_argument` key. Its
value is the zero-based index of the argument that holds the cursor. The value
is `nil` when the cursor is in a block.

A signature has these keys:

- `:label` - the text that the user sees. Required.
- `:parameters` - the list of parameter labels. The default is an empty list.
- `:doc` - Markdown text that describes the signature

The popup lists the signatures of each provider in list order. The built-in
signatures follow. When two signatures have the same `:label`, the popup shows
the first one. A plugin signature therefore replaces a built-in signature with
the same label. The popup highlights the parameter at `:active_argument`.

Each provider call has a ten-second time limit. Expert reads the first 500
signatures of a response and drops malformed signatures.

## Metadata in generated modules

A macro can generate a module that publishes its own metadata. Inside `quote`,
`__MODULE__` is the module that calls the macro, so the metadata can name the
functions that the macro defines:

```elixir
defmodule My.Worker do
  defmacro __using__(_options) do
    quote do
      Module.register_attribute(__MODULE__, :elixir_semantic_metadata,
        accumulate: true,
        persist: true
      )

      @elixir_semantic_metadata {
        :elixir_semantic_metadata_v1,
        %{
          contexts: [
            %{
              mfa: {__MODULE__, :new, 2},
              argument: 1,
              scope: :worker_options
            }
          ],
          scopes: %{
            worker_options: %{
              entries: [
                %{kind: :keyword, name: :queue},
                %{kind: :keyword, name: :priority}
              ]
            }
          }
        }
      }

      def new(arguments, options), do: {arguments, options}
    end
  end
end

defmodule MyApp.EmailWorker do
  use My.Worker
end
```

For this module, an editor suggests `:queue` and `:priority` in
`MyApp.EmailWorker.new(args, |)`.
