defmodule MagusWeb.Workbench.UploadHelpers do
  @moduledoc """
  Shared upload limits. Originates from the classic workbench upload
  pipeline; the SPA RPC controllers (`MagusWeb.Rpc.UploadController`,
  `MagusWeb.Rpc.ImageController`) enforce the same size cap.
  """

  @max_uploads 10
  @max_file_size 50_000_000

  @doc "Maximum number of files allowed in a single upload batch."
  def max_uploads, do: @max_uploads

  @doc "Maximum file size in bytes."
  def max_file_size, do: @max_file_size
end
