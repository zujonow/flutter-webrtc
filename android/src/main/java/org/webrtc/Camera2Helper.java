
package org.webrtc;

import android.hardware.camera2.CameraManager;

import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.List;

/**
 * A helper to access package-protected methods used in [Camera2Session]
 * <p>
 * Note: cameraId as used in the Camera2XXX classes refers to the id returned
 * by [CameraManager.getCameraIdList].
 */
public class Camera2Helper {

    @Nullable
    public static List<CameraEnumerationAndroid.CaptureFormat> getSupportedFormats(CameraManager cameraManager, @Nullable String cameraId) {
        return Camera2Enumerator.getSupportedFormats(cameraManager, cameraId);
    }

    public static Size findClosestCaptureFormat(CameraManager cameraManager, @Nullable String cameraId, int width, int height) {
        List<CameraEnumerationAndroid.CaptureFormat> formats = getSupportedFormats(cameraManager, cameraId);

        List<Size> sizes = new ArrayList<>();
        if (formats != null) {
            for (CameraEnumerationAndroid.CaptureFormat format : formats) {
                sizes.add(new Size(format.width, format.height));
            }
        }

        return CameraEnumerationAndroid.getClosestSupportedSize(sizes, width, height);
    }
}