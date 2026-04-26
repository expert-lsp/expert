# Development

## Getting Started

First follow the [installation instructions](installation.md) to install the
required prerequisites.

To build Expert, run:

```sh
just release
```

You may point your editor's LSP configuration to the `start_expert` executable
in the generated release:

```sh
<your-repo>/apps/expert/_build/prod/rel/plain/bin/start_expert --stdio
```

## Parser Configuration

Expert uses [Spitfire](https://github.com/elixir-tools/spitfire) as the default
parser. To use the built-in Elixir parser instead, set the `EXPERT_PARSER` env
variable to `elixir` when building the release:

```sh
EXPERT_PARSER=elixir just release
```

## Logging

When expert starts up, it creates a `.expert` directory in the root
directory of a project. Inside that directory are two log files,
`expert.log` and `project.log`. The `expert.log` log file contains
logging and OTP messages from the language server, while the
`project.log` file contains logging and OTP messages from the
project's node. While developing expert, it's helpful to open up a
terminal and tail both of these log files so you can see any errors
and messages that expert emits. To do that, run the following in a
terminal while in the project's root directory:

```sh
tail -f .expert/*.log
```

Note: These log files roll over when they reach 1 megabyte, so after a
time, it will be necessary to re-run the above command.

## Debugging

Expert supports a debug shell, which will connect a remote IEx session to a
currently-running language server process.

### connectionDetails command

The `connectionDetails` LSP command (via `workspace/executeCommand`) returns
the connection info needed to attach a remote shell:

```json
{
  "nodeName": "expert-manager-core-41110@127.0.0.1",
  "port": 59345,
  "cookie": "expert",
  "epmdModule": "Elixir.XPForge.EPMD",
  "epmdEbinPath": "/path/to/forge/ebin",
  "debugScriptPath": "/path/to/debug_shell.sh"
}
```

Editor extensions can use `debugScriptPath` to spawn a terminal running the
debug shell with the connection details as arguments:

```sh
<debugScriptPath> <nodeName> <port> <epmdModule> <epmdEbinPath> [cookie]
```

This will connect you to a remote IEx session _inside_ the language server,
where all evaluation happens on the manager node. You can investigate processes,
make changes to the running code, or run `:observer`.

Editor integrations can use these details to launch a debug shell and some of
them may already have a builtin integration for it.

If your editor does not include one, you can manually configure it to launch the
shell on demand, for example you can add this to your neovim+lsp-config configuration
to open a new terminal pane with the debug shell, assuming you have configured the
Expert LSP client with the name `expert`:

```lua
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("kickstart-lsp-attach", { clear = true }),

  callback = function(event)
    local client = vim.lsp.get_client_by_id(event.data.client_id)

    if client.name == "expert" then
      map("<leader>ed", function()
        client:request('workspace/executeCommand', {
          command = 'connectionDetails',
          arguments = {},
        }, function(err, result)
          if err then
            vim.notify('connectionDetails failed: ' .. vim.inspect(err), vim.log.levels.ERROR)
            return
          end
          local cmd = string.format(
            '%s %s %s %s %s %s',
            result.debugScriptPath,
            result.nodeName,
            tostring(result.port),
            result.epmdModule,
            result.epmdEbinPath,
            result.cookie
          )

          vim.cmd('belowright split | terminal ' .. cmd)
        end)
      end, "Expert debug shell")
    end
  end,
})
```
