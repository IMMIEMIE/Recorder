#include "webrtc/common_audio/vad/include/webrtc_vad.h"
extern "C" {
__declspec(dllexport) VadInst * __cdecl recorder_vad_create() {
    VadInst * v = nullptr;
    if (WebRtcVad_Create(&v) || !v) return nullptr;
    if (WebRtcVad_Init(v) || WebRtcVad_set_mode(v, 2)) { WebRtcVad_Free(v); return nullptr; }
    return v;
}
__declspec(dllexport) int __cdecl recorder_vad_process(VadInst * v, const short * pcm, int count) { return WebRtcVad_Process(v, 16000, pcm, count); }
__declspec(dllexport) void __cdecl recorder_vad_destroy(VadInst * v) { if (v) WebRtcVad_Free(v); }
}
