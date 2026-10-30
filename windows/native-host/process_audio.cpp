#include <windows.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <wrl.h>
#include <thread>
#include <vector>
using Microsoft::WRL::ComPtr;
using AudioCallback = void(__cdecl *)(const unsigned char *, int, HRESULT, void *);

class Activation final : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>, IActivateAudioInterfaceCompletionHandler, Microsoft::WRL::FtmBase> {
public:
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HRESULT result = E_PENDING;
    ComPtr<IAudioClient> client;
    ~Activation() { CloseHandle(done); }
    STDMETHODIMP ActivateCompleted(IActivateAudioInterfaceAsyncOperation * operation) override {
        HRESULT activated = E_FAIL; ComPtr<IUnknown> object;
        result = operation->GetActivateResult(&activated, &object);
        if (SUCCEEDED(result)) result = activated;
        if (SUCCEEDED(result)) result = object.As(&client);
        SetEvent(done); return S_OK;
    }
};
struct Capture {
    HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, nullptr), ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HRESULT result = E_PENDING; std::thread worker;
    ~Capture() { SetEvent(stop); if (worker.joinable()) worker.join(); CloseHandle(stop); CloseHandle(ready); }
    void run(DWORD process, AudioCallback callback, void * user) {
        HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        HRESULT hr = initialized;
        auto activation = Microsoft::WRL::Make<Activation>();
        ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
        AUDIOCLIENT_ACTIVATION_PARAMS parameters{};
        parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
        parameters.ProcessLoopbackParams.TargetProcessId = process;
        parameters.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;
        PROPVARIANT value{}; value.vt = VT_BLOB; value.blob.cbSize = sizeof(parameters); value.blob.pBlobData = reinterpret_cast<BYTE *>(&parameters);
        if (SUCCEEDED(hr)) hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &value, activation.Get(), &operation);
        if (SUCCEEDED(hr)) hr = WaitForSingleObject(activation->done, 10000) == WAIT_OBJECT_0 ? activation->result : HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        HANDLE audioEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        ComPtr<IAudioCaptureClient> capture;
        WAVEFORMATEX format{}; format.wFormatTag = WAVE_FORMAT_PCM; format.nChannels = 1; format.nSamplesPerSec = 16000; format.wBitsPerSample = 16; format.nBlockAlign = 2; format.nAvgBytesPerSec = 32000;
        if (SUCCEEDED(hr)) hr = activation->client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, 0, 0, &format, nullptr);
        if (SUCCEEDED(hr)) hr = activation->client->GetService(IID_PPV_ARGS(&capture));
        if (SUCCEEDED(hr)) hr = activation->client->SetEventHandle(audioEvent);
        if (SUCCEEDED(hr)) hr = activation->client->Start();
        result = hr; SetEvent(ready);
        HANDLE wait[] = {stop, audioEvent};
        while (SUCCEEDED(hr) && WaitForMultipleObjects(2, wait, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) {
            UINT32 frames = 0; hr = capture->GetNextPacketSize(&frames);
            while (SUCCEEDED(hr) && frames > 0) {
                BYTE * bytes = nullptr; DWORD flags = 0;
                hr = capture->GetBuffer(&bytes, &frames, &flags, nullptr, nullptr);
                if (FAILED(hr)) break;
                if (flags & AUDCLNT_BUFFERFLAGS_SILENT) { std::vector<unsigned char> silence(frames * 2, 0); callback(silence.data(), static_cast<int>(silence.size()), S_OK, user); }
                else callback(bytes, static_cast<int>(frames * 2), S_OK, user);
                hr = capture->ReleaseBuffer(frames);
                if (SUCCEEDED(hr)) hr = capture->GetNextPacketSize(&frames);
            }
        }
        if (activation->client) activation->client->Stop();
        if (FAILED(hr)) callback(nullptr, 0, hr, user);
        capture.Reset(); operation.Reset(); activation.Reset(); CloseHandle(audioEvent);
        if (SUCCEEDED(initialized)) CoUninitialize();
    }
};
extern "C" __declspec(dllexport) Capture * __cdecl recorder_audio_start(DWORD process, AudioCallback callback, void * user, HRESULT * error) {
    if (!callback || !error) return nullptr;
    auto capture = new Capture();
    capture->worker = std::thread([=] { capture->run(process, callback, user); });
    WaitForSingleObject(capture->ready, INFINITE); *error = capture->result;
    if (FAILED(*error)) { delete capture; return nullptr; }
    return capture;
}
extern "C" __declspec(dllexport) void __cdecl recorder_audio_stop(Capture * capture) { delete capture; }
