defmodule GrayScott.Application do
  @moduledoc """
  Supervision tree. Grid: `@n_strips` horizontal strips of `@rows_per_strip`
  rows, `@cols` columns. Each strip is a permanent worker: kill one and it
  restarts blank - the pattern heals from the neighbours.

      Registry (unique keys: strip index -> pid)
      Strip 0 .. Strip 7
      Server  (Task: seeds the field, accepts one renderer at a time)
  """
  use Application

  @n_strips 8
  @rows_per_strip 16
  @cols 128
  @port 4041

  @impl true
  def start(_type, _args) do
    strips =
      for i <- 0..(@n_strips - 1) do
        Supervisor.child_spec({GrayScott.Strip, {i, @rows_per_strip, @cols}}, id: {:strip, i})
      end

    server =
      Supervisor.child_spec(
        {Task,
         fn ->
           GrayScott.Server.start(
             n_strips: @n_strips,
             rows_per_strip: @rows_per_strip,
             cols: @cols,
             port: @port
           )
         end},
        id: GrayScott.Server,
        restart: :permanent
      )

    children = [{Registry, keys: :unique, name: GrayScott.Registry}] ++ strips ++ [server]

    # Generous restart intensity: chaos mode kills strips on purpose
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: GrayScott.Supervisor,
      max_restarts: 100,
      max_seconds: 1
    )
  end
end
