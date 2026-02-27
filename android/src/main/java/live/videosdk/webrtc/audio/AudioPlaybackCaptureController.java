package live.videosdk.webrtc.audio;

import android.annotation.TargetApi;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.util.Log;

import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;

public class AudioPlaybackCaptureController implements JavaAudioDeviceModule.AudioBufferCallback {
    private static final String TAG = "AudioPlaybackCaptureController";
    private static final int BUFFER_SIZE_FACTOR = 2;
    private static final float DEFAULT_GAIN = 1.0f;
    private static final float MIN_GAIN_CHANGE = 0.01f;
    private static final int SAMPLE_RATE = 24000;
    private static final int CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO;
    private static final int AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT;
    private static final int BYTES_PER_SAMPLE = 2; // 16-bit audio
    private static final int CHANNELS = 2; // Stereo

    private final Context context;
    private AudioRecord audioRecord;
    private boolean isCapturing = false;
    private MediaProjection mediaProjection;

    private boolean shareScreenAudio ;
    private float gain = DEFAULT_GAIN;

    // New field to hold the ADM you built in WebRTCModule
    private final JavaAudioDeviceModule audioDeviceModule;

    public AudioPlaybackCaptureController(Context context,JavaAudioDeviceModule audioDeviceModule) {
        this.context = context;
        this.audioDeviceModule = audioDeviceModule;
    }

    public void initialize(MediaProjection mediaProjection, boolean shareScreenAudio) {
        this.mediaProjection = mediaProjection;
        this.shareScreenAudio = shareScreenAudio;
    }

    // -----------------------------------------------------------------------
    // Noise Cancellation via rnnoise JNI — applied HERE because this is
    // raw mic PCM before WebRTC's sub-band splitter. rnnoise requires
    // full-band broadband PCM (not sub-band-split data).
    // -----------------------------------------------------------------------
    private static boolean rnnoiseLibLoaded = false;
    private static final String RNNOISE_TAG = "RustNoiseCancel";

    static {
        try {
            System.loadLibrary("rnnoise_jni");
            rnnoiseLibLoaded = true;
            android.util.Log.d(RNNOISE_TAG, ">>> rnnoise_jni loaded in AudioPlaybackCaptureController");
        } catch (UnsatisfiedLinkError e) {
            android.util.Log.e(RNNOISE_TAG, ">>> Failed to load rnnoise_jni: " + e.getMessage());
        }
    }

    // JNI bindings — implemented in native-lib.cpp
    private native void initNoiseCancellation();
    private native void destroyNoiseCancellation();
    private native float processAudioFrame(short[] audioData);

    private boolean rnnoiseInitialized = false;

    private void ensureRnnoiseInitialized() {
        if (!rnnoiseInitialized && rnnoiseLibLoaded) {
            try {
                initNoiseCancellation();
                rnnoiseInitialized = true;
                android.util.Log.d(RNNOISE_TAG, ">>> rnnoise initialized in onBuffer hook");
            } catch (Throwable t) {
                android.util.Log.e(RNNOISE_TAG, ">>> rnnoise init failed: " + t.getMessage());
            }
        }
    }

    private static final int FRAME_SIZE = 480; // 10ms at 48kHz

    /**
     * Apply rnnoise to raw 16-bit PCM in the buffer.
     * Processes in-place using 480-sample frames (10ms at 48kHz).
     */
    private long noiseCancelFrameCount = 0;

    private void applyNoiseCancellation(ByteBuffer buffer, int bytesAvailable, int sampleRate) {
        ensureRnnoiseInitialized();
        if (!rnnoiseInitialized) return;

        int frameSize = (sampleRate == 48000) ? 480 : (sampleRate * 10 / 1000);
        if (frameSize <= 0) return;
        int frameSizeBytes = frameSize * 2; // 16-bit = 2 bytes per sample
        int numFrames = bytesAvailable / frameSizeBytes;
        if (numFrames == 0) {
            android.util.Log.w(RNNOISE_TAG, ">>> applyNC: 0 frames! sampleRate=" + sampleRate + " bytesAvailable=" + bytesAvailable + " frameSize=" + frameSize);
            return;
        }

        noiseCancelFrameCount += numFrames;
        if ((noiseCancelFrameCount / 100) > ((noiseCancelFrameCount - numFrames) / 100)) {
            System.out.println(">>> [RustNoiseCancel] onBuffer ACTIVE! total frames=" + noiseCancelFrameCount + " sampleRate=" + sampleRate);
        }

        short[] frame = new short[frameSize];
        for (int f = 0; f < numFrames; f++) {
            int byteOffset = f * frameSizeBytes;
            // Read frame from buffer (little-endian int16)
            for (int i = 0; i < frameSize; i++) {
                int lo = buffer.get(byteOffset + i * 2) & 0xFF;
                int hi = buffer.get(byteOffset + i * 2 + 1);
                frame[i] = (short) ((hi << 8) | lo);
            }
            // Apply rnnoise
            processAudioFrame(frame);
            // Write denoised frame back
            for (int i = 0; i < frameSize; i++) {
                buffer.put(byteOffset + i * 2,     (byte) (frame[i] & 0xFF));
                buffer.put(byteOffset + i * 2 + 1, (byte) ((frame[i] >>> 8) & 0xFF));
            }
        }
    }

    private boolean firstBufferLogged = false;

    @Override
    public long onBuffer(ByteBuffer buffer,
                         int audioFormat,
                         int channelCount,
                         int sampleRate,
                         int bytesRead,
                         long captureTimeNs) {

        // Log the first call so we can see the exact params WebRTC passes
        if (!firstBufferLogged) {
            firstBufferLogged = true;
            android.util.Log.d(RNNOISE_TAG, ">>> onBuffer: sampleRate=" + sampleRate
                    + " channelCount=" + channelCount
                    + " bytesRead=" + bytesRead
                    + " audioFormat=" + audioFormat);
            System.out.println(">>> [RustNoiseCancel] onBuffer: sampleRate=" + sampleRate
                    + " channelCount=" + channelCount + " bytesRead=" + bytesRead);
        }

        // Apply noise cancellation on raw mic PCM BEFORE any mixing or WebRTC processing
        // Works for mono (channelCount=1). For stereo we still process interleaved channel 0.
        if (bytesRead > 0) {
            applyNoiseCancellation(buffer, bytesRead, sampleRate);
        }

        // If not capturing system audio, we're done.
        if (!isCapturing || audioRecord == null || !shareScreenAudio) {
            return captureTimeNs;
        }

        // Read system audio and mix into the (now denoised) mic buffer
        byte[] sysData = new byte[bytesRead];
        int sysRead = audioRecord.read(sysData, 0, bytesRead);

        // Mix in-place: for each 16-bit sample pair
        for (int i = 0; i + 1 < bytesRead; i += 2) {
            // 1) absolute read mic sample (little-endian)
            int mLo = buffer.get(i) & 0xFF;
            int mHi = buffer.get(i + 1);
            short m = (short) ((mHi << 8) | mLo);

            // 2) absolute read system sample if available
            short s = 0;
            if (sysRead > i + 1) {
                int sLo = sysData[i] & 0xFF;
                int sHi = sysData[i + 1];
                s = (short) ((sHi << 8) | sLo);
            }

            // 3) sum + clamp
            int mix = m + s;
            if (mix > Short.MAX_VALUE) mix = Short.MAX_VALUE;
            else if (mix < Short.MIN_VALUE) mix = Short.MIN_VALUE;
            short out = (short) mix;

            // 4) absolute write back (little-endian)
            buffer.put(i,     (byte) (out & 0xFF));
            buffer.put(i + 1, (byte) ((out >>> 8) & 0xFF));
        }

        return captureTimeNs;
    }

    public void startCapture() {
        // 1) Only Android Q+ supports AudioPlaybackCapture
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.e(TAG, "Audio playback capture requires Android Q+");
            return;
        }

        // 2) Already mixing? nothing to do.
        if (isCapturing) {
            Log.d(TAG, "Audio capture is already running");
            return;
        }

        try {

            // 4) Build the playback‐capture config
            AudioPlaybackCaptureConfiguration config =
                    new AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                            .addMatchingUsage(AudioAttributes.USAGE_GAME)
                            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                            .build();

            // 5) Compute buffer sizes
            int minBuf = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT);
            if (minBuf == AudioRecord.ERROR || minBuf == AudioRecord.ERROR_BAD_VALUE) {
                Log.e(TAG, "Failed to get minimum buffer size");
                return;
            }
            int bytesPerFrame   = CHANNELS * BYTES_PER_SAMPLE;   // stereo * 16-bit
            int framesPerBuffer = SAMPLE_RATE / 100;             // 10 ms of audio
            int targetBuf       = bytesPerFrame * framesPerBuffer;
            int bufferSize      = Math.max(BUFFER_SIZE_FACTOR * minBuf, targetBuf);

            // 6) Create and init AudioRecord for system audio
            audioRecord = new AudioRecord.Builder()
                    .setAudioPlaybackCaptureConfig(config)
                    .setAudioFormat(new AudioFormat.Builder()
                            .setEncoding(AUDIO_FORMAT)
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelMask(CHANNEL_CONFIG)
                            .build())
                    .setBufferSizeInBytes(bufferSize)
                    .build();

            if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "Failed to initialize AudioRecord");
                return;
            }

            // 7) Start the OS recording loop
            audioRecord.startRecording();
            if (audioRecord.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                Log.e(TAG, "Failed to start recording - state: " + audioRecord.getRecordingState());
                return;
            }

            // 8) Flip the flag so onBuffer() begins mixing system audio
            isCapturing = true;

        } catch (Exception e) {
            Log.e(TAG, "Error starting audio capture", e);
            stopCapture();
        }
    }

    public void stopCapture() {
        if (!isCapturing) {
            return;
        }

        Log.d(TAG, "Stopping audio capture");
        isCapturing = false;


        if (audioRecord != null) {
            try {
                audioRecord.stop();
                audioRecord.release();
            } catch (Exception e) {
                Log.e(TAG, "Error releasing AudioRecord: " + e.getMessage());
            }
            audioRecord = null;
        }
    }

    public void dispose() {
        stopCapture();
        mediaProjection = null;
    }

}