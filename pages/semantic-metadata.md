# Semantic metadata

Functions and macros often accept arguments that follow rules the compiler
doesn't check: the keys of an options list, the functions available inside a
query, the values of a field type. Semantic metadata describes these rules as
data stored in compiled modules. Editors and language servers read it from BEAM
files and use it for completion, hover documentation, signature help, go to
definition, and find references in code that calls those functions and macros.

This document specifies version 1 of the semantic metadata format.

## Conventions

The key words "MUST", "MUST NOT", "REQUIRED", "SHOULD", "SHOULD NOT",
"RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as
described in [BCP 14](https://www.rfc-editor.org/info/bcp14) when, and only
when, they appear in all capitals.

A field that is not marked as REQUIRED is OPTIONAL. Maps defined by this
specification MUST NOT contain fields other than the ones listed for them.

A document that does not conform to this specification is invalid. The effect
of an invalid document is unspecified.

## Storage

Semantic metadata is stored in the `:elixir_semantic_metadata` module
attribute. The attribute MUST be registered with `accumulate: true` and
`persist: true`, so that a module can hold several values and the values are
written into the BEAM file.

Each value of the attribute is a tuple `{:elixir_semantic_metadata_v1,
document}`, where `document` is a [document](#document). Each assignment of
the attribute adds one document. Unrelated rules SHOULD be in separate
documents.

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
        %{mfa: {My.Query, :from, 2}, argument: 1, scope: :query_options}
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
            %{kind: :keyword, name: :limit, doc: "Sets the maximum result count."}
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

This document describes the options of `My.Query.from/2`, as in
`My.Query.from(User, where: active, limit: 10)`. With it, the completions at
the cursor `|` are, each with its documentation:

```elixir
My.Query.from(User, |)         # where:, limit:
My.Query.from(User, where: |)  # coalesce/2, true, false
```

### Documents in macros

The attribute MAY be set inside `quote`, which adds the document to the module
that calls the macro. There, `__MODULE__` is the calling module, so the
document can name the functions that the macro defines:

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
          contexts: [%{mfa: {__MODULE__, :new, 2}, argument: 1, scope: :options}],
          scopes: %{
            options: %{
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

With this document, the completions in `MyApp.EmailWorker.new(args, |)` are
`queue:` and `priority:`.

## Document

A document is a map with these fields:

| Field | Type | Description |
|---|---|---|
| `:contexts` | list of [contexts](#contexts) | REQUIRED. The positions where the document applies. MUST NOT be empty. |
| `:scopes` | map of scope name to [scope](#scope) | REQUIRED. The scopes of the document. |
| `:data` | keyword list | Data for tools, about the whole document. See [Data](#data). |

Every scope name in a context or in a `:value_scope` MUST be a key of
`:scopes`.

## Contexts

A context selects a scope at the positions it matches. There are four kinds of
contexts: function argument, function block, language, and sigil contexts.

### Function argument context

| Field | Type | Description |
|---|---|---|
| `:mfa` | `{module, atom, arity}` | REQUIRED. The function or macro. The arity is an integer from `0` to `255`. |
| `:argument` | non-negative integer | REQUIRED. The zero-based position of the argument. |
| `:scope` | scope name | REQUIRED. The scope selected in the argument. |

This context selects `:query_options` in the second argument of
`My.Query.from/2`:

```elixir
%{mfa: {My.Query, :from, 2}, argument: 1, scope: :query_options}
```

A call matches the context when it calls the function of `:mfa` with as many
arguments as the arity, including the arguments after the cursor. In a pipe,
the piped value is the first argument. A `do` block is the last argument. Both
calls below are calls to `where/3` with `user.active` as argument `2`:

```elixir
where(query, [user], user.active)
query |> where([user], user.active)
```

Each arity of a function with default arguments requires its own context. For
`field(name, type \\ :string, opts \\ [])`, the type is argument `1` of both
`field/2` and `field/3`, as in `field :name, :string` and
`field :name, :string, default: ""`.

### Function block context

| Field | Type | Description |
|---|---|---|
| `:mfa` | `{module, atom, arity}` | REQUIRED. The function or macro. |
| `:block` | `:do`, `:else`, `:after`, `:rescue`, or `:catch` | REQUIRED. The block. |
| `:scope` | scope name | REQUIRED. The scope selected in the block. |

These contexts select `:body` in the `do` block of `My.DSL.run/1`, and
`:fallback` in its `else` block:

```elixir
%{mfa: {My.DSL, :run, 1}, block: :do, scope: :body}
%{mfa: {My.DSL, :run, 1}, block: :else, scope: :fallback}
```

### Language context

| Field | Type | Description |
|---|---|---|
| `:language_id` | string | REQUIRED. The language ID of the documents. |
| `:scope` | scope name | REQUIRED. The scope selected everywhere in those documents. |

This context selects `:template` in `my-template` documents:

```elixir
%{language_id: "my-template", scope: :template}
```

Completion in documents of other languages comes from completion handlers. See
[Expert data](#expert-data) and [Delegating completion](#delegating-completion).

### Sigil context

| Field | Type | Description |
|---|---|---|
| `:sigil` | string | REQUIRED. The name of the sigil, without `~`. |
| `:scope` | scope name | REQUIRED. The scope selected between the delimiters of the sigil. |

The name is one lowercase letter, or one uppercase letter followed by any
number of uppercase letters and digits, as in `"q"` or `"SQL"`. Sigil contexts
match by name, so this context selects `:sql` inside every `~SQL` sigil,
whichever module defines it:

```elixir
%{sigil: "SQL", scope: :sql}
```

### Precedence

Language contexts take precedence over sigil contexts, and sigil contexts take
precedence over function contexts. A language context therefore selects its
scope everywhere in its documents.

Function contexts are matched against the calls around the cursor from the
outermost to the innermost, and the innermost match selects the scope. A call
matches the function of `:mfa` when it is:

- a remote call, such as `My.Query.from(...)`, or `Q.from(...)` after
  `alias My.Query, as: Q`
- a local call to a function of the current module, or to a function imported
  at the call, including imports added by macros such as `use`
- a local call to a call entry of the scope selected by an outer call. In
  `My.Query.from(User, where: coalesce(name, |))`, `coalesce(name, |)` matches
  a context for `My.Query.API.coalesce/2`, because `coalesce/2` is an entry of
  the `:expressions` scope.

A document MUST NOT have more than one context for the same function argument,
function block, language ID, or sigil. When contexts of several documents
match the same position, one of them applies, and which one is unspecified.

## Scope

A scope is the set of entries available at the positions its contexts select.
A scope name is an atom other than `nil`, an integer, or a string. Several
contexts MAY select the same scope.

| Field | Type | Description |
|---|---|---|
| `:entries` | list of [entries](#entries) | REQUIRED. The entries of the scope. MAY be empty. |
| `:data` | keyword list | Data for tools. See [Data](#data). |

## Entries

An entry is a function, a keyword key, or a literal value available in a
scope. The entries of a scope are its completions. Every entry has these
fields:

| Field | Type | Description |
|---|---|---|
| `:kind` | atom | REQUIRED. The kind of the entry. |
| `:doc` | string or `{module, kind, atom, arity}` | The documentation of the entry, shown on hover and with its completion item. |

A `:doc` string is Markdown. A `:doc` tuple refers to the documentation of a
function or a macro, where `kind` is `:function` or `:macro`. In the example
of [Storage](#storage), the `coalesce/2` entry has the `@doc` of
`My.Query.API.coalesce/2`:

```elixir
defmodule My.Query.API do
  @doc """
  Returns `left` when it is not `nil`. Otherwise returns `right`.
  """
  def coalesce(left, right), do: if(is_nil(left), do: right, else: left)
end
```

The entries of a scope MUST be unique: no two entries of a scope have the same
`:kind` and the same `:mfa`, `:name`, or `:value`.

### Call entry

A call entry is a function or a macro that can be called in the scope. Its
`:kind` is any atom other than `:keyword` and `:literal`.

| Field | Type | Description |
|---|---|---|
| `:mfa` | `{module, atom, arity}` | REQUIRED. The function or macro. |

```elixir
%{kind: :function, mfa: {My.Query.API, :coalesce, 2}}
%{kind: :macro, mfa: {My.DSL, :attribute, 2}}
```

Call entries of the kinds `:function`, `:macro`, `:callback`, and `:typespec`
are completion items of that kind. Call entries of any other kind are
completion items labeled `name/arity` that insert the call, with the icon of
their kind when it is a [completion item kind](#completion-items).

### Keyword entry

A keyword entry is a key of a keyword list. Its `:kind` is `:keyword`.

| Field | Type | Description |
|---|---|---|
| `:name` | atom | REQUIRED. The key. |
| `:value_scope` | scope name | The scope of the value of the key. |

```elixir
%{kind: :keyword, name: :mode, value_scope: :modes}
```

In the example of [Storage](#storage), `:where` has the value scope
`:expressions`, so `where: |` is in the `:expressions` scope. In nested
keyword lists, each value has the scope of its key, following the keys from
the argument to the cursor. The value of a key without a `:value_scope`, or of
a key without an entry in the scope, has no scope.

A value scope MAY be the scope itself, or a scope that names it back. This
describes recursive options, such as a `:filters` option whose value accepts
another `:filters` option.

### Literal entry

A literal entry is a value written as it is. Its `:kind` is `:literal`.

| Field | Type | Description |
|---|---|---|
| `:value` | atom, string, number, boolean, or `nil` | REQUIRED. The value. |

```elixir
%{kind: :literal, value: :open}
%{kind: :literal, value: "automatic"}
%{kind: :literal, value: 10}
%{kind: :literal, value: nil}
```

An atom literal matches the typed text by its name, so `:open` matches `open`,
and its documentation is the hover of `:open`.

## Data

The `:data` field of a document or a scope is a keyword list keyed by tool
name. Each tool defines the form of its own value. A key MAY appear more than
once, and every occurrence applies.

```elixir
%{
  entries: [],
  data: [
    expert: %{facets: %{completion: [{My.Query.Expert, :complete, 1}]}},
    another_tool: %{feature: :example}
  ]
}
```

Values MUST be plain terms: atoms, strings, numbers, booleans, `nil`, lists,
tuples, and maps other than structs.

### Expert data

The value of the `:expert` key is a map with these fields:

| Field | Type | Description |
|---|---|---|
| `:facets` | map of facet to list of `{module, atom, 1}` | The handlers of each facet. |

A facet is an editor feature, such as completion or hover, that the metadata
extends with functions. The functions of a facet are its handlers, written as
`{module, function, 1}` tuples. A handler takes a [request](#requests) and
returns a result in the form that its facet defines. [Facets](#facets)
specifies the request and the result of each facet.

Handlers give the answers that entries can't. Entries are fixed when the
library compiles, but handlers run in the user's project, with the current code
of their module, and MAY call the compiled modules of the project. The fields
of an Ecto schema, for example, exist only in the user's project.

| Facet | Editor feature | In the data of |
|---|---|---|
| `:completion` | Completion | scope |
| `:hover` | Hover | scope |
| `:definition` | Go to definition | scope |
| `:resolve` | The entity under the cursor, for hover, go to definition, references, and call hierarchy | scope |
| `:references` | Find references | document |
| `:signature_help` | Signature help | scope |

The handlers in the data of a scope apply when the cursor is in that scope.
Inside a keyword value, that is the scope of the value. `:references`
handlers are in the data of a document, because they answer for the whole
project. Handlers don't apply in comments. Hover, definition, resolve, and
signature help handlers don't apply in strings.

This scope has a completion, a hover, and a signature help handler:

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

These handlers complete the fields of the schema in `My.Query.from/2`, show the
type of a field on hover, and show the signature of `coalesce/2`. With them,
the completions in `My.Query.from(User, where: na|)` include the `name` field
of `User`.

```elixir
defmodule My.Query.Expert do
  def complete(%{call: %{args: [source | _]}, aliases: aliases, hint: hint}) do
    for field <- fields(schema(source, aliases)),
        name = Atom.to_string(field),
        String.starts_with?(name, hint),
        do: %{label: name, kind: :field}
  end

  def hover(%{call: %{args: [source | _]}, aliases: aliases, identifier: identifier}) do
    schema = schema(source, aliases)

    case Enum.find(fields(schema), &(Atom.to_string(&1) == identifier)) do
      nil -> nil
      field -> "`#{identifier}` is a `#{inspect(schema.__schema__(:type, field))}` field."
    end
  end

  # `ancestors` go from the cursor out, so the node before the call is the
  # argument that holds the cursor.
  def signatures(%{ancestors: ancestors}) do
    case Enum.find_index(ancestors, &match?({:coalesce, _meta, _args}, &1)) do
      nil ->
        []

      index ->
        {:coalesce, _meta, arguments} = Enum.at(ancestors, index)
        argument = Enum.at(ancestors, index - 1)

        [
          %{
            label: "coalesce(value, fallback)",
            parameters: ["value", "fallback"],
            active_parameter: Enum.find_index(arguments, &(&1 == argument))
          }
        ]
    end
  end

  defp schema({:__aliases__, _meta, [first | rest]}, aliases) do
    case aliases do
      %{[^first] => module} -> Module.concat([module | rest])
      %{} -> Module.concat([first | rest])
    end
  end

  defp schema(_source, _aliases), do: nil

  defp fields(schema) do
    if schema && Code.ensure_loaded?(schema) && function_exported?(schema, :__schema__, 1),
      do: schema.__schema__(:fields),
      else: []
  end
end
```

## Facets

Each facet defines the request that its handlers take and the result that
they return.

### Positions and ranges

A position is a map with a `:line` and a `:character`, both starting at 1.
Characters count codepoints, like the columns of `Code.string_to_quoted/2` and
`EEx.tokenize/2`, and unlike those of `Code.Fragment`, which count graphemes.

A range is a map with a `:start` and an `:end` position. The `:end` is
exclusive.

### Requests

A request is a map. The requests of all facets in a scope have these fields:

| Field | Type | Description |
|---|---|---|
| `:aliases` | map of alias segments to module | The aliases at the cursor, including aliases defined by macros before the cursor, such as `%{[:Account] => MyApp.Account}`. |
| `:ancestors` | list of quoted nodes | The nodes around the cursor, from the cursor out to the enclosing module. |
| `:call` | map | The call whose context selected the scope. `:args` are its arguments, starting with the piped value in a pipe. `:ast` is the call, or the whole pipe. `:target` is the `{module, name, arity}` of the context. For language and sigil contexts, `:args` is `[]`, and `:ast` and `:target` are `nil`. |
| `:imports` | list of `{module, atom, arity}` | The functions and macros imported at the cursor, including imports added by macros before the cursor. |
| `:language_id` | string | The language of the document. |
| `:module` | string or `nil` | The name of the enclosing module, such as `"MyApp.Query"`. |
| `:path` | string | The path of the document. |
| `:uri` | string | The URI of the document. |
| `:position` | position | The cursor. |
| `:semantic` | map | The name of the scope at the cursor as `:scope`, and the `:target` of `:call`. |
| `:sigil` | map or `nil` | For a sigil context, the sigil `:name`, the `:range` of the whole sigil, and the `:content` range between its delimiters. |
| `:source` | string | The text of the document. |

The quoted nodes in `:ancestors` and `:call` are parsed from the source up to
the cursor, which is a `{:__cursor__, meta, []}` node. They have the form that
`Code.Fragment.container_cursor_to_quoted/2` returns with the options
`columns: true`, `token_metadata: true`, `unescape: false`, and a
`:literal_encoder` that wraps each literal in a `{:__block__, meta, [literal]}`
node.

This is the completion request for `My.Query.from(Account, where: na|)` in a
module with `alias MyApp.Account`:

```elixir
%{
  aliases: %{[:Account] => MyApp.Account},
  ancestors: [cursor_ast, ..., call_ast, module_ast],
  call: %{
    args: [{:__aliases__, meta, [:Account]}, options_ast],
    ast: call_ast,
    target: {My.Query, :from, 2}
  },
  context: :code,
  hint: "na",
  imports: [{Kernel, :is_nil, 1}, ...],
  language_id: "elixir",
  module: "MyApp.Query",
  path: "/project/lib/my_app/query.ex",
  position: %{line: 12, character: 41},
  semantic: %{scope: :expressions, target: {My.Query, :from, 2}},
  sigil: nil,
  source: "defmodule MyApp.Query do\n...\nend",
  uri: "file:///project/lib/my_app/query.ex"
}
```

### Completion

The request has these additional fields:

| Field | Type | Description |
|---|---|---|
| `:context` | `:code` or `:string` | `:string` when the cursor is inside a string. |
| `:hint` | string | The identifier before the cursor, or `""`. After a dot, the name after the dot, such as `"na"` after `user.na`. In a string, the run of letters, digits, and `_ ! ? . / : -` before the cursor, such as `"user.cr"` after `"user.cr`. |

The entries of the scope are completions in code, except after a dot, as in
`user.na|`. The items of handlers are completions everywhere in the scope.

#### Completion items

The result is a list of completion items:

```elixir
[%{label: "name", kind: :field, documentation: "The schema field."}]
```

| Field | Type | Description |
|---|---|---|
| `:label` | string | REQUIRED. The text shown in the list. |
| `:kind` | completion item kind | REQUIRED. The category of the item, which sets its icon. |
| `:insert_text` | string | The text to insert. Defaults to `:label`. |
| `:snippet` | string | A snippet to insert in place of `:insert_text`. An item MUST NOT have both. |
| `:filter_text` | string | The text to filter by. Defaults to `:label`. |
| `:detail` | string | A short description. |
| `:documentation` | string | A longer description, in Markdown. |
| `:range` | range | The text that the item replaces. |

The completion item kinds are the ones of the Language Server Protocol:
`:class`, `:color`, `:constant`, `:constructor`, `:enum`, `:enum_member`,
`:event`, `:field`, `:file`, `:folder`, `:function`, `:interface`, `:keyword`,
`:method`, `:module`, `:operator`, `:property`, `:reference`, `:snippet`,
`:struct`, `:text`, `:type_parameter`, `:unit`, `:value`, and `:variable`.

The `:range` MUST start and end on the same line. A range on the cursor line
that contains the cursor is replaced exactly. Items with any other range, or
without one, replace the identifier before the cursor as Elixir reads it. In
other languages, where Elixir reads a different identifier, the `:range`
SHOULD be the typed text, such as `bu` in `<.bu`.

#### Combining results

The result MAY instead be a map that sets how its items combine with other
completions:

```elixir
%{mode: :override, incomplete?: false, items: [%{label: "name", kind: :field}]}
```

| Field | Type | Description |
|---|---|---|
| `:items` | list of completion items | REQUIRED. The items. |
| `:mode` | `:augment` or `:override` | `:augment` adds the items to the entries of the scope and to the Elixir completions. `:override` makes the items and the entries of the scope the whole result. Defaults to `:augment`. |
| `:incomplete?` | boolean | `true` when the list can change as the user types, `false` when it is final. Defaults to `true`. |

With the result `%{mode: :override, incomplete?: false, items: []}`, the
completions are the entries of the scope, so a scope without entries has no
completions.

#### Delegating completion

In a document of another language, the result MAY delegate completion to
Elixir source:

```elixir
%{delegate: %{source: elixir_source}}
```

The result MUST have only the `:delegate` field, and the delegation only the
`:source` field. A map with other fields is not a delegation.

The source MUST have the cursor at the same line and character as the
document. Its completions are those of any Elixir source, including the
semantic metadata of its calls, and they edit the original document. A
delegation replaces the results of the other handlers and the entries of the
scope.

### Hover

The request has these additional fields:

| Field | Type | Description |
|---|---|---|
| `:identifier` | string or `nil` | The identifier under the cursor, as Elixir reads it: an alias such as `"MyApp.User"`, the name of a variable or a function, a keyword key or an atom without its colon, or the name after a dot. A cursor right after an identifier is on that identifier. `nil` where Elixir reads no identifier, as in the HTML of a template. |
| `:range` | range or `nil` | The range of the identifier. `nil` when `:identifier` is `nil`. |

The result is `nil`, a Markdown string, or a map:

| Field | Type | Description |
|---|---|---|
| `:contents` | string | REQUIRED. The text, in Markdown. |
| `:range` | range | The range that the hover covers. |

A string covers the range of `:identifier`. Where `:identifier` is `nil`, only
the map has a range:

```elixir
%{contents: "Renders a button.", range: range}
```

### Definition

The request has the `:identifier` and `:range` fields of the
[hover](#hover) request.

The result is a list of locations. A location is a map with these fields:

| Field | Type | Description |
|---|---|---|
| `:path` | string | REQUIRED. The path of the file. |
| `:range` | range | REQUIRED. The range in the file. |

```elixir
[%{path: "/project/lib/my_app_web/components.ex", range: range}]
```

In the user's project, the source path of a module is
`List.to_string(module.module_info(:compile)[:source])`, and the docs that
`Code.fetch_docs/1` returns contain the line of each function.

When no definition handler returns a location, go to definition uses the
entity of a [resolve](#resolve) result.

### Resolve

The resolve facet maps the identifier under the cursor to the entity that it
refers to, such as a module or a function. Hover, go to definition, find
references, and call hierarchy then treat the identifier as a reference to that
entity.

This applies to identifiers whose entity Elixir can't determine. In this
router, `PageController` refers to the module `MyApp.Web.PageController`
through the `namespace` around it, and `:index` refers to the function
`MyApp.Web.PageController.index/2`. Elixir reads `PageController` as the module
`PageController`, and `:index` as an atom:

```elixir
namespace MyApp.Web do
  route "/", PageController, :index
end
```

With a resolve handler for this router, `PageController` resolves to the
entity `%{kind: :module, module: MyApp.Web.PageController}`, and `:index` to
`%{kind: :function, module: MyApp.Web.PageController, name: :index, arity: 2}`.

The request has the `:identifier` and `:range` fields of the
[hover](#hover) request.

The result is one of:

- `%{entity: entity}` - the identifier refers to `entity`. An optional
  `:range` field is the range of the identifier, which defaults to the range
  of `:identifier`. Where `:identifier` is `nil`, the `:range` field is the
  only range.
- `%{delegate: %{source: source}}` - the identifier resolves in the Elixir
  `source`, at the same line and character, as in
  [Delegating completion](#delegating-completion)
- `nil` - no answer

An entity is one of these maps:

- `%{kind: :module, module: module}`
- `%{kind: :struct, module: module}`
- `%{kind: :function, module: module, name: name, arity: arity}`
- `%{kind: :macro, module: module, name: name, arity: arity}`
- `%{kind: :type, module: module, name: name, arity: arity}`

### References

The references facet lists the references to an entity that Elixir can't
determine. In the router of [Resolve](#resolve), `PageController` is a
reference to `MyApp.Web.PageController`, so the references of
`MyApp.Web.PageController` include it.

References handlers are called only for the code inside the function contexts
of their document. The request lists the calls in the project that match those
contexts, and the handlers are not called when there are none. References
outside those calls, including inside language and sigil contexts, are not
part of the references facet.

| Field | Type | Description |
|---|---|---|
| `:entity` | entity | The entity to find. See [Resolve](#resolve). |
| `:files` | list of maps | The files with those calls. Each has the `:path` of the file and its `:calls`. |

A call is a map with these fields:

| Field | Type | Description |
|---|---|---|
| `:position` | position | The start of the call: its name for a local call, its module for a remote call. |
| `:target` | `{module, atom, arity}` | The function of the context that the call matches. |

For that router, the request is:

```elixir
%{
  entity: %{kind: :module, module: MyApp.Web.PageController},
  files: [
    %{
      path: "/project/lib/my_app/router.ex",
      calls: [
        %{position: %{line: 2, character: 3}, target: {My.Router, :route, 3}}
      ]
    }
  ]
}
```

The result is the list of [locations](#definition) in those calls that refer to
the entity.

### Signature help

The request has no additional fields. The call and the argument at the cursor
are in `:ancestors`, as in the `signatures/1` handler of
[Expert data](#expert-data).

The result is a list of signatures. A signature is a map with these fields:

| Field | Type | Description |
|---|---|---|
| `:label` | string | REQUIRED. The text shown in the popup. |
| `:parameters` | list of strings | The labels of the parameters, each of which appears in `:label`. Defaults to `[]`. |
| `:active_parameter` | non-negative integer or `nil` | The zero-based index in `:parameters` of the parameter at the cursor. `nil` highlights none. |
| `:doc` | string | The description of the signature, in Markdown. |
