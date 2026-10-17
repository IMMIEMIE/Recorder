#include <windows.h>
#include "llama.h"
#include "ggml-backend.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using json = nlohmann::json;
static std::atomic<uint64_t> active{0}, cancelled{0};
static bool aborted(void *) { return active.load() != 0 && cancelled.load() == active.load(); }
static void check_cancel() { if (aborted(nullptr)) throw std::runtime_error("cancelled"); }
static void quiet(ggml_log_level, const char *, void *) {}
static void require(bool ok, const char * message) { if (!ok) throw std::runtime_error(message); }
static std::wstring wide(const std::string & s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0);
    require(n > 0, "invalid UTF-8 path");
    std::wstring out(n, 0); MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n); return out;
}
static bool transfer(HANDLE pipe, void * data, size_t size, bool write) {
    auto * p = (unsigned char *)data;
    while (size) {
        OVERLAPPED operation{}; operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!operation.hEvent) return false;
        DWORD n = 0;
        BOOL ok = write ? WriteFile(pipe, p, (DWORD)std::min<size_t>(size, 65536), &n, &operation) : ReadFile(pipe, p, (DWORD)std::min<size_t>(size, 65536), &n, &operation);
        if (!ok && GetLastError() == ERROR_IO_PENDING) ok = GetOverlappedResult(pipe, &operation, &n, TRUE);
        CloseHandle(operation.hEvent);
        if (!ok || !n) return false; p += n; size -= n;
    }
    return true;
}
struct Request { json value; std::vector<int16_t> pcm; };
struct Engine {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    mtmd_context * audio = nullptr;
    llama_sampler * sampler = nullptr;
    HMODULE whisper = nullptr;
    void * whisper_ctx = nullptr;
    using Create = void * (__cdecl *)(const wchar_t *, int);
    using Destroy = void (__cdecl *)(void *);
    using Cancel = void (__cdecl *)(void *);
    using Transcribe = const char * (__cdecl *)(void *, const float *, int, const char *);
    Destroy destroy = nullptr; Cancel cancel = nullptr, reset = nullptr; Transcribe transcribe = nullptr;
    std::string kind, device;
    int remaining = 0;
    ~Engine() { unload(); }
    void end() {
        if (sampler) llama_sampler_free(sampler); sampler = nullptr; remaining = 0;
        if (ctx) llama_memory_clear(llama_get_memory(ctx), true);
    }
    void unload() {
        end();
        if (audio) mtmd_free(audio); audio = nullptr;
        if (ctx) llama_free(ctx); ctx = nullptr;
        if (model) llama_model_free(model); model = nullptr;
        if (whisper_ctx && destroy) destroy(whisper_ctx); whisper_ctx = nullptr;
        if (whisper) FreeLibrary(whisper); whisper = nullptr;
        kind.clear();
    }
    bool has_gpu() {
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i)
            if (ggml_backend_dev_type(ggml_backend_dev_get(i)) == GGML_BACKEND_DEVICE_TYPE_GPU) return true;
        return false;
    }
    json gpu_memory() {
        json devices = json::array();
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            auto dev = ggml_backend_dev_get(i);
            if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU) {
                size_t available = 0, total = 0; ggml_backend_dev_memory(dev, &available, &total);
                devices.push_back({{"name", ggml_backend_dev_name(dev)}, {"free_bytes", available}, {"total_bytes", total}});
            }
        }
        return devices;
    }
    void load(const json & j) {
        unload(); check_cancel();
        kind = j.at("engine"); device = j.value("device", "cpu");
        bool gpu = device == "cuda";
        require(!gpu || (RECORDER_CUDA && has_gpu()), "CUDA device unavailable");
        std::string path = j.at("path");
        if (kind == "whisper") {
            wchar_t self[MAX_PATH]; GetModuleFileNameW(nullptr, self, MAX_PATH);
            auto dll = std::filesystem::path(self).parent_path() / L"recorder-whisper.dll";
            whisper = LoadLibraryExW(dll.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
            require(whisper != nullptr, "Whisper runtime missing");
            auto create = (Create)GetProcAddress(whisper, "recorder_create_device");
            destroy = (Destroy)GetProcAddress(whisper, "recorder_destroy");
            cancel = (Cancel)GetProcAddress(whisper, "recorder_cancel"); reset = (Cancel)GetProcAddress(whisper, "recorder_reset");
            transcribe = (Transcribe)GetProcAddress(whisper, "recorder_transcribe");
            require(create && destroy && cancel && reset && transcribe, "Whisper ABI mismatch");
            whisper_ctx = create(wide(path).c_str(), gpu ? 1 : 0); require(whisper_ctx != nullptr, "Whisper model load failed"); return;
        }
        auto mp = llama_model_default_params(); mp.n_gpu_layers = gpu ? 999 : 0;
        mp.progress_callback = [](float, void *) { return !aborted(nullptr); };
        model = llama_model_load_from_file(path.c_str(), mp); require(model != nullptr, "GGUF model load failed");
        auto cp = llama_context_default_params(); cp.n_ctx = 8192; cp.n_batch = 512; cp.n_ubatch = 512;
        cp.n_threads = cp.n_threads_batch = std::max(1u, std::min(8u, std::thread::hardware_concurrency()));
        cp.abort_callback = aborted; cp.abort_callback_data = nullptr;
        ctx = llama_init_from_model(model, cp); require(ctx != nullptr, "Model context allocation failed");
        if (kind == "qwen") {
            auto ap = mtmd_context_params_default(); ap.use_gpu = gpu; ap.n_threads = cp.n_threads;
            audio = mtmd_init_from_file(j.at("projector").get<std::string>().c_str(), model, ap);
            require(audio && mtmd_support_audio(audio) && mtmd_get_audio_sample_rate(audio) == 16000, "Qwen audio encoder mismatch");
        }
        check_cancel();
    }
    void decode(std::vector<llama_token> & tokens) {
        for (size_t at = 0; at < tokens.size(); at += 512) {
            check_cancel();
            auto batch = llama_batch_get_one(tokens.data() + at, (int)std::min<size_t>(512, tokens.size() - at));
            require(llama_decode(ctx, batch) == 0, "Token decode failed");
        }
    }
    void text_prompt(const std::string & prompt) {
        auto vocab = llama_model_get_vocab(model);
        int n = -llama_tokenize(vocab, prompt.data(), (int)prompt.size(), nullptr, 0, true, true);
        require(n > 0 && n < 7000, "Prompt too long or invalid");
        std::vector<llama_token> tokens(n);
        require(llama_tokenize(vocab, prompt.data(), (int)prompt.size(), tokens.data(), n, true, true) == n, "Tokenization failed");
        decode(tokens);
    }
    void begin(const json & j) {
        require(ctx && kind != "qwen", "Translation model not loaded"); end();
        llama_memory_clear(llama_get_memory(ctx), true);
        std::vector<std::string> roles, texts;
        for (const auto & m : j.at("messages")) { roles.push_back(m.at("role")); texts.push_back(m.at("content")); }
        std::vector<llama_chat_message> messages;
        for (size_t i = 0; i < roles.size(); ++i) messages.push_back({roles[i].c_str(), texts[i].c_str()});
        auto tmpl = llama_model_chat_template(model, nullptr); require(tmpl != nullptr, "Chat template missing");
        int n = llama_chat_apply_template(tmpl, messages.data(), messages.size(), true, nullptr, 0);
        require(n > 0 && n < 100000, "Unsupported chat template");
        std::string prompt(n, 0); llama_chat_apply_template(tmpl, messages.data(), messages.size(), true, prompt.data(), n);
        text_prompt(prompt); sampler = llama_sampler_init_greedy(); remaining = j.value("max_tokens", 512);
    }
    std::string next(bool & done) {
        require(ctx && sampler, "Generation not started"); check_cancel();
        if (remaining-- <= 0) { done = true; return ""; }
        auto token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(llama_model_get_vocab(model), token)) { done = true; return ""; }
        char buf[256]; int n = llama_token_to_piece(llama_model_get_vocab(model), token, buf, sizeof(buf), 0, false);
        require(n >= 0, "Token piece too long");
        std::vector<llama_token> one{token}; decode(one); done = false; return std::string(buf, n);
    }
    std::string asr(const Request & r) {
        check_cancel();
        std::vector<float> pcm(r.pcm.size()); for (size_t i = 0; i < pcm.size(); ++i) pcm[i] = r.pcm[i] / 32768.0f;
        require(!pcm.empty() && pcm.size() <= 25 * 16000, "Audio input must be 0..25 seconds");
        auto language = r.value.value("language", "auto");
        if (kind == "whisper") {
            require(whisper_ctx != nullptr, "Whisper not loaded"); reset(whisper_ctx);
            std::atomic<bool> done{false};
            std::thread monitor([&] { while (!done) { if (aborted(nullptr)) cancel(whisper_ctx); Sleep(10); } });
            auto result = transcribe(whisper_ctx, pcm.data(), (int)pcm.size(), language.c_str());
            std::string text = result ? result : ""; done = true; monitor.join(); check_cancel();
            require(result != nullptr, "Whisper inference failed"); return text;
        }
        require(ctx && audio && kind == "qwen", "ASR model not loaded"); end();
        llama_memory_clear(llama_get_memory(ctx), true);
        std::string prompt = "<|im_start|>system\n<|im_end|>\n<|im_start|>user\n" + std::string(mtmd_default_marker()) + "<|im_end|>\n<|im_start|>assistant\n";
        if (language != "auto") prompt += "language " + language + "<asr_text>";
        auto bitmap = std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)>(mtmd_bitmap_init_from_audio(pcm.size(), pcm.data()), mtmd_bitmap_free);
        auto chunks = std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)>(mtmd_input_chunks_init(), mtmd_input_chunks_free);
        mtmd_input_text input{prompt.data(), prompt.size(), true, true}; const mtmd_bitmap * images[] = {bitmap.get()};
        require(mtmd_tokenize(audio, chunks.get(), &input, images, 1) == 0, "Audio tokenization failed");
        llama_pos past = 0;
        require(mtmd_helper_eval_chunks(audio, ctx, chunks.get(), 0, 0, 512, true, &past) == 0, "Audio encoding failed");
        sampler = llama_sampler_init_greedy(); remaining = 512;
        bool done = false; std::string out;
        while (!done) out += next(done);
        end();
        auto marker = out.find("<asr_text>"); if (marker != std::string::npos) out.erase(0, marker + 10);
        auto tail = out.find("<|im_end|>"); if (tail != std::string::npos) out.resize(tail);
        return out;
    }
};

int wmain(int argc, wchar_t ** argv) {
    if (argc != 3 || std::wstring(argv[1]) != L"--pipe") return 2;
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    // The CUDA runtime/cuBLAS may be installed outside the app (downloaded on demand). PATH already resolved this
    // executable's imports; AddDllDirectory lets recorder-whisper.dll, loaded with LOAD_LIBRARY_SEARCH_*, find them too.
    if (const wchar_t * dirs = _wgetenv(L"SHENGJIAN_DLL_DIRS")) {
        std::wstring list(dirs);
        for (size_t start = 0; start <= list.size();) {
            size_t end = list.find(L';', start); if (end == std::wstring::npos) end = list.size();
            if (end > start) AddDllDirectory(list.substr(start, end - start).c_str());
            start = end + 1;
        }
    }
    llama_log_set(quiet, nullptr); mtmd_helper_log_set(quiet, nullptr);
    llama_backend_init();
    std::wstring path = L"\\\\.\\pipe\\" + std::wstring(argv[2]);
    if (!WaitNamedPipeW(path.c_str(), 15000)) return 3;
    HANDLE pipe = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return 4;
    std::mutex mutex; std::condition_variable cv; std::deque<Request> queue; bool eof = false;
    std::thread reader([&] {
        try {
            for (;;) {
                uint32_t n = 0; if (!transfer(pipe, &n, 4, false)) break; require(n > 0 && n <= 1024 * 1024, "Invalid frame size");
                std::string raw(n, 0); if (!transfer(pipe, raw.data(), n, false)) break;
                Request r; r.value = json::parse(raw); require(r.value.at("rpc_version") == 1, "Protocol mismatch");
                int bytes = r.value.value("payload_bytes", 0); require(bytes >= 0 && bytes <= 800000 && bytes % 2 == 0, "Invalid audio size");
                r.pcm.resize(bytes / 2); if (bytes && !transfer(pipe, r.pcm.data(), bytes, false)) break;
                if (r.value.at("command") == "cancel") { cancelled = r.value.at("target_id").get<uint64_t>(); continue; }
                { std::lock_guard<std::mutex> lock(mutex); require(queue.size() < 8, "Request queue full"); queue.push_back(std::move(r)); } cv.notify_one();
            }
        } catch (...) { }
        { std::lock_guard<std::mutex> lock(mutex); eof = true; } cancelled = active.load(); cv.notify_one();
    });
    {
        Engine engine;
        for (;;) {
            Request r;
            { std::unique_lock<std::mutex> lock(mutex); cv.wait(lock, [&] { return eof || !queue.empty(); }); if (eof) break; r = std::move(queue.front()); queue.pop_front(); }
            auto id = r.value.at("id").get<uint64_t>(); active = id;
            json response{{"rpc_version", 1}, {"id", id}};
            try {
                auto cmd = r.value.at("command").get<std::string>(); check_cancel();
                json result = json::object();
                if (cmd == "hello") result = {{"cuda_build", (bool)RECORDER_CUDA}, {"cuda_available", engine.has_gpu()}};
                else if (cmd == "memory") result["devices"] = engine.gpu_memory();
                else if (cmd == "load") { try { engine.load(r.value); } catch (...) { engine.unload(); throw; } result["device"] = engine.device; }
                else if (cmd == "unload") engine.unload();
                else if (cmd == "asr") result["text"] = engine.asr(r);
                else if (cmd == "begin") engine.begin(r.value);
                else if (cmd == "next") { bool done; auto piece = engine.next(done); result["token_bytes"] = std::vector<unsigned char>(piece.begin(), piece.end()); result["done"] = done; if (done) engine.end(); }
                else if (cmd == "end") engine.end();
                else throw std::runtime_error("Unknown command");
                response["result"] = result;
            } catch (const std::exception & e) { response["error"] = e.what(); }
            active = 0;
            std::string raw = response.dump(-1, ' ', false, json::error_handler_t::replace); uint32_t n = (uint32_t)raw.size();
            if (!transfer(pipe, &n, 4, true) || !transfer(pipe, raw.data(), n, true)) break;
        }
    }
    CancelIoEx(pipe, nullptr); reader.join(); CloseHandle(pipe); llama_backend_free(); return 0;
}
