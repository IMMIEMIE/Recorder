param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
# Prepare a build-only copy. The pinned vendor checkout and the x86 build stay untouched.
$text = [IO.File]::ReadAllText($Source).Replace("`r`n", "`n")
$signature = 'bool   sched_reset = true) {'
if (-not $text.Contains($signature)) { throw 'Pinned Whisper scheduler signature changed' }
$text = $text.Replace($signature, "bool   sched_reset = true,`n         ggml_abort_callback   abort_callback = nullptr,`n                        void * abort_callback_data = nullptr) {")
$threadSetter = '        auto * fn_set_n_threads = (ggml_backend_set_n_threads_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_n_threads");'
if (-not $text.Contains($threadSetter)) { throw 'Pinned Whisper backend registry changed' }
$text = $text.Replace($threadSetter, @'
        auto * fn_set_abort = (ggml_backend_set_abort_callback_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_abort_callback");
        if (fn_set_abort) fn_set_abort(backend, abort_callback, abort_callback_data);
'@ + "`n" + $threadSetter)
foreach ($bounds in @(@('static bool whisper_encode_internal(', 'static struct ggml_cgraph * whisper_build_graph_decoder('), @('static bool whisper_decode_internal(', '//  500 -> 00:05.000'))) {
    $start = $text.IndexOf($bounds[0], [StringComparison]::Ordinal)
    $end = $text.IndexOf($bounds[1], $start, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) { throw 'Pinned Whisper inference boundaries changed' }
    $section = $text.Substring($start, $end - $start)
    if (-not $section.Contains('ggml_graph_compute_helper(sched, gf, n_threads)')) { throw 'Pinned Whisper graph calls changed' }
    $section = $section.Replace('ggml_graph_compute_helper(sched, gf, n_threads)', 'ggml_graph_compute_helper(sched, gf, n_threads, true, abort_callback, abort_callback_data)')
    $text = $text.Substring(0, $start) + $section + $text.Substring($end)
}
[IO.File]::WriteAllText($Output, $text, [Text.UTF8Encoding]::new($false))
