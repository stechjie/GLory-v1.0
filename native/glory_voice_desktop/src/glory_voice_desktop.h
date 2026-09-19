// 组队语音的电脑版桥接（docs/语音LiveKit方案.md 5.2，2026-09-19 定的做法「甲」）。
//
// 包一层 LiveKit C++ 开发包，注册成和安卓桥接同名的单例 GloryVoice，方法照
// scripts/autoload/VoiceService.gd 的 BRIDGE_METHODS。麦克风、喇叭、回声消除、降噪、自动音量
// 都交给开发包自带的「系统音频」（WebRTC 的音频设备模块），声音不经过 Godot。
//
// 线程：Godot 在自己的线程上调这些方法，这里只把活儿排进一条工作线程就返回
// （进房要等服务器回应，不能卡住游戏）。LiveKit 的回调来自开发包自己的线程，只改状态快照。
// 每次进房 / 离开换一个编号，旧房间迟到的回调一律丢掉。
#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace livekit {
class LocalAudioTrack;
class PlatformAudio;
class PlatformAudioSource;
class Room;
class RoomDelegate;
} // namespace livekit

class GloryVoiceDesktop : public godot::Object {
	GDCLASS(GloryVoiceDesktop, godot::Object)

public:
	// 与 build_dll.ps1 下载校验的开发包版本一致（tools/voice_check 对账）。
	static constexpr const char *LIVEKIT_SDK_VERSION = "1.11.0";

	GloryVoiceDesktop();
	~GloryVoiceDesktop() override;

	bool hasRecordPermission() const;
	godot::String joinRoom(const godot::String &url, const godot::String &token, bool listen_only);
	void leaveRoom();
	godot::String setMicrophoneEnabled(bool enabled);
	void setParticipantVolume(const godot::String &identity, double volume);
	godot::String getStatus() const;
	godot::String getCapabilities() const;

	// 下面给房间回调用（开发包的线程）。
	int generation() const { return generation_.load(); }
	void on_state(int gen, const char *state);
	void on_failed(int gen, const std::string &code);
	void on_speakers(int gen, const std::vector<std::string> &identities, const std::string &self_identity);
	void on_participants(int gen, const std::vector<std::string> &identities);
	void on_track_subscribed(int gen, const std::string &identity);

	// 退出前由 register_types 调：停工作线程、断开、关掉开发包。
	void shutdown();

protected:
	static void _bind_methods();

private:
	struct Snapshot {
		std::string state = "disconnected";
		std::string error;
		bool mic_on = false;
		std::string mic_error;
		bool self_speaking = false;
		std::vector<std::string> speaking;
		std::vector<std::string> participants;
		std::string output;
	};

	void post(std::function<void()> task);
	void worker_loop();
	void reset_snapshot(const char *state);

	// 只在工作线程上跑。
	void do_join(int gen, const std::string &url, const std::string &token);
	void do_apply_mic(int gen, bool enabled);
	void do_apply_volume(const std::string &identity);
	void do_teardown();

	std::atomic<int> generation_{0};

	mutable std::mutex mutex_;
	Snapshot snapshot_;
	// 语音身份 -> 音量（0 = 屏蔽）。跨房间保留（屏蔽跟着人走），Godot 线程写、工作线程读。
	std::unordered_map<std::string, double> volumes_;

	std::mutex queue_mutex_;
	std::condition_variable queue_cv_;
	std::deque<std::function<void()>> queue_;
	bool stopping_ = false;
	std::thread worker_;

	// 只在工作线程上碰。
	bool sdk_ready_ = false;
	bool want_mic_ = false;
	std::unique_ptr<livekit::PlatformAudio> platform_audio_;
	std::unique_ptr<livekit::RoomDelegate> delegate_;
	std::unique_ptr<livekit::Room> room_;
	std::shared_ptr<livekit::PlatformAudioSource> mic_source_;
	std::shared_ptr<livekit::LocalAudioTrack> mic_track_;
};
