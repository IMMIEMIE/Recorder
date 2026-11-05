#!/usr/bin/env python3
"""Test the actual native Session class without loading a model or using a GPU.

The production source and helper binary are never modified. The complete class
is extracted verbatim, with balanced C++ delimiters, and compiled against fake
model responses. A source hash in the report identifies the exact tested code.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build/hy-session-tests"


def extract_class(source, name):
    matches = list(re.finditer(rf"^class {re.escape(name)} \{{", source, re.M))
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one class {name} definition")
    start = matches[0].start()
    index = source.index("{", start)
    depth = 0
    state = "code"
    while index < len(source):
        current, following = source[index], source[index:index + 2]
        if state == "line":
            if current == "\n":
                state = "code"
        elif state == "block":
            if following == "*/":
                state = "code"
                index += 1
        elif state in ('"', "'"):
            if current == "\\":
                index += 1
            elif current == state:
                state = "code"
        elif following == "//":
            state = "line"
            index += 1
        elif following == "/*":
            state = "block"
            index += 1
        elif following == 'R"':
            raise RuntimeError("raw C++ literal in Session: update extraction explicitly")
        elif current in ('"', "'"):
            state = current
        elif current == "{":
            depth += 1
        elif current == "}":
            depth -= 1
            if depth == 0:
                if source[index + 1:index + 2] != ";":
                    raise RuntimeError("Session definition has an unexpected terminator")
                return source[start:index + 2]
        index += 1
    raise RuntimeError("unterminated Session definition")


PRELUDE = r'''
#include "protocol.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <deque>
#include <functional>
#include <iostream>
#include <utility>
using hy::json;
using Clock = std::chrono::steady_clock;
using llama_token = int;
static std::vector<json> events;
static void emit(json event) { event["protocol_version"] = 1; events.push_back(std::move(event)); }
static uint64_t peak_rss_bytes() { return 0; }
'''

FAKES = r'''
class Model {
public:
    std::deque<Reply> replies, recoveries;
    std::vector<std::pair<size_t, bool>> turns;
    std::vector<size_t> recovered_samples;
    int reset_count = 0;
    bool fail_recovery = false;
    int position_value = 0;
    int position() const { return position_value; }
    int context_size() const { return 16384; }
    void reset(const std::string &) { reset_count++; position_value = 0; }
    bool fits(const std::vector<float> &) { return true; }
    Reply turn(const std::vector<float> & samples, bool first,
               const std::function<void(const Reply &)> & progress) {
        if (replies.empty()) throw std::runtime_error("unexpected fake model turn");
        turns.emplace_back(samples.size(), first);
        Reply result = replies.front(); replies.pop_front();
        Reply partial = result; partial.source.resize(result.source.size() / 2); partial.target.clear();
        progress(partial); progress(result);
        return result;
    }
    Reply recover(const std::vector<float> & samples) {
        recovered_samples.push_back(samples.size());
        if (fail_recovery) throw std::runtime_error("injected recovery failure");
        if (recoveries.empty()) throw std::runtime_error("unexpected fake recovery");
        Reply result = recoveries.front(); recoveries.pop_front(); return result;
    }
};
struct Mailbox { double peak_queue_seconds() { return 0.125; } };
class VoiceActivity {
public:
    int voiced_ms(const std::vector<float> & samples, size_t count) {
        double energy = 0; for (size_t i = 0; i < count; ++i) energy += samples[i] * samples[i];
        return count && std::sqrt(energy / count) > 0.003 ? int(count * 1000 / hy::sample_rate) : 0;
    }
};
'''

TESTS = r'''
static void require(bool condition, const char * message) {
    if (!condition) throw std::runtime_error(message);
}
static Reply reply(std::string source, std::string target = "", bool ended = true) {
    Reply value; value.source = std::move(source); value.target = std::move(target); value.ended = ended; return value;
}
static std::vector<float> pcm(size_t count) { return std::vector<float>(count, 0.01f); }
// A real microphone's room tone: never exactly zero, always below the speech threshold.
static std::vector<float> room_tone(size_t count) { return std::vector<float>(count, 0.001f); }
static std::vector<json> of_type(const std::string & type) {
    std::vector<json> values;
    for (const auto & event : events) if (event.at("type") == type) values.push_back(event);
    return values;
}
static std::vector<json> commits() {
    std::vector<json> values;
    for (const auto & event : of_type("update")) if (event.at("committed") == true) values.push_back(event);
    return values;
}
static json done() {
    auto values = of_type("done"); require(values.size() == 1, "exactly one terminal done required"); return values[0];
}
static void revisions() {
    std::map<uint64_t, uint64_t> last;
    for (const auto & event : of_type("update")) {
        uint64_t segment = event.at("segment_id"), revision = event.at("revision");
        require(revision > last[segment], "revisions must increase per segment"); last[segment] = revision;
    }
}
static void wait_then_commit() {
    Model model; Mailbox mailbox;
    model.replies = {reply("five "), reply("percent", "百分之五")};
    Session session(model, mailbox, "wait", "zh", false, false);
    session.audio(pcm(hy::first_samples));
    require(commits().empty(), "WAIT must not commit a subtitle");
    session.audio(pcm(hy::step_samples)); session.finish();
    auto rows = commits(); require(rows.size() == 1, "WAIT and target must form one committed row");
    require(rows[0].at("source") == "five percent", "previous WAIT source was lost or duplicated");
    require(rows[0].at("translation") == "百分之五", "target must remain intact");
    require(rows[0].at("segment_id") == 1 && rows[0].at("start_sample") == 0 && rows[0].at("end_sample") == 38400,
            "WAIT and target must retain the complete sample interval");
    require(rows[0].at("source_done") == true && rows[0].at("translation_done") == true, "committed completion flags");
    require(done().at("complete") == true && done().at("duration_ms") == 2400, "normal completion accounting");
    require(model.turns == std::vector<std::pair<size_t,bool>>{{25600,true},{12800,false}}, "first and subsequent cadence");
    revisions();
}
static void recovery_replaces() {
    Model model; Mailbox mailbox;
    model.replies = {reply("fifteen percent")}; model.recoveries = {reply("five percent", "百分之五")};
    Session session(model, mailbox, "replace", "zh", false, false);
    session.audio(pcm(hy::first_samples)); session.finish();
    auto rows = commits(); require(rows.size() == 1, "successful recovery commits once");
    require(rows[0].at("source") == "five percent", "recovery must replace, not append, old source");
    require(rows[0].at("segment_id") == 1 && rows[0].at("start_sample") == 0 && rows[0].at("end_sample") == 25600,
            "recovery must revise the same pending audio interval");
    require(model.recovered_samples == std::vector<size_t>{25600}, "recovery receives all and only pending PCM");
    require(done().at("complete") == true && done().at("successful_eof_recoveries") == 1,
            "successful EOF recovery must be counted");
    revisions();
}
static void failed_recovery(bool ended, const std::string & target) {
    Model model; Mailbox mailbox;
    model.replies = {reply("pending source")}; model.recoveries = {reply("recovered source", target, ended)};
    Session session(model, mailbox, "failed", "zh", false, false);
    session.audio(pcm(hy::first_samples)); session.finish();
    require(commits().empty(), "failed recovery must never commit target text");
    auto warnings = of_type("warning"); require(warnings.size() == 1, "failed recovery must warn exactly once");
    const auto & warning = warnings[0];
    require(warning.at("code") == "unresolved_audio" && warning.at("reason") == "eof", "failure warning identity");
    require(warning.at("start_sample") == 0 && warning.at("end_sample") == 25600 && warning.at("unresolved_audio_ms") == 1600,
            "failed recovery must report the exact pending interval");
    auto terminal = done();
    require(terminal.at("complete") == false && terminal.at("cancelled") == false, "failed recovery cannot claim completion");
    require(terminal.at("unresolved_audio_ms") == 1600 && terminal.at("duration_ms") == 1600,
            "failed recovery sample accounting");
    require(terminal.at("successful_recoveries") == 0 && terminal.at("eof_recovery_attempts") == 1,
            "failed recovery counters");
}
static void cumulative_failures() {
    Model model; Mailbox mailbox;
    model.replies = {reply("first", "", false), reply("second", "", false)};
    model.recoveries = {reply("", "", false), reply("", "", true)};
    Session session(model, mailbox, "cumulative", "zh", false, false);
    session.audio(pcm(25600)); session.audio(pcm(25600)); session.finish();
    auto warnings = of_type("warning"); require(warnings.size() == 2, "each lost interval must be reported");
    require(warnings[0].at("start_sample") == 0 && warnings[0].at("end_sample") == 25600 &&
            warnings[1].at("start_sample") == 25600 && warnings[1].at("end_sample") == 51200,
            "failed interval boundaries must not overlap or disappear after reset");
    require(done().at("unresolved_audio_ms") == 3200 && done().at("duration_ms") == 3200 && done().at("complete") == false,
            "reset cannot clear previously unresolved audio");
    require(model.turns == std::vector<std::pair<size_t,bool>>{{25600,true},{25600,true}}, "recovery reset restores first cadence");
}
static void recovery_throws() {
    Model model; Mailbox mailbox; model.replies = {reply("pending source")}; model.fail_recovery = true;
    Session session(model, mailbox, "throws", "zh", false, false); session.audio(pcm(25600));
    bool propagated = false;
    try { session.finish(); }
    catch (const std::runtime_error & error) { propagated = std::string(error.what()) == "injected recovery failure"; }
    require(propagated, "recovery error must propagate to the existing process error handler");
    require(of_type("done").empty() && commits().empty(), "exception cannot emit success or commit a partial translation");
}
static void recovery_preserves_existing_source() {
    Model model; Mailbox mailbox;
    model.replies = {reply("five percent")}; model.recoveries = {reply("", "百分之五")};
    Session session(model, mailbox, "preserve", "zh", false, false); session.audio(pcm(25600)); session.finish();
    auto rows = commits();
    require(rows.size() == 1, "successful target recovery must commit once");
    require(rows[0].at("source") == "five percent", "empty recovery source must not delete previously received source");
    require(rows[0].at("translation") == "百分之五", "target recovery must remain intact");
    require(rows[0].at("segment_id") == 1 && rows[0].at("start_sample") == 0 && rows[0].at("end_sample") == 25600,
            "preserved source must keep the same pending segment and sample interval");
    require(done().at("complete") == true, "completed translation remains complete when preserving known source");
    revisions();
}
static void room_tone_needs_no_inference() {
    Model model; Mailbox mailbox;
    Session session(model, mailbox, "room", "zh", false, false);
    for (int i = 0; i < 40; ++i) session.audio(room_tone(hy::step_samples));
    session.finish();
    require(model.turns.empty(), "silence before any speech must not reach the model");
    require(model.recovered_samples.empty() && model.reset_count == 1, "silence must not recover or reset");
    require(of_type("warning").empty() && done().at("complete") == true, "silence is not untranslated audio");
    require(done().at("duration_ms") == 40 * 800, "skipped silence still advances the timeline");
}
static void room_tone_after_commit_keeps_context() {
    Model model; Mailbox mailbox;
    model.replies = {reply("hello", "你好"), reply("again", "再次")};
    Session session(model, mailbox, "pause", "zh", false, false);
    session.audio(pcm(hy::first_samples));
    for (int i = 0; i < 30; ++i) session.audio(room_tone(hy::step_samples));
    session.audio(pcm(hy::step_samples)); session.finish();
    require(model.turns == std::vector<std::pair<size_t,bool>>{{25600,true},{12800,false}},
            "a pause after committed speech keeps the context and costs no turns");
    require(model.reset_count == 1 && model.recovered_samples.empty(), "a pause is not a context reset");
    auto rows = commits(); require(rows.size() == 2, "both sides of the pause commit");
    require(rows[1].at("start_sample") == 25600 + 30 * 12800, "the next row starts after the pause");
    require(of_type("warning").empty() && done().at("complete") == true, "a pause is not an error");
}
static void trailing_silence_recovers_once() {
    Model model; Mailbox mailbox;
    model.replies = {reply("waiting")};
    for (int i = 0; i < 3; ++i) model.replies.push_back(reply(""));
    model.recoveries = {reply("waiting for", "等待")};
    Session session(model, mailbox, "tail", "zh", false, false);
    session.audio(pcm(hy::first_samples));
    for (int i = 0; i < 20; ++i) session.audio(room_tone(hy::step_samples));
    session.finish();
    require(model.recovered_samples.size() == 1, "untranslated speech recovers exactly once, however long the pause");
    require(model.turns.size() == 4, "the context reset by recovery does not reopen on silence");
    require(commits().size() == 1 && commits()[0].at("translation") == "等待", "recovered text commits");
    require(of_type("warning").empty() && done().at("complete") == true, "successful recovery is complete");
}
static void noise_the_model_never_hears_is_not_a_failure() {
    Model model; Mailbox mailbox;
    size_t turns = hy::max_pending_samples / hy::step_samples + 8;
    for (size_t i = 0; i <= turns; ++i) model.replies.push_back(reply(""));
    model.recoveries = {reply("", ""), reply("", "")};
    Session session(model, mailbox, "noise", "zh", false, false);
    session.audio(pcm(hy::first_samples));
    for (size_t i = 0; i < turns; ++i) session.audio(pcm(hy::step_samples));
    session.finish();
    require(of_type("warning").empty(), "audio with no heard speech is not reported as untranslated");
    require(done().at("complete") == true && done().at("unresolved_audio_ms") == 0, "noise cannot make a session incomplete");
    require(commits().empty(), "noise commits nothing");
}
static void source_without_target_waits_for_the_next_turn() {
    Model model; Mailbox mailbox;
    Reply broken = reply("no separator"); broken.malformed = true;
    model.replies = {broken, reply(" then", "然后")};
    Session session(model, mailbox, "malformed", "zh", false, false);
    session.audio(pcm(hy::first_samples)); session.audio(pcm(hy::step_samples)); session.finish();
    auto rows = commits(); require(rows.size() == 1, "the session survives a malformed turn");
    require(rows[0].at("source") == "no separator then", "text from the malformed turn is kept");
    require(rows[0].at("start_sample") == 0 && rows[0].at("end_sample") == 38400, "its audio stays in the row");
    require(done().at("malformed_turns") == 1 && done().at("complete") == true, "malformed turns are counted, not fatal");
}
static void whitespace_target_is_not_a_translation() {
    Model model; Mailbox mailbox;
    model.replies = {reply("hello", " "), reply(" world", "你好世界")};
    Session session(model, mailbox, "blank", "zh", false, false);
    session.audio(pcm(hy::first_samples)); session.audio(pcm(hy::step_samples)); session.finish();
    auto rows = commits(); require(rows.size() == 1, "a blank target must not commit an empty row");
    require(rows[0].at("source") == "hello world" && rows[0].at("translation") == "你好世界", "the blank turn's source stays pending");
}
static void sentence_end_rolls_context_over_early() {
    Model model; Mailbox mailbox;
    model.replies = {reply("first", "第一句。"), reply("second", "第二")};
    Session session(model, mailbox, "rollover", "zh", false, false);
    session.audio(pcm(hy::first_samples));
    model.position_value = 16384 * 4 / 5;
    session.audio(pcm(hy::first_samples)); session.finish();
    require(model.reset_count == 2, "a late context resets at a finished sentence, before it is forced mid-speech");
    require(model.recovered_samples.empty(), "the rollover itself needs no recovery");
    require(model.turns == std::vector<std::pair<size_t,bool>>{{25600,true},{25600,true}}, "the next turn opens a new context");
    require(done().at("context_resets") == 0 && done().at("early_rollovers") == 1, "an early rollover is not a forced context reset");
}
int main() {
    std::vector<std::pair<std::string,std::function<void()>>> cases = {
        {"room_tone_needs_no_inference", room_tone_needs_no_inference},
        {"room_tone_after_commit_keeps_context", room_tone_after_commit_keeps_context},
        {"trailing_silence_recovers_once", trailing_silence_recovers_once},
        {"noise_the_model_never_hears_is_not_a_failure", noise_the_model_never_hears_is_not_a_failure},
        {"source_without_target_waits_for_the_next_turn", source_without_target_waits_for_the_next_turn},
        {"whitespace_target_is_not_a_translation", whitespace_target_is_not_a_translation},
        {"sentence_end_rolls_context_over_early", sentence_end_rolls_context_over_early},
        {"wait_source_accumulates_until_target", wait_then_commit},
        {"recovery_replaces_same_segment_source", recovery_replaces},
        {"recovery_empty_source_preserves_received_source", recovery_preserves_existing_source},
        {"recovery_truncated_target_is_unresolved", [] { failed_recovery(false, "partial translation"); }},
        {"recovery_empty_target_is_unresolved", [] { failed_recovery(true, ""); }},
        {"unresolved_intervals_survive_reset", cumulative_failures},
        {"recovery_exception_never_reports_success", recovery_throws}
    };
    json report = {{"passed", true}, {"cases", json::array()}};
    for (const auto & item : cases) {
        events.clear();
        try { item.second(); report["cases"].push_back({{"name", item.first}, {"passed", true}}); }
        catch (const std::exception & error) {
            report["passed"] = false; report["cases"].push_back({{"name", item.first}, {"passed", false}, {"error", error.what()}});
        }
    }
    std::cout << report.dump(2) << '\n'; return report.at("passed").get<bool>() ? 0 : 1;
}
'''


def main():
    source_path = ROOT / "native/HySimulMT/main.cpp"
    source = source_path.read_text()
    session = extract_class(source, "Session")
    reply = re.findall(r"^struct Reply \{.*\};$", source, re.M)
    if len(reply) != 1:
        raise RuntimeError("Reply layout changed; review the fake model before testing")
    BUILD.mkdir(parents=True, exist_ok=True)
    harness = BUILD / "session.cpp"
    executable = BUILD / "session-tests"
    harness.write_text(PRELUDE + reply[0] + "\n" + FAKES + session + "\n" + TESTS)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O0", "-Wall", "-Wextra", "-Werror",
                    "-I", str(ROOT / "native/HySimulMT"),
                    "-I", str(ROOT / ".build/hy-runtime-src/vendor"),
                    str(harness), "-o", str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True)
    report = json.loads(result.stdout)
    report.update(schema_version=1, model_loaded=False, gpu_used=False,
                  source=str(source_path.relative_to(ROOT)),
                  session_source_sha256=hashlib.sha256(session.encode()).hexdigest(),
                  extraction="verbatim complete Session class; model and protocol output injected")
    output = BUILD / "results.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"report: {output}")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
