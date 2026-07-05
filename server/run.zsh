#!/bin/zsh
# run.zsh — compile and start the Gray-Scott server, no Mix project needed.
# Run from the server/ directory:
#   server % ./run.zsh
# Requires Elixir (brew install elixir).

set -euo pipefail

mkdir -p ebin
elixirc -o ebin ./*.ex

exec elixir -pa ebin -e '
{:ok, _} = GrayScott.Application.start(:normal, [])
Process.sleep(:infinity)
'
