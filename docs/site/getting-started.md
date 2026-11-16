---
title: Getting started
order: 1
---

## Download

venomx is in alpha. Each release ships two binaries:

| Platform | Download |
|---|---|
| Linux x86_64 (static, any distribution) | [venomx-x86_64-linux.tar.gz](https://github.com/venom-org/venomx/releases/latest/download/venomx-x86_64-linux.tar.gz) |
| macOS on Apple silicon (M1 and later, macOS 13 or later) | [venomx-aarch64-macos.tar.gz](https://github.com/venom-org/venomx/releases/latest/download/venomx-aarch64-macos.tar.gz) |

Both are listed in
[sha256sums.txt](https://github.com/venom-org/venomx/releases/latest/download/sha256sums.txt).
Every release, with its notes, is on the
[releases page](https://github.com/venom-org/venomx/releases).

On Linux:

```sh
curl -fsSLO https://github.com/venom-org/venomx/releases/latest/download/venomx-x86_64-linux.tar.gz
curl -fsSLO https://github.com/venom-org/venomx/releases/latest/download/sha256sums.txt
sha256sum --check --ignore-missing sha256sums.txt
tar -xzf venomx-x86_64-linux.tar.gz
mkdir -p ~/.local/bin
install -m 755 venomx-x86_64-linux/venomx ~/.local/bin/venomx
```

On macOS:

```sh
curl -fsSLO https://github.com/venom-org/venomx/releases/latest/download/venomx-aarch64-macos.tar.gz
curl -fsSLO https://github.com/venom-org/venomx/releases/latest/download/sha256sums.txt
grep venomx-aarch64-macos.tar.gz sha256sums.txt | shasum -a 256 --check
tar -xzf venomx-aarch64-macos.tar.gz
mkdir -p ~/.local/bin
install -m 755 venomx-aarch64-macos/venomx ~/.local/bin/venomx
```

The macOS binary is not notarized. `curl` doesn't mark what it downloads, so
the commands above just work. If you download the tarball with a browser
instead, macOS blocks the binary the first time it runs; clear the quarantine
flag with `xattr -d com.apple.quarantine ~/.local/bin/venomx`.

If `~/.local/bin` isn't on your `PATH`, add it to your shell's startup file
(for zsh, the macOS default: `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`).

## Build from source

venomx is written in Zig 0.17 (the exact version is in `.zigversion`).
`zig build` fetches `venom-std` and `venom-term` at the commits pinned in
`build.zig.zon`:

```sh
git clone https://github.com/venom-org/venomx
cd venomx
zig build -Doptimize=ReleaseFast
install -m 755 zig-out/bin/venomx ~/.local/bin/venomx
```

Once a daemon is running (next section), `venomx doctor` checks the config,
the socket, the key tables and the process tree, and prints a `fix` command
for each check that fails.

## Your first session

```sh
venomx
```

The bare command does three things: it starts a daemon if none is running,
creates a session named after the current directory with your login shell in
it, and attaches. The status line at the top shows the session, its windows
and the focused pane.

Press `ctrl+b` (the **leader**), wait a moment, and a popup lists the keys
you can press next. A few to start with:

| Keys | Does |
|---|---|
| `ctrl+b \` | split right |
| `ctrl+b -` | split down |
| `ctrl+b h j k l` | move focus |
| `ctrl+b c` | new window |
| `ctrl+b n` / `p` | next / previous window |
| `ctrl+b d` | detach |
| `ctrl+b ?` | search every key |

The full table is in [Keys and the attach client](keys.md).

## Detach and come back

`ctrl+b d` detaches. Your shells keep running in the daemon.

```console
$ venomx attach                 # back to the most recent session
$ venomx new --name work        # a second session, named
$ venomx new -A --name work     # attach to "work" if it exists, else create it
$ venomx new -d -- htop         # create one in the background, running htop
```

`venomx new` takes `--name`, `--cwd`, `-A`, `-d` and a trailing
`-- program args...`. Without a program it runs your login shell: `$SHELL` if
it is an absolute executable path, else the shell from the password database,
else `/bin/sh`.

Typing `exit` in the last shell of a session removes the pane, the window and
the session. When the last session goes, a daemon that `venomx` started on
its own stops too. A daemon you started with `venomx serve` keeps running; see
[Daemon lifetime](daemon.md).

## Shell integration

The status line names what runs in the focused pane. Without help it can only
see the process name (`ping`). Load the snippet for your shell and it shows
the whole command line (`ping example.com`), and the daemon learns where each
prompt and command starts, which powers jumping between commands in
scrollback and the `command.started` / `command.finished` events:

```sh
eval "$(venomx shell init --shell=zsh)"     # ~/.zshrc
eval "$(venomx shell init --shell=bash)"    # ~/.bashrc (bash 4.4+)
venomx shell init --shell=fish | source     # ~/.config/fish/config.fish
```

The snippet sends OSC 133 marks only inside a venomx pane, does nothing on a
second load, and leaves your prompt and existing hooks alone.

## Shell completions

Completions are generated from the verb schema:

```sh
venomx completions --shell zsh  > ~/.zfunc/_venomx
venomx completions --shell bash > ~/.local/share/bash-completion/completions/venomx
venomx completions --shell fish > ~/.config/fish/completions/venomx.fish
```

## Next

- Make it yours: [Configuration](configuration.md).
- Let an agent in: [Agents](agents.md).
