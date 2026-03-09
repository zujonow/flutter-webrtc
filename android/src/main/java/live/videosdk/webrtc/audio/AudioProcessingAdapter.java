package live.videosdk.webrtc.audio;

import org.webrtc.ExternalAudioProcessingFactory;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

public class AudioProcessingAdapter implements ExternalAudioProcessingFactory.AudioProcessing {
    public interface ExternalAudioFrameProcessing {
        void initialize(int sampleRateHz, int numChannels);

        void reset(int newRate);

        void process(int numBands, int numFrames, ByteBuffer buffer);
    }

    public AudioProcessingAdapter() {}
    
    // -----------------------------------------------------------------------
    // Static hook for external plugins (like flutter_videosdk_media_effects)
    // to process audio globally without needing the instance reference.
    // -----------------------------------------------------------------------
    private static volatile ExternalAudioFrameProcessing staticAudioProcessor = null;

    public static void setStaticAudioProcessor(ExternalAudioFrameProcessing processor) {
        staticAudioProcessor = processor;
    }
    // -----------------------------------------------------------------------
    List<ExternalAudioFrameProcessing> audioProcessors = new ArrayList<>();

    public void addProcessor(ExternalAudioFrameProcessing audioProcessor) {
        synchronized (audioProcessors) {
            audioProcessors.add(audioProcessor);
        }
    }

    public void removeProcessor(ExternalAudioFrameProcessing audioProcessor) {
        synchronized (audioProcessors) {
            audioProcessors.remove(audioProcessor);
        }
    }

    @Override
    public void initialize(int sampleRateHz, int numChannels) {
        synchronized (audioProcessors) {
            for (ExternalAudioFrameProcessing audioProcessor : audioProcessors) {
                audioProcessor.initialize(sampleRateHz, numChannels);
            }
        }
        ExternalAudioFrameProcessing staticProc = staticAudioProcessor;
        if (staticProc != null) {
            staticProc.initialize(sampleRateHz, numChannels);
        }
    }

    @Override
    public void reset(int newRate) {
        synchronized (audioProcessors) {
            for (ExternalAudioFrameProcessing audioProcessor : audioProcessors) {
                audioProcessor.reset(newRate);
            }
        }
        ExternalAudioFrameProcessing staticProc = staticAudioProcessor;
        if (staticProc != null) {
            staticProc.reset(newRate);
        }
    }

    @Override
    public void process(int numBands, int numFrames, ByteBuffer buffer) {
        synchronized (audioProcessors) {
            for (ExternalAudioFrameProcessing audioProcessor : audioProcessors) {
                audioProcessor.process(numBands, numFrames, buffer);
            }
        }
        ExternalAudioFrameProcessing staticProc = staticAudioProcessor;
        if (staticProc != null) {
            staticProc.process(numBands, numFrames, buffer);
        }
    }
}