defmodule Engine.CodeMod.RenameTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.EngineApi.Messages
  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.EventualAssertions
  import Forge.Test.Fixtures

  alias Engine.CodeMod.Rename
  alias Engine.CodeMod.Rename.Prepare
  alias Engine.Commands.RenameSupervisor
  alias Engine.ManagerApi
  alias Engine.Search.Indexer.Source
  alias Forge.Document

  setup do
    project = project()

    Engine.set_project(project)
    {:ok, store} = Agent.start_link(fn -> [] end)

    start_supervised!(Engine.ApplicationCache)
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    start_supervised!(Engine.Dispatch)

    patch(ManagerApi, :search_store_replace, fn ^project, entries ->
      Agent.update(store, fn _ -> entries end)
      :ok
    end)

    patch(ManagerApi, :search_store_exact, fn ^project, subject, constraints ->
      {:ok, query_entries(store, subject, constraints, :exact)}
    end)

    patch(ManagerApi, :search_store_prefix, fn ^project, subject, constraints ->
      {:ok, query_entries(store, subject, constraints, :prefix)}
    end)

    patch(Engine.Progress, :begin, {:error, :rejected})
    patch(Engine.Api.Proxy, :start_buffering, :ok)
    start_supervised!(RenameSupervisor)

    {:ok, project: project, store: store}
  end

  describe "prepare/2" do
    test "returns module name" do
      {:ok, result, _} =
        ~q[
        defmodule |Users do
        end
      ]
        |> prepare()

      assert result == "Users"
    end

    test "returns full module name" do
      {:ok, result, _} =
        ~q[
        defmodule MyApp.|Users do
        end
      ]
        |> prepare()

      assert result == "MyApp.Users"
    end

    test "returns full module name when cursor is in the middle" do
      {:ok, result, _} =
        ~q[
        defmodule My|App.Users do
        end
      ]
        |> prepare()

      assert result == "MyApp.Users"
    end

    test "returns Inner instead of MyApp.Test.Inner for a nested module" do
      {:ok, result, _} =
        ~q[
        defmodule MyApp.Test do
          defmodule |Inner do
          end
        end
      ]
        |> prepare()

      assert result == "Inner"
    end

    test "returns a multi-segment relative module name" do
      {:ok, result, _} =
        ~q[
        defmodule MyApp.Users do
          defmodule Admin.|Query do
          end
        end
      ]
        |> prepare()

      assert result == "Admin.Query"
    end

    test "prepares an Ecto repo declaration from source while the index is loading" do
      patch(ManagerApi, :search_store_exact, {:error, :loading})

      assert {:ok, "MyApp.Repo", _range} =
               ~q[
               defmodule MyApp.|Repo do
                 use Ecto.Repo,
                   otp_app: :my_app,
                   adapter: Ecto.Adapters.Postgres
               end
               ]
               |> prepare()
    end

    test "prepares a protocol declaration from source while the index is loading" do
      patch(ManagerApi, :search_store_exact, {:error, :loading})

      assert {:ok, "MyApp.Protocol", _range} =
               ~q[
               defprotocol MyApp.|Protocol do
                 def run(value)
               end
               ]
               |> prepare()
    end

    test "returns nil for module reference" do
      assert {:ok, nil} =
               ~q[
        defmodule MyApp.Users do
        end

        defmodule MyApp.Accounts do
          alias |MyApp.Users
        end
      ]
               |> prepare()
    end

    # Returns {:ok, nil} instead of an error because gen_lsp 0.11.x has a
    # serialization bug where ErrorResponse crashes in Schematic.oneof.
    # See commit message for details.
    test "returns nil for unsupported entity" do
      assert {:ok, nil} =
               ~q[
          x = 1
          |x
      ]
               |> prepare()
    end

    @tag :skip
    # TODO: restore once gen_lsp fixes ErrorResponse serialization in oneof,
    # so we can return a user-friendly message via the LSP error response.
    test "returns error with friendly message for unsupported entity" do
      assert {:error, "Renaming :variable is not supported for now"} =
               ~q[
          x = 1
          |x
      ]
               |> prepare()
    end
  end

  test "does not track rename without document changes" do
    patch(Rename.Module, :rename, [])

    assert {:ok, _result} =
             ~q[
             defmodule |MyApp.Users do
             end
             ]
             |> rename("MyApp.Accounts")

    refute_called(RenameSupervisor.start_renaming(_, _, _, _, _))
  end

  test "reports progress before calculating edits" do
    test = self()

    patch(Engine.Progress, :begin, fn "Renaming", [message: message] ->
      send(test, {:begin_progress, message})
      {:ok, :rename}
    end)

    patch(Engine.Progress, :complete, fn :rename -> send(test, :complete_progress) end)

    patch(Rename.Module, :rename, fn _analysis, _range, _new_name, _module, _rename_files? ->
      send(test, {:calculating_edits, self()})
      receive do: (:continue -> [])
    end)

    task =
      Task.async(fn ->
        ~q[defmodule |MyApp.Users do
        end]
        |> rename("MyApp.Accounts")
      end)

    assert_receive {:begin_progress, "Calculating edits"}
    assert_receive {:calculating_edits, planner}
    send(planner, :continue)

    assert {:ok, _changes} = Task.await(task)
    assert_receive :complete_progress
  end

  test "completes progress when planning fails" do
    test = self()

    patch(Engine.Progress, :begin, {:ok, :rename})
    patch(Engine.Progress, :complete, fn :rename -> send(test, :complete_progress) end)
    patch(Prepare, :resolve, {:error, :planning_failed})

    assert {:error, :planning_failed} =
             ~q[defmodule |MyApp.Users do
             end]
             |> rename("MyApp.Accounts")

    assert_receive :complete_progress
  end

  test "rejects rename while another rename is in progress" do
    uri = "file://file.ex"

    {:ok, pid} =
      RenameSupervisor.start_renaming(
        %{uri => file_saved(uri: uri)},
        [],
        [],
        fn _delta, _message -> :ok end,
        fn -> :ok end
      )

    assert {:error, :rename_in_progress} =
             ~q[
             defmodule |MyApp.Users do
             end
             ]
             |> rename("MyApp.Accounts")

    send(pid, :timeout)
    refute_eventually Process.whereis(Engine.Commands.Rename)
  end

  test "rejects rename when progress tracking starts concurrently" do
    patch(Engine.Progress, :begin, {:error, :unsupported})
    patch(RenameSupervisor, :start_renaming, {:error, {:already_started, self()}})

    assert {:error, :rename_in_progress} =
             ~q[
             defmodule |MyApp.Users do
             end
             ]
             |> rename("MyApp.Accounts")
  end

  for invalid_name <- ["", "Elixir", "my_app.Users", "MyApp..Users", "MyApp.Users;System.halt()"] do
    test "rejects invalid module name #{inspect(invalid_name)}" do
      assert {:error, {:invalid_module_name, unquote(invalid_name)}} =
               ~q[defmodule |MyApp.Users do
               end]
               |> rename(unquote(invalid_name))
    end
  end

  test "rejects an existing destination module" do
    assert {:error, {:module_already_exists, "MyApp.Accounts"}} =
             ~q[
             defmodule |MyApp.Users do
             end
             defmodule MyApp.Accounts do
             end
             ]
             |> rename("MyApp.Accounts")
  end

  test "rejects an existing destination descendant" do
    assert {:error, {:module_already_exists, "MyApp.Accounts.Query"}} =
             ~q[
             defmodule |MyApp.Users do
             end
             defmodule MyApp.Users.Query do
             end
             defmodule MyApp.Accounts.Query do
             end
             ]
             |> rename("MyApp.Accounts")
  end

  test "allows an existing destination namespace" do
    assert {:ok, result} =
             ~q[
             defmodule |Parent2 do
             end
             defmodule Parent.ChildA do
             end
             defmodule Parent.ChildB do
             end
             ]
             |> rename("Parent")

    assert result =~ "defmodule Parent do"
    assert result =~ "defmodule Parent.ChildA do"
    assert result =~ "defmodule Parent.ChildB do"
  end

  test "rejects rename while proxy is still buffering" do
    test = self()
    patch(Engine.Progress, :begin, {:ok, :rename})
    patch(Engine.Progress, :complete, fn :rename -> send(test, :complete_progress) end)
    patch(Engine.Api.Proxy, :start_buffering, {:error, {:already_buffering, self()}})

    assert {:error, :rename_in_progress} =
             ~q[
             defmodule |MyApp.Users do
             end
             ]
             |> rename("MyApp.Accounts")

    assert_receive :complete_progress
    refute_receive :complete_progress
  end

  test "returns an error when exact references are unavailable" do
    patch(ManagerApi, :search_store_exact, {:error, :loading})

    assert {:error, :loading} =
             ~q[
             defmodule |MyApp.Users do
             end
             ]
             |> rename("MyApp.Accounts")
  end

  test "returns an error when descendant references are unavailable" do
    patch(ManagerApi, :search_store_prefix, {:error, :loading})

    assert {:error, :loading} =
             ~q[
             defmodule |MyApp.Users do
             end
             ]
             |> rename("MyApp.Accounts")
  end

  test "returns an error when exact reference search is unavailable" do
    patch(ManagerApi, :search_store_exact, [])

    assert {:error, :search_store_unavailable} =
             ~q[
             defmodule |MyApp.Users do
             end
             ]
             |> rename("MyApp.Accounts")
  end

  test "returns an error when descendant reference search is unavailable" do
    patch(ManagerApi, :search_store_prefix, [])

    assert {:error, :search_store_unavailable} =
             ~q[
             defmodule |MyApp.Users do
             end
             ]
             |> rename("MyApp.Accounts")
  end

  describe "rename/4 basic" do
    test "renames an Ecto repo declaration when the index has no definition" do
      patch(ManagerApi, :search_store_exact, {:ok, []})

      assert {:ok, result} =
               ~q[
               defmodule MyApp.|Repo do
                 use Ecto.Repo,
                   otp_app: :my_app,
                   adapter: Ecto.Adapters.Postgres
               end
               ]
               |> rename("MyApp.DataRepo")

      assert result =~ ~S[defmodule MyApp.DataRepo do]
    end

    test "renames a protocol declaration when the index has no definition" do
      patch(ManagerApi, :search_store_exact, {:ok, []})

      assert {:ok, result} =
               ~q[
               defprotocol MyApp.|Protocol do
                 def run(value)
               end
               ]
               |> rename("MyApp.Runnable")

      assert result =~ ~S[defprotocol MyApp.Runnable do]
    end

    test "renames at definition" do
      {:ok, result} =
        ~q[
        defmodule |Users do
        end
      ]
        |> rename("Accounts")

      assert result =~ ~S[defmodule Accounts do]
    end

    test "fails at alias reference" do
      assert {:error, {:unsupported_location, :module}} ==
               ~q[
        defmodule MyApp.Accounts do
          alias |MyApp.Users
        end
      ]
               |> rename("Members")
    end

    test "fails at module call reference" do
      assert {:error, {:unsupported_location, :module}} ==
               ~q[
        defmodule MyApp.Accounts do
          alias MyApp.Users
          Use|rs.list()
        end
      ]
               |> rename("Members")
    end

    test "renames multi-part module" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Auth.|Session do
        end
      ]
        |> rename("MyApp.Auth.Token")

      assert result =~ ~S[defmodule MyApp.Auth.Token do]
    end

    test "renames middle segment" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Auth.|Session do
        end
      ]
        |> rename("MyApp.Identity.Session")

      assert result =~ ~S[defmodule MyApp.Identity.Session do]
    end

    test "simplifies module name" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Auth.|Session do
        end
      ]
        |> rename("MyApp.Session")

      assert result =~ ~S[defmodule MyApp.Session do]
    end

    test "does not qualify a renamed nested module declaration" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Test do
          defmodule |Inner do
          end
        end

        defmodule MyApp.TestTest do
          alias MyApp.Test.Inner
        end
      ]
        |> rename("InnerRenamed")

      assert result == ~q[
        defmodule MyApp.Test do
          defmodule InnerRenamed do
          end
        end

        defmodule MyApp.TestTest do
          alias MyApp.Test.InnerRenamed
        end
      ]

      refute result =~ "defmodule MyApp.Test.InnerRenamed"
    end

    test "does not rename the same nested name under another module" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Test do
          defmodule |Inner do
          end
        end

        defmodule OtherApp.Test do
          defmodule Inner do
          end
        end

        defmodule MyApp.Consumer do
          alias MyApp.Test.Inner
        end

        defmodule OtherApp.Consumer do
          alias OtherApp.Test.Inner
        end
      ]
        |> rename("InnerRenamed")

      assert result =~ ~S[alias MyApp.Test.InnerRenamed]
      assert result =~ ~S[defmodule OtherApp.Test do]
      assert result =~ ~S[alias OtherApp.Test.Inner]
      refute result =~ ~S[alias OtherApp.Test.InnerRenamed]
    end

    test "preserves every segment requested for a relative declaration" do
      {:ok, result} =
        ~q[
        defmodule MyApp.Users do
          defmodule |Query do
          end
        end

        defmodule MyApp.UsersTest do
          alias MyApp.Users.Query
        end
      ]
        |> rename("Admin.Filter")

      assert result =~ ~S[defmodule Admin.Filter do]
      assert result =~ ~S[alias MyApp.Users.Admin.Filter]
    end

    test "renames multi-alias syntax" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Accounts do
        end

        defmodule MyApp.Web do
          alias MyApp.{
            Users, Accounts,
            Auth.Session
          }
        end
      ]
        |> rename("MyApp.Members")

      assert result =~ ~S[  Users, Members,]
    end

    test "renames the shared prefix in multi-alias syntax" do
      {:ok, result} =
        ~q[
        defmodule Parent.|Child do
        end

        defmodule Parent do
          alias Parent.{Child}
        end
        ]
        |> rename("Parent2.Child")

      assert result =~ ~S[alias Parent2.{Child}]
    end

    test "preserves grouped-alias siblings when a member changes namespace" do
      {:ok, result} =
        ~q[
        defmodule Parent.|Child do
        end

        defmodule Consumer do
          alias Parent.{
            # keep this comment
            Child, Other
          }, warn: false
        end
        ]
        |> rename("Parent2.Child")

      assert result =~ "# keep this comment"
      assert result =~ "alias Parent2.Child, warn: false\n  alias Parent.Other, warn: false"
      assert match?({:ok, _, _}, Forge.Ast.from(result))
    end

    test "renames multiple affected grouped-alias members" do
      {:ok, result} =
        ~q[
        defmodule Parent.|Child do
        end

        defmodule Parent.Child.Sub do
        end

        defmodule Consumer do
          alias Parent.{Other, Child, Child.Sub,}
        end
        ]
        |> rename("Parent2.RenamedChild")

      assert result =~
               "alias Parent.Other\n  alias Parent2.RenamedChild\n  alias Parent2.RenamedChild.Sub"

      assert match?({:ok, _, _}, Forge.Ast.from(result))
    end

    test "keeps split grouped aliases inside their enclosing expression" do
      {:ok, result} =
        ~q[
        defmodule Parent.|Child do
        end

        defmodule Consumer do
          if enabled?(), do: alias Parent.{Child, Other}
        end
        ]
        |> rename("Parent2.Child")

      assert result =~ "if enabled?(), do: (alias Parent2.Child; alias Parent.Other)"
      assert match?({:ok, _, _}, Forge.Ast.from(result))
    end
  end

  describe "rename/4 with references" do
    test "renames use reference" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.Web do
          use MyApp.Users
        end
        ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[use MyApp.Accounts]
    end

    test "renames local use reference" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Auth.Session do
        end

        defmodule MyApp.Web do
          alias MyApp.Auth.Session
          use Session
        end
        ]
        |> rename("MyApp.Identity.Token")

      assert result =~ ~S[alias MyApp.Identity.Token]
      assert result =~ ~S[use Token]
    end

    test "renames use reference through alias" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Auth.Session do
        end

        defmodule MyApp.Web do
          alias MyApp.Auth, as: Auth
          alias MyApp.Identity.Token
          use Auth.Session
        end
        ]
        |> rename("MyApp.Identity.Token")

      assert result =~ ~S[use MyApp.Identity.Token]
      refute result =~ ~S[use Identity.Token]
    end

    test "keeps explicit alias in use reference" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Auth.Session do
        end

        defmodule MyApp.Web do
          alias MyApp.Auth.Session, as: Session
          use Session
        end
        ]
        |> rename("MyApp.Identity.Token")

      assert result =~ ~S[alias MyApp.Identity.Token, as: Session]
      assert result =~ ~S[use Session]
    end

    test "keeps explicit alias for single segment module" do
      {:ok, result} =
        ~q[
        defmodule |Users do
        end

        defmodule MyApp.Web do
          alias Users, as: Users
          use Users
        end
        ]
        |> rename("Accounts")

      assert result =~ ~S[alias Accounts, as: Users]
      assert result =~ ~S[use Users]
    end

    test "does not rename similar module names" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.UsersTest do
        end
        ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[defmodule MyApp.UsersTest do]
    end

    test "renames local references when local name changes" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.UsersTest do
          alias MyApp.Users
          Users.list()
        end
        ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[alias MyApp.Accounts]
      assert result =~ ~S[ Accounts.list()]
    end

    test "keeps local reference when local name unchanged" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.Admin do
          alias MyApp.Users

          Users.list() # no change
        end
      ]
        |> rename("MyApp.Core.Users")

      assert result =~ ~S[defmodule MyApp.Core.Users do]
      assert result =~ ~S[alias MyApp.Core.Users]
      assert result =~ ~S[ Users.list() # no change]
    end

    test "keeps local reference when only prefix changes" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Core.Utils do
        end

        defmodule MyApp.Web do
          alias MyApp.Core.Utils

          Utils.format() # no change
        end
      ]
        |> rename("MyApp.Shared.Utils")

      assert result =~ ~S[defmodule MyApp.Shared.Utils do]
      assert result =~ ~S[alias MyApp.Shared.Utils]
      assert result =~ ~S[ Utils.format() # no change]
    end
  end

  describe "rename/4 descendants" do
    test "renames descendants" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Users do
        end

        defmodule MyApp.Users.Query do
        end
      ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[defmodule MyApp.Accounts.Query]
      assert result =~ ~S[defmodule MyApp.Accounts do]
    end

    test "renames descendants when expanding name" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Users do
          alias MyApp.Users.Query
        end

        defmodule MyApp.Users.Query do
        end
      ]
        |> rename("MyApp.Core.Users")

      assert result =~ ~S[defmodule MyApp.Core.Users]
      assert result =~ ~S[alias MyApp.Core.Users.Query]
      assert result =~ ~S[defmodule MyApp.Core.Users.Query do]
    end

    test "renames descendants with multi-part expansion" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Auth do
        end

        defmodule MyApp.Auth.Session do
        end

        defmodule MyApp.AuthTest do
          alias MyApp.Auth
          alias MyApp.Auth.Session
        end
      ]
        |> rename("MyApp.Auth.OAuth")

      assert result =~ ~S[defmodule MyApp.Auth.OAuth do]
      assert result =~ ~S[alias MyApp.Auth.OAuth]
      assert result =~ ~S[alias MyApp.Auth.OAuth.Session]
    end

    test "handles repeated module name in path" do
      {:ok, result} =
        ~q[
          defmodule MyApp.Core.MyApp.|Core do
          end

          defmodule MyApp.Core.MyApp.Core.Utils do
          end

          defmodule MyApp.Web do
            alias MyApp.Core.MyApp.Core.Utils
          end
        ]
        |> rename("MyApp.Core.MyApp.Shared")

      assert result =~ ~S[defmodule MyApp.Core.MyApp.Shared do]
      assert result =~ ~S[defmodule MyApp.Core.MyApp.Shared.Utils do]
      assert result =~ ~S[alias MyApp.Core.MyApp.Shared.Utils]
    end

    test "skips same-named nested modules" do
      {:ok, result} =
        ~q[
        defmodule MyApp.|Users do
          defmodule Users do # skip this
          end
        end

        defmodule MyApp.Admin do
          alias MyApp.Users.Users
        end
      ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[defmodule MyApp.Accounts do]
      assert result =~ ~S[defmodule Users do # skip this]
      assert result =~ ~S[alias MyApp.Accounts.Users]
    end

    test "renames when removing middle segment" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Core.Users do
        end

        defmodule MyApp.Core.Users.Query do
          alias MyApp.Core.Users.Query
        end
      ]
        |> rename("MyApp.Users")

      assert result =~ ~S[defmodule MyApp.Users.Query do]
      assert result =~ ~S[alias MyApp.Users.Query]
    end

    test "does not rename modules containing old suffix as substring" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Ast do
        end

        defmodule MyApp.Parser do
          alias MyApp.Ast.Detection

          Detection.Bitstring.detected?() # Bitstring contains the old suffix: `st`
        end
      ]
        |> rename("MyApp.AST")

      refute result =~ ~S[Detection.BitSTring.detected?()]
    end
  end

  describe "rename/4 struct" do
    test "renames struct references" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
          defstruct name: nil, email: nil
        end

        defmodule MyApp.Accounts do
          def new do
            %MyApp.User{}
          end
        end
      ]
        |> rename("MyApp.Account")

      assert result =~ ~S[defmodule MyApp.Account do]
      assert result =~ ~S[%MyApp.Account{}]
    end

    test "renames struct in pattern matching" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
          defstruct name: nil, email: nil
        end

        defmodule MyApp.Accounts do
          def get_name(%MyApp.User{name: name}), do: name
        end
      ]
        |> rename("MyApp.Account")

      assert result =~ ~S[def get_name(%MyApp.Account{name: name})]
    end

    test "renames struct update syntax" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
          defstruct name: nil, email: nil
        end

        defmodule MyApp.Accounts do
          def update(user, name) do
            %MyApp.User{user | name: name}
          end
        end
      ]
        |> rename("MyApp.Account")

      assert result =~ ~S[%MyApp.Account{user | name: name}]
    end
  end

  describe "rename/4 edge cases" do
    test "does not rename module with similar prefix" do
      # MyApp.User should not affect MyApp.UserProfile
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
        end

        defmodule MyApp.UserProfile do
        end

        defmodule MyApp.Consumer do
          alias MyApp.User
          alias MyApp.UserProfile
        end
      ]
        |> rename("MyApp.Account")

      assert result =~ ~S[defmodule MyApp.Account do]
      # UserProfile should NOT be renamed
      assert result =~ ~S[defmodule MyApp.UserProfile do]
      assert result =~ ~S[alias MyApp.UserProfile]
    end

    test "does not rename module that contains old name as substring" do
      # Renaming MyApp.API should not affect MyApp.SomeAPIService
      {:ok, result} =
        ~q[
        defmodule |MyApp.API do
        end

        defmodule MyApp.SomeAPIService do
        end
      ]
        |> rename("MyApp.Gateway")

      assert result =~ ~S[defmodule MyApp.Gateway do]
      # SomeAPIService should NOT be renamed to SomeGatewayService
      assert result =~ ~S[defmodule MyApp.SomeAPIService do]
    end

    test "correctly renames when old and new names share common prefix" do
      # MyApp.User -> MyApp.UserAccount (extending the name)
      {:ok, result} =
        ~q[
        defmodule |MyApp.User do
        end

        defmodule MyApp.Consumer do
          alias MyApp.User
        end
      ]
        |> rename("MyApp.UserAccount")

      assert result =~ ~S[defmodule MyApp.UserAccount do]
      assert result =~ ~S[alias MyApp.UserAccount]
    end

    test "correctly renames when new name is shorter" do
      # MyApp.UserAccount -> MyApp.User (shortening the name)
      {:ok, result} =
        ~q[
        defmodule |MyApp.UserAccount do
        end

        defmodule MyApp.Consumer do
          alias MyApp.UserAccount
        end
      ]
        |> rename("MyApp.User")

      assert result =~ ~S[defmodule MyApp.User do]
      assert result =~ ~S[alias MyApp.User]
    end

    test "handles renaming module with single segment name" do
      {:ok, result} =
        ~q[
        defmodule |Users do
        end

        defmodule Consumer do
          alias Users
        end
      ]
        |> rename("Accounts")

      assert result =~ ~S[defmodule Accounts do]
      assert result =~ ~S[alias Accounts]
    end

    test "renames single segment module to full module name" do
      {:ok, result} =
        ~q[
        defmodule |Users do
        end

        defmodule MyApp.Web do
          use Users
        end
      ]
        |> rename("MyApp.Accounts")

      assert result =~ ~S[defmodule MyApp.Accounts do]
      assert result =~ ~S[use MyApp.Accounts]
    end

    test "handles renaming to completely different module path" do
      # MyApp.Users -> OtherApp.Accounts (different prefix entirely)
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.Consumer do
          alias MyApp.Users
        end
      ]
        |> rename("OtherApp.Accounts")

      assert result =~ ~S[defmodule OtherApp.Accounts do]
      assert result =~ ~S[alias OtherApp.Accounts]
    end

    test "renames deeply nested module correctly" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Core.Domain.Users.Query do
        end

        defmodule MyApp.Web do
          alias MyApp.Core.Domain.Users.Query
        end
      ]
        |> rename("MyApp.Core.Domain.Users.Filter")

      assert result =~ ~S[defmodule MyApp.Core.Domain.Users.Filter do]
      assert result =~ ~S[alias MyApp.Core.Domain.Users.Filter]
    end

    test "does not corrupt nearby code when renaming" do
      {:ok, result} =
        ~q[
        defmodule |MyApp.Users do
          @moduledoc "Users module"

          def list, do: :ok
        end

        defmodule MyApp.UsersTest do
          use ExUnit.Case
        end
      ]
        |> rename("MyApp.Accounts")

      # Verify the module is renamed
      assert result =~ ~S[defmodule MyApp.Accounts do]
      # Verify other code is preserved
      assert result =~ ~S[@moduledoc "Users module"]
      assert result =~ ~S[def list, do: :ok]
      # UsersTest should NOT be renamed (different module)
      assert result =~ ~S[defmodule MyApp.UsersTest do]
    end
  end

  describe "rename/4 file rename eligibility" do
    test "checks file rename eligibility once per document" do
      patch(Rename.File, :maybe_rename, nil)

      assert {:ok, _result} =
               ~q[
               defmodule |MyApp.Users do
                 def current, do: MyApp.Users
               end
               ]
               |> rename("MyApp.Accounts")

      assert_called_once(
        Rename.File.maybe_rename(_, %Engine.CodeMod.Rename.Entry{subtype: :definition}, _)
      )
    end

    test "does not rename a nested module's file", %{project: project} do
      {:ok, {_applied, nil}} =
        ~q[
        defmodule MyApp.Server do
          defmodule |State do
          end
        end
        ]
        |> rename_with_file("Config", "lib/my_app/server.ex", project)
    end

    test "does not rename a file with multiple top-level modules", %{project: project} do
      assert {:ok, {_applied, nil}} =
               ~q[
        defmodule |MyApp.Users do
        end

        defmodule MyApp.Accounts do
        end
        ]
               |> rename_with_file("Members", "lib/my_app/users.ex", project)
    end

    test "does not rename a file when its path matches neither convention", %{project: project} do
      assert {:ok, {_applied, nil}} =
               ~q[
        defmodule |MyApp.Orders do
        end
        ]
               |> rename_with_file("MyApp.Ordering", "lib/my_app/index.ex", project)
    end

    test "does not rename files when file operations are disabled", %{project: project} do
      assert {:ok, {_applied, nil}} =
               ~q[
               defmodule |MyApp.Users do
               end
               ]
               |> rename_with_file("MyApp.Accounts", "lib/my_app/users.ex", project, false)
    end
  end

  describe "rename/4 document versions" do
    test "captures the version of an open document" do
      {position, code} =
        pop_cursor(~q[
        defmodule |MyApp.Users do
        end
        ])

      {:ok, _document, analysis} = index(code)

      assert {:ok, [%Document.Changes{expected_version: 1}]} =
               Rename.rename(analysis, position, "MyApp.Accounts", nil)
    end

    test "omits the version for a reference loaded from disk", %{
      project: project,
      store: store
    } do
      {position, code} =
        pop_cursor(~q[
        defmodule |MyApp.Users do
        end
        ])

      {:ok, _document, analysis} = index(code)
      path = file_path(project, "lib/rename_version_consumer.ex")
      File.write!(path, "defmodule Consumer do\n  alias MyApp.Users\nend\n")
      on_exit(fn -> File.rm!(path) end)

      reference_document = Document.new(path, File.read!(path), 1)
      {:ok, entries} = Source.index_document(reference_document)
      Agent.update(store, &(&1 ++ entries))

      assert {:ok, changes} = Rename.rename(analysis, position, "MyApp.Accounts", nil)
      reference_uri = Document.Path.ensure_uri(path)

      assert %Document.Changes{expected_version: nil} =
               Enum.find(changes, &(&1.document.uri == reference_uri))
    end

    test "uses current entries and skips missing indexed files", %{
      project: project
    } do
      {position, users_source} =
        pop_cursor(~q[
        defmodule MyApp.|Users do
        end
        ])

      users_uri = subject_uri(project, "lib/users.ex")
      consumer_uri = subject_uri(project, "lib/consumer.ex")
      consumer_source = "defmodule Consumer do\n  alias MyApp.Users\nend\n"

      :ok = Document.Store.open(users_uri, users_source, 1)
      {:ok, users, users_analysis} = Document.Store.fetch(users_uri, :analysis)
      {:ok, users_entries} = Source.index_document(users)

      :ok = Document.Store.open(consumer_uri, consumer_source, 1)
      {:ok, consumer} = Document.Store.fetch(consumer_uri)
      {:ok, consumer_entries} = Source.index_document(consumer)

      missing_path = file_path(project, "lib/missing_consumer.ex")
      missing_document = Document.new(missing_path, consumer_source, 1)
      {:ok, missing_entries} = Source.index_document(missing_document)

      :ok =
        ManagerApi.search_store_replace(
          project,
          users_entries ++ consumer_entries ++ missing_entries
        )

      shifted_source =
        "# unsaved shift\ndefmodule Consumer do\n  alias MyApp.Users.Report\nend\n"

      :ok =
        Document.Store.update(consumer_uri, fn document ->
          Document.apply_content_changes(document, 2, [Document.Edit.new(shifted_source)])
        end)

      assert {:ok, changes} =
               Rename.rename(users_analysis, position, "MyApp.Accounts", nil, false)

      assert %Document.Changes{document: document, edits: edits, expected_version: 2} =
               Enum.find(changes, &(&1.document.uri == consumer_uri))

      assert {:ok, updated} = Document.apply_content_changes(document, 3, edits)

      assert Document.to_string(updated) ==
               "# unsaved shift\ndefmodule Consumer do\n  alias MyApp.Accounts.Report\nend\n"
    end
  end

  describe "rename/4 standard file convention" do
    test "renames a file when its path matches the standard lib convention", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |MyApp.Users do
        end
      ]
        |> rename_with_file("MyApp.Accounts", "lib/my_app/users.ex", project)

      assert rename_file.new_uri == subject_uri(project, "lib/my_app/accounts.ex")
    end

    test "derives the destination from the new module using the matched standard convention", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |MyApp.Users do
        end
      ]
        |> rename_with_file("Billing.Accounts", "lib/my_app/users.ex", project)

      assert rename_file.new_uri == subject_uri(project, "lib/billing/accounts.ex")
    end

    test "rejects an existing destination file", %{project: project} do
      destination = file_path(project, "lib/accounts.ex")
      refute File.exists?(destination)
      File.write!(destination, "defmodule Accounts do\nend\n")
      on_exit(fn -> File.rm!(destination) end)

      assert {:error, {:file_already_exists, ^destination}} =
               ~q[
               defmodule |Users do
               end
               ]
               |> rename_with_file("Accounts", "lib/users.ex", project)
    end

    test "does not emit a file rename when the conventional destination is unchanged", %{
      project: project
    } do
      assert {:ok, {_applied, nil}} =
               ~q[
        defmodule |MyApp.Users do
        end
        ]
               |> rename_with_file("MyApp.USERS", "lib/my_app/users.ex", project)
    end

    test "renames a file when its path matches the standard umbrella convention", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |MyApp.Users do
        end
      ]
        |> rename_with_file("MyApp.Accounts", "apps/my_app/lib/my_app/users.ex", project)

      assert rename_file.new_uri == subject_uri(project, "apps/my_app/lib/my_app/accounts.ex")
    end

    test "derives the conventional destination inside the same umbrella application", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |Engine.CodeMod do
        end
      ]
        |> rename_with_file(
          "Engine.Refactor",
          "apps/engine/lib/engine/code_mod.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "apps/engine/lib/engine/refactor.ex")
    end

    test "renames a file when its path matches the standard test convention", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule |MyApp.UsersTest do
        end
      ]
        |> rename_with_file("MyApp.AccountsTest", "test/my_app/users_test.exs", project)

      assert rename_file.new_uri == subject_uri(project, "test/my_app/accounts_test.exs")
    end
  end

  describe "rename/4 Phoenix file convention" do
    test "renames a file when its path matches the Phoenix components convention", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.|IconComponent do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.BadgeComponent",
          "lib/my_app_web/components/icon_component.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/components/badge_component.ex")
    end

    test "preserves the Phoenix components convention for a nested module", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.Admin.|IconComponent do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.Admin.BadgeComponent",
          "lib/my_app_web/components/admin/icon_component.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/components/admin/badge_component.ex")
    end

    test "does not duplicate a Phoenix folder present in the module name", %{project: project} do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.Components.|Icons do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.Components.Badges",
          "lib/my_app_web/components/icons.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/components/badges.ex")
    end

    test "renames a file when its path matches the Phoenix controllers convention", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.|UserController do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.AccountController",
          "lib/my_app_web/controllers/user_controller.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/controllers/account_controller.ex")
    end

    test "derives the destination from the new module using the matched Phoenix convention", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.Admin.|UserController do
        end
      ]
        |> rename_with_file(
          "BillingWeb.AccountController",
          "lib/my_app_web/controllers/admin/user_controller.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/billing_web/controllers/account_controller.ex")
    end

    test "preserves the Phoenix controllers convention for a nested module", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.UserController.|JSON do
        end
      ]
        |> rename_with_file(
          "MyAppWeb.UserController.API",
          "lib/my_app_web/controllers/user_controller/json.ex",
          project
        )

      assert rename_file.new_uri ==
               subject_uri(project, "lib/my_app_web/controllers/user_controller/api.ex")
    end

    test "renames a file when its path matches the Phoenix live convention", %{
      project: project
    } do
      {:ok, {_applied, rename_file}} =
        ~q[
        defmodule MyAppWeb.|UserLive do
        end
      ]
        |> rename_with_file("MyAppWeb.AccountLive", "lib/my_app_web/live/user_live.ex", project)

      assert rename_file.new_uri == subject_uri(project, "lib/my_app_web/live/account_live.ex")
    end
  end

  # Helpers

  defp prepare(code) do
    with {position, code} <- pop_cursor(code),
         {:ok, _document, analysis} <- index(code) do
      Rename.prepare(analysis, position)
    end
  end

  defp rename(code, new_name) do
    with {position, code} <- pop_cursor(code),
         {:ok, document, analysis} <- index(code),
         {:ok, results} <- Rename.rename(analysis, position, new_name, nil) do
      case results do
        [%Document.Changes{edits: edits, document: doc}] ->
          {:ok, edited_doc} =
            Document.apply_content_changes(doc, doc.version + 1, edits)

          {:ok, Document.to_string(edited_doc)}

        [] ->
          {:ok, Document.to_string(document)}
      end
    end
  end

  defp rename_with_file(code, new_name, path, project, rename_files? \\ true) do
    uri = subject_uri(project, path)

    with {position, text} <- pop_cursor(code),
         {:ok, document} <- open_document(uri, text),
         {:ok, entries} <- Source.index_document(document),
         :ok <- ManagerApi.search_store_replace(project, entries),
         {:ok, _document, analysis} <- Document.Store.fetch(uri, :analysis),
         {:ok, document_changes} <-
           Rename.rename(analysis, position, new_name, nil, rename_files?) do
      changes = document_changes |> Enum.map(& &1.edits) |> List.flatten()
      applied = apply_edits(document, changes)
      rename_file = document_changes |> Enum.map(& &1.rename_file) |> List.first()

      {:ok, {applied, rename_file}}
    end
  end

  defp index(code) do
    project = Engine.get_project()
    uri = module_uri(project)

    with :ok <- Document.Store.open(uri, code, 1),
         {:ok, document, analysis} <- Document.Store.fetch(uri, :analysis),
         {:ok, entries} <- Engine.Search.Indexer.Quoted.index(analysis) do
      ManagerApi.search_store_replace(project, entries)
      {:ok, document, analysis}
    end
  end

  defp query_entries(store, subject, constraints, match_type) do
    type = Keyword.get(constraints, :type, :_)
    subtype = Keyword.get(constraints, :subtype, :_)
    subject = format_subject(subject)

    store
    |> Agent.get(& &1)
    |> Enum.filter(fn entry ->
      matches_constraint?(entry.type, type) and matches_constraint?(entry.subtype, subtype) and
        matches_subject?(format_subject(entry.subject), subject, match_type)
    end)
  end

  defp matches_subject?(entry_subject, subject, :exact), do: entry_subject == subject

  defp matches_subject?(entry_subject, subject, :prefix),
    do: String.starts_with?(entry_subject, subject)

  defp matches_constraint?(_value, :_), do: true
  defp matches_constraint?(value, value), do: true
  defp matches_constraint?(_, _), do: false

  defp format_subject(subject) when is_atom(subject), do: Forge.Formats.module(subject)
  defp format_subject(subject) when is_binary(subject), do: subject
  defp format_subject(subject), do: to_string(subject)

  defp module_uri(project) do
    project
    |> file_path(Path.join("lib", "my_module.ex"))
    |> Document.Path.ensure_uri()
  end

  defp subject_uri(project, path) do
    project
    |> file_path(path)
    |> Document.Path.ensure_uri()
  end

  defp open_document(uri, content) do
    with :ok <- Document.Store.open(uri, content, 0) do
      Document.Store.fetch(uri)
    end
  end

  defp apply_edits(document, text_edits) do
    {:ok, edited_document} = Document.apply_content_changes(document, 1, text_edits)
    Document.to_string(edited_document)
  end
end
