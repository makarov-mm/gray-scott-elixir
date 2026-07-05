defmodule GrayScott.Server do
  @moduledoc """
  TCP server for the renderer (Swift/Metal or the Python test client).

  Wire protocol, little-endian:

      frame = rows :: uint32, cols :: uint32, rows*cols bytes (V field, 0..255)

  Commands from the client, single bytes:

      0x01 — chaos: kill a random strip process
      0x02 — seed: drop new V spots
  """
  require Logger

  @steps_per_frame 6
  @frame_ms 5

  def start(opts) do
    n_strips = opts[:n_strips]
    rows_per_strip = opts[:rows_per_strip]
    cols = opts[:cols]
    port = opts[:port] || 4041

    GrayScott.Coordinator.seed(n_strips, cols, 8)

    {:ok, lsock} =
      :gen_tcp.listen(port, [:binary, packet: 0, active: true, reuseaddr: true, nodelay: true])

    Logger.info("gray_scott: #{n_strips} strips x #{rows_per_strip} rows x #{cols} cols, port #{port}")
    accept_loop(lsock, n_strips, rows_per_strip, cols)
  end

  defp accept_loop(lsock, n, rps, cols) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    Logger.info("renderer connected")
    client_loop(sock, n, rps, cols)
    Logger.info("renderer disconnected")
    accept_loop(lsock, n, rps, cols)
  end

  defp client_loop(sock, n, rps, cols) do
    for _ <- 1..@steps_per_frame, do: GrayScott.Coordinator.step_all(n)

    field = GrayScott.Coordinator.render_frame(n, rps, cols)
    rows = n * rps
    header = <<rows::32-little, cols::32-little>>

    case :gen_tcp.send(sock, [header, field]) do
      :ok ->
        receive do
          {:tcp, ^sock, data} ->
            handle_commands(data, n, cols)
            client_loop(sock, n, rps, cols)

          {:tcp_closed, ^sock} -> :ok
          {:tcp_error, ^sock, _} -> :ok
        after
          @frame_ms -> client_loop(sock, n, rps, cols)
        end

      {:error, _} ->
        :ok
    end
  end

  defp handle_commands(<<>>, _n, _cols), do: :ok

  defp handle_commands(<<0x01, rest::binary>>, n, cols) do
    GrayScott.Coordinator.chaos(n)
    handle_commands(rest, n, cols)
  end

  defp handle_commands(<<0x02, rest::binary>>, n, cols) do
    GrayScott.Coordinator.seed(n, cols, 4)
    handle_commands(rest, n, cols)
  end

  defp handle_commands(<<_, rest::binary>>, n, cols),
    do: handle_commands(rest, n, cols)
end
