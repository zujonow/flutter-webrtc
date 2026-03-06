package live.videosdk.webrtc.audio;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.util.Log;

import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;

/**
 * AudioPlaybackCaptureController
 *
 * Implements JavaAudioDeviceModule.AudioBufferCallback to receive raw writable
 * mic PCM from WebRTC before encoding occurs.
 *
 * Acts as a pure "frame bus": if an external AudioFrameProcessor is registered,
 * it delegates each 480-sample chunk to the processor for in-place
 * modification.
 * flutter_webrtc has no knowledge of what the processor does.
 */
public class AudioPlaybackCaptureController implements JavaAudioDeviceModule.AudioBufferCallback {
    private static final String TAG = "AudioPlaybackCaptureController";
    private static final int BUFFER_SIZE_FACTOR = 2;
    private static final int SAMPLE_RATE_CAPTURE = 24000;
    private static final int CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO;
    private static final int AUDIO_FORMAT_CONST = AudioFormat.ENCODING_PCM_16BIT;
    private static final int BYTES_PER_SAMPLE = 2;
    private static final int CHANNELS = 2;
    private static final int FRAME_SIZE = 480; // 10ms at 48kHz

    private final android.content.Context context;
    private AudioRecord audioRecord;
    private volatile boolean isCapturing = false;
    private MediaProjection mediaProjection;
    private volatile boolean shareScreenAudio;
    private final JavaAudioDeviceModule audioDeviceModule;

    // -----------------------------------------------------------------------
    // External audio processor registration — zero rnnoise knowledge here
    // -----------------------------------------------------------------------
    private static volatile AudioFrameProcessor externalProcessor = null;

    /**
     * Register an external AudioFrameProcessor. The processor's process(short[])
     * will be called for every 480-sample frame on the WebRTC audio thread.
     * Pass null to unregister.
     */
    public static void setAudioFrameProcessor(AudioFrameProcessor processor) {
        externalProcessor = processor;
        Log.d(TAG, ">>> AudioFrameProcessor " + (processor != null ? "registered" : "cleared"));
    }

    // -----------------------------------------------------------------------

    public AudioPlaybackCaptureController(android.content.Context context,
            JavaAudioDeviceModule audioDeviceModule) {
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

        // Delegate to external processor if registered
        AudioFrameProcessor proc = externalProcessor;
        if (proc != null && bytesRead > 0) {
            applyExternalProcessor(proc, buffer, bytesRead, sampleRate);
        }

        // Screen-share mode: mix device audio into mic buffer
        if (!isCapturing || audioRecord == null || !shareScreenAudio) {
            return captureTimeNs;
        }

        byte[] sysData = new byte[bytesRead];
        int sysRead = audioRecord.read(sysData, 0, bytesRead);

        for (int i = 0; i + 1 < bytesRead; i += 2) {
            int mLo = buffer.get(i) & 0xFF;
            int mHi = buffer.get(i + 1);
            short m = (short) ((mHi << 8) | mLo);

            short s = 0;
            if (sysRead > i + 1) {
                int sLo = sysData[i] & 0xFF;
                int sHi = sysData[i + 1];
                s = (short) ((sHi << 8) | sLo);
            }

            int mix = m + s;
            if (mix > Short.MAX_VALUE)       mix = Short.MAX_VALUE;
            else if (mix < Short.MIN_VALUE)  mix = Short.MIN_VALUE;

            buffer.put(i,     (byte) ((short) mix & 0xFF));
            buffer.put(i + 1, (byte) (((short) mix >>> 8) & 0xFF));
        }

        return captureTimeNs;
    }

    /**
     * Slice the raw ByteBuffer into 480-sample short[] frames, pass each
     * to the processor in-place, write denoised result back into the buffer.
     */
    private void applyExternalProcessor(AudioFrameProcessor proc,
            ByteBuffer buffer,
            int bytesAvailable,
            int sampleRate) {
        int frameSize = (sampleRate == 48000) ? FRAME_SIZE : Math.max(1, sampleRate * 10 / 1000);
        int frameSizeBytes = frameSize * BYTES_PER_SAMPLE;
        int numFrames = bytesAvailable / frameSizeBytes;
        if (numFrames == 0) return;

        short[] frame = new short[frameSize];
        for (int f = 0; f < numFrames; f++) {
            int byteOffset = f * frameSizeBytes;

            // Read frame (little-endian Int16)
            for (int i = 0; i < frameSize; i++) {
                int lo = buffer.get(byteOffset + i * 2) & 0xFF;
                int hi = buffer.get(byteOffset + i * 2 + 1);
                frame[i] = (short) ((hi << 8) | lo);
            }

            // Delegate to plugin — modifies frame in-place
            proc.process(frame);

            // Write processed frame back into the buffer
            for (int i = 0; i < frameSize; i++) {
                buffer.put(byteOffset + i * 2,     (byte) (frame[i] & 0xFF));
                buffer.put(byteOffset + i * 2 + 1, (byte) ((frame[i] >>> 8) & 0xFF));
            }
        }
    }

    public void startCapture() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.e(TAG, "Audio playback capture requires Android Q+");
            return;
        }
        if (isCapturing) return;

        try {
            AudioPlaybackCaptureConfiguration config =
                    new AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                            .addMatchingUsage(AudioAttributes.USAGE_GAME)
                            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                            .build();

            int minBuf = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE_CAPTURE, CHANNEL_CONFIG, AUDIO_FORMAT_CONST);
            if (minBuf == AudioRecord.ERROR || minBuf == AudioRecord.ERROR_BAD_VALUE) {
                Log.e(TAG, "Failed to get minimum buffer size");
                return;
            }
            int bufferSize = Math.max(BUFFER_SIZE_FACTOR * minBuf,
                    CHANNELS * BYTES_PER_SAMPLE * (SAMPLE_RATE_CAPTURE / 100));

            audioRecord = new AudioRecord.Builder()
                    .setAudioPlaybackCaptureConfig(config)
                    .setAudioFormat(new AudioFormat.Builder()
                            .setEncoding(AUDIO_FORMAT_CONST)
                            .setSampleRate(SAMPLE_RATE_CAPTURE)
                            .setChannelMask(CHANNEL_CONFIG)
                            .build())
                    .setBufferSizeInBytes(bufferSize)
                    .build();

            if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "Failed to initialize AudioRecord");
                return;
            }

            audioRecord.startRecording();
            if (audioRecord.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                Log.e(TAG, "Failed to start recording");
                return;
            }
            isCapturing = true;

        } catch (Exception e) {
            Log.e(TAG, "Error starting audio capture", e);
            stopCapture();
        }
    }

    public void stopCapture() {
        if (!isCapturing) return;
        isCapturing = false;
        if (audioRecord != null) {
            try { audioRecord.stop(); audioRecord.release(); }
            catch (Exception e) { Log.e(TAG, "Error releasing AudioRecord: " + e.getMessage()); }
            audioRecord = null;
        }
    }

    public void dispose() {
        stopCapture();
        mediaProjection = null;
    }
}