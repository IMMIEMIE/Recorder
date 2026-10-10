package com.localrecorder.shengjian

import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/** Where sound goes and comes from: headphone detection and the optional Bluetooth headset microphone. */
class AudioRouting(private val manager: AudioManager) {
    var bluetoothActive = false
        private set

    /** With headphones, translated speech cannot reach the microphone. */
    fun hasHeadphones(): Boolean =
        manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in HEADPHONES }

    /**
     * Routes capture (and voice playback) to a connected Bluetooth headset. Returns its input
     * device, or null when there is none and the phone microphone should be used.
     */
    fun startBluetoothMicrophone(): AudioDeviceInfo? {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val headset = manager.availableCommunicationDevices.firstOrNull { isBluetoothHeadset(it.type) } ?: return null
                if (!manager.setCommunicationDevice(headset)) return null
            } else {
                if (!manager.isBluetoothScoAvailableOffCall || input() == null) return null
                @Suppress("DEPRECATION")
                manager.startBluetoothSco()
                @Suppress("DEPRECATION")
                manager.isBluetoothScoOn = true
            }
        } catch (_: Exception) {
            return null
        }
        bluetoothActive = true
        return input() ?: run {
            stopBluetoothMicrophone()
            null
        }
    }

    fun stopBluetoothMicrophone() {
        if (!bluetoothActive) return
        bluetoothActive = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                manager.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                manager.isBluetoothScoOn = false
                @Suppress("DEPRECATION")
                manager.stopBluetoothSco()
            }
        } catch (_: Exception) {
        }
    }

    private fun input(): AudioDeviceInfo? =
        manager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { isBluetoothHeadset(it.type) }

    private fun isBluetoothHeadset(type: Int): Boolean =
        type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && type == AudioDeviceInfo.TYPE_BLE_HEADSET)

    private companion object {
        val HEADPHONES = buildSet {
            add(AudioDeviceInfo.TYPE_WIRED_HEADSET)
            add(AudioDeviceInfo.TYPE_WIRED_HEADPHONES)
            add(AudioDeviceInfo.TYPE_USB_HEADSET)
            add(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP)
            add(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
            add(AudioDeviceInfo.TYPE_HEARING_AID)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(AudioDeviceInfo.TYPE_BLE_HEADSET)
        }
    }
}
