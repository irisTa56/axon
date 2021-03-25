defmodule MNIST do
  use Axon

  @default_defn_compiler {EXLA, keep_on_device: true}

  defn mish(x) do
    x * Nx.tanh(Axon.Activations.softplus(x))
  end

  def model do
    input({nil, 784})
    |> dense(128, activation: :relu)
    |> layer_norm()
    |> dropout()
    |> dense(10, activation: :softmax)
  end

  defn init, do: Axon.init(model())

  defn loss({w1, b1, w2, b2, w3, b3}, batch_images, batch_labels) do
    preds = Axon.predict(model(), {w1, b1, w2, b2, w3, b3}, batch_images)
    Nx.mean(Axon.Losses.categorical_cross_entropy(batch_labels, preds))
  end

  defn update({w1, b1, w2, b2, w3, b3}, batch_images, batch_labels, step) do
    {grad_w1, grad_b1, grad_w2, grad_b2, grad_w3, grad_b3} =
      grad({w1, b1, w2, b2, w3, b3}, &loss(&1, batch_images, batch_labels))

    {
      w1 + Axon.Updates.scale(grad_w1, -step),
      b1 + Axon.Updates.scale(grad_b1, -step),
      w2 + Axon.Updates.scale(grad_w2, -step),
      b2 + Axon.Updates.scale(grad_b2, -step),
      w3 + Axon.Updates.scale(grad_w3, -step),
      b3 + Axon.Updates.scale(grad_b3, -step)
    }
  end

  defn update_with_averages({_, _, _, _, _, _} = cur_params, imgs, tar, avg_loss, avg_accuracy, total) do
    batch_loss = loss(cur_params, imgs, tar)
    batch_accuracy = Axon.Metrics.accuracy(tar, Axon.predict(model(), cur_params, imgs))
    avg_loss = avg_loss + batch_loss / total
    avg_accuracy = avg_accuracy + batch_accuracy / total
    {update(cur_params, imgs, tar, 0.01), avg_loss, avg_accuracy}
  end

  defp unzip_cache_or_download(zip) do
    base_url = 'https://storage.googleapis.com/cvdf-datasets/mnist/'
    path = Path.join("tmp", zip)

    data =
      if File.exists?(path) do
        IO.puts("Using #{zip} from tmp/\n")
        File.read!(path)
      else
        IO.puts("Fetching #{zip} from https://storage.googleapis.com/cvdf-datasets/mnist/\n")
        :inets.start()
        :ssl.start()

        {:ok, {_status, _response, data}} = :httpc.request(:get, {base_url ++ zip, []}, [], [])
        File.mkdir_p!("tmp")
        File.write!(path, data)

        data
      end

    :zlib.gunzip(data)
  end

  def download(images, labels) do
    <<_::32, n_images::32, n_rows::32, n_cols::32, images::binary>> =
      unzip_cache_or_download(images)

    train_images =
      images
      |> Nx.from_binary({:u, 8})
      |> Nx.reshape({n_images, n_rows * n_cols})
      |> Nx.divide(255)
      |> Nx.to_batched_list(32)

    IO.puts("#{n_images} #{n_rows}x#{n_cols} images\n")

    <<_::32, n_labels::32, labels::binary>> = unzip_cache_or_download(labels)

    train_labels =
      labels
      |> Nx.from_binary({:u, 8})
      |> Nx.new_axis(-1)
      |> Nx.equal(Nx.tensor(Enum.to_list(0..9)))
      |> Nx.to_batched_list(32)

    IO.puts("#{n_labels} labels\n")

    {train_images, train_labels}
  end

  def train_epoch(cur_params, imgs, labels) do
    total_batches = Enum.count(imgs)

    imgs
    |> Enum.zip(labels)
    |> Enum.reduce({cur_params, Nx.tensor(0.0), Nx.tensor(0.0)}, fn
      {imgs, tar}, {cur_params, avg_loss, avg_accuracy} ->
        update_with_averages(cur_params, imgs, tar, avg_loss, avg_accuracy, total_batches)
    end)
  end

  def train(imgs, labels, opts \\ []) do
    epochs = opts[:epochs] || 5

    IO.puts("Initializing parameters...\n")
    params = init()

    for epoch <- 1..epochs, reduce: params do
      cur_params ->
        {time, {new_params, epoch_avg_loss, epoch_avg_acc}} =
          :timer.tc(__MODULE__, :train_epoch, [cur_params, imgs, labels])

        epoch_avg_loss =
          epoch_avg_loss
          |> Nx.backend_transfer()
          |> Nx.to_scalar()

        epoch_avg_acc =
          epoch_avg_acc
          |> Nx.backend_transfer()
          |> Nx.to_scalar()

        IO.puts("Epoch #{epoch} Time: #{time / 1_000_000}s")
        IO.puts("Epoch #{epoch} average loss: #{inspect(epoch_avg_loss)}")
        IO.puts("Epoch #{epoch} average accuracy: #{inspect(epoch_avg_acc)}")
        IO.puts("\n")
        new_params
    end
  end
end

IO.inspect MNIST.model()

{train_images, train_labels} =
  MNIST.download('train-images-idx3-ubyte.gz', 'train-labels-idx1-ubyte.gz')

IO.puts("Training MNIST for 10 epochs...\n\n")
final_params = MNIST.train(train_images, train_labels, epochs: 10)

IO.inspect(Nx.backend_transfer(final_params))
