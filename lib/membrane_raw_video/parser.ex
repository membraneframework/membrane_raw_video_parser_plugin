defmodule Membrane.RawVideo.Parser do
  @moduledoc """
  Simple module responsible for splitting the incoming buffers into
  frames of raw (uncompressed) video frames of desired format.

  The parser sends proper stream_format when moves to playing state.
  No data analysis is done, this element simply ensures that
  the resulting packets have proper size.
  """
  use Membrane.Filter
  alias Membrane.{Buffer, Payload}
  alias Membrane.{RawVideo, RemoteStream}

  def_input_pad :input, accepted_format: RemoteStream

  def_output_pad :output, accepted_format: %RawVideo{aligned: true}

  def_options pixel_format: [
                spec: RawVideo.pixel_format(),
                description: """
                Format used to encode pixels of the video frame.
                """
              ],
              width: [
                spec: pos_integer(),
                description: """
                Width of a frame in pixels.
                """
              ],
              height: [
                spec: pos_integer(),
                description: """
                Height of a frame in pixels.
                """
              ],
              framerate: [
                spec: RawVideo.framerate(),
                default: {0, 1},
                description: """
                Framerate of video stream. Passed forward in stream_format.
                """
              ]

  @supported_formats [:I420, :I422, :I444, :RGB, :BGRA, :RGBA, :NV12, :NV21, :YV12, :AYUV, :YUY2]

  @impl true
  def handle_init(_ctx, opts) do
    unless opts.pixel_format in @supported_formats do
      raise """
      Unsupported frame pixel format: #{inspect(opts.pixel_format)}
      The elements supports: #{Enum.map_join(@supported_formats, ", ", &inspect/1)}
      """
    end

    frame_size =
      case RawVideo.frame_size(opts.pixel_format, opts.width, opts.height) do
        {:ok, frame_size} ->
          frame_size

        {:error, :invalid_dimensions} ->
          raise "Provided dimensions (#{opts.width}x#{opts.height}) are invalid for #{inspect(opts.pixel_format)} pixel format"
      end

    stream_format = %RawVideo{
      pixel_format: opts.pixel_format,
      width: opts.width,
      height: opts.height,
      framerate: opts.framerate,
      aligned: true
    }

    {num, denom} = stream_format.framerate
    frame_duration = if num == 0, do: 0, else: Ratio.new(denom * Membrane.Time.second(), num)

    {[],
     %{
       stream_format: stream_format,
       timestamp: Ratio.new(0),
       frame_duration: frame_duration,
       frame_size: frame_size,
       queue: []
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, state.stream_format}], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    # Do not forward stream_format
    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    %{frame_size: frame_size} = state

    payload = Payload.to_binary(buffer.payload)

    queue = [payload | state.queue]
    size = IO.iodata_length(queue)

    if size < frame_size do
      {[], %{state | queue: queue}}
    else
      data_binary = queue |> Enum.reverse() |> IO.iodata_to_binary()

      {payloads, tail} = Bunch.Binary.chunk_every_rem(data_binary, frame_size)

      {bufs, state} =
        payloads
        |> Enum.map_reduce(state, fn payload, state_acc ->
          timestamp = state_acc.timestamp |> Ratio.floor()
          {%Buffer{payload: payload, pts: timestamp}, bump_timestamp(state_acc)}
        end)

      {[buffer: {:output, bufs}], %{state | queue: [tail]}}
    end
  end

  defp bump_timestamp(%{stream_format: %{framerate: {0, _denominator}}} = state) do
    state
  end

  defp bump_timestamp(state) do
    %{timestamp: timestamp, frame_duration: frame_duration} = state
    timestamp = Ratio.add(timestamp, frame_duration)
    %{state | timestamp: timestamp}
  end
end
