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

    @Override
    public long onBuffer(ByteBuffer buffer,
                         int audioFormat,
                         int channelCount,
                         int sampleRate,
                         int bytesRead,
                         long captureTimeNs) {
        // If not capturing system audio, do nothing.
        if (!isCapturing || audioRecord == null || !shareScreenAudio) {
            return captureTimeNs;
        }

        // Read system audio into its own array
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
            Log.d(TAG, "Audio capture started: mixing mic + system audio");

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

        Log.d(TAG, "Audio capture stopped");
    }

    public void dispose() {
        Log.d(TAG, "Disposing AudioPlaybackCaptureController");
        stopCapture();
        mediaProjection = null;
    }

}