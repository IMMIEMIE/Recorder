using System.Text.Json.Nodes;
namespace Recorder.Backend;

public sealed partial class BackendCore
{
    private partial bool HasTranslation => false;
    private partial Task TranslationStepAsync() => Task.CompletedTask;
    private partial async Task LoadTranslatorAsync(TranslationConfig next, RuntimeConfig nextRuntime, EngineModel? resolved)
    {
        try
        {
            resolved ??= resolver.Resolve(next, nextRuntime).Model;
            await translator.LoadAsync(resolved, lifetime.Token);
            lock (gate) TranslatorStatus("warming");
            await translator.WarmupAsync(lifetime.Token);
            store.SaveSelection(next with { Enabled = true }, nextRuntime);
            lock (gate) { runtime = nextRuntime; translation = next with { Enabled = true }; TranslatorStatus("ready"); }
        }
        catch (Exception ex) { await translator.UnloadAsync(); lock (gate) { TranslatorStatus("error", ex.Message); } }
    }
    private partial void MaybeLoadTranslator()
    {
        if (translation.Enabled && translation.Provider == "local" && !translator.IsLoaded && translatorState is not ("loading" or "warming"))
        { TranslatorStatus("loading"); var current = translation; var options = runtime; Queue(() => LoadTranslatorAsync(current, options)); }
    }
    private partial void SetTranslation(JsonObject message)
    {
        if (translatorState is "loading" or "warming" or "downloading") throw new InvalidOperationException("请等待翻译模型操作结束。");
        var values = BackendJson.Object(translation);
        foreach (var key in new[] { "enabled", "target_language", "provider", "api_profile" }) if (message[key] is JsonNode value) values[key] = value.DeepClone();
        var next = BackendJson.Parse<TranslationConfig>(values);
        store.Save("translation.json", next); translation = next;
        if (!next.Enabled || next.Provider == "api") Queue(async () => { await translator.UnloadAsync(); lock (gate) TranslatorStatus("idle"); });
        else MaybeLoadTranslator();
        TranslatorStatus(translatorState);
    }
}
