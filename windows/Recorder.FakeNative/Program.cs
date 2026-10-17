using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;

// Mirrors native-host/main.cpp: one reader thread (cancel bypasses the queue), one serialized worker, at most 8 queued requests.
// Timing and fault knobs come from the environment so tests can reproduce races without models or a GPU.
if (args.Length != 2 || args[0] != "--pipe") return 2;
int tokenMs = Env("FAKE_TOKEN_MS", 15), loadMs = Env("FAKE_LOAD_MS", 40), asrMs = Env("FAKE_ASR_MS", 20), exitAfterTokens = Env("FAKE_EXIT_AFTER_TOKENS", 0);
string exitOnLanguage = Environment.GetEnvironmentVariable("FAKE_EXIT_ON_LANGUAGE") ?? "";
using var pipe = new NamedPipeClientStream(".", args[1], PipeDirection.InOut, PipeOptions.Asynchronous);
try { pipe.Connect(15000); } catch { return 3; }
long active = 0, cancelled = 0;
var queue = new BlockingCollection<(JsonObject Value, byte[] Pcm)>();
var writeLock = new object();
var reader = new Thread(() =>
{
    try
    {
        for (;;)
        {
            var header = new byte[4]; pipe.ReadExactly(header); int n = BinaryPrimitives.ReadInt32LittleEndian(header);
            if (n is <= 0 or > 1024 * 1024) throw new InvalidDataException("Invalid frame size");
            var raw = new byte[n]; pipe.ReadExactly(raw); var value = JsonNode.Parse(raw)!.AsObject();
            if ((int?)value["rpc_version"] != 1) throw new InvalidDataException("Protocol mismatch");
            int bytes = (int?)value["payload_bytes"] ?? 0; if (bytes is < 0 or > 800000 || bytes % 2 != 0) throw new InvalidDataException("Invalid audio size");
            var pcm = new byte[bytes]; if (bytes > 0) pipe.ReadExactly(pcm);
            if ((string?)value["command"] == "cancel") { Interlocked.Exchange(ref cancelled, (long)value["target_id"]!); continue; }
            if (queue.Count >= 8) throw new InvalidOperationException("Request queue full");
            queue.Add((value, pcm));
        }
    }
    catch { }
    Interlocked.Exchange(ref cancelled, Interlocked.Read(ref active)); queue.CompleteAdding();
}) { IsBackground = true };
reader.Start();
bool Aborted() { long a = Interlocked.Read(ref active); return a != 0 && Interlocked.Read(ref cancelled) == a; }
void CheckCancel() { if (Aborted()) throw new OperationCanceledException("cancelled"); }
void Work(int ms) { for (int i = 0; i < ms; i += 2) { CheckCancel(); Thread.Sleep(2); } CheckCancel(); }
string kind = "", device = "";
byte[] script = Encoding.UTF8.GetBytes("Hello 世界，这是译文。"); int position = -1, remaining = 0, produced = 0;
foreach (var (value, pcm) in queue.GetConsumingEnumerable())
{
    long id = (long)value["id"]!; Interlocked.Exchange(ref active, id);
    var response = new JsonObject { ["rpc_version"] = 1, ["id"] = id };
    try
    {
        CheckCancel(); var result = new JsonObject();
        switch ((string?)value["command"])
        {
            case "hello": result["cuda_build"] = false; result["cuda_available"] = false; break;
            case "memory": result["devices"] = new JsonArray(); break;
            case "load":
                kind = ""; Work(loadMs); string path = (string)value["path"]!;
                if (path.Contains("missing")) throw new InvalidOperationException("GGUF model load failed");
                kind = (string)value["engine"]!; device = (string?)value["device"] ?? "cpu"; result["device"] = device; break;
            case "unload": kind = ""; position = -1; break;
            case "asr":
                if (kind is not ("qwen" or "whisper")) throw new InvalidOperationException("ASR model not loaded");
                if (pcm.Length == 0 || pcm.Length > 25 * 32000) throw new InvalidOperationException("Audio input must be 0..25 seconds");
                string language = (string?)value["language"] ?? "auto";
                if (exitOnLanguage.Length > 0 && language == exitOnLanguage) Environment.Exit(unchecked((int)0xC0000005));
                Work(asrMs); result["text"] = language == "auto" ? "测试" : "测试(" + language + ")"; break;
            case "begin":
                if (kind is "" or "qwen" or "whisper") throw new InvalidOperationException("Translation model not loaded");
                if (value["messages"] is not JsonArray { Count: > 0 }) throw new InvalidOperationException("Unsupported chat template");
                Work(tokenMs); position = 0; remaining = (int?)value["max_tokens"] ?? 512; break;
            case "next":
                if (position < 0) throw new InvalidOperationException("Generation not started");
                Work(tokenMs);
                // Two-byte pieces split multi-byte UTF-8 characters across tokens, like real BPE output.
                if (remaining-- <= 0 || position >= script.Length) { result["token_bytes"] = new JsonArray(); result["done"] = true; position = -1; break; }
                var piece = script.AsSpan(position, Math.Min(2, script.Length - position)).ToArray(); position += piece.Length;
                if (exitAfterTokens > 0 && ++produced >= exitAfterTokens) Environment.Exit(unchecked((int)0xC0000409));
                result["token_bytes"] = new JsonArray(piece.Select(b => (JsonNode)(int)b).ToArray()); result["done"] = false; break;
            case "end": position = -1; remaining = 0; break;
            default: throw new InvalidOperationException("Unknown command");
        }
        response["result"] = result;
    }
    catch (OperationCanceledException) { response["error"] = "cancelled"; }
    catch (Exception ex) { response["error"] = ex.Message; }
    Interlocked.Exchange(ref active, 0);
    var bytesOut = Encoding.UTF8.GetBytes(response.ToJsonString()); var length = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(length, bytesOut.Length);
    try { lock (writeLock) { pipe.Write(length); pipe.Write(bytesOut); pipe.Flush(); } } catch { break; }
}
return 0;

static int Env(string name, int fallback) => int.TryParse(Environment.GetEnvironmentVariable(name), out int value) ? value : fallback;
