package live.videosdk.webrtc.audio;

/**
 * AudioFrameProcessor
 *
 * A minimal interface for external plugins to hook into the WebRTC mic
 * audio pipeline via AudioPlaybackCaptureController.
 *
 * The plugin registers an implementation via:
 *   AudioPlaybackCaptureController.setAudioFrameProcessor(processor)
 *
 * The controller calls process(frame) for every 480-sample chunk on the
 * real-time audio thread. The implementation modifies the frame in-place.
 */
public interface AudioFrameProcessor {
    /**
     * Process a 480-sample Int16 PCM frame in-place.
     * Called on the WebRTC audio thread — must be fast (no I/O, no allocation).
     *
     * @param frame 480 Int16 samples (10ms at 48kHz). Modified in-place.
     * @return true if processing was applied, false to pass frame through unchanged.
     */
    boolean process(short[] frame);
}
