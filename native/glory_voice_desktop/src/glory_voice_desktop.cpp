#include "glory_voice_desktop.h"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "livekit/livekit.h"
#include "livekit/local_audio_track.h"
#include "livekit/local_participant.h"
#include "livekit/local_track_publication.h"
#include "livekit/participant.h"
#include "livekit/platform_audio.h"
#include "livekit/remote_participant.h"
#include "livekit/remote_track_publication.h"
#include "livekit/room.h"
#include "livekit/room_delegate.h"
#include "livekit/room_event_types.h"
#include "livekit/track.h"

#include <algorithm>
#include <exception>

using namespace godot;

namespace {

std::string to_std(const String &value) {
	return std::string(value.utf8().get_data());
}

String to_godot(const std::string &value) {
	return String::utf8(value.c_str());
}

void log_warning(const std::string &message) {
	UtilityFunctions::push_warning(to_godot("[GloryVoice] " + message));
}

std::vector<std::string> remote_identities(livekit::Room &room) {
	std::vector<std::string> out;
	for (const auto &weak : room.remoteParticipants()) {
		if (auto participant = weak.lock()) {
			out.push_back(participant->identity());
		}
	}
	return out;
}

// 与 VoiceService.explain() 的原因代码一致。
const char *disconnect_code(livekit::DisconnectReason reason) {
	switch (reason) {
		case livekit::DisconnectReason::ParticipantRemoved:
			return "removed";
		case livekit::DisconnectReason::RoomDeleted:
			return "room_deleted";
		case livekit::DisconnectReason::DuplicateIdentity:
			return "duplicate_identity";
		case livekit::DisconnectReason::JoinFailure:
			return "join_failed";
		default:
			return "disconnected";
	}
}

// 房间回调（开发包的线程）：只转给 GloryVoiceDesktop 改状态快照，编号对不上的一律丢掉。
class DesktopRoomDelegate : public livekit::RoomDelegate {
public:
	DesktopRoomDelegate(GloryVoiceDesktop *owner, int gen) :
			owner_(owner), gen_(gen) {}

	void onConnectionStateChanged(livekit::Room &, const livekit::ConnectionStateChangedEvent &event) override {
		if (event.state == livekit::ConnectionState::Reconnecting) {
			owner_->on_state(gen_, "reconnecting");
		} else if (event.state == livekit::ConnectionState::Connected) {
			owner_->on_state(gen_, "connected");
		}
	}

	void onReconnecting(livekit::Room &, const livekit::ReconnectingEvent &) override {
		owner_->on_state(gen_, "reconnecting");
	}

	void onReconnected(livekit::Room &, const livekit::ReconnectedEvent &) override {
		owner_->on_state(gen_, "connected");
	}

	// 自己 leaveRoom 引起的断开到不了这里（编号已经变了）。
	void onDisconnected(livekit::Room &, const livekit::DisconnectedEvent &event) override {
		owner_->on_failed(gen_, disconnect_code(event.reason));
	}

	void onActiveSpeakersChanged(livekit::Room &room, const livekit::ActiveSpeakersChangedEvent &event) override {
		std::vector<std::string> identities;
		for (const livekit::Participant *participant : event.speakers) {
			if (participant != nullptr) {
				identities.push_back(participant->identity());
			}
		}
		std::string self;
		if (auto local = room.localParticipant().lock()) {
			self = local->identity();
		}
		owner_->on_speakers(gen_, identities, self);
	}

	void onParticipantConnected(livekit::Room &room, const livekit::ParticipantConnectedEvent &) override {
		owner_->on_participants(gen_, remote_identities(room));
	}

	void onParticipantDisconnected(livekit::Room &room, const livekit::ParticipantDisconnectedEvent &event) override {
		std::vector<std::string> identities = remote_identities(room);
		if (event.participant != nullptr) {
			const std::string gone = event.participant->identity();
			identities.erase(std::remove(identities.begin(), identities.end(), gone), identities.end());
		}
		owner_->on_participants(gen_, identities);
	}

	// 新订阅到的声音按屏蔽表处理（自动订阅会把被屏蔽的人重新订上）。
	void onTrackSubscribed(livekit::Room &, const livekit::TrackSubscribedEvent &event) override {
		if (event.participant != nullptr && event.track && event.track->kind() == livekit::TrackKind::KIND_AUDIO) {
			owner_->on_track_subscribed(gen_, event.participant->identity());
		}
	}

private:
	GloryVoiceDesktop *owner_;
	int gen_;
};

} // namespace

// --- 给 Godot 的方法（Godot 的线程）---------------------------------------------------

GloryVoiceDesktop::GloryVoiceDesktop() {
	worker_ = std::thread([this]() { worker_loop(); });
}

GloryVoiceDesktop::~GloryVoiceDesktop() {
	shutdown();
}

void GloryVoiceDesktop::_bind_methods() {
	// 名字、参数个数与 VoiceService.BRIDGE_METHODS 一致（tools/voice_check 对账）。
	ClassDB::bind_method(D_METHOD("hasRecordPermission"), &GloryVoiceDesktop::hasRecordPermission);
	ClassDB::bind_method(D_METHOD("joinRoom", "url", "token", "listen_only"), &GloryVoiceDesktop::joinRoom);
	ClassDB::bind_method(D_METHOD("leaveRoom"), &GloryVoiceDesktop::leaveRoom);
	ClassDB::bind_method(D_METHOD("setMicrophoneEnabled", "enabled"), &GloryVoiceDesktop::setMicrophoneEnabled);
	ClassDB::bind_method(D_METHOD("setParticipantVolume", "identity", "volume"), &GloryVoiceDesktop::setParticipantVolume);
	ClassDB::bind_method(D_METHOD("getStatus"), &GloryVoiceDesktop::getStatus);
	ClassDB::bind_method(D_METHOD("getCapabilities"), &GloryVoiceDesktop::getCapabilities);
}

// Windows 桌面程序没有运行时麦克风权限弹窗；系统设置里关了麦克风的话，开麦时报 mic_error。
bool GloryVoiceDesktop::hasRecordPermission() const {
	return true;
}

// 开始连（异步）。空串 = 已开始；进展看 getStatus 的 state。
// listen_only 在电脑上不影响进房：只听 / 开麦用的是同一套设备，换档不用重进。
String GloryVoiceDesktop::joinRoom(const String &url, const String &token, bool) {
	if (url.is_empty() || token.is_empty()) {
		return "bad_args";
	}
	const int gen = ++generation_;
	reset_snapshot("connecting");
	const std::string url_s = to_std(url);
	const std::string token_s = to_std(token);
	post([this, gen, url_s, token_s]() {
		// 新房间默认不开麦；要开麦由 VoiceService 随后调 setMicrophoneEnabled（排在这之后，连上就生效）。
		want_mic_ = false;
		do_teardown();
		do_join(gen, url_s, token_s);
	});
	return "";
}

void GloryVoiceDesktop::leaveRoom() {
	++generation_;
	reset_snapshot("disconnected");
	post([this]() {
		want_mic_ = false;
		do_teardown();
	});
}

// 开 / 关麦。还没连上时先记下，连上再生效；打不开（异步）写进 getStatus 的 mic_error。
String GloryVoiceDesktop::setMicrophoneEnabled(bool enabled) {
	const int gen = generation_.load();
	{
		std::lock_guard<std::mutex> lock(mutex_);
		snapshot_.mic_error.clear();
	}
	post([this, gen, enabled]() {
		want_mic_ = enabled;
		do_apply_mic(gen, enabled);
	});
	return "";
}

// 某个队友的音量，0 = 屏蔽（只影响自己）。开发包的系统音频没有按人调音量的接口，
// 所以只分「听 / 不听」：0 退订这个人的声音，大于 0 重新订上。
void GloryVoiceDesktop::setParticipantVolume(const String &identity, double volume) {
	const std::string id = to_std(identity);
	{
		std::lock_guard<std::mutex> lock(mutex_);
		volumes_[id] = volume;
	}
	post([this, id]() { do_apply_volume(id); });
}

String GloryVoiceDesktop::getStatus() const {
	Dictionary d;
	Array speaking;
	Array participants;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		d["state"] = to_godot(snapshot_.state);
		d["error"] = to_godot(snapshot_.error);
		d["mic_on"] = snapshot_.mic_on;
		d["mic_error"] = to_godot(snapshot_.mic_error);
		d["self_speaking"] = snapshot_.self_speaking;
		for (const std::string &id : snapshot_.speaking) {
			speaking.push_back(to_godot(id));
		}
		for (const std::string &id : snapshot_.participants) {
			participants.push_back(to_godot(id));
		}
		d["output"] = to_godot(snapshot_.output);
	}
	d["speaking"] = speaking;
	d["participants"] = participants;
	// 电脑上没有安卓那种「媒体 / 通话」两种声音模式。
	d["audio_mode"] = "";
	return JSON::stringify(d);
}

String GloryVoiceDesktop::getCapabilities() const {
	Dictionary d;
	d["platform"] = "windows";
	d["sdk"] = to_godot(std::string("livekit-cpp ") + LIVEKIT_SDK_VERSION);
	// WebRTC 自己的回声消除（只认得它自己放出来的声音，见 docs/语音LiveKit方案.md 5.2 做法「甲」）。
	d["aec"] = "webrtc";
	d["listen_mode_fixed_at_join"] = false;
	return JSON::stringify(d);
}

// --- 房间回调（开发包的线程）------------------------------------------------------------

void GloryVoiceDesktop::on_state(int gen, const char *state) {
	std::lock_guard<std::mutex> lock(mutex_);
	if (gen != generation_.load() || snapshot_.state == "failed") {
		return;
	}
	snapshot_.state = state;
}

void GloryVoiceDesktop::on_failed(int gen, const std::string &code) {
	std::lock_guard<std::mutex> lock(mutex_);
	if (gen != generation_.load()) {
		return;
	}
	snapshot_.state = "failed";
	snapshot_.error = code;
	snapshot_.mic_on = false;
	snapshot_.self_speaking = false;
	snapshot_.speaking.clear();
	snapshot_.participants.clear();
}

void GloryVoiceDesktop::on_speakers(int gen, const std::vector<std::string> &identities, const std::string &self_identity) {
	std::lock_guard<std::mutex> lock(mutex_);
	if (gen != generation_.load()) {
		return;
	}
	snapshot_.self_speaking = false;
	snapshot_.speaking.clear();
	for (const std::string &id : identities) {
		if (!self_identity.empty() && id == self_identity) {
			snapshot_.self_speaking = true;
		} else {
			snapshot_.speaking.push_back(id);
		}
	}
}

void GloryVoiceDesktop::on_participants(int gen, const std::vector<std::string> &identities) {
	std::lock_guard<std::mutex> lock(mutex_);
	if (gen != generation_.load()) {
		return;
	}
	snapshot_.participants = identities;
}

void GloryVoiceDesktop::on_track_subscribed(int gen, const std::string &identity) {
	if (gen != generation_.load()) {
		return;
	}
	bool muted = false;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		auto it = volumes_.find(identity);
		muted = it != volumes_.end() && it->second <= 0.0;
	}
	if (muted) {
		post([this, identity]() { do_apply_volume(identity); });
	}
}

// --- 工作线程 ----------------------------------------------------------------------------

void GloryVoiceDesktop::post(std::function<void()> task) {
	{
		std::lock_guard<std::mutex> lock(queue_mutex_);
		if (stopping_) {
			return;
		}
		queue_.push_back(std::move(task));
	}
	queue_cv_.notify_one();
}

void GloryVoiceDesktop::worker_loop() {
	for (;;) {
		std::function<void()> task;
		{
			std::unique_lock<std::mutex> lock(queue_mutex_);
			queue_cv_.wait(lock, [this]() { return stopping_ || !queue_.empty(); });
			if (queue_.empty()) {
				return; // 要停了，而且排着的活儿都做完了
			}
			task = std::move(queue_.front());
			queue_.pop_front();
		}
		// 语音出任何错都不能把游戏带崩：开发包的错误以异常抛出，这里全部接住。
		try {
			task();
		} catch (const std::exception &e) {
			log_warning(std::string("task failed: ") + e.what());
		} catch (...) {
			log_warning("task failed");
		}
	}
}

void GloryVoiceDesktop::reset_snapshot(const char *state) {
	std::lock_guard<std::mutex> lock(mutex_);
	snapshot_ = Snapshot();
	snapshot_.state = state;
	snapshot_.output = std::string(state) == "disconnected" ? "" : "system";
}

void GloryVoiceDesktop::do_join(int gen, const std::string &url, const std::string &token) {
	if (gen != generation_.load()) {
		return;
	}
	try {
		if (!sdk_ready_) {
			sdk_ready_ = livekit::initialize(livekit::LogLevel::Warn);
			if (!sdk_ready_) {
				on_failed(gen, "sdk_failed");
				return;
			}
		}
		// 系统音频（WebRTC 的音频设备模块）：队友的声音由它直接放到系统默认的喇叭 / 耳机。
		if (!platform_audio_) {
			platform_audio_ = std::make_unique<livekit::PlatformAudio>();
		}
	} catch (const std::exception &e) {
		log_warning(std::string("audio device: ") + e.what());
		on_failed(gen, "audio_device_failed");
		return;
	}

	auto delegate = std::make_unique<DesktopRoomDelegate>(this, gen);
	auto room = std::make_unique<livekit::Room>();
	room->setDelegate(delegate.get());
	delegate_ = std::move(delegate);
	room_ = std::move(room);

	livekit::RoomOptions options;
	options.auto_subscribe = true;
	bool ok = false;
	try {
		ok = room_->connect(url, token, options);
	} catch (const std::exception &e) {
		log_warning(std::string("connect: ") + e.what());
	}
	if (gen != generation_.load()) {
		do_teardown(); // 连的这段时间里已经离开 / 换了房间
		return;
	}
	if (!ok) {
		on_failed(gen, "join_failed");
		return;
	}
	on_state(gen, "connected");
	on_participants(gen, remote_identities(*room_));

	std::vector<std::string> muted;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		for (const auto &entry : volumes_) {
			if (entry.second <= 0.0) {
				muted.push_back(entry.first);
			}
		}
	}
	for (const std::string &id : muted) {
		do_apply_volume(id);
	}
	if (want_mic_) {
		do_apply_mic(gen, true);
	}
}

void GloryVoiceDesktop::do_apply_mic(int gen, bool enabled) {
	if (!room_ || gen != generation_.load()) {
		return;
	}
	auto local = room_->localParticipant().lock();
	if (!local || room_->connectionState() != livekit::ConnectionState::Connected) {
		return; // 还没连上：want_mic_ 记着，连上之后 do_join 会再调
	}
	if (enabled) {
		if (mic_track_) {
			return;
		}
		std::string failure;
		try {
			livekit::PlatformAudioOptions audio;
			audio.echo_cancellation = true;
			audio.noise_suppression = true;
			audio.auto_gain_control = true;
			audio.prefer_hardware = false;
			auto source = platform_audio_->createAudioSource(audio);
			auto track = livekit::LocalAudioTrack::createLocalAudioTrack("microphone", source);
			livekit::TrackPublishOptions publish;
			publish.source = livekit::TrackSource::SOURCE_MICROPHONE;
			local->publishTrack(track, publish);
			mic_source_ = source;
			mic_track_ = track;
		} catch (const std::exception &e) {
			failure = e.what();
		}
		std::lock_guard<std::mutex> lock(mutex_);
		if (gen != generation_.load()) {
			return;
		}
		snapshot_.mic_on = failure.empty();
		snapshot_.mic_error = failure.empty() ? "" : "mic_failed";
		if (!failure.empty()) {
			log_warning("microphone: " + failure);
		}
		return;
	}
	// 关麦 = 撤掉麦克风轨道并放掉录音源，不是静音：麦克风关着的时候不能再录。
	if (mic_track_) {
		try {
			if (auto publication = mic_track_->publication()) {
				local->unpublishTrack(publication->sid());
			}
		} catch (const std::exception &e) {
			log_warning(std::string("unpublish: ") + e.what());
		}
		mic_track_.reset();
		mic_source_.reset();
	}
	std::lock_guard<std::mutex> lock(mutex_);
	if (gen == generation_.load()) {
		snapshot_.mic_on = false;
	}
}

void GloryVoiceDesktop::do_apply_volume(const std::string &identity) {
	if (!room_) {
		return;
	}
	double volume = 1.0;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		auto it = volumes_.find(identity);
		if (it != volumes_.end()) {
			volume = it->second;
		}
	}
	auto participant = room_->remoteParticipant(identity).lock();
	if (!participant) {
		return;
	}
	for (const auto &entry : participant->trackPublications()) {
		const auto &publication = entry.second;
		if (publication && publication->kind() == livekit::TrackKind::KIND_AUDIO) {
			publication->setSubscribed(volume > 0.0);
		}
	}
}

void GloryVoiceDesktop::do_teardown() {
	mic_track_.reset();
	mic_source_.reset();
	if (room_) {
		try {
			room_->disconnect();
		} catch (const std::exception &e) {
			log_warning(std::string("disconnect: ") + e.what());
		}
		room_.reset();
	}
	delegate_.reset(); // 房间先没，回调对象才能没
	// 不在语音里就放掉音频设备（不占着麦克风和喇叭）。
	platform_audio_.reset();
}

void GloryVoiceDesktop::shutdown() {
	{
		std::lock_guard<std::mutex> lock(queue_mutex_);
		if (stopping_ && !worker_.joinable()) {
			return;
		}
	}
	++generation_;
	post([this]() {
		want_mic_ = false;
		do_teardown();
	});
	{
		std::lock_guard<std::mutex> lock(queue_mutex_);
		stopping_ = true;
	}
	queue_cv_.notify_all();
	if (worker_.joinable()) {
		worker_.join();
	}
	if (sdk_ready_) {
		livekit::shutdown();
		sdk_ready_ = false;
	}
}
