package dev.bridge.companion

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager

/** Find-phone torch only, never starts a camera preview or retains any images. */
class PhoneTorch(context: Context) {
    private val cameras = context.getSystemService(CameraManager::class.java)
    private var activeCamera: String? = null
    fun start() {
        val id = cameras.cameraIdList.firstOrNull { candidate ->
            val info = cameras.getCameraCharacteristics(candidate)
            info.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true && info.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: error("This phone has no available flashlight")
        cameras.setTorchMode(id, true); activeCamera = id
    }
    fun stop() { activeCamera?.let { runCatching { cameras.setTorchMode(it, false) } }; activeCamera = null }
}
