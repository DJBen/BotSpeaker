namespace BotSpeaker;

/// <summary>FIFO gate shared by synthesis clients. Cache hits bypass it.</summary>
internal sealed class SpeechSynthesisQueue
{
    private readonly object _sync = new();
    private readonly int _limit;
    private int _active;
    private readonly LinkedList<TaskCompletionSource> _waiting = new();

    public SpeechSynthesisQueue(int limit)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(limit);
        _limit = limit;
    }

    public async Task AcquireAsync(CancellationToken cancellation = default)
    {
        LinkedListNode<TaskCompletionSource> node;
        lock (_sync)
        {
            cancellation.ThrowIfCancellationRequested();
            if (_active < _limit)
            {
                _active++;
                return;
            }
            node = _waiting.AddLast(new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously));
        }
        using var registration = cancellation.Register(() =>
        {
            lock (_sync)
            {
                if (node.List is null) return; // Already granted; the caller releases it.
                _waiting.Remove(node);
                node.Value.SetCanceled(cancellation);
            }
        });
        await node.Value.Task;
    }

    public void Release()
    {
        lock (_sync)
        {
            if (_waiting.First is { } node)
            {
                _waiting.RemoveFirst();
                node.Value.SetResult(); // Transfer this occupied slot to the oldest waiter.
            }
            else
            {
                _active--;
            }
        }
    }
}
