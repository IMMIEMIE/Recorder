#include "protocol.hpp"
#include "webrtc_vad.h"
#include "llama.h"
#include "ggml-backend.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <thread>
#include <unistd.h>
#include <sys/resource.h>

using hy::json;
using Clock = std::chrono::steady_clock;
static std::mutex output_mutex;
static void emit(json event) {
    event["protocol_version"] = 1;
    std::lock_guard<std::mutex> lock(output_mutex);
    // A turn can end inside a multi-byte character; that must never end the session.
    std::cout << event.dump(-1, ' ', false, json::error_handler_t::replace) << '\n' << std::flush;
}
static void log_message(ggml_log_level, const char * text, void *) { std::fputs(text, stderr); }
static uint64_t peak_rss_bytes() {
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage)) return 0;
#ifdef __APPLE__
    return uint64_t(usage.ru_maxrss);
#else
    return uint64_t(usage.ru_maxrss) * 1024;
#endif
}
struct Cancelled : std::exception {};
struct Reply { std::string source, target; bool ended = false; bool eos = false; bool malformed = false; int tokens = 0; std::vector<llama_token> ids; };

class Model {
    llama_model * model_ = nullptr;
    llama_context * context_ = nullptr;
    mtmd_context * audio_ = nullptr;
    llama_sampler * sampler_ = nullptr;
    const llama_vocab * vocab_ = nullptr;
    llama_pos position_ = 0;
    int ctx_size_;
    std::atomic<bool> & aborted_;
    llama_token src_, tgt_, eot_, eos_, speech_eos_, user_;
    std::vector<llama_token> suffix_;
    std::string target_;
    static bool abort_callback(void * data) { return static_cast<std::atomic<bool> *>(data)->load(); }
    void check() const { if (aborted_) throw Cancelled(); }
    std::vector<llama_token> tokenize(const std::string & text, bool bos = false) const {
        int count = llama_tokenize(vocab_, text.data(), int32_t(text.size()), nullptr, 0, bos, true);
        if (count >= 0) return {};
        std::vector<llama_token> out(size_t(-count));
        count = llama_tokenize(vocab_, text.data(), int32_t(text.size()), out.data(), int32_t(out.size()), bos, true);
        if (count < 0) throw std::runtime_error("模型分词失败");
        out.resize(size_t(count));
        return out;
    }
    llama_token special(const std::string & text, int expected) const {
        auto ids = tokenize(text);
        if (ids.size() != 1 || ids[0] != expected) throw std::runtime_error("模型特殊标记不兼容，请使用指定的 Interleave GGUF");
        return ids[0];
    }
    std::string piece(llama_token token) const {
        std::string out(128, '\0');
        int n = llama_token_to_piece(vocab_, token, out.data(), int(out.size()), 0, false);
        if (n < 0) { out.resize(size_t(-n)); n = llama_token_to_piece(vocab_, token, out.data(), int(out.size()), 0, false); }
        if (n < 0) throw std::runtime_error("模型字符解码失败");
        out.resize(size_t(n));
        return out;
    }
    void text(const std::vector<llama_token> & tokens) {
        check();
        if (position_ + tokens.size() > size_t(ctx_size_)) throw std::runtime_error("本地模型上下文预算不足");
        for (size_t offset = 0; offset < tokens.size(); offset += 512) {
            int n = int(std::min<size_t>(512, tokens.size() - offset));
            llama_batch b = llama_batch_init(n, 0, 1);
            b.n_tokens = n;
            for (int i = 0; i < n; ++i) {
                b.token[i] = tokens[offset + i]; b.pos[i] = position_ + i;
                b.n_seq_id[i] = 1; b.seq_id[i][0] = 0; b.logits[i] = i == n - 1;
            }
            int result = llama_decode(context_, b);
            llama_batch_free(b);
            check();
            if (result) throw std::runtime_error("本地模型文本推理失败");
            position_ += n;
        }
    }
    mtmd::input_chunks chunks(const std::vector<float> & samples) {
        mtmd::bitmap bitmap(mtmd_bitmap_init_from_audio(samples.size(), samples.data()));
        mtmd::input_chunks result(mtmd_input_chunks_init());
        mtmd_input_part part{nullptr, bitmap.ptr.get()};
        const mtmd_input_part * parts[] = {&part};
        if (mtmd_tokenize_from_parts(audio_, result.ptr.get(), parts, 1, false))
            throw std::runtime_error("本地模型音频预处理失败");
        return mtmd::input_chunks(result.ptr.release());
    }
    void encode(const mtmd::input_chunks & chunks) {
        check();
        llama_pos end = position_;
        if (mtmd_helper_eval_chunks(audio_, context_, chunks.ptr.get(), position_, 0, 512, false, &end)) {
            check(); throw std::runtime_error("本地模型音频推理失败");
        }
        check(); position_ = end;
    }
    /// Rarely, the model breaks the source/target format, more often deep into a long context
    /// (one source-only turn in about 1500). One bad turn must not end a live session: its
    /// text stays source-only and the next turn or recovery translates the audio.
    Reply generate(int limit, const std::function<void(const Reply &)> & progress, bool force_target = false) {
        Reply reply;
        bool target_branch = false;
        for (int i = 0; i < limit; ++i) {
            check();
            llama_token token = llama_sampler_sample(sampler_, context_, -1);
            reply.ids.push_back(token);
            reply.tokens++;
            if (token == eot_ || token == eos_ || token == speech_eos_ || llama_vocab_is_eog(vocab_, token)) {
                if (!target_branch && hy::has_text(reply.source)) {
                    reply.malformed = true;
                    if (force_target) { target_branch = true; text({tgt_}); continue; }
                }
                reply.ended = true; reply.eos = token != eot_;
                text({token});
                return reply;
            }
            if (token == tgt_) {
                reply.malformed |= target_branch;
                target_branch = true;
            } else if (token == src_) {
                reply.malformed = true;
            } else if (!llama_vocab_is_control(vocab_, token)) {
                (target_branch ? reply.target : reply.source) += piece(token);
                if (progress && hy::valid_utf8(reply.source) && hy::valid_utf8(reply.target)) progress(reply);
            }
            text({token});
        }
        return reply;
    }
public:
    Model(const std::string & path, int ctx_size, std::atomic<bool> & abort) : ctx_size_(ctx_size), aborted_(abort) {
        llama_log_set(log_message, nullptr); mtmd_log_set(log_message, nullptr);
        ggml_backend_load_all(); llama_backend_init();
        auto mp = llama_model_default_params(); mp.n_gpu_layers = -1;
        model_ = llama_model_load_from_file(path.c_str(), mp);
        if (!model_) throw std::runtime_error("无法加载 Hy-SimulMT GGUF 模型");
        vocab_ = llama_model_get_vocab(model_);
        src_ = special("<｜hy_place▁holder▁no▁790｜>", 120808);
        tgt_ = special("<｜hy_place▁holder▁no▁791｜>", 120809);
        eot_ = special("<｜hy_EOT｜>", 120008);
        eos_ = special("<｜hy_end▁of▁sentence｜>", 120001);
        speech_eos_ = 120025;
        auto u = tokenize("<｜hy_User｜>");
        if (u.size() != 1 || !llama_vocab_is_eog(vocab_, eot_)) throw std::runtime_error("模型没有有效的回合结束标记");
        user_ = u[0];
        auto cp = llama_context_default_params();
        cp.n_ctx = uint32_t(ctx_size_); cp.n_batch = 512; cp.n_ubatch = 512; cp.n_seq_max = 1;
        cp.n_threads = cp.n_threads_batch = int32_t(std::min(10u, std::max(1u, std::thread::hardware_concurrency())));
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO; cp.no_perf = false;
        cp.abort_callback = abort_callback; cp.abort_callback_data = &aborted_;
        context_ = llama_init_from_model(model_, cp);
        if (!context_) throw std::runtime_error("无法分配本地模型上下文，请释放内存后重试");
        auto ap = mtmd_context_params_default(); ap.use_gpu = true; ap.n_threads = cp.n_threads;
        ap.print_timings = false; ap.warmup = false; ap.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        audio_ = mtmd_init_from_file(path.c_str(), model_, ap);
        if (!audio_ || mtmd_get_audio_sample_rate(audio_) != 16000 || mtmd_audio_stream_mode(audio_) != MTMD_AUDIO_STREAM_TURN)
            throw std::runtime_error("模型缺少兼容的 Hy-SimulMT 音频编码器");
        sampler_ = llama_sampler_init_greedy();
        suffix_ = tokenize("<｜hy_Assistant｜><think></think><｜hy_place▁holder▁no▁790｜>");
    }
    ~Model() {
        if (sampler_) llama_sampler_free(sampler_);
        if (audio_) mtmd_free(audio_);
        if (context_) llama_free(context_);
        if (model_) llama_model_free(model_);
        llama_backend_free();
    }
    int position() const { return position_; }
    int context_size() const { return ctx_size_; }
    void reset(const std::string & language, bool recovery = false) {
        check(); target_ = language;
        llama_memory_clear(llama_get_memory(context_), true); llama_sampler_reset(sampler_); position_ = 0;
        const std::string name = language == "en" ? "英文" : "中文";
        const std::string instruction = recovery ? "把这段语音翻译成" + name + "，要全部输出，不要分块。" :
            "请完成下面的同声传译任务，将陆续收到的语音翻译成" + name + "。请结合上下文边听边译，输出能够确定的译文，不必等待整句结束。";
        text(tokenize("<｜hy_begin▁of▁sentence｜><｜reasoning_mode｜>reasoning_effort:no_think<｜hy_User｜>" + instruction, true));
    }
    bool fits(const std::vector<float> & samples, int output = 128, int reserve = 512) {
        auto c = chunks(samples);
        return position_ + mtmd_helper_get_n_pos(c.ptr.get()) + int(suffix_.size()) + 1 + output + reserve <= ctx_size_;
    }
    Reply turn(const std::vector<float> & samples, bool first, const std::function<void(const Reply &)> & progress = {}) {
        auto c = chunks(samples);
        if (position_ + mtmd_helper_get_n_pos(c.ptr.get()) + int(suffix_.size()) + 1 + 128 > ctx_size_)
            throw std::runtime_error("本地模型上下文预算不足");
        if (!first) text({user_});
        encode(c); text(suffix_);
        return generate(128, progress);
    }
    Reply recover(const std::vector<float> & samples) {
        reset(target_, true);
        auto c = chunks(samples);
        if (position_ + mtmd_helper_get_n_pos(c.ptr.get()) + int(suffix_.size()) + 512 > ctx_size_)
            throw std::runtime_error("本地模型尾句恢复上下文不足");
        encode(c); text(suffix_);
        // Official ST continues from a source + TGT prefix too. Recovery has no later turn to fall back on.
        return generate(512, {}, true);
    }
};

/// WebRTC VAD at the backend segmenter's aggressiveness. It adapts to steady room noise,
/// which a fixed energy threshold cannot: a fan is louder than quiet speech.
class VoiceActivity {
    VadInst * handle_ = nullptr;
    std::vector<int16_t> frame_;
public:
    VoiceActivity() : frame_(hy::sample_rate / 50) {
        if (WebRtcVad_Create(&handle_) || WebRtcVad_Init(handle_) || WebRtcVad_set_mode(handle_, 2))
            throw std::runtime_error("语音活动检测初始化失败");
    }
    ~VoiceActivity() { if (handle_) WebRtcVad_Free(handle_); }
    VoiceActivity(const VoiceActivity &) = delete;
    VoiceActivity & operator=(const VoiceActivity &) = delete;
    int voiced_ms(const std::vector<float> & samples, size_t count) {
        int voiced = 0;
        for (size_t offset = 0; offset + frame_.size() <= count; offset += frame_.size()) {
            for (size_t i = 0; i < frame_.size(); ++i)
                frame_[i] = int16_t(std::lround(std::clamp(samples[offset + i] * 32768.0f, -32768.0f, 32767.0f)));
            if (WebRtcVad_Process(handle_, hy::sample_rate, frame_.data(), int(frame_.size())) == 1) voiced += 20;
        }
        return voiced;
    }
};

struct Command { json value; std::vector<float> samples; };
struct Mailbox {
    std::mutex mutex; std::condition_variable available;
    std::deque<Command> commands; size_t queued_samples = 0, max_queued_samples = 0;
    std::string active; std::atomic<bool> aborted{false}; bool eof = false;
    void read() {
        try {
            std::string line;
            while (true) {
                int c = std::getchar();
                if (c == EOF) break;
                if (c != '\n') {
                    if (line.size() >= hy::max_line_bytes) throw std::runtime_error("本地模型控制消息过大");
                    line.push_back(char(c)); continue;
                }
                if (line.empty()) continue;
                Command command{json::parse(line), {}}; line.clear();
                auto & v = command.value;
                if (!v.is_object() || !v.contains("protocol_version") || !v["protocol_version"].is_number_integer() ||
                    v["protocol_version"].get<int>() != 1) throw std::runtime_error("本地模型协议版本不兼容");
                std::string type = v.at("type").get<std::string>();
                if (type == "audio") command.samples = hy::decode_pcm(v.at("pcm").get<std::string>());
                std::unique_lock<std::mutex> lock(mutex);
                std::string session = v.value("session_id", "");
                if ((type == "cancel" && session == active) || type == "shutdown") {
                    aborted = true;
                    commands.clear(); queued_samples = 0;
                    commands.push_front(std::move(command));
                } else {
                    if (queued_samples + command.samples.size() > hy::max_queue_samples || commands.size() >= 1024) {
                        aborted = true;
                        commands.clear(); queued_samples = 0;
                        commands.push_back({{{"type", "overload"}, {"session_id", active}}, {}});
                    } else {
                        queued_samples += command.samples.size();
                        max_queued_samples = std::max(max_queued_samples, queued_samples);
                        commands.push_back(std::move(command));
                    }
                }
                available.notify_one();
                if (type == "shutdown") return;
            }
        } catch (const std::exception & e) {
            emit({{"type", "error"}, {"code", "protocol"}, {"message", e.what()}, {"recoverable", false}});
        }
        std::lock_guard<std::mutex> lock(mutex); eof = true; aborted = true; available.notify_one();
    }
    bool pop(Command & command) {
        std::unique_lock<std::mutex> lock(mutex);
        available.wait(lock, [&] { return eof || !commands.empty(); });
        if (commands.empty()) return false;
        command = std::move(commands.front()); commands.pop_front(); queued_samples -= command.samples.size(); return true;
    }
    void set_session(const std::string & id) {
        std::lock_guard<std::mutex> lock(mutex); active = id; aborted = false; max_queued_samples = queued_samples;
    }
    double peak_queue_seconds() { std::lock_guard<std::mutex> lock(mutex); return double(max_queued_samples) / hy::sample_rate; }
    bool is_active(const std::string & id) { std::lock_guard<std::mutex> lock(mutex); return !id.empty() && active == id; }
};

class Session {
    Model & model_; Mailbox & mailbox_;
    VoiceActivity voice_;
    std::string id_, language_, source_;
    std::vector<float> buffer_, pending_;
    uint64_t cursor_ = 0, pending_start_ = 0, segment_ = 1, revision_ = 0, unresolved_ = 0, silent_ = 0, pending_voiced_ms_ = 0;
    bool first_ = true, sentence_ended_ = false;
    bool reference_mode_, trace_tokens_;
    Clock::time_point start_;
    double inference_ms_ = 0, first_translation_ms_ = -1;
    int resets_ = 0, recovery_attempts_ = 0, successful_recoveries_ = 0, context_resets_ = 0, early_rollovers_ = 0, malformed_turns_ = 0;
    int eof_recovery_attempts_ = 0, successful_eof_recoveries_ = 0;
    uint64_t tail_padding_ = 0, turns_ = 0;
    void update(const std::string & source, const std::string & target, bool committed) {
        emit({{"type", "update"}, {"session_id", id_}, {"segment_id", segment_},
              {"start_sample", pending_start_}, {"end_sample", cursor_}, {"source", source}, {"translation", target},
              {"revision", ++revision_}, {"source_done", committed}, {"translation_done", committed}, {"committed", committed}});
    }
    void drop_pending() { pending_.clear(); pending_voiced_ms_ = 0; source_.clear(); pending_start_ = cursor_; }
    /// Recovery on audio the model never reacted to would only invent text for a cough or a door.
    bool heard_speech() const { return hy::has_text(source_) || pending_voiced_ms_ >= hy::min_recovery_voiced_ms; }
    void commit(const Reply & reply, bool replace_source) {
        if (!replace_source) source_ += reply.source;
        else if (hy::has_text(reply.source)) source_ = reply.source;
        if (hy::has_text(reply.target)) {
            update(source_, reply.target, true);
            if (first_translation_ms_ < 0) first_translation_ms_ = std::chrono::duration<double, std::milli>(Clock::now() - start_).count();
            sentence_ended_ = hy::ends_sentence(reply.target);
            drop_pending(); segment_++; revision_ = 0;
        } else if (!reply.source.empty()) update(source_, "", false);
    }
    void reset() {
        auto begin = Clock::now(); model_.reset(language_);
        inference_ms_ += std::chrono::duration<double, std::milli>(Clock::now() - begin).count();
        first_ = true; resets_++;
    }
    void recover(const char * reason) {
        if (pending_.empty() || !heard_speech()) { drop_pending(); reset(); return; }
        auto begin = Clock::now();
        recovery_attempts_++;
        const bool eof = std::string(reason) == "eof";
        if (eof) eof_recovery_attempts_++;
        Reply reply = model_.recover(pending_);
        inference_ms_ += std::chrono::duration<double, std::milli>(Clock::now() - begin).count();
        if (reply.malformed) malformed_turns_++;
        if (reply.ended && hy::has_text(reply.target)) {
            successful_recoveries_++; if (eof) successful_eof_recoveries_++;
            commit(reply, true);
        } else if (reply.ended && !hy::has_text(source_) && !hy::has_text(reply.source)) {
            // Neither the streaming turns nor the full audio produced a word: noise, not lost speech.
            drop_pending();
        } else {
            uint64_t missed = cursor_ - pending_start_;
            unresolved_ += missed;
            emit({{"type", "warning"}, {"session_id", id_}, {"code", "unresolved_audio"},
                  {"message", "部分语音未能完整翻译"}, {"reason", reason}, {"start_sample", pending_start_},
                  {"end_sample", cursor_}, {"unresolved_audio_ms", missed * 1000 / hy::sample_rate}});
            drop_pending(); segment_++; revision_ = 0;
        }
        reset();
    }
    /// Past three quarters of the budget, the next finished sentence or pause opens a new context.
    /// A forced rollover later would interrupt speech and depend on a recovery pass.
    bool rollover_due() const {
        return !reference_mode_ && !first_ && pending_.empty()
            && (sentence_ended_ || silent_ >= 2 * hy::step_samples)
            && model_.position() >= model_.context_size() / 4 * 3;
    }
    void step(std::vector<float> samples, size_t valid) {
        const int voiced = voice_.voiced_ms(samples, valid);
        const bool speech = voiced >= hy::min_voiced_ms;
        silent_ = speech ? 0 : silent_ + valid;
        // Nothing waits on this audio, so silence costs neither inference nor context budget.
        if (!reference_mode_ && !speech && pending_.empty()) {
            cursor_ += valid; pending_start_ = cursor_; return;
        }
        if (pending_.empty()) pending_start_ = cursor_;
        pending_.insert(pending_.end(), samples.begin(), samples.begin() + valid);
        cursor_ += valid;
        pending_voiced_ms_ += uint64_t(voiced);
        auto begin = Clock::now();
        if (trace_tokens_) emit({{"type", "inference_started"}, {"session_id", id_}, {"turn", turns_}});
        Reply reply = model_.turn(samples, first_, [&](const Reply & partial) { update(source_ + partial.source, partial.target, false); });
        inference_ms_ += std::chrono::duration<double, std::milli>(Clock::now() - begin).count(); first_ = false;
        if (trace_tokens_) emit({{"type", "trace"}, {"session_id", id_}, {"turn", turns_}, {"token_ids", reply.ids}, {"valid_samples", valid}});
        turns_++;
        if (reply.malformed) malformed_turns_++;
        if (reference_mode_) { if (!reply.ended) throw std::runtime_error("参考推理超过单回合 token 限制"); commit(reply, false); return; }
        if (!reply.ended) { source_ += reply.source; recover("max_tokens"); return; }
        commit(reply, false);
        if (reply.eos) recover("model_eos");
        else if (!pending_.empty() && silent_ >= hy::trailing_silence_samples) {
            if (heard_speech()) recover("trailing_silence");
            else drop_pending();
        }
    }
public:
    Session(Model & model, Mailbox & mailbox, const std::string & id, std::string language, bool reference_mode, bool trace_tokens) :
        model_(model), mailbox_(mailbox), id_(id), language_(std::move(language)), reference_mode_(reference_mode), trace_tokens_(trace_tokens), start_(Clock::now()) {
        if (language_ == "en-zh") language_ = "zh";
        if (language_ == "zh-en") language_ = "en";
        if ((language_ != "zh" && language_ != "en") || id.empty() || id.size() > 128) throw std::runtime_error("无效的会话或目标语言");
        auto begin = Clock::now(); model_.reset(language_);
        inference_ms_ += std::chrono::duration<double, std::milli>(Clock::now() - begin).count();
        emit({{"type", "ready"}, {"session_id", id_}, {"sample_rate", 16000}, {"channels", 1}, {"format", "s16le"}});
    }
    const std::string & id() const { return id_; }
    void audio(const std::vector<float> & samples) {
        buffer_.insert(buffer_.end(), samples.begin(), samples.end());
        while (buffer_.size() >= (first_ ? hy::first_samples : hy::step_samples)) {
            if (rollover_due()) { early_rollovers_++; reset(); continue; }
            size_t n = first_ ? hy::first_samples : hy::step_samples;
            std::vector<float> turn(buffer_.begin(), buffer_.begin() + n);
            if (!model_.fits(turn)) { context_resets_++; recover("context_limit"); continue; }
            if (pending_.size() + n > hy::max_pending_samples) { recover("pending_limit"); continue; }
            buffer_.erase(buffer_.begin(), buffer_.begin() + n); step(std::move(turn), n);
        }
    }
    void finish(bool cancelled = false) {
        if (!cancelled) {
            if (!buffer_.empty()) {
                size_t valid = buffer_.size();
                if (!reference_mode_) buffer_.resize(first_ ? hy::first_samples : hy::step_samples, 0);
                if (!model_.fits(buffer_)) { context_resets_++; recover("context_limit"); }
                if (pending_.size() + valid > hy::max_pending_samples) recover("pending_limit");
                // A recovery starts a fresh context: its first audio turn must
                // regain the full 1600 ms cadence before checking the budget.
                if (!reference_mode_) { buffer_.resize(first_ ? hy::first_samples : hy::step_samples, 0); tail_padding_ += buffer_.size() - valid; }
                if (!model_.fits(buffer_)) throw std::runtime_error("本地模型尾块上下文预算不足");
                step(std::move(buffer_), valid); buffer_.clear();
            }
            if (!pending_.empty() && !reference_mode_) recover("eof");
        }
        emit({{"type", "done"}, {"session_id", id_}, {"cancelled", cancelled}, {"complete", !cancelled && unresolved_ == 0},
              {"duration_ms", cursor_ * 1000 / hy::sample_rate}, {"unresolved_audio_ms", unresolved_ * 1000 / hy::sample_rate},
              {"skipped_untranslated_audio_ms", 0}, {"inference_ms", inference_ms_}, {"first_translation_ms", first_translation_ms_},
              {"max_queue_seconds", mailbox_.peak_queue_seconds()}, {"window_resets", resets_}, {"context_resets", context_resets_},
              {"early_rollovers", early_rollovers_}, {"malformed_turns", malformed_turns_},
              {"tail_padding_samples", tail_padding_}, {"recovery_attempts", recovery_attempts_}, {"successful_recoveries", successful_recoveries_},
              {"eof_recovery_attempts", eof_recovery_attempts_}, {"successful_eof_recoveries", successful_eof_recoveries_},
              {"peak_rss_bytes", peak_rss_bytes()}});
    }
};

static int self_test() {
    auto known = hy::decode_pcm("AIAAAP9/");
    if (known.size() != 3 || known[0] != -1 || known[1] != 0 || known[2] != 32767.0f / 32768) return 1;
    for (const std::string bad : {"A", "AA=A", "AB==", "////=", "AA=="}) {
        bool rejected = false; try { (void)hy::decode_pcm(bad); } catch (...) { rejected = true; }
        if (!rejected) return 2;
    }
    if (hy::next_turn_samples(0) != 25600 || hy::next_turn_samples(25600) != 12800 || hy::valid_utf8("\xff")) return 3;
    if (hy::has_text(" \n") || !hy::has_text(" a") || !hy::ends_sentence("好。 ") || !hy::ends_sentence("done. ")
        || hy::ends_sentence("3.5") || hy::ends_sentence("好，") || hy::ends_sentence(" ")) return 4;
    VoiceActivity voice;
    std::vector<float> silence(12800, 0.0f);
    if (voice.voiced_ms(silence, silence.size()) != 0) return 5;
    emit({{"type", "self_test"}, {"passed", true}}); return 0;
}
int main(int argc, char ** argv) {
    std::string model_path; int context = 16384; bool reference_mode = false, trace_tokens = false;
    for (int i = 1; i < argc; ++i) {
        std::string flag = argv[i];
        if (flag == "--self-test") return self_test();
        if (flag == "--model" && i + 1 < argc) model_path = argv[++i];
        else if (flag == "--ctx" && i + 1 < argc) context = std::stoi(argv[++i]);
        else if (flag == "--reference-mode") reference_mode = true;
        else if (flag == "--trace-tokens") trace_tokens = true;
        else { std::fprintf(stderr, "Usage: HySimulMTHelper --model FILE [--ctx 16384]\n"); return 2; }
    }
    if (model_path.empty() || context < 2048 || context > 16384) return 2;
    Mailbox mailbox;
    try {
        auto load_start = Clock::now();
        Model model(model_path, context, mailbox.aborted);
        emit({{"type", "hello"}, {"runtime_commit", hy::runtime_commit}, {"context_size", context},
              {"load_ms", std::chrono::duration<double, std::milli>(Clock::now() - load_start).count()},
              {"peak_rss_bytes", peak_rss_bytes()},
              {"capabilities", {"interleave", "streaming_pcm", "bounded_context", "local_only"}}});
        std::thread reader([&] { mailbox.read(); });
        std::unique_ptr<Session> session;
        Command command;
        while (mailbox.pop(command)) {
            std::string type = command.value.value("type", "");
            std::string id = command.value.value("session_id", "");
            try {
                if (type == "shutdown") break;
                if (type == "start") {
                    if (session) throw std::runtime_error("本地同传会话仍在运行");
                    mailbox.set_session(id);
                    session = std::make_unique<Session>(model, mailbox, id, command.value.at("language").get<std::string>(), reference_mode, trace_tokens);
                } else if (type == "overload") {
                    throw std::runtime_error("本地同传处理积压超过10秒，请停止其他高负载应用后重试");
                } else if (session && session->id() == id) {
                    if (type == "audio") session->audio(command.samples);
                    else if (type == "finish") { session->finish(); session.reset(); mailbox.set_session(""); }
                    else if (type == "cancel") { session->finish(true); session.reset(); mailbox.set_session(""); }
                    else throw std::runtime_error("未知的本地同传控制命令");
                } else if (type == "cancel" && mailbox.is_active(id)) {
                    emit({{"type", "done"}, {"session_id", id}, {"cancelled", true}, {"complete", false},
                          {"duration_ms", 0}, {"unresolved_audio_ms", 0}, {"skipped_untranslated_audio_ms", 0}});
                    mailbox.set_session("");
                } else if (type != "cancel") throw std::runtime_error("本地同传会话不存在或已结束");
            } catch (const Cancelled &) {
                // The queued cancel/overload/shutdown command owns the terminal event.
            } catch (const std::exception & e) {
                emit({{"type", "error"}, {"session_id", id}, {"code", "session"}, {"message", e.what()}, {"recoverable", true}});
                session.reset(); mailbox.set_session("");
            }
        }
        mailbox.aborted = true;
        if (reader.joinable()) reader.join();
    } catch (const std::exception & e) {
        emit({{"type", "error"}, {"code", "load"}, {"message", e.what()}, {"recoverable", false}}); return 1;
    }
    return 0;
}
