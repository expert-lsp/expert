defmodule Expert.Provider.Handlers.CallHierarchyTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.Test.CursorSupport

  alias Engine.CodeIntelligence.Entity
  alias Engine.Search.Indexer.Source
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers.CallHierarchy
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite
  alias Forge.Document
  alias Forge.Project
  alias GenLSP.Requests
  alias GenLSP.Structures

  setup do
    {:ok, _} = Application.ensure_all_started(:briefly)
    # Test-name directories can exceed Windows' path limit once SQLite appends its journal suffix.
    {:ok, tmp_dir} = Briefly.create(directory: true)
    project = tmp_dir |> Document.Path.to_uri() |> Project.new()
    start_supervised!(Engine.ApplicationCache)
    start_supervised!(Expert.Application.document_store_child_spec())

    start_supervised!(
      {Sqlite, [project, runtime_versions: %{erlang: "test-erlang", elixir: "test-elixir"}]}
    )

    start_supervised!({Store, [project, Sqlite]})
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    # Delete the directory after the supervised SQLite connection has closed.
    :ok = Briefly.give_away(tmp_dir, supervisor)
    assert :ok = Store.enable(project)

    patch(EngineApi, :resolve_entity, fn ^project, analysis, position ->
      Entity.resolve(analysis, position)
    end)

    {:ok, project: project}
  end

  describe "prepare" do
    test "returns no items for a module declaration", %{project: project} do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Chec|kout do
             value = :ready
           end
           """}
        ])

      assert [] = prepare(documents["checkout.ex"], project)
    end

    test "returns no items for a non-call module expression", %{project: project} do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Checkout do
             value = :ready
             val|ue
           end
           """}
        ])

      assert [] = prepare(documents["checkout.ex"], project)
    end

    test "returns no items for a keyword-do module declaration", %{project: project} do
      documents =
        index(project, [
          {"checkout.ex", "defmodule Chec|kout, do: :ok"}
        ])

      assert [] = prepare(documents["checkout.ex"], project)
    end

    test "returns no items for a protocol declaration", %{project: project} do
      documents =
        index(project, [
          {"action.ex",
           """
           defprotocol Act|ion do
             def run(value)
           end
           """}
        ])

      assert [] = prepare(documents["action.ex"], project)
    end

    test "returns no items for a non-call implementation expression", %{project: project} do
      documents =
        index(project, [
          {"action.ex",
           """
           defimpl Action, for: Atom, do: (
             value = :ready
             val|ue
           )
           """}
        ])

      assert [] = prepare(documents["action.ex"], project)
    end

    test "returns no items for a non-call nested module expression", %{project: project} do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Checkout do
             defmodule Nested do
               value = :ready
               val|ue
             end
           end
           """}
        ])

      assert [] = prepare(documents["checkout.ex"], project)
    end

    test "returns no items for a top-level non-call expression", %{project: project} do
      documents =
        index(project, [
          {"boot.exs",
           """
           value = :ready
           val|ue
           """}
        ])

      assert [] = prepare(documents["boot.exs"], project)
    end

    test "returns no items for an empty file", %{project: project} do
      documents = index(project, [{"empty.exs", "|"}])

      assert [] = prepare(documents["empty.exs"], project)
    end

    test "keeps non-call positions inside named functions empty", %{project: project} do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Checkout do
             def submit(value), do: val|ue
           end
           """}
        ])

      assert [] = prepare(documents["checkout.ex"], project)
    end

    test "resolves function calls at module and file level", %{project: project} do
      documents =
        index(project, [
          {"boot.exs", "Payments.cha|rge(:file)"},
          {"startup.ex",
           """
           defmodule Startup do
             Payments.cha|rge(:module)
           end
           """},
          {"payments.ex",
           """
           defmodule Payments do
             def charge(value), do: value
           end
           """}
        ])

      assert [file_call] = prepare(documents["boot.exs"], project)
      assert [module_call] = prepare(documents["startup.ex"], project)
      assert file_call.name == "Payments.charge/1"
      assert file_call.kind == GenLSP.Enumerations.SymbolKind.function()
      assert module_call == file_call
    end

    test "resolves an aliased remote call to its definition", %{project: project} do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Checkout do
             alias Billing.Payments, as: Payments
             def submit(cart), do: Payments.cha|rge(cart)
           end
           """},
          {"payments.ex",
           """
           defmodule Billing.Payments do
             def charge(cart) do
               {:ok, cart}
             end
           end
           """}
        ])

      {payments, _position} = documents["payments.ex"]
      assert [%Structures.CallHierarchyItem{} = item] = prepare(documents["checkout.ex"], project)

      assert item.name == "Billing.Payments.charge/1"
      assert item.kind == GenLSP.Enumerations.SymbolKind.function()
      assert item.uri == payments.uri
      assert text_at(payments, item.selection_range) == "charge(cart)"
      assert item.range == lsp_range(1, 2, 3, 5)
      assert item.data == %{"project_root_uri" => project.root_uri}
    end

    test "resolves a local call to its definition", %{project: project} do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Checkout do
             def submit(cart), do: vali|date(cart)
             defp validate(cart) do
               cart
             end
           end
           """}
        ])

      {checkout, _position} = documents["checkout.ex"]
      assert [%Structures.CallHierarchyItem{} = item] = prepare(documents["checkout.ex"], project)

      assert item.name == "Checkout.validate/1"
      assert item.kind == GenLSP.Enumerations.SymbolKind.function()
      assert item.uri == checkout.uri
      assert text_at(checkout, item.selection_range) == "validate(cart)"
      assert item.range == lsp_range(2, 2, 4, 5)
      assert item.data == %{"project_root_uri" => project.root_uri}
    end

    test "resolves the called arity", %{project: project} do
      documents =
        index(project, [
          {"parser.ex",
           """
           defmodule Parser do
             def run(input), do: par|se(input, :strict)
             def parse(input), do: input
             def parse(input, mode), do: {input, mode}
           end
           """}
        ])

      {parser, _position} = documents["parser.ex"]
      assert [%Structures.CallHierarchyItem{} = item] = prepare(documents["parser.ex"], project)

      assert item.name == "Parser.parse/2"
      assert item.kind == GenLSP.Enumerations.SymbolKind.function()
      assert item.uri == parser.uri
      assert text_at(parser, item.selection_range) == "parse(input, mode)"
      assert text_at(parser, item.range) == "def parse(input, mode), do: {input, mode}"
      assert item.data == %{"project_root_uri" => project.root_uri}
    end

    test "accounts for the argument supplied by a pipe", %{project: project} do
      documents =
        index(project, [
          {"renderer.ex",
           """
           defmodule Renderer do
             def render(text), do: text |> normal|ize()
             defp normalize(text), do: text
           end
           """}
        ])

      {renderer, _position} = documents["renderer.ex"]
      assert [%Structures.CallHierarchyItem{} = item] = prepare(documents["renderer.ex"], project)

      assert item.name == "Renderer.normalize/1"
      assert item.kind == GenLSP.Enumerations.SymbolKind.function()
      assert item.uri == renderer.uri
      assert text_at(renderer, item.selection_range) == "normalize(text)"
      assert text_at(renderer, item.range) == "defp normalize(text), do: text"
      assert item.data == %{"project_root_uri" => project.root_uri}
    end
  end

  describe "incoming" do
    test "returns caller definitions and call sites from each caller's file", %{project: project} do
      documents =
        index(project, [
          {"payments.ex",
           """
           defmodule Payments do
             def cha|rge(cart), do: {:ok, cart}
           end
           """},
          {"checkout.ex",
           """
           defmodule Checkout do
             def submit(cart), do: Payments.charge(cart)
           end
           """},
          {"retry_job.ex",
           """
           defmodule RetryJob do
             def perform(cart), do: Payments.charge(cart)
           end
           """}
        ])

      {checkout_document, _position} = documents["checkout.ex"]
      {retry_document, _position} = documents["retry_job.ex"]
      assert [charge] = prepare(documents["payments.ex"], project)
      assert [checkout, retry] = charge |> incoming(project) |> Enum.sort_by(& &1.from.name)

      assert checkout.from.name == "Checkout.submit/1"
      assert checkout.from.uri == checkout_document.uri
      assert text_at(checkout_document, checkout.from.selection_range) == "submit(cart)"

      assert text_at(checkout_document, checkout.from.range) ==
               "def submit(cart), do: Payments.charge(cart)"

      assert Enum.map(checkout.from_ranges, &text_at(checkout_document, &1)) ==
               ["Payments.charge(cart)"]

      assert retry.from.name == "RetryJob.perform/1"
      assert retry.from.uri == retry_document.uri
      assert text_at(retry_document, retry.from.selection_range) == "perform(cart)"

      assert text_at(retry_document, retry.from.range) ==
               "def perform(cart), do: Payments.charge(cart)"

      assert Enum.map(retry.from_ranges, &text_at(retry_document, &1)) ==
               ["Payments.charge(cart)"]
    end

    test "groups repeated calls from the same function into one caller item", %{project: project} do
      documents =
        index(project, [
          {"payments.ex",
           """
           defmodule Payments do
             def cha|rge(amount), do: amount

             def pay do
               charge(:deposit)
               charge(:balance)
             end
           end
           """}
        ])

      {document, _position} = documents["payments.ex"]
      assert [charge] = prepare(documents["payments.ex"], project)
      assert [payment] = incoming(charge, project)

      assert payment.from.name == "Payments.pay/0"

      call_sites =
        payment.from_ranges
        |> Enum.sort_by(&{&1.start.line, &1.start.character})
        |> Enum.map(&text_at(document, &1))

      assert call_sites == ["charge(:deposit)", "charge(:balance)"]
    end

    test "does not include callers of a different arity", %{project: project} do
      documents =
        index(project, [
          {"parser.ex",
           """
           defmodule Parser do
             def par|se(input), do: input
             def parse(input, mode), do: {input, mode}
             def normal(input), do: parse(input)
             def strict(input), do: parse(input, :strict)
           end
           """}
        ])

      {document, _position} = documents["parser.ex"]
      assert [parse] = prepare(documents["parser.ex"], project)
      assert [normal] = incoming(parse, project)

      assert normal.from.name == "Parser.normal/1"
      assert Enum.map(normal.from_ranges, &text_at(document, &1)) == ["parse(input)"]
    end

    test "returns direct callers and expands the next level only when requested", %{
      project: project
    } do
      documents =
        index(project, [
          {"workflow.ex",
           """
           defmodule Workflow do
             def start(), do: middle()
             defp middle(), do: finish()
             defp fin|ish(), do: :ok
           end
           """}
        ])

      {document, _position} = documents["workflow.ex"]
      assert [finish] = prepare(documents["workflow.ex"], project)
      assert [middle] = incoming(finish, project)
      assert middle.from.name == "Workflow.middle/0"
      assert Enum.map(middle.from_ranges, &text_at(document, &1)) == ["finish()"]

      assert [start] = incoming(middle.from, project)
      assert start.from.name == "Workflow.start/0"
      assert Enum.map(start.from_ranges, &text_at(document, &1)) == ["middle()"]
    end

    test "returns no callers for an unreferenced function", %{project: project} do
      documents =
        index(project, [
          {"payments.ex",
           """
           defmodule Payments do
             def cha|rge(cart), do: cart
           end
           """}
        ])

      assert [charge] = prepare(documents["payments.ex"], project)
      assert [] = incoming(charge, project)
    end

    test "includes module-body calls separately from function calls", %{project: project} do
      documents =
        index(project, [
          {"payments.ex",
           """
           defmodule Payments do
             def cha|rge(cart), do: cart
           end
           """},
          {"checkout.ex",
           """
           defmodule Checkout do
             def submit(cart), do: Payments.charge(cart)
             Payments.charge(:module_level)
           end
           """}
        ])

      {document, _position} = documents["checkout.ex"]
      assert [charge] = prepare(documents["payments.ex"], project)
      assert [module, checkout] = charge |> incoming(project) |> Enum.sort_by(& &1.from.name)

      assert checkout.from.name == "Checkout.submit/1"
      assert Enum.map(checkout.from_ranges, &text_at(document, &1)) == ["Payments.charge(cart)"]
      assert module.from.name == "Checkout"
      assert module.from.kind == GenLSP.Enumerations.SymbolKind.module()

      assert Enum.map(module.from_ranges, &text_at(document, &1)) == [
               "Payments.charge(:module_level)"
             ]
    end

    test "includes file and module callers as terminal locations alongside function callers", %{
      project: project
    } do
      documents =
        index(project, [
          {"boot.exs",
           """
           Payments.charge(:script)

           defmodule Checkout do
             Payments.charge(:module)

             def submit(cart), do: Payments.charge(cart)
           end
           """},
          {"payments.ex",
           """
           defmodule Payments do
             def cha|rge(value), do: value
           end
           """}
        ])

      {document, _position} = documents["boot.exs"]
      assert [charge] = prepare(documents["payments.ex"], project)

      assert [file, module, function] =
               charge |> incoming(project) |> Enum.sort_by(& &1.from.kind)

      assert file.from.kind == GenLSP.Enumerations.SymbolKind.file()
      assert file.from.name == "boot.exs"
      assert file.from.uri == document.uri
      assert file.from.range == lsp_range(0, 0, 7, 0)
      assert file.from.selection_range == lsp_range(0, 0, 0, 0)
      assert file.from.data == %{"project_root_uri" => project.root_uri}
      assert Enum.map(file.from_ranges, &text_at(document, &1)) == ["Payments.charge(:script)"]

      assert module.from.kind == GenLSP.Enumerations.SymbolKind.module()
      assert module.from.name == "Checkout"
      assert module.from.uri == document.uri
      assert module.from.range == lsp_range(2, 0, 6, 3)
      assert module.from.data == %{"project_root_uri" => project.root_uri}
      assert text_at(document, module.from.selection_range) == "Checkout"
      assert Enum.map(module.from_ranges, &text_at(document, &1)) == ["Payments.charge(:module)"]

      assert function.from.name == "Checkout.submit/1"
      assert Enum.map(function.from_ranges, &text_at(document, &1)) == ["Payments.charge(cart)"]

      assert [] = outgoing(file.from, project)
      assert [] = outgoing(module.from, project)

      assert [function_call] = outgoing(function.from, project)
      assert function_call.to == charge
      assert function_call.from_ranges == function.from_ranges

      assert [] = incoming(file.from, project)
      assert [] = incoming(module.from, project)
    end

    test "loads an unopened script to construct its file caller item", %{project: project} do
      documents =
        index(project, [
          {"boot.exs", "Payments.charge(:script)\n"},
          {"payments.ex",
           """
           defmodule Payments do
             def cha|rge(value), do: value
           end
           """}
        ])

      {script, _position} = documents["boot.exs"]
      File.write!(script.path, Document.to_string(script))
      assert :ok = Document.Store.close(script.uri)
      assert [charge] = prepare(documents["payments.ex"], project)
      assert [caller] = incoming(charge, project)
      assert caller.from.kind == GenLSP.Enumerations.SymbolKind.file()
      assert caller.from.uri == script.uri
      assert caller.from.range == lsp_range(0, 0, 1, 0)
    end

    test "uses a UTF-16 file caller extent when the last line has no newline", %{project: project} do
      documents =
        index(project, [
          {"boot.exs", "Payments.charge(:script)\n# \u{1F680}"},
          {"payments.ex",
           """
           defmodule Payments do
             def cha|rge(value), do: value
           end
           """}
        ])

      {script, _position} = documents["boot.exs"]
      assert [charge] = prepare(documents["payments.ex"], project)
      assert [caller] = incoming(charge, project)
      assert caller.from.kind == GenLSP.Enumerations.SymbolKind.file()
      assert caller.from.uri == script.uri
      assert caller.from.range == lsp_range(0, 0, 1, 4)
      assert Enum.map(caller.from_ranges, &text_at(script, &1)) == ["Payments.charge(:script)"]
    end

    test "includes the function itself as a caller when it recurses", %{project: project} do
      documents =
        index(project, [
          {"counter.ex",
           """
           defmodule Counter do
             def count|down(value) do
               if value > 0 do
                 countdown(value - 1)
               end
             end
           end
           """}
        ])

      {document, _position} = documents["counter.ex"]
      assert [countdown] = prepare(documents["counter.ex"], project)
      assert [recursive_call] = incoming(countdown, project)

      assert recursive_call.from == countdown

      assert Enum.map(recursive_call.from_ranges, &text_at(document, &1)) ==
               ["countdown(value - 1)"]
    end
  end

  describe "outgoing" do
    test "uses the prepared definition's document when invoked at a call in another file", %{
      project: project
    } do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Checkout do
             def submit(order), do: Payments.cha|rge(order)
           end
           """},
          {"payments.ex",
           """
           defmodule Payments do
             def charge(order) do
               Processor.process(order)
             end
           end
           """},
          {"processor.ex",
           """
           defmodule Processor do
             def process(order), do: {:ok, order}
           end
           """}
        ])

      {payments, _position} = documents["payments.ex"]
      {processor, _position} = documents["processor.ex"]
      assert [charge] = prepare(documents["checkout.ex"], project)
      assert charge.name == "Payments.charge/1"
      assert charge.uri == payments.uri

      request = %Requests.CallHierarchyOutgoingCalls{
        id: 3,
        params: %Structures.CallHierarchyOutgoingCallsParams{item: charge}
      }

      assert {:ok, %Context{document: document, project: ^project}} =
               Expert.Document.Lookup.resolve_from_request(request, [project])

      assert document.uri == payments.uri
      assert [call] = handle(request, project, document)
      assert call.to.name == "Processor.process/1"
      assert call.to.uri == processor.uri
      assert text_at(processor, call.to.selection_range) == "process(order)"
      assert call.from_ranges == [lsp_range(2, 4, 2, 28)]
      assert Enum.map(call.from_ranges, &text_at(payments, &1)) == ["Processor.process(order)"]
    end

    test "returns callees, not callers or calls inside unrelated functions", %{project: project} do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Checkout do
             def start(cart), do: submit(cart)

             def sub|mit(cart) do
               validate(cart)
               persist(cart)
             end

             defp validate(cart), do: cart
             defp persist(cart), do: {:ok, cart}
             def unrelated(cart), do: audit(cart)
             defp audit(cart), do: cart
           end
           """}
        ])

      {document, _position} = documents["checkout.ex"]
      assert [submit] = prepare(documents["checkout.ex"], project)
      assert [persist, validate] = submit |> outgoing(project) |> Enum.sort_by(& &1.to.name)

      assert persist.to.name == "Checkout.persist/1"
      assert persist.to.uri == document.uri
      assert text_at(document, persist.to.selection_range) == "persist(cart)"
      assert text_at(document, persist.to.range) == "defp persist(cart), do: {:ok, cart}"
      assert Enum.map(persist.from_ranges, &text_at(document, &1)) == ["persist(cart)"]

      assert validate.to.name == "Checkout.validate/1"
      assert validate.to.uri == document.uri
      assert text_at(document, validate.to.selection_range) == "validate(cart)"
      assert text_at(document, validate.to.range) == "defp validate(cart), do: cart"
      assert Enum.map(validate.from_ranges, &text_at(document, &1)) == ["validate(cart)"]
    end

    test "uses the callee's file for its definition and the caller's file for call sites", %{
      project: project
    } do
      documents =
        index(project, [
          {"checkout.ex",
           """
           defmodule Checkout do
             def sub|mit(order) do
               Payments.charge(order)
             end
           end
           """},
          {"payments.ex",
           """
           defmodule Payments do
             def charge(cart) do
               {:ok, cart}
             end
           end
           """}
        ])

      {checkout_document, _position} = documents["checkout.ex"]
      {payments_document, _position} = documents["payments.ex"]
      assert [submit] = prepare(documents["checkout.ex"], project)
      assert [charge] = outgoing(submit, project)

      assert charge.to.name == "Payments.charge/1"
      assert charge.to.uri == payments_document.uri
      assert text_at(payments_document, charge.to.selection_range) == "charge(cart)"
      assert charge.to.range == lsp_range(1, 2, 3, 5)

      assert Enum.map(charge.from_ranges, &text_at(checkout_document, &1)) ==
               ["Payments.charge(order)"]
    end

    test "groups repeated calls to one function into one callee item", %{project: project} do
      documents =
        index(project, [
          {"workflow.ex",
           """
           defmodule Workflow do
             def ru|n do
               record(:started)
               record(:finished)
             end

             defp record(event), do: event
           end
           """}
        ])

      {document, _position} = documents["workflow.ex"]
      assert [run] = prepare(documents["workflow.ex"], project)
      assert [record] = outgoing(run, project)

      assert record.to.name == "Workflow.record/1"

      call_sites =
        record.from_ranges
        |> Enum.sort_by(&{&1.start.line, &1.start.character})
        |> Enum.map(&text_at(document, &1))

      assert call_sites == ["record(:started)", "record(:finished)"]
    end

    test "keeps calls to different arities as separate callees", %{project: project} do
      documents =
        index(project, [
          {"parser.ex",
           """
           defmodule Parser do
             def ru|n(input) do
               parse(input)
               parse(input, :strict)
             end

             def parse(input), do: input
             def parse(input, mode), do: {input, mode}
           end
           """}
        ])

      {document, _position} = documents["parser.ex"]
      assert [run] = prepare(documents["parser.ex"], project)
      assert [normal, strict] = run |> outgoing(project) |> Enum.sort_by(& &1.to.name)

      assert normal.to.name == "Parser.parse/1"
      assert text_at(document, normal.to.selection_range) == "parse(input)"
      assert Enum.map(normal.from_ranges, &text_at(document, &1)) == ["parse(input)"]

      assert strict.to.name == "Parser.parse/2"
      assert text_at(document, strict.to.selection_range) == "parse(input, mode)"
      assert Enum.map(strict.from_ranges, &text_at(document, &1)) == ["parse(input, :strict)"]
    end

    test "returns direct callees and expands the next level only when requested", %{
      project: project
    } do
      documents =
        index(project, [
          {"workflow.ex",
           """
           defmodule Workflow do
             def sta|rt(), do: middle()
             defp middle(), do: finish()
             defp finish(), do: :ok
           end
           """}
        ])

      {document, _position} = documents["workflow.ex"]
      assert [start] = prepare(documents["workflow.ex"], project)
      assert [middle] = outgoing(start, project)
      assert middle.to.name == "Workflow.middle/0"
      assert Enum.map(middle.from_ranges, &text_at(document, &1)) == ["middle()"]

      assert [finish] = outgoing(middle.to, project)
      assert finish.to.name == "Workflow.finish/0"
      assert Enum.map(finish.from_ranges, &text_at(document, &1)) == ["finish()"]
    end

    test "returns no callees for a function whose body makes no calls", %{project: project} do
      documents =
        index(project, [
          {"identity.ex",
           """
           defmodule Identity do
             def ke|ep(value), do: value
           end
           """}
        ])

      assert [keep] = prepare(documents["identity.ex"], project)
      assert [] = outgoing(keep, project)
    end

    test "includes the function itself as a callee when it recurses", %{project: project} do
      documents =
        index(project, [
          {"counter.ex",
           """
           defmodule Counter do
             def count|down(value) do
               if value > 0 do
                 countdown(value - 1)
               end
             end
           end
           """}
        ])

      {document, _position} = documents["counter.ex"]
      assert [countdown] = prepare(documents["counter.ex"], project)
      assert [recursive_call] = outgoing(countdown, project)

      assert recursive_call.to == countdown

      assert Enum.map(recursive_call.from_ranges, &text_at(document, &1)) ==
               ["countdown(value - 1)"]
    end
  end

  defp index(project, sources) do
    indexed =
      for {name, source} <- sources do
        uri = project |> Project.root_path() |> Path.join(name) |> Document.Path.to_uri()
        {position, document} = pop_cursor(source, document: uri)
        assert :ok = Document.Store.open(uri, Document.to_string(document), 0)
        assert {:ok, entries} = Source.index(document.path, Document.to_string(document))
        {name, document, position, entries}
      end

    entries = Enum.flat_map(indexed, fn {_name, _document, _position, entries} -> entries end)
    assert :ok = Store.replace(project, entries)

    Map.new(indexed, fn {name, document, position, _entries} -> {name, {document, position}} end)
  end

  defp prepare({document, position}, project) do
    assert {:ok, position} = Convert.to_lsp(position)

    request = %Requests.TextDocumentPrepareCallHierarchy{
      id: 1,
      params: %Structures.CallHierarchyPrepareParams{
        text_document: %Structures.TextDocumentIdentifier{uri: document.uri},
        position: position
      }
    }

    handle(request, project, document)
  end

  defp incoming(item, project) do
    request = %Requests.CallHierarchyIncomingCalls{
      id: 2,
      params: %Structures.CallHierarchyIncomingCallsParams{item: item}
    }

    assert {:ok, document} = Document.Store.fetch(item.uri)
    handle(request, project, document)
  end

  defp outgoing(item, project) do
    request = %Requests.CallHierarchyOutgoingCalls{
      id: 3,
      params: %Structures.CallHierarchyOutgoingCallsParams{item: item}
    }

    assert {:ok, document} = Document.Store.fetch(item.uri)
    handle(request, project, document)
  end

  defp handle(request, project, document) do
    context = Context.new(document.uri, document, project)
    assert {:ok, native_request} = Convert.to_native(request, document)
    assert {:ok, result} = CallHierarchy.handle(native_request, context)
    assert {:ok, result} = Convert.to_lsp(result)
    assert {:ok, _json} = Schematic.dump(request.__struct__.result(), result)
    result
  end

  defp text_at(document, range) do
    assert {:ok, range} = Expert.Protocol.Conversions.to_elixir(range, document)
    Document.fragment(document, range.start, range.end)
  end

  defp lsp_range(start_line, start_character, end_line, end_character) do
    %Structures.Range{
      start: %Structures.Position{line: start_line, character: start_character},
      end: %Structures.Position{line: end_line, character: end_character}
    }
  end
end
