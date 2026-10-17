#include "whisper.h"
#include <atomic>
#include <algorithm>
#include <string>
#include <thread>
#include <cstdio>

struct Engine {
    whisper_context *ctx = nullptr;
    std::atomic<bool> cancel{false};
    std::string text;
};
static void quiet(ggml_log_level, const char *, void *) {}
extern "C" {
__declspec(dllexport) Engine *__cdecl recorder_create(const wchar_t *path) {
    try {
    // Open with UTF-16: Windows user/model directories often contain Chinese characters.
    FILE *file = _wfopen(path, L"rb");
    if (!file) return nullptr;
    whisper_model_loader loader{};
    loader.context = file;
    loader.read = [](void *p, void *data, size_t size) { return fread(data, 1, size, (FILE *)p); };
    loader.eof = [](void *p) { return feof((FILE *)p) != 0; };
    loader.close = [](void *p) { fclose((FILE *)p); };
    whisper_log_set(quiet, nullptr);
    auto params = whisper_context_default_params();
    params.use_gpu = false;
    auto ctx = whisper_init_with_params(&loader, params);
    if (!ctx) return nullptr;
    auto engine = new Engine;
    engine->ctx = ctx;
    return engine;
    } catch (...) { return nullptr; }
}
__declspec(dllexport) void __cdecl recorder_destroy(Engine *e) {
    if (e) { whisper_free(e->ctx); delete e; }
}
__declspec(dllexport) void __cdecl recorder_cancel(Engine *e) { if (e) e->cancel = true; }
__declspec(dllexport) void __cdecl recorder_reset(Engine *e) { if (e) e->cancel = false; }
__declspec(dllexport) const char *__cdecl recorder_transcribe(Engine *e, const float *pcm, int count, const char *language) {
    if (!e || !pcm || count <= 0) return nullptr;
    try {
    auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = std::max(1, std::min(4, (int)std::thread::hardware_concurrency()));
    p.language = language;
    p.no_context = true;
    p.print_realtime = false; p.print_progress = false;
    p.print_timestamps = false; p.print_special = false;
    p.abort_callback = [](void *data) { return ((Engine *)data)->cancel.load(); };
    p.abort_callback_user_data = e;
    if (whisper_full(e->ctx, p, pcm, count) != 0 || e->cancel) return nullptr;
    e->text.clear();
    for (int i = 0; i < whisper_full_n_segments(e->ctx); ++i)
        e->text += whisper_full_get_segment_text(e->ctx, i);
    return e->text.c_str();
    } catch (...) { return nullptr; }
}
}
