#pragma once
#include <stdbool.h>
#include <stdint.h>

/// One finger on the trackpad. x and y run 0...1 from the bottom-left corner.
typedef struct {
    int32_t id;
    float x;
    float y;
} ct_touch;

/// Called on the multitouch thread for every frame while fingers are on the pad,
/// and once with count 0 after the last finger lifts.
typedef void (*ct_frame_cb)(const ct_touch *touches, int32_t count);

/// Starts reading the built-in trackpad. Returns false if there is no trackpad
/// or the private framework could not be loaded.
bool ct_touch_start(ct_frame_cb cb);
void ct_touch_stop(void);

/// Plays a trackpad haptic (actuation id, e.g. 3 = light, 6 = strong). Thread safe.
bool ct_haptic(int32_t actuation);

/// Brightness of the built-in display, 0...1. False when there is none (lid closed).
bool ct_brightness_get(float *value);
bool ct_brightness_set(float value);
