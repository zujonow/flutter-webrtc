package live.videosdk.webrtc.audio;

import android.util.Log;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Implements the double-pass Rust neural network noise cancellation.
 * Hooks into WebRTC's ExternalAudioProcessingFactory via the AudioProcessingAdapter.
 * This processes audio BEFORE it is sent out over WebRTC.
 */
public class RustNoiseCancellationProcessor implements AudioProcessingAdapter.ExternalAudioFrameProcessing {
    private static final String TAG = "RustNoiseCancel";
    private volatile boolean isInitialized = false;
    private final java.util.concurrent.atomic.AtomicLong frameCount = new java.util.concurrent.atomic.AtomicLong(0);

    // Temporally smoothed gain applied to bands 1 and 2.
    // Using IIR low-pass filter: smoothed = 0.85*prev + 0.15*target
    // This prevents rapid gain changes which cause musical noise / whistling.
    private float smoothedGain = 1.0f;

    // Minimum gain floor: never suppress to less than 5% of original signal.
    // Avoids the tonal artifacts ("ringing") from complete silence transitions.
    private static final float GAIN_FLOOR = 0.05f;

    static {
        // Prominent startup log - visible in terminal via: adb logcat | grep RustNoiseCancel
        System.out.println(">>> [RustNoiseCancel] Loading rnnoise_jni native library...");
        Log.d(TAG, ">>> Loading rnnoise_jni native library...");
        try {
            System.loadLibrary("rnnoise_jni");
            System.out.println(">>> [RustNoiseCancel] rnnoise_jni loaded SUCCESSFULLY!");
            Log.d(TAG, ">>> rnnoise_jni loaded SUCCESSFULLY!");
        } catch (UnsatisfiedLinkError e) {
            System.out.println(">>> [RustNoiseCancel] FAILED to load rnnoise_jni: " + e.getMessage());
            Log.e(TAG, ">>> FAILED to load rnnoise_jni: " + e.getMessage());
        }
    }

    // JNI Methods implemented in native-lib.cpp
    private native void initNoiseCancellation();
    private native void destroyNoiseCancellation();
    // Returns the VAD probability: 0.0 = noise/silence, 1.0 = speech
    private native float processAudioFrame(short[] audioData);

    @Override
    public void initialize(int sampleRateHz, int numChannels) {
        System.out.println(">>> [RustNoiseCancel] initialize() called! sampleRate=" + sampleRateHz + " channels=" + numChannels);
        Log.d(TAG, ">>> initialize() called! sampleRate=" + sampleRateHz + " channels=" + numChannels);
        if (!isInitialized) {
            try {
                initNoiseCancellation();
                isInitialized = true;
                System.out.println(">>> [RustNoiseCancel] Rust double-pass NN initialized successfully!");
                Log.d(TAG, ">>> Rust double-pass NN initialized successfully!");
            } catch (Throwable t) {
                System.out.println(">>> [RustNoiseCancel] INIT FAILED: " + t.getMessage());
                Log.e(TAG, ">>> INIT FAILED: " + t.getMessage());
            }
        }
    }

    @Override
    public void reset(int newRate) {
        System.out.println(">>> [RustNoiseCancel] reset() called with newRate=" + newRate);
        Log.d(TAG, ">>> reset() called with newRate=" + newRate);
        if (isInitialized) {
            try {
                destroyNoiseCancellation();
                isInitialized = false;
            } catch (Throwable t) {
                Log.e(TAG, "Error during reset cleanup: " + t.getMessage());
            }
        }
        try {
            initNoiseCancellation();
            isInitialized = true;
        } catch (Throwable t) {
            Log.e(TAG, "Failed to reinitialize after reset: " + t.getMessage());
        }
    }

    @Override
    public void process(int numBands, int numFrames, ByteBuffer buffer) {
        if (!isInitialized) {
            long count = frameCount.incrementAndGet();
            if (count % 100 == 0) {
                System.out.println(">>> [RustNoiseCancel] process() called but NOT initialized! count=" + count);
            }
            return;
        }
        if (buffer == null || buffer.remaining() < 2) return;

        long count = frameCount.incrementAndGet();
        if (count % 100 == 0) {
            System.out.println(">>> [RustNoiseCancel] ACTIVE! Processed " + count + " frames. numBands=" + numBands + " numFrames=" + numFrames);
        }

        try {
            buffer.order(ByteOrder.nativeOrder());

            int totalSamples = buffer.remaining() / 2;
            short[] allSamples = new short[totalSamples];
            buffer.asShortBuffer().get(allSamples);

            // -------------------------------------------------------
            // Band-aware processing:
            //   Band 0 (first numFrames shorts) = broadband 0-8kHz audio
            //     → run through rnnoise (correct input format)
            //     → rnnoise also returns VAD probability for current frame
            //   Bands 1+2 (remaining shorts) = high-freq sub-band data
            //     → DO NOT run through rnnoise (wrong format, causes whistling)
            //     → Instead: apply same smooth VAD-based gain to maintain
            //                spectral balance without any inter-band artifacts
            // -------------------------------------------------------

            // 1. Extract band 0 and run rnnoise on it
            short[] band0 = java.util.Arrays.copyOf(allSamples, numFrames);
            float vad = processAudioFrame(band0);  // modifies band0 in-place, returns VAD

            // 2. Compute smooth target gain from VAD probability
            //    vad=1.0 → speech → gain=1.0 (no suppression)
            //    vad=0.0 → noise  → gain=GAIN_FLOOR (max suppression, but never 0)
            float targetGain = GAIN_FLOOR + (1.0f - GAIN_FLOOR) * vad;

            // 3. Apply IIR low-pass filter to gain to prevent rapid changes
            //    (rapid changes cause tonal artifacts = whistling)
            smoothedGain = 0.85f * smoothedGain + 0.15f * targetGain;

            // 4. Write rnnoise-processed band 0 back
            for (int i = 0; i < numFrames; i++) {
                allSamples[i] = band0[i];
            }

            // 5. Apply smooth gain to bands 1 and 2
            for (int i = numFrames; i < totalSamples; i++) {
                allSamples[i] = (short) Math.round(allSamples[i] * smoothedGain);
            }

            // 6. Write all samples back to the WebRTC buffer
            buffer.rewind();
            buffer.asShortBuffer().put(allSamples);
        } catch (Throwable t) {
            System.out.println(">>> [RustNoiseCancel] process() ERROR: " + t.getMessage());
            Log.e(TAG, ">>> process() ERROR: " + t.getMessage());
        }
    }

    public void destroy() {
        if (isInitialized) {
            try {
                destroyNoiseCancellation();
                isInitialized = false;
                System.out.println(">>> [RustNoiseCancel] Destroyed.");
                Log.d(TAG, ">>> Destroyed.");
            } catch (Throwable t) {
                Log.e(TAG, "Failed to destroy: " + t.getMessage());
            }
        }
    }
}
