defmodule GrayScott.Server do
  @moduledoc """
  TCP server for the renderer: one client at a time, frames pushed as
  fast as the client reads them.

  Wire protocol, little-endian:

      frame = rows :: uint32, cols :: uint32, rows*cols bytes (V field, 0..255)

  Commands from the client, single bytes:

      0x01 - chaos: kill a random strip process
      0x02 - seed: drop new V spots

  The simulation advances only while a renderer is connected: every
  frame is `@steps_per_frame` synchronized steps followed by one field
  assembly. With `nodelay` and a frame per round trip, the pacing comes
  from the client's reads; `@frame_ms` only bounds the wait for commands.
  """
  require Logger

  alias GrayScott.Coordinator

  @steps_per_frame 6
  @frame_ms 5
  @initial_seeds 8
  @seeds_per_command 4

  @type opts :: [n_strips: pos_integer, rows_per_strip: pos_integer, cols: pos_integer, port: :inet.port_number()]

  @doc "Seeds the field, listens on the port and serves renderers forever."
  @spec start(opts) :: no_return
  def start(opts) do
    grid = %{n: opts[:n_strips], rps: opts[:rows_per_strip], cols: opts[:cols]}
    port = opts[:port] || 4041

    Coordinator.seed(grid.n, grid.cols, @initial_seeds)

    {:ok, listen} =
      :gen_tcp.listen(port, [:binary, packet: 0, active: true, reuseaddr: true, nodelay: true])

    Logger.info("gray_scott: #{grid.n} strips x #{grid.rps} rows x #{grid.cols} cols, port #{port}")
    accept_loop(listen, grid)
  end

  defp accept_loop(listen, grid) do
    {:ok, sock} = :gen_tcp.accept(listen)
    Logger.info("renderer connected")
    serve(sock, grid, %{})
    Logger.info("renderer disconnected")
    accept_loop(listen, grid)
  end

  # One frame per iteration; `cache` is the coordinator's halo cache
  defp serve(sock, grid, cache) do
    cache = Enum.reduce(1..@steps_per_frame, cache, fn _, acc -> Coordinator.step_all(grid.n, acc) end)
    field = Coordinator.render_frame(grid.n, grid.rps, grid.cols)
    header = <<grid.n * grid.rps::32-little, grid.cols::32-little>>

    case :gen_tcp.send(sock, [header, field]) do
      :ok ->
        receive do
          {:tcp, ^sock, data} ->
            serve(sock, grid, handle_commands(data, grid, cache))

          {:tcp_closed, ^sock} ->
            :ok

          {:tcp_error, ^sock, reason} ->
            Logger.warning("renderer socket error: #{inspect(reason)}")
            :ok
        after
          @frame_ms -> serve(sock, grid, cache)
        end

      {:error, _closed} ->
        :ok
    end
  end

  # Applies every command byte in the packet; returns the halo cache,
  # dropped when a command changed the cells
  defp handle_commands(<<>>, _grid, cache), do: cache

  defp handle_commands(<<0x01, rest::binary>>, grid, _cache) do
    Coordinator.chaos(grid.n)
    handle_commands(rest, grid, %{})
  end

  defp handle_commands(<<0x02, rest::binary>>, grid, _cache) do
    Coordinator.seed(grid.n, grid.cols, @seeds_per_command)
    handle_commands(rest, grid, %{})
  end

  defp handle_commands(<<byte, rest::binary>>, grid, cache) do
    Logger.debug("ignoring unknown command byte #{byte}")
    handle_commands(rest, grid, cache)
  end
end
