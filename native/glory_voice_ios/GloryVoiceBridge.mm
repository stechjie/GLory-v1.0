#import <Foundation/Foundation.h>
#import "GloryVoiceNative.h"
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;
static void on_main(void (^operation)(void)) {
    if ([NSThread isMainThread]) operation();
    else dispatch_sync(dispatch_get_main_queue(), operation);
}
static NSString *native_string(const String &s) {
    return [NSString stringWithUTF8String:s.utf8().get_data()];
}

class GloryVoiceIOS : public Object {
    GDCLASS(GloryVoiceIOS, Object)
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("hasRecordPermission"), &GloryVoiceIOS::hasRecordPermission);
        ClassDB::bind_method(D_METHOD("requestRecordPermission"), &GloryVoiceIOS::requestRecordPermission);
        ClassDB::bind_method(D_METHOD("joinRoom", "url", "token", "listen_only"), &GloryVoiceIOS::joinRoom);
        ClassDB::bind_method(D_METHOD("leaveRoom"), &GloryVoiceIOS::leaveRoom);
        ClassDB::bind_method(D_METHOD("setMicrophoneEnabled", "enabled"), &GloryVoiceIOS::setMicrophoneEnabled);
        ClassDB::bind_method(D_METHOD("setParticipantVolume", "identity", "volume"), &GloryVoiceIOS::setParticipantVolume);
        ClassDB::bind_method(D_METHOD("getStatus"), &GloryVoiceIOS::getStatus);
        ClassDB::bind_method(D_METHOD("getCapabilities"), &GloryVoiceIOS::getCapabilities);
    }
public:
    bool hasRecordPermission() {
        __block bool result = false;
        on_main(^{ result = [[GloryVoiceNative shared] hasRecordPermission]; });
        return result;
    }
    void requestRecordPermission() { on_main(^{ [[GloryVoiceNative shared] requestRecordPermission]; }); }
    String joinRoom(const String &url, const String &token, bool listen_only) {
        NSString *u = native_string(url), *t = native_string(token);
        __block NSString *result;
        on_main(^{ result = [[GloryVoiceNative shared] joinRoom:u token:t listenOnly:listen_only]; });
        return String::utf8(result.UTF8String);
    }
    void leaveRoom() { on_main(^{ [[GloryVoiceNative shared] leaveRoom]; }); }
    String setMicrophoneEnabled(bool enabled) {
        __block NSString *result;
        on_main(^{ result = [[GloryVoiceNative shared] setMicrophoneEnabled:enabled]; });
        return String::utf8(result.UTF8String);
    }
    void setParticipantVolume(const String &identity, double volume) {
        NSString *i = native_string(identity);
        on_main(^{ [[GloryVoiceNative shared] setParticipantVolume:i volume:volume]; });
    }
    String getStatus() {
        __block NSString *result;
        on_main(^{ result = [[GloryVoiceNative shared] getStatus]; });
        return String::utf8(result.UTF8String);
    }
    String getCapabilities() {
        __block NSString *result;
        on_main(^{ result = [[GloryVoiceNative shared] getCapabilities]; });
        return String::utf8(result.UTF8String);
    }
};

static GloryVoiceIOS *voice = nullptr;
static void initialize_voice(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    GDREGISTER_ABSTRACT_CLASS(GloryVoiceIOS);
    if (Engine::get_singleton()->is_editor_hint()) return;
    voice = memnew(GloryVoiceIOS);
    Engine::get_singleton()->register_singleton("GloryVoice", voice);
}
static void terminate_voice(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE || !voice) return;
    Engine::get_singleton()->unregister_singleton("GloryVoice");
    voice->leaveRoom();
    memdelete(voice);
    voice = nullptr;
}
extern "C" GDExtensionBool GDE_EXPORT glory_voice_library_init(
        GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_voice);
    init.register_terminator(terminate_voice);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
