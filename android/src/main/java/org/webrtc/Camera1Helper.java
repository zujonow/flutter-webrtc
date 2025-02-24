package org.webrtc;

import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.List;

/**
 * A helper to access package-protected methods used in [Camera2Session]
 * <p>
 * Note: cameraId as used in the Camera1XXX classes refers to the index within the list of cameras.
 *
 * @suppress
 */

public class Camera1Helper {

    public static int getCameraId(String deviceName) {
        return Camera1Enumerator.getCameraIndex(deviceName);
    }

    @Nullable
    public static List<CameraEnumerationAndroid.CaptureFormat> getSupportedFormats(int cameraId) {
        return Camera1Enumerator.getSupportedFormats(cameraId);
    }

    public static Size findClosestCaptureFormat(int cameraId, int width, int height) {
        List<CameraEnumerationAndroid.CaptureFormat> formats = getSupportedFormats(cameraId);

        List<Size> sizes = new ArrayList<>();
        if (formats != null) {
            for (CameraEnumerationAndroid.CaptureFormat format : formats) {
                sizes.add(new Size(format.width, format.height));
            }
        }

        return CameraEnumerationAndroid.getClosestSupportedSize(sizes, width, height);
    }
}