#include <jni.h>
#include <string>
#include <cmath>
#include "rnnoise.h"

// Single DenoiseState for noise cancellation
// This is called from AudioPlaybackCaptureController.onBuffer() with
// RAW mono PCM at the device sample rate — the correct input for rnnoise.
DenoiseState *st1 = nullptr;
const int FRAME_SIZE = 480;

extern "C" JNIEXPORT void JNICALL
Java_live_videosdk_webrtc_audio_AudioPlaybackCaptureController_initNoiseCancellation(
        JNIEnv* env,
        jobject /* this */) {
    if (st1 == nullptr) {
        st1 = rnnoise_create(nullptr);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_live_videosdk_webrtc_audio_AudioPlaybackCaptureController_destroyNoiseCancellation(
        JNIEnv* env,
        jobject /* this */) {
    if (st1 != nullptr) {
        rnnoise_destroy(st1);
        st1 = nullptr;
    }
}

/**
 * Processes exactly FRAME_SIZE (480) short samples in-place.
 * Returns the VAD probability: 0.0 = noise, 1.0 = speech.
 *
 * Called with raw 48kHz mono PCM from AudioPlaybackCaptureController.onBuffer()
 * — this is the correct, broadband input format that rnnoise expects.
 */
extern "C" JNIEXPORT jfloat JNICALL
Java_live_videosdk_webrtc_audio_AudioPlaybackCaptureController_processAudioFrame(
        JNIEnv* env,
        jobject /* this */,
        jshortArray audioBuffer) {

    if (st1 == nullptr) return 1.0f;

    jsize len = env->GetArrayLength(audioBuffer);
    if (len < FRAME_SIZE) return 1.0f;

    jboolean isCopy;
    jshort* elements = env->GetShortArrayElements(audioBuffer, &isCopy);

    // Convert int16 → float (rnnoise expects float in int16 value range)
    float x[FRAME_SIZE];
    for (int i = 0; i < FRAME_SIZE; i++) {
        x[i] = elements[i];
    }

    // Process with rnnoise.
    // Output x[] = denoised audio of PREVIOUS frame (1-frame latency by design).
    // Return value = VAD probability for CURRENT frame.
    float vad = rnnoise_process_frame(st1, x, x);

    // Convert denoised float → int16 with clamping
    for (int i = 0; i < FRAME_SIZE; i++) {
        float val = std::round(x[i]);
        if (val > 32767.0f)  val = 32767.0f;
        if (val < -32768.0f) val = -32768.0f;
        elements[i] = static_cast<jshort>(val);
    }

    env->ReleaseShortArrayElements(audioBuffer, elements, 0);
    return vad;
}
