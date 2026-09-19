// 电脑版语音桥接的入口：注册成和安卓插件同名的单例 GloryVoice（VoiceService.SINGLETON）。
#include <gdextension_interface.h>

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/godot.hpp>

#include "glory_voice_desktop.h"

using namespace godot;

static GloryVoiceDesktop *g_voice = nullptr;

static void initialize_glory_voice(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	// 抽象类：脚本 new 不出来，只能用下面这一个单例。
	GDREGISTER_ABSTRACT_CLASS(GloryVoiceDesktop);
	// 编辑器里不跑语音（VoiceService 是游戏运行时的 autoload），也就不起工作线程。
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	g_voice = memnew(GloryVoiceDesktop);
	Engine::get_singleton()->register_singleton("GloryVoice", g_voice);
}

static void uninitialize_glory_voice(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE || g_voice == nullptr) {
		return;
	}
	Engine::get_singleton()->unregister_singleton("GloryVoice");
	g_voice->shutdown();
	memdelete(g_voice);
	g_voice = nullptr;
}

extern "C" {
GDExtensionBool GDE_EXPORT glory_voice_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_glory_voice);
	init_obj.register_terminator(uninitialize_glory_voice);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
