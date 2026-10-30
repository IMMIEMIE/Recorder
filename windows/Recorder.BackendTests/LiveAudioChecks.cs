using System.Text.Json.Nodes;
using Recorder.Backend;
internal static class LiveAudioChecks
{
    public static void Run(Action<bool, string> check)
    {
        JsonObject Event(string type, string item, string id, byte[]? bytes = null) => new() { ["type"] = type, ["item_id"] = item, ["event_id"] = id, ["delta"] = Convert.ToBase64String(bytes ?? []) };
        var decoder = new LiveAudioDecoder(); var first = Event("response.audio.delta", "a", "1", [1, 2, 3]);
        check(decoder.Consume(first)!.SequenceEqual(new byte[] { 1, 2 }) && decoder.Consume(first) == null, "audio decoder filters duplicate events and retains odd-byte sample tail");
        check(decoder.Consume(Event("response.audio.delta", "a", "2", [4]))!.SequenceEqual(new byte[] { 3, 4 }), "audio decoder joins PCM16 samples across messages");
        decoder.Consume(Event("response.audio.done", "a", "3")); check(decoder.Consume(Event("response.audio.delta", "a", "4", [5, 6])) == null, "completed output cannot replay late audio deltas");
        decoder.Consume(Event("response.audio.delta", "b", "5", [1])); bool failed = false; try { decoder.Consume(Event("response.audio.done", "b", "6")); } catch (InvalidDataException) { failed = true; }
        check(failed, "incomplete final PCM sample reports recoverable audio failure");
        var queue = new LivePlaybackQueue(true);
        queue.Consume(Event("response.audio.delta", "out-b", "7", [3, 4]), []); queue.Consume(Event("response.audio.done", "out-b", "8"), []);
        LiveRowState[] rows = [new("a", false, "First", ["out-a"], false), new("b", true, "Second", ["out-b"], true)];
        check(queue.Consume(new JsonObject(), rows).Count == 0, "final playback never overtakes an earlier incomplete source");
        queue.Consume(Event("response.audio.delta", "out-a", "9", [1, 2]), rows); queue.Consume(Event("response.audio.done", "out-a", "10"), rows);
        rows[0] = rows[0] with { SourceDone = true, TranslationDone = true };
        var audio = queue.Consume(new JsonObject(), rows);
        check(audio.Count == 2 && audio[0][0] == 1 && audio[1][0] == 3 && !queue.HasPending, "audio arriving before association releases once in source order");
        check(queue.Consume(new JsonObject(), rows).Count == 0, "final playback does not release the same output twice");
        failed = false; try { new LivePlaybackQueue(true).Consume(Event("response.audio.delta", "big", "11", new byte[1_440_002]), []); } catch (InvalidDataException) { failed = true; }
        check(failed, "pending final playback is bounded to thirty seconds");
        var cache = new LiveReplayCache(8);
        for (int i = 0; i < 3; i++)
        {
            string output = "o" + i; cache.Consume(Event("response.audio.delta", output, "d" + i, [1, 2, 3, 4]), [], "s");
            cache.Consume(Event("response.audio.done", output, "e" + i), [new("r" + i, true, "source", [output], true)], "s");
        }
        check(cache.Get("s:live:r0") == null && cache.Get("s:live:r2")?.Length == 4 && cache.Bytes == 8, "replay cache evicts oldest clips within its memory capacity");
        cache.BeginSession(); check(cache.Get("s:live:r2") != null, "completed replay survives recording restart");
        cache.Consume(Event("response.audio.delta", "huge", "12", new byte[10]), [], "new"); cache.Consume(Event("response.audio.done", "huge", "13"), [new("r", true, "source", ["huge"], true)], "new");
        check(cache.Get("new:live:r") == null && cache.Bytes <= 8, "replay rejects oversized clips instead of caching truncated sound");
        cache.Clear(); check(cache.Bytes == 0 && cache.Get("s:live:r2") == null, "clearing history frees pending and completed replay PCM");
    }
}
