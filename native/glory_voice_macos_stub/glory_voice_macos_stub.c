/* macOS has no LiveKit voice implementation yet. Load cleanly, but deliberately
 * do NOT register GloryVoice: VoiceService.is_supported() must remain false.
 * This is an unavailable-platform adapter, not a working voice bridge. */
#include "gdextension_interface.h"

static void initialize(void *userdata, GDExtensionInitializationLevel level) {
    (void)userdata;
    (void)level;
}

__attribute__((visibility("default")))
GDExtensionBool glory_voice_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization) {
    (void)get_proc_address;
    (void)library;
    initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
    initialization->userdata = 0;
    initialization->initialize = initialize;
    initialization->deinitialize = initialize;
    return 1;
}
