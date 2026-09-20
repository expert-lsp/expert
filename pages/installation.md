# Installation

The following instructions document how to install Expert after
building from source. Some editors, like Visual Studio Code, have the
ability to automatically install the latest version of Expert for
you.

Expert aims to support Elixir versions `1.15.3` with Erlang `25.0` and later.
**You must compile Expert under the lowest version of Elixir and Erlang that you intend to use in your projects.**

Caveats with the following versions of Elixir and Erlang are documented below:

| Elixir   | Version Range  | Notes    |
| -------- | -------------- | -------- |
| 1.19     | `>= 1.19.0`    |          |
| 1.18     | `>= 1.18.0`    |          |
| 1.17     | `>= 1.17.0`    |          |
| 1.16     | `>= 1.16.0`    |          |
| 1.15     | `>= 1.15.3`    | `1.15.0` - `1.15.2` have compiler bugs that prevent Expert from working. |

| Erlang      | Version range    | Notes  |
| ----------- |----------------- | ------ |
|  27         | `>= 27.0`        | Expert will use dramatically more memory due to a bug in Erlang's ETS table compression.  |
|  26         | `>= 26.0.2`      |        |
|  25         | `>= 25.0`        |        |

## Building a release

If you see errors while building a release, please file a bug.

### Prerequisites

- Install Git LFS by [following these instructions](https://docs.github.com/en/repositories/working-with-files/managing-large-files/installing-git-large-file-storage)
- Install [`just`](https://github.com/casey/just?tab=readme-ov-file#cross-platform)
- (Burrito only) Install [Zig `0.15.2`](https://ziglang.org/learn/getting-started/)

> [!IMPORTANT]
> Later versions of Zig will not work. If you are on macOS,
> this version will only work with Xcode 26.3 **at most**.

Then, clone the git repository. Do this with

```sh
git clone git@github.com:expert-lsp/expert.git
```

Then, change to the expert directory

```sh
cd expert
```

### Plain release

Build the project as a plain release with

```sh
just release
```

If things complete successfully, you will then find the generated `start_expert`
executable in your `apps/expert/_build/prod/rel/plain/bin` directory.

In case you want to build and install it locally, you can run `just install`,
which will install the release to `~/.local/libexec/expert` and symlink `start_expert`
to `~/.local/bin/expert`. You can install it somewhere other than `~/.local` with the
`--prefix` flag.

### Burrito release

Build the project as a burrito release with

```sh
just burrito-local
```

If things complete successfully, you will then have a binary with the name
`expert_<os>_<arch>` in your `apps/expert/burrito_out` directory. You will need
to run `chmod +x expert_<os>_<arch>` to be able to use it.

## Editor-specific setup

To launch expert, you need to specify `--stdio` or `--port <port>`.

The examples below assume you want to use `--stdio`, that the absolute path to your
Expert source code is `/my/home/projects/expert`, and that you are running an amd64
Linux system. For other systems, replace the `expert_linux_amd64` with the
appropriate binary name.

1. [Vanilla Emacs with lsp-mode](#vanilla-emacs-with-lsp-mode)
2. [Vanilla Emacs with eglot](#vanilla-emacs-with-eglot)
3. [Doom Emacs with lsp-mode](#doom-emacs-with-lsp-mode)
4. [Visual Studio Code](#visual-studio-code)
5. [neovim](#neovim)
6. [Vim + Vim-LSP](#vim--vim-lsp)
7. [Helix](#helix)
8. [Sublime Text](#sublime-text)
9. [Zed](#zed)
10. [Termux](#termux)

### Vanilla Emacs with lsp-mode
The emacs instructions assume you're using `use-package`, which you
really should be. In your `.emacs.d/init.el` (or wherever you put your
emacs configuration), insert the following code:

```lisp
(use-package lsp-mode
  :ensure t
  :config
  (setq lsp-modeline-code-actions-segments '(count icon name))

  :init
  '(lsp-mode))


(use-package elixir-mode
  :ensure t
  :custom
  (lsp-elixir-server-command '("expert_linux_amd64" "--stdio")))
```

Restart emacs, and Expert should start when you open a file with a
`.ex` extension.

### Vanilla Emacs with eglot

You can add Expert support in the following way:

```emacs-lisp
(with-eval-after-load 'eglot
  (setf (alist-get '(elixir-mode elixir-ts-mode heex-ts-mode)
                   eglot-server-programs
                   nil nil #'equal)
        (if (and (fboundp 'w32-shell-dos-semantics)
                 (w32-shell-dos-semantics))
            '(("expert_windows_amd64" "--stdio"))
          (eglot-alternatives
           '(("expert_linux_amd64" "--stdio"))))))
```

For versions before 30, you can add Eglot support for Expert in the
following way:

```emacs-lisp
(with-eval-after-load 'eglot
  (setf (alist-get 'elixir-mode eglot-server-programs)
        (if (and (fboundp 'w32-shell-dos-semantics)
                 (w32-shell-dos-semantics))
            '(("expert_windows_amd64" "--stdio"))
          (eglot-alternatives
           '(("expert_linux_amd64" "--stdio"))))))
```

If you're using `elixir-ts-mode` on Emacs 29, you can add a new entry
for Eglot:

```emacs-lisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               `((elixir-ts-mode heex-ts-mode) .
                 ,(if (and (fboundp 'w32-shell-dos-semantics)
                           (w32-shell-dos-semantics))
                      '(("expert_windows_amd64" "--stdio"))
                    (eglot-alternatives
                     '(("expert_linux_amd64" "--stdio")))))))
```

### Doom Emacs with lsp-mode
Go to your `~/.config/doom/init.el` and change the following lines:

```emacs-lisp
(doom!
       :tools
       ; (lsp +eglot)
       (lsp)
       
       :lang
       (elixir)
```

Then run `~/.config/emacs/bin/doom sync`.

Then add this to your `~/.config/doom/config.el`

```emacs-lisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration
               '(elixir-mode . "elixir"))

  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection '("expert" "--stdio"))
    ; :major-modes '(elixir-mode)
    :priority -1
    :activation-fn (lsp-activate-on "elixir")
    :server-id 'expert))
  )

(add-hook 'elixir-mode-hook #'lsp)
```

Restart emacs, and Expert should start when you open a file with a
`.ex` extension.

### Visual Studio Code

> [!NOTE]
> Support for VS Code is a work in progress.

Clone and build the [Expert VS Code extension](https://github.com/expert-lsp/vscode-expert).
Once you have the `.vsix` file, you can install it by using the `Extensions: Install from VSIX...` command in the command palette.


To change to a local executable, go to `Settings -> Extensions -> Expert` and
type `/my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64` into the text box in
the `Server: Release path override` section.

To run in TCP mode, you can add `--port PORT` in the `Server: Startup Flags Override` section.


> [!TIP]
> If you are using the Lexical extension for VS Code, you will need to wrap the
> expert executable with a script that passes the `--stdio` flag, as Lexical
> does not currently support passing additional arguments to language servers.
>
> For example, create a file called `expert_wrapper.sh` with the following content:
> ```bash
> #!/bin/bash
> ~/.local/bin/expert_linux_amd64 --stdio
> ```
> Make the script executable with `chmod +x expert_wrapper.sh`, and then
> set the `Server: Release path override` to the path of the script.

### Neovim

Expert requires neovim `>= 0.9.0`.

In version `>= 0.9.0`, the key is to append the custom LS
configuration to
[lspconfig](https://github.com/neovim/nvim-lspconfig), so regardless
of whether you are using mason or others, you can use this
configuration below as a reference:

```lua
require('lspconfig').lexical.setup {
  cmd = { "my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64", "--stdio" },
  root_dir = function(fname)
    return require('lspconfig').util.root_pattern("mix.exs", ".git")(fname) or vim.loop.cwd()
  end,
  filetypes = { "elixir", "eelixir", "heex" },
  -- optional settings
  settings = {}
}
```

As of neovim `0.11.3`, you can use the built-in lsp config:
```lua
vim.lsp.config('expert', {
  cmd = { 'expert', '--stdio' },
  root_markers = { 'mix.exs', '.git' },
  filetypes = { 'elixir', 'eelixir', 'heex' },
})

vim.lsp.enable 'expert'
```

If you are using `nvim-lspconfig` this should be handled automatically.

### Vim + Vim-LSP

An example of configuring Expert as the Elixir language server for
[Vim-LSP](https://github.com/prabirshrestha/vim-lsp). Uses the newer vim9script syntax but
can be converted to Vim 8 etc (`:h vim9script`).

```vim9script

# Loading vim-lsp with minpac:
call minpac#add("prabirshrestha/vim-lsp")
# ...or use your package manager of choice/Vim native packages

# Useful for debugging vim-lsp:
# g:lsp_log_verbose = 1
# g:lsp_log_file = expand('~/vim-lsp.log')

# Configure as the elixir language server
if executable("elixir")
    augroup lsp_expert
    autocmd!
    autocmd User lsp_setup call lsp#register_server({ name: "expert", cmd: (server_info) => "{{path_to_expert}}/expert/apps/expert/burrito_out/expert_linux_amd64", allowlist: ["elixir", "eelixir"] })
    autocmd FileType elixir setlocal omnifunc=lsp#complete
    autocmd FileType eelixir setlocal omnifunc=lsp#complete
    augroup end
endif

```

If you use [Vim-LSP-Settings](mattn/vim-lsp-settings) for installing and configuring language servers,
you can use the following flag to disable prompts to install elixir-ls:

```viml
g:lsp_settings_filetype_elixir = ["expert"]

```

For more config, debugging help, or getting vim-lsp to work with ALE, see
[this example vimrc](https://github.com/jHwls/dotfiles/blob/4425a4feef823512d96b92e5fd64feaf442485c9/vimrc#L239).

### Helix

> [!NOTE]
> This co!nfiguration is applicable for Helix version 23.09 and above.*

Add the language server to your `~/.config/helix/languages.toml` config.
In the case that the file doesn't exist yet, you can create a new file at this location.

```toml
[language-server.expert]
command = "/my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64"
args = ["--stdio"]

[[language]]
name = "elixir"
language-servers = ["expert"]

[[language]]
name = "heex"
language-servers = ["expert"]
```

### Sublime Text

#### Background

Expert can be used with Sublime Text via the [LSP-Sublime](https://lsp.sublimetext.io/) package, which integrates Language Servers with Sublime Text. If you don't have the LSP-Sublime package installed already, [install it with Package Control](https://packagecontrol.io/packages/LSP).

There is currently no [language server package](https://lsp.sublimetext.io/language_servers/) specifically for Expert that works with LSP-Sublime so we'll need to create a [custom client configuration](https://lsp.sublimetext.io/client_configuration/).

#### Installation
First, install LSP-Sublime with Package Control if you haven't already.

Next, open up the LSP settings in Sublime. You can do this by invoking the command palette (`ctrl/cmd + shift + p`) and selecting `Preferences: LSP Settings`.

You'll need to add a key called `"clients"` in the top-level `LSP.sublime-settings` JSON dictionary that is as follows:

```json
"clients": {
  "elixir-expert": {
    "enabled": true,
    "command": ["/my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64", "--stdio"],
    "selector": "source.elixir"
  }
}
```
_note: you can name elixir-expert whatever you like, it's just for your own identification_

Upon saving the configuration, LSP-Sublime should enable the new `elixir-expert` LSP server. Go into an Elixir file and you should now see `elixir-expert` in the lower left of the status bar. If not, invoke the command palette and select `LSP: Enable Language Server Globally/In Project` and it should run.

### Zed

Zed [supports Expert](https://zed.dev/docs/languages/elixir) through the [Elixir extension](https://github.com/zed-extensions/elixir).

So, first install the extension and then update your `settings.json` to use Expert as language server:

```json
{
  "lsp": {
    "expert": {
      "binary": {
        "arguments": ["--stdio"]
      }
    }
  },
  "languages": {
    "Elixir": {
      "language_servers": [
        "expert",
        "!elixir-ls",
        "!lexical",
        "..."
      ]
    }
  }
}
```

The Elixir extension will [download the latest Expert release](https://github.com/zed-extensions/elixir/blob/96fd0581d84cfac857a23c1351e2405836de39fd/src/language_servers/expert.rs#L65) and keep it updated. So, you don't need to manually download and update the expert release yourself.

### Termux

If using Termux, you will need to wrap Expert with `termux-chroot`. Expert distributables uses `erlexec`, which expects `/tmp` to be accessible. Termux does not provide access to it, resulting in `error: FileNotFound` being printed when launching Expert.

To workaround this, first install the `proot` package:

```sh
pkg install proot
```

Then launch Expert with `termux-chroot`:

```sh
termux-chroot expert --help
```

