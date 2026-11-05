#pragma once
#include <nlohmann/json.hpp>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace hy {
using json = nlohmann::json;
inline constexpr const char * runtime_commit = "d38e66aac7bb18101f417338b795e4546a5a1a59";
inline constexpr int sample_rate = 16000;
inline constexpr size_t first_samples = 25600;
inline constexpr size_t step_samples = 12800;
inline constexpr size_t max_queue_samples = sample_rate * 10;
inline constexpr size_t max_pending_samples = sample_rate * 30;
inline constexpr size_t max_line_bytes = 262144;
// A block with less voiced audio than this is silence to the session; WebRTC VAD reports 20 ms frames.
inline constexpr int min_voiced_ms = 60;
// Without text from the model, recovery needs this much speech: below it, a recovery pass only invents text.
inline constexpr uint64_t min_recovery_voiced_ms = 300;
inline constexpr size_t trailing_silence_samples = sample_rate * 12 / 5;

inline std::vector<float> decode_pcm(const std::string & encoded) {
    if (encoded.size() % 4 || encoded.size() > max_line_bytes - 1024)
        throw std::runtime_error("音频包长度无效");
    auto digit = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1;
    };
    std::vector<uint8_t> bytes;
    bytes.reserve(encoded.size() / 4 * 3);
    for (size_t i = 0; i < encoded.size(); i += 4) {
        int a = digit(encoded[i]), b = digit(encoded[i + 1]);
        bool pad2 = encoded[i + 2] == '=', pad3 = encoded[i + 3] == '=';
        int c = pad2 ? 0 : digit(encoded[i + 2]), d = pad3 ? 0 : digit(encoded[i + 3]);
        if (a < 0 || b < 0 || c < 0 || d < 0 || (pad2 && !pad3) ||
            ((pad2 || pad3) && i + 4 != encoded.size()) ||
            (pad2 && (b & 15)) || (pad3 && !pad2 && (c & 3)))
            throw std::runtime_error("音频包不是有效的 Base64");
        uint32_t value = uint32_t(a << 18 | b << 12 | c << 6 | d);
        bytes.push_back(uint8_t(value >> 16));
        if (!pad2) bytes.push_back(uint8_t(value >> 8));
        if (!pad3) bytes.push_back(uint8_t(value));
    }
    if (bytes.size() % 2) throw std::runtime_error("音频包必须包含完整的 PCM16 采样");
    std::vector<float> samples;
    samples.reserve(bytes.size() / 2);
    for (size_t i = 0; i < bytes.size(); i += 2) {
        int16_t value = int16_t(uint16_t(bytes[i]) | uint16_t(bytes[i + 1]) << 8);
        samples.push_back(float(value) / 32768.0f);
    }
    return samples;
}

inline bool valid_utf8(const std::string & text) {
    // The JSON encoder checks overlong sequences and surrogate code points too.
    try { (void) json(text).dump(); return true; }
    catch (const json::type_error &) { return false; }
}

inline bool has_text(const std::string & text) {
    return text.find_first_not_of(" \t\r\n") != std::string::npos;
}

inline bool ends_sentence(const std::string & text) {
    const size_t last = text.find_last_not_of(" \t\r\n");
    if (last == std::string::npos) return false;
    const std::string body = text.substr(0, last + 1);
    for (const std::string mark : {".", "!", "?", "。", "！", "？"})
        if (body.size() >= mark.size() && body.compare(body.size() - mark.size(), mark.size(), mark) == 0) return true;
    return false;
}

inline size_t next_turn_samples(uint64_t processed) {
    return processed == 0 ? first_samples : step_samples;
}
} // namespace hy
