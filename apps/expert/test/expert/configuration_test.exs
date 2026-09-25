defmodule Expert.ConfigurationTest do
  use ExUnit.Case, async: false

  import Expert.Test.ConfigurationSupport

  alias Expert.Configuration
  alias Expert.Configuration.WorkspaceSymbols
  alias GenLSP.Notifications.WorkspaceDidChangeConfiguration
  alias GenLSP.Structures.ClientCapabilities
  alias GenLSP.Structures.DidChangeConfigurationParams
  alias GenLSP.Structures.DidChangeWatchedFilesClientCapabilities
  alias GenLSP.Structures.WorkspaceClientCapabilities

  setup do
    :persistent_term.erase(Expert.Configuration)

    Configuration.new()
    |> Configuration.set()

    on_exit(fn ->
      :persistent_term.erase(Expert.Configuration)
    end)

    :ok
  end

  describe "new/0 and new/1" do
    test "creates configuration with default values" do
      config = Configuration.new()

      assert config.workspace_symbols.min_query_length == 2
    end

    test "accepts keyword list of attributes" do
      config = Configuration.new(workspace_symbols: %WorkspaceSymbols{min_query_length: 0})

      assert config.workspace_symbols.min_query_length == 0
    end

    test "set/1 stores configuration in persistent_term" do
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 5}]
      |> Configuration.new()
      |> Configuration.set()

      assert Configuration.get().workspace_symbols.min_query_length == 5
    end
  end

  describe "window_log_message_enabled?/0" do
    test "is enabled by default when client name is missing" do
      assert Configuration.window_log_message_enabled?()
    end

    test "is disabled for emacs and eglot clients" do
      Configuration.set(Configuration.new(client_name: "Emacs"))

      refute Configuration.window_log_message_enabled?()

      Configuration.set(Configuration.new(client_name: "Eglot"))

      refute Configuration.window_log_message_enabled?()
    end

    test "is enabled for other clients" do
      Configuration.set(Configuration.new(client_name: "Visual Studio Code"))

      assert Configuration.window_log_message_enabled?()
    end
  end

  describe "log_level/0" do
    test "defaults to :info" do
      assert Configuration.log_level() == :info
    end

    test "can be set via new/1" do
      [log_level: :warning]
      |> Configuration.new()
      |> Configuration.set()

      assert Configuration.log_level() == :warning
    end
  end

  describe "file_log_level/0" do
    test "defaults to :debug" do
      assert Configuration.file_log_level() == :debug
    end

    test "can be set via new/1" do
      [file_log_level: :warning]
      |> Configuration.new()
      |> Configuration.set()

      assert Configuration.file_log_level() == :warning
    end
  end

  describe "on_change/1 with logLevel" do
    test "parses the 4 valid LSP log level strings" do
      for {string, atom} <- [
            {"error", :error},
            {"warning", :warning},
            {"info", :info},
            {"log", :log}
          ] do
        change = build_change(%{"logLevel" => string})

        {:ok, updated} = Configuration.on_change(change)

        assert updated.log_level == atom
      end
    end

    test "defaults to :info when setting is missing" do
      change = build_change(%{})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.log_level == :info
    end

    test "defaults to :info for invalid string values" do
      change = build_change(%{"logLevel" => "verbose"})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.log_level == :info
    end

    test "ignores non-map settings values" do
      change = build_change(%{"logLevel" => "warning"})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.log_level == :warning

      for settings <- [nil, [], "bad", 123, true] do
        assert {:ok, updated} = Configuration.on_change(build_change(settings))

        assert updated.log_level == :warning
        assert updated.workspace_symbols.min_query_length == 2
      end
    end
  end

  describe "on_change/1 with fileLogLevel" do
    test "parses valid file log level strings" do
      for {string, atom} <- [
            {"debug", :debug},
            {"info", :info},
            {"warning", :warning},
            {"error", :error}
          ] do
        change = build_change(%{"fileLogLevel" => string})

        {:ok, updated} = Configuration.on_change(change)

        assert updated.file_log_level == atom
      end
    end

    test "preserves previous value when setting is missing" do
      change = build_change(%{"fileLogLevel" => "error"})
      {:ok, _} = Configuration.on_change(change)

      change = build_change(%{})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.file_log_level == :error
    end

    test "resets to default when explicit null is sent" do
      change = build_change(%{"fileLogLevel" => "error"})
      {:ok, _} = Configuration.on_change(change)

      change = build_change(%{"fileLogLevel" => nil})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.file_log_level == :debug
    end

    test "resets to default for invalid string values" do
      change = build_change(%{"fileLogLevel" => "verbose"})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.file_log_level == :debug
    end

    test "updates the project log file handler level" do
      handler_name = Expert.Logging.ProjectLogFile.handler_name()
      had_handler = match?({:ok, _}, :logger.get_handler_config(handler_name))

      if !had_handler do
        :logger.add_handler(handler_name, :logger_std_h, %{
          config: %{file: ~c"/dev/null"},
          level: :debug
        })
      end

      on_exit(fn ->
        if had_handler do
          :logger.set_handler_config(handler_name, :level, :debug)
        else
          :logger.remove_handler(handler_name)
        end
      end)

      change = build_change(%{"fileLogLevel" => "warning"})
      {:ok, _updated} = Configuration.on_change(change)

      {:ok, handler_config} = :logger.get_handler_config(handler_name)
      assert handler_config.level == :warning
    end

    test "does not crash when handler is not attached" do
      handler_name = Expert.Logging.ProjectLogFile.handler_name()

      previous_config =
        case :logger.get_handler_config(handler_name) do
          {:ok, config} ->
            :logger.remove_handler(handler_name)
            config

          {:error, _} ->
            nil
        end

      on_exit(fn ->
        if previous_config do
          :logger.add_handler(handler_name, previous_config.module, previous_config)
        end
      end)

      change = build_change(%{"fileLogLevel" => "error"})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.file_log_level == :error
    end
  end

  describe "client_resolves_code_action_edits?/0" do
    test "true when the client can resolve the edit property" do
      put_resolve_support(%{properties: ["edit"]})

      assert Configuration.client_resolves_code_action_edits?()
    end

    test "false when the client resolves other properties only" do
      put_resolve_support(%{properties: ["command"]})

      refute Configuration.client_resolves_code_action_edits?()
    end

    test "false when the client declares no resolve support" do
      put_resolve_support(nil)

      refute Configuration.client_resolves_code_action_edits?()
    end

    test "false with default configuration" do
      refute Configuration.client_resolves_code_action_edits?()
    end
  end

  describe "on_change/1 with workspace_symbols.min_query_length" do
    test "parses nested setting correctly" do
      settings = %{"workspaceSymbols" => %{"minQueryLength" => 0}}

      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 0
    end

    test "accepts any non-negative integer" do
      settings = %{"workspaceSymbols" => %{"minQueryLength" => 5}}

      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 5
    end

    test "defaults to 2 when setting is missing" do
      settings = %{}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 2
    end

    test "defaults to 2 when workspaceSymbols is present but minQueryLength is missing" do
      settings = %{"workspaceSymbols" => %{}}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 2
    end

    test "defaults to 2 when value is not a non-negative integer" do
      settings = %{"workspaceSymbols" => %{"minQueryLength" => "0"}}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)
      assert updated.workspace_symbols.min_query_length == 2

      settings = %{"workspaceSymbols" => %{"minQueryLength" => -1}}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)
      assert updated.workspace_symbols.min_query_length == 2

      settings = %{"workspaceSymbols" => %{"minQueryLength" => 1.5}}
      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)
      assert updated.workspace_symbols.min_query_length == 2
    end

    test "can override a previously set value" do
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 0}]
      |> Configuration.new()
      |> Configuration.set()

      settings = %{"workspaceSymbols" => %{"minQueryLength" => 3}}

      change = build_change(settings)
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 3
    end

    test "preserves previous value when workspaceSymbols is missing" do
      change = build_change(%{"workspaceSymbols" => %{"minQueryLength" => 0}})
      {:ok, _updated} = Configuration.on_change(change)

      change = build_change(%{"fileLogLevel" => "error"})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.workspace_symbols.min_query_length == 0
    end
  end

  describe "on_change/1 with elixirSourcePath" do
    test "parses a valid directory path" do
      change = build_change(%{"elixirSourcePath" => "/path/to/elixir/source"})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.elixir_source_path == "/path/to/elixir/source"
    end

    test "preserves previous value when setting is missing" do
      change = build_change(%{"elixirSourcePath" => "/some/path"})
      {:ok, _} = Configuration.on_change(change)

      change = build_change(%{})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.elixir_source_path == "/some/path"
    end

    test "clears the value when explicit null is sent" do
      change = build_change(%{"elixirSourcePath" => "/some/path"})
      {:ok, _} = Configuration.on_change(change)

      change = build_change(%{"elixirSourcePath" => nil})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.elixir_source_path == nil
    end

    test "defaults to nil" do
      change = build_change(%{})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.elixir_source_path == nil
    end

    test "ignores non-string values" do
      change = build_change(%{"elixirSourcePath" => 123})
      {:ok, updated} = Configuration.on_change(change)

      assert updated.elixir_source_path == nil
    end
  end

  describe "on_change/1 with runtime executable paths" do
    test "stores configured executable paths" do
      change =
        build_change(%{
          "elixirExecutablePath" => "/opt/elixir/bin/elixir",
          "erlangExecutablePath" => "/opt/erlang/bin/erl"
        })

      {:ok, updated} = Configuration.on_change(change)

      assert updated.elixir_executable_path == "/opt/elixir/bin/elixir"
      assert updated.erlang_executable_path == "/opt/erlang/bin/erl"
    end

    test "preserves configured executable paths when settings are missing" do
      change =
        build_change(%{
          "elixirExecutablePath" => "/opt/elixir/bin/elixir",
          "erlangExecutablePath" => "/opt/erlang/bin/erl"
        })

      {:ok, _updated} = Configuration.on_change(change)
      {:ok, updated} = Configuration.on_change(build_change(%{}))

      assert updated.elixir_executable_path == "/opt/elixir/bin/elixir"
      assert updated.erlang_executable_path == "/opt/erlang/bin/erl"
    end

    test "clears configured executable paths when explicit null is sent" do
      change =
        build_change(%{
          "elixirExecutablePath" => "/opt/elixir/bin/elixir",
          "erlangExecutablePath" => "/opt/erlang/bin/erl"
        })

      {:ok, _updated} = Configuration.on_change(change)

      change =
        build_change(%{
          "elixirExecutablePath" => nil,
          "erlangExecutablePath" => nil
        })

      {:ok, updated} = Configuration.on_change(change)

      assert updated.elixir_executable_path == nil
      assert updated.erlang_executable_path == nil
    end
  end

  describe "on_change/1 with autoFetchDependencies" do
    test "parses boolean values" do
      {:ok, updated} = Configuration.on_change(build_change(%{"autoFetchDependencies" => true}))

      assert updated.auto_fetch_dependencies
      assert Configuration.auto_fetch_dependencies?()

      {:ok, updated} = Configuration.on_change(build_change(%{"autoFetchDependencies" => false}))

      refute updated.auto_fetch_dependencies
    end

    test "preserves previous value when setting is missing" do
      {:ok, _updated} = Configuration.on_change(build_change(%{"autoFetchDependencies" => true}))
      {:ok, updated} = Configuration.on_change(build_change(%{}))

      assert updated.auto_fetch_dependencies
    end

    test "defaults to true for invalid values and explicit null" do
      for value <- [nil, "true", 1] do
        {:ok, updated} =
          Configuration.on_change(build_change(%{"autoFetchDependencies" => value}))

        assert updated.auto_fetch_dependencies
      end
    end
  end

  describe "on_change/1 with compileOnType" do
    test "defaults to enabled" do
      assert Configuration.compile_on_type?()
    end

    test "parses boolean values" do
      {:ok, updated} = Configuration.on_change(build_change(%{"compileOnType" => false}))

      refute updated.compile_on_type
      refute Configuration.compile_on_type?()

      {:ok, updated} = Configuration.on_change(build_change(%{"compileOnType" => true}))

      assert updated.compile_on_type
    end

    test "preserves the previous value when the setting is missing" do
      {:ok, _updated} = Configuration.on_change(build_change(%{"compileOnType" => false}))
      {:ok, updated} = Configuration.on_change(build_change(%{}))

      refute updated.compile_on_type
    end

    test "defaults to enabled for invalid values and explicit null" do
      for value <- [nil, "true", 1] do
        {:ok, updated} = Configuration.on_change(build_change(%{"compileOnType" => value}))

        assert updated.compile_on_type
      end
    end
  end

  describe "race condition prevention" do
    defmodule DummyServer do
      use GenServer

      alias Expert.Configuration
      alias GenLSP.Notifications.WorkspaceDidChangeConfiguration
      alias GenLSP.Structures.DidChangeConfigurationParams

      def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
      def update_config(pid, settings), do: GenServer.cast(pid, {:update_config, settings})
      def slow_noop(pid, delay), do: GenServer.cast(pid, {:slow_noop, delay})

      @impl GenServer
      def init(test_pid), do: {:ok, test_pid}

      @impl GenServer
      def handle_cast({:update_config, settings}, test_pid) do
        change = %WorkspaceDidChangeConfiguration{
          params: %DidChangeConfigurationParams{settings: settings}
        }

        {:ok, _} = Configuration.on_change(change)
        send(test_pid, :update_finished)
        {:noreply, test_pid}
      end

      def handle_cast({:slow_noop, delay}, test_pid) do
        Process.sleep(delay)
        send(test_pid, :noop_finished)
        {:noreply, test_pid}
      end
    end

    test "config update persists even when a slow handler completes afterwards" do
      # Start with initial config
      [workspace_symbols: %WorkspaceSymbols{min_query_length: 5}]
      |> Configuration.new()
      |> Configuration.set()

      {:ok, pid} = DummyServer.start_link(self())

      # 1. slow_noop starts processing (takes 50ms)
      # 2. update_config is queued and waits
      # 3. slow_noop finishes, update_config starts and updates config
      # 4. update_config finishes

      DummyServer.slow_noop(pid, 50)
      DummyServer.update_config(pid, %{"workspaceSymbols" => %{"minQueryLength" => 0}})

      assert_receive :noop_finished, 100
      assert_receive :update_finished, 100

      # The update should persist, not be overwritten by the slow handler
      assert Configuration.get().workspace_symbols.min_query_length == 0
    end
  end

  describe "on_change/1 watched files registration" do
    test "does not register watched files when the client lacks support" do
      change = build_change(%{"additionalWatchedExtensions" => [".heex"]})

      assert {:ok, _updated} = Configuration.on_change(change)
    end

    test "registers watched files when the client supports dynamic registration" do
      put_watched_files_support(true)
      change = build_change(%{"additionalWatchedExtensions" => [".heex"]})

      assert {:ok, _updated, %GenLSP.Requests.ClientRegisterCapability{} = request} =
               Configuration.on_change(change)

      assert [%{method: "workspace/didChangeWatchedFiles"}] = request.params.registrations
    end

    test "does not register watched files for non-map settings" do
      assert {:ok, updated} = Configuration.on_change(build_change(nil))

      assert updated.additional_watched_extensions == nil
    end

    test "nil settings do not reset previously configured values" do
      change =
        build_change(%{
          "logLevel" => "warning",
          "workspaceSymbols" => %{"minQueryLength" => 5}
        })

      {:ok, updated} = Configuration.on_change(change)
      assert updated.log_level == :warning
      assert updated.workspace_symbols.min_query_length == 5

      {:ok, after_nil} = Configuration.on_change(build_change(nil))

      assert after_nil.log_level == :warning
      assert after_nil.workspace_symbols.min_query_length == 5
    end
  end

  defp build_change(settings) do
    %WorkspaceDidChangeConfiguration{
      params: %DidChangeConfigurationParams{
        settings: settings
      }
    }
  end

  defp put_watched_files_support(dynamic_registration) do
    %ClientCapabilities{
      workspace: %WorkspaceClientCapabilities{
        did_change_watched_files: %DidChangeWatchedFilesClientCapabilities{
          dynamic_registration: dynamic_registration
        }
      }
    }
    |> Configuration.new("test-client")
    |> Configuration.set()
  end
end
