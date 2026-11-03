#include "CTouch.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>

// Layout of MultitouchSupport's private touch record (unchanged since 10.5; used by
// BetterTouchTool, OpenMultitouchSupport and others).
typedef struct { float x, y; } mt_point;
typedef struct { mt_point pos, vel; } mt_vector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t path_index;
    int32_t state;
    int32_t finger_id;
    int32_t hand_id;
    mt_vector normalized;
    float total;
    int32_t field9;
    float angle;
    float major_axis;
    float minor_axis;
    mt_vector absolute;
    int32_t field14;
    int32_t field15;
    float density;
} mt_touch;

enum { MT_MAKE_TOUCH = 3, MT_TOUCHING = 4 };

typedef CFTypeRef mt_device;
typedef int (*mt_contact_fn)(mt_device, const mt_touch *, int32_t, double, int32_t);

static struct {
    bool loaded;
    mt_device (*create_default)(void);
    void (*register_cb)(mt_device, mt_contact_fn);
    void (*unregister_cb)(mt_device, mt_contact_fn);
    int32_t (*start)(mt_device, int32_t);
    int32_t (*stop)(mt_device);
    int32_t (*get_device_id)(mt_device, uint64_t *);
    CFTypeRef (*actuator_create)(uint64_t);
    int32_t (*actuator_open)(CFTypeRef);
    int32_t (*actuator_close)(CFTypeRef);
    int32_t (*actuate)(CFTypeRef, int32_t, uint32_t, float, float);
} mt;

static void load_mt_symbols(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!lib) return;
    mt.create_default = dlsym(lib, "MTDeviceCreateDefault");
    mt.register_cb = dlsym(lib, "MTRegisterContactFrameCallback");
    mt.unregister_cb = dlsym(lib, "MTUnregisterContactFrameCallback");
    mt.start = dlsym(lib, "MTDeviceStart");
    mt.stop = dlsym(lib, "MTDeviceStop");
    mt.get_device_id = dlsym(lib, "MTDeviceGetDeviceID");
    mt.actuator_create = dlsym(lib, "MTActuatorCreateFromDeviceID");
    mt.actuator_open = dlsym(lib, "MTActuatorOpen");
    mt.actuator_close = dlsym(lib, "MTActuatorClose");
    mt.actuate = dlsym(lib, "MTActuatorActuate");
    mt.loaded = mt.create_default && mt.register_cb && mt.start && mt.stop;
}

static bool load_mt(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load_mt_symbols);
    return mt.loaded;
}

// MARK: Touches

#define MAX_TOUCHES 16
static ct_frame_cb g_cb;
static mt_device g_device;

static int on_frame(mt_device dev, const mt_touch *t, int32_t n, double ts, int32_t frame) {
    ct_touch out[MAX_TOUCHES];
    int32_t m = 0;
    for (int32_t i = 0; i < n && m < MAX_TOUCHES; i++) {
        if (t[i].state != MT_MAKE_TOUCH && t[i].state != MT_TOUCHING) continue; // skip hovering/lifting
        out[m++] = (ct_touch){t[i].path_index, t[i].normalized.pos.x, t[i].normalized.pos.y};
    }
    if (g_cb) g_cb(out, m);
    return 0;
}

bool ct_touch_start(ct_frame_cb cb) {
    if (!load_mt()) return false;
    if (g_device) return true;
    g_cb = cb;
    g_device = mt.create_default();
    if (!g_device) return false;
    mt.register_cb(g_device, on_frame);
    mt.start(g_device, 0);
    return true;
}

static void close_actuator(void);

void ct_touch_stop(void) {
    if (!g_device) return;
    if (mt.unregister_cb) mt.unregister_cb(g_device, on_frame);
    mt.stop(g_device);
    // Not released: the framework's thread can still touch it right after stopping,
    // and this only happens on wake from sleep.
    g_device = NULL;
    close_actuator();
}

// MARK: Haptics

static pthread_mutex_t g_haptic_lock = PTHREAD_MUTEX_INITIALIZER;
static CFTypeRef g_actuator;

static CFTypeRef open_actuator(uint64_t id) {
    CFTypeRef a = mt.actuator_create(id);
    if (!a) return NULL;
    if (mt.actuator_open(a) != 0) {
        CFRelease(a);
        return NULL;
    }
    return a;
}

static CFTypeRef find_actuator(void) {
    uint64_t id = 0;
    if (g_device && mt.get_device_id && mt.get_device_id(g_device, &id) == 0 && id) {
        CFTypeRef a = open_actuator(id);
        if (a) return a;
    }
    // Fall back to every multitouch device in the registry.
    CFTypeRef found = NULL;
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &it) != KERN_SUCCESS)
        return NULL;
    io_object_t service;
    while (!found && (service = IOIteratorNext(it))) {
        CFTypeRef num = IORegistryEntryCreateCFProperty(service, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
        if (num && CFGetTypeID(num) == CFNumberGetTypeID() && CFNumberGetValue(num, kCFNumberSInt64Type, &id))
            found = open_actuator(id);
        if (num) CFRelease(num);
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    return found;
}

static void close_actuator(void) {
    pthread_mutex_lock(&g_haptic_lock);
    if (g_actuator) {
        if (mt.actuator_close) mt.actuator_close(g_actuator);
        CFRelease(g_actuator);
        g_actuator = NULL;
    }
    pthread_mutex_unlock(&g_haptic_lock);
}

bool ct_haptic(int32_t actuation) {
    if (!load_mt() || !mt.actuator_create || !mt.actuator_open || !mt.actuate) return false;
    pthread_mutex_lock(&g_haptic_lock);
    if (!g_actuator) g_actuator = find_actuator();
    bool ok = g_actuator && mt.actuate(g_actuator, actuation, 0, 0, 0) == 0;
    pthread_mutex_unlock(&g_haptic_lock);
    return ok;
}

// MARK: Brightness

static int (*ds_get)(CGDirectDisplayID, float *);
static int (*ds_set)(CGDirectDisplayID, float);

static void load_ds(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
    if (!lib) return;
    ds_get = dlsym(lib, "DisplayServicesGetBrightness");
    ds_set = dlsym(lib, "DisplayServicesSetBrightness");
}

static CGDirectDisplayID builtin_display(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load_ds);
    if (!ds_get || !ds_set) return kCGNullDirectDisplay;
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return kCGNullDirectDisplay;
    for (uint32_t i = 0; i < n; i++)
        if (CGDisplayIsBuiltin(ids[i])) return ids[i];
    return kCGNullDirectDisplay;
}

bool ct_brightness_get(float *value) {
    CGDirectDisplayID d = builtin_display();
    return d != kCGNullDirectDisplay && ds_get(d, value) == 0;
}

bool ct_brightness_set(float value) {
    CGDirectDisplayID d = builtin_display();
    return d != kCGNullDirectDisplay && ds_set(d, value) == 0;
}
