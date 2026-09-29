/* Copyright (c) 2015, The Linux Foundataion. All rights reserved.
*
* Redistribution and use in source and binary forms, with or without
* modification, are permitted provided that the following conditions are
* met:
*     * Redistributions of source code must retain the above copyright
*       notice, this list of conditions and the following disclaimer.
*     * Redistributions in binary form must reproduce the above
*       copyright notice, this list of conditions and the following
*       disclaimer in the documentation and/or other materials provided
*       with the distribution.
*     * Neither the name of The Linux Foundation nor the names of its
*       contributors may be used to endorse or promote products derived
*       from this software without specific prior written permission.
*
* THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED
* WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT
* ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS
* BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
* CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
* SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
* BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
* WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
* OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
* IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*
*/

#include <stdio.h>
#include <fcntl.h>
#include <linux/media.h>
#include <media/msmb_camera.h>
#include <media/msm_cam_sensor.h>
#include <utils/Log.h>

#include "HAL3/QCamera3HWI.h"
#include "QCameraFlash.h"

#define STRING_LENGTH_OF_64_BIT_NUMBER 21

#define FLASH_PATH_FIRST "/sys/class/leds/led:torch_0/brightness"
#define FLASH_PATH_SECOND "/sys/class/leds/led:torch_1/brightness"

volatile uint32_t gCamHal3LogLevel = 1;

namespace qcamera {

/*===========================================================================
 * FUNCTION   : getInstance
 *
 * DESCRIPTION: Get and create the QCameraFlash singleton.
 *
 * PARAMETERS : None
 *
 * RETURN     : None
 *==========================================================================*/
QCameraFlash& QCameraFlash::getInstance()
{
    static QCameraFlash flashInstance;
    return flashInstance;
}

/*===========================================================================
 * FUNCTION   : QCameraFlash
 *
 * DESCRIPTION: default constructor of QCameraFlash
 *
 * PARAMETERS : None
 *
 * RETURN     : None
 *==========================================================================*/
QCameraFlash::QCameraFlash() : m_callbacks(NULL)
{
    memset(&m_flashOn, 0, sizeof(m_flashOn));
    memset(&m_cameraOpen, 0, sizeof(m_cameraOpen));
    for (int pos = 0; pos < MM_CAMERA_MAX_NUM_SENSORS; pos++) {
        m_flashFds[pos].first = -1;
        m_flashFds[pos].second = -1;
    }
}

/*===========================================================================
 * FUNCTION   : ~QCameraFlash
 *
 * DESCRIPTION: deconstructor of QCameraFlash
 *
 * PARAMETERS : None
 *
 * RETURN     : None
 *==========================================================================*/
QCameraFlash::~QCameraFlash()
{
    for (int pos = 0; pos < MM_CAMERA_MAX_NUM_SENSORS; pos++) {
        if (m_flashFds[pos].first >= 0)
        {
            setFlashMode(pos, false, LED_FIRST);
            close(m_flashFds[pos].first);
            m_flashFds[pos].first = -1;
        }
        if (m_flashFds[pos].second >= 0)
        {
            setFlashMode(pos, false, LED_SECOND);
            close(m_flashFds[pos].second);
            m_flashFds[pos].second = -1;
        }
    }
}

/*===========================================================================
 * FUNCTION   : registerCallbacks
 *
 * DESCRIPTION: provide flash module with reference to callbacks to framework
 *
 * PARAMETERS : None
 *
 * RETURN     : None
 *==========================================================================*/
int32_t QCameraFlash::registerCallbacks(
        const camera_module_callbacks_t* callbacks)
{
    int32_t retVal = 0;
    m_callbacks = callbacks;
    return retVal;
}

/*===========================================================================
 * FUNCTION   : initFlash
 *
 * DESCRIPTION: Reserve and initialize the flash unit associated with a
 *              given camera id. This function is blocking until the
 *              operation completes or fails. Each flash unit can be "inited"
 *              by only one process at a time.
 *
 * PARAMETERS :
 *   @camera_id : Camera id of the flash.
 *
 * RETURN     :
 *   0        : success
 *   -EBUSY   : The flash unit or the resource needed to turn on the
 *              the flash is busy, typically because the flash is
 *              already in use.
 *   -EINVAL  : No flash present at camera_id.
 *==========================================================================*/
int32_t QCameraFlash::initFlash(const int camera_id)
{
    int32_t retVal = 0;

    if (camera_id < 0 || camera_id >= MM_CAMERA_MAX_NUM_SENSORS) {
        ALOGE("%s: Invalid camera id: %d", __func__, camera_id);
        return -EINVAL;
    }

    if (camera_id != 0) {
        ALOGE("%s: No flash available for camera id: %d",
                __func__,
                camera_id);
        retVal = -EINVAL;
    } else if (m_cameraOpen[camera_id]) {
        ALOGE("%s: Camera in use for camera id: %d",
                __func__,
                camera_id);
        retVal = -EBUSY;
    }

    if (retVal < 0) {
        return retVal;
    }

    if (m_flashFds[camera_id].first >= 0) {
        CDBG("First flash led is already inited for camera id: %d",
                camera_id);
    } else {
        m_flashFds[camera_id].first = open(FLASH_PATH_FIRST, O_RDWR);
        if (m_flashFds[camera_id].first < 0) {
            ALOGE("%s: Unable to open node '%s'",
                    __func__,
                    FLASH_PATH_FIRST);
            retVal = -EBUSY;
        }
    }

    if (m_flashFds[camera_id].second >= 0) {
        CDBG("Second flash led is already inited for camera id: %d",
                camera_id);
    } else {
        m_flashFds[camera_id].second = open(FLASH_PATH_SECOND, O_RDWR);
        if (m_flashFds[camera_id].second < 0) {
            ALOGE("%s: Unable to open node '%s'",
                    __func__,
                    FLASH_PATH_SECOND);
            retVal = -EBUSY;
        }
    }

    /* wait for PMIC to init */
    usleep(5000);

    CDBG("%s: X, retVal = %d", __func__, retVal);
    return retVal;
}

/*===========================================================================
 * FUNCTION   : setFlashMode
 *
 * DESCRIPTION: Turn on or off the flash associated with a given handle.
 *              This function is blocking until the operation completes or
 *              fails.
 *
 * PARAMETERS :
 *   @camera_id  : Camera id of the flash
 *   @on         : Whether to turn flash on (true) or off (false)
 *   @flashLed   : LED identifier
 *
 * RETURN     :
 *   0        : success
 *   -EINVAL  : No camera present at camera_id, or it is not inited.
 *   -EALREADY: Flash is already in requested state
 *==========================================================================*/
int32_t QCameraFlash::setFlashMode(const int camera_id, const bool mode, flashLed led)
{
    int32_t retVal = 0;
    int32_t count = 0;
    char buffer[16];

    if (camera_id < 0 || camera_id >= MM_CAMERA_MAX_NUM_SENSORS) {
        ALOGE("%s: Invalid camera id: %d", __func__, camera_id);
        retVal = -EINVAL;
    } else if (mode == m_flashOn[camera_id]) {
        CDBG("%s: flash %d is already in requested state: %d",
                __func__,
                camera_id,
                mode);
        retVal = -EALREADY;
    }

    if (retVal < 0) {
        return retVal;
    }

    if (led == LED_FIRST || led == LED_DUAL) {
        if (m_flashFds[camera_id].first < 0) {
            ALOGE("%s: called for uninited first flash: %d", __func__, camera_id);
            retVal = -EINVAL;
        } else {
            if (mode) {
                int bytes = snprintf(buffer, sizeof(buffer), "70");
                count = write(m_flashFds[camera_id].first, buffer, (size_t)bytes);
            } else {
                int bytes = snprintf(buffer, sizeof(buffer), "0");
                count = write(m_flashFds[camera_id].first, buffer, (size_t)bytes);
            }

            if (count <= 0)
                ALOGE("%s: Unable to change first flash mode to %d for camera id: %d",
                        __func__, mode, camera_id);
            else
                m_flashOn[camera_id] = mode;
        }
    }

    if (led == LED_SECOND || led == LED_DUAL) {
        if (m_flashFds[camera_id].second < 0) {
            ALOGE("%s: called for uninited second flash: %d", __func__, camera_id);
            retVal = -EINVAL;
        } else {
            if (mode) {
                int bytes = snprintf(buffer, sizeof(buffer), "70");
                count = write(m_flashFds[camera_id].second, buffer, (size_t)bytes);
            } else {
                int bytes = snprintf(buffer, sizeof(buffer), "0");
                count = write(m_flashFds[camera_id].second, buffer, (size_t)bytes);
            }

            if (count <= 0)
                ALOGE("%s: Unable to change second flash mode to %d for camera id: %d",
                    __func__, mode, camera_id);
        }
    }
    return retVal;
}

/*===========================================================================
 * FUNCTION   : deinitFlash
 *
 * DESCRIPTION: Release the flash unit associated with a given camera
 *              position. This function is blocking until the operation
 *              completes or fails.
 *
 * PARAMETERS :
 *   @camera_id : Camera id of the flash.
 *
 * RETURN     :
 *   0        : success
 *   -EINVAL  : No camera present at camera_id or not inited.
 *==========================================================================*/
int32_t QCameraFlash::deinitFlash(const int camera_id)
{
    int32_t retVal = 0;

    if (camera_id < 0 || camera_id >= MM_CAMERA_MAX_NUM_SENSORS) {
        ALOGE("%s: Invalid camera id: %d", __func__, camera_id);
        return -EINVAL;
    }

    if (m_flashFds[camera_id].first < 0) {
        ALOGE("%s: called deinitFlash for uninited flash", __func__);
        retVal = -EINVAL;
    } else {
        setFlashMode(camera_id, false, LED_FIRST);
        close(m_flashFds[camera_id].first);
        m_flashFds[camera_id].first = -1;
    }

    if (m_flashFds[camera_id].second < 0) {
        ALOGE("%s: called deinitFlash for uninited flash", __func__);
        retVal = -EINVAL;
    } else {
        setFlashMode(camera_id, false, LED_SECOND);
        close(m_flashFds[camera_id].second);
        m_flashFds[camera_id].second = -1;
    }

    return retVal;
}

/*===========================================================================
 * FUNCTION   : reserveFlashForCamera
 *
 * DESCRIPTION: Give control of the flash to the camera, and notify
 *              framework that the flash has become unavailable.
 *
 * PARAMETERS :
 *   @camera_id : Camera id of the flash.
 *
 * RETURN     :
 *   0        : success
 *   -EINVAL  : No camera present at camera_id or not inited.
 *   -ENOSYS  : No callback available for torch_mode_status_change.
 *==========================================================================*/
int32_t QCameraFlash::reserveFlashForCamera(const int camera_id)
{
    int32_t retVal = 0;

    if (camera_id < 0 || camera_id >= MM_CAMERA_MAX_NUM_SENSORS) {
        ALOGE("%s: Invalid camera id: %d", __func__, camera_id);
        retVal = -EINVAL;
    } else if (m_cameraOpen[camera_id]) {
        CDBG("%s: Flash already reserved for camera id: %d",
                __func__,
                camera_id);
    } else {
        if (m_flashOn[camera_id]) {
            setFlashMode(camera_id, false, LED_DUAL);
            deinitFlash(camera_id);
        }
        m_cameraOpen[camera_id] = true;

        if (m_callbacks == NULL ||
                m_callbacks->torch_mode_status_change == NULL) {
            ALOGE("%s: Callback is not defined!", __func__);
            retVal = -ENOSYS;
        } else if (camera_id != 0) {
            CDBG("%s: Suppressing callback "
                    "because no flash exists for camera id: %d",
                    __func__,
                    camera_id);
        } else {
            char cameraIdStr[STRING_LENGTH_OF_64_BIT_NUMBER];
            snprintf(cameraIdStr, STRING_LENGTH_OF_64_BIT_NUMBER,
                    "%d", camera_id);
            m_callbacks->torch_mode_status_change(m_callbacks,
                    cameraIdStr,
                    TORCH_MODE_STATUS_NOT_AVAILABLE);
        }
    }

    return retVal;
}

/*===========================================================================
 * FUNCTION   : releaseFlashFromCamera
 *
 * DESCRIPTION: Release control of the flash from the camera, and notify
 *              framework that the flash has become available.
 *
 * PARAMETERS :
 *   @camera_id : Camera id of the flash.
 *
 * RETURN     :
 *   0        : success
 *   -EINVAL  : No camera present at camera_id or not inited.
 *   -ENOSYS  : No callback available for torch_mode_status_change.
 *==========================================================================*/
int32_t QCameraFlash::releaseFlashFromCamera(const int camera_id)
{
    int32_t retVal = 0;

    if (camera_id < 0 || camera_id >= MM_CAMERA_MAX_NUM_SENSORS) {
        ALOGE("%s: Invalid camera id: %d", __func__, camera_id);
        retVal = -EINVAL;
    } else if (!m_cameraOpen[camera_id]) {
        CDBG("%s: Flash not reserved for camera id: %d",
                __func__,
                camera_id);
    } else {
        m_cameraOpen[camera_id] = false;

        if (m_callbacks == NULL ||
                m_callbacks->torch_mode_status_change == NULL) {
            ALOGE("%s: Callback is not defined!", __func__);
            retVal = -ENOSYS;
        } else if (camera_id != 0) {
            CDBG("%s: Suppressing callback "
                    "because no flash exists for camera id: %d",
                    __func__,
                    camera_id);
        } else {
            char cameraIdStr[STRING_LENGTH_OF_64_BIT_NUMBER];
            snprintf(cameraIdStr, STRING_LENGTH_OF_64_BIT_NUMBER,
                    "%d", camera_id);
            m_callbacks->torch_mode_status_change(m_callbacks,
                    cameraIdStr,
                    TORCH_MODE_STATUS_AVAILABLE_OFF);
        }
    }

    return retVal;
}

}; // namespace qcamera
