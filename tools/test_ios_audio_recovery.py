"""Compile the actual recovery method from our engine patch against fake audio units."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class RecoveryTests(unittest.TestCase):
    def test_recovery_sequence_budget_and_failures(self):
        patch = Path(__file__).resolve().parents[1] / "deploy/engine/godot-4.7-ios-audio-recovery.patch"
        added = "\n".join(line[1:] for line in patch.read_text().splitlines()
                          if line.startswith("+") and not line.startswith("+++"))
        start = added.index("void AudioDriverCoreAudio::recover_output_if_stalled()")
        method = added[start:added.index("\n#endif", start)]
        harness = r'''
#import <Foundation/Foundation.h>
#include <cassert>
#include <vector>
using OSStatus = int;
static bool activate_ok = true;
static int init_result = 0, start_result = 0;
static std::vector<int> calls;
@interface AVAudioSession : NSObject
+ (instancetype)sharedInstance;
- (BOOL)setActive:(BOOL)value error:(NSError **)error;
@end
@implementation AVAudioSession
+ (instancetype)sharedInstance { static AVAudioSession *s = [AVAudioSession new]; return s; }
- (BOOL)setActive:(BOOL)value error:(NSError **)error { return activate_ok; }
@end
OSStatus AudioOutputUnitStop(void *) { calls.push_back(1); return 0; }
OSStatus AudioUnitUninitialize(void *) { calls.push_back(2); return 0; }
OSStatus AudioUnitInitialize(void *) { calls.push_back(3); return init_result; }
OSStatus AudioOutputUnitStart(void *) { calls.push_back(4); return start_result; }
struct OS {
    uint64_t now = 2000000;
    static OS *get_singleton() { static OS os; return &os; }
    uint64_t get_ticks_usec() { return now; }
};
struct AudioDriverCoreAudio {
    void *audio_unit = (void *)1;
    unsigned int recovery_attempts = 0;
    uint64_t recovery_check_after = 0;
    bool active = true;
    double age = 0.01;
    double get_time_since_last_mix() { return age; }
    void recover_output_if_stalled();
};
''' + method + r'''
int main() {
    AudioDriverCoreAudio d;
    d.recover_output_if_stalled(); assert(calls.empty()); // Healthy mixing.
    d.age = 0.24;
    d.recover_output_if_stalled(); assert(calls.empty()); // Allow callback scheduling jitter.
    d.age = 0.26;
    d.recovery_check_after = OS::get_singleton()->now + 1;
    d.recover_output_if_stalled(); assert(calls.empty()); // Initial grace still applies.
    d.recovery_check_after = 0;
    d.recover_output_if_stalled(); assert(calls.size() == 4); // Recover before a full second.
    d = {}; calls.clear();
    d.age = 2;
    d.recover_output_if_stalled();
    assert((calls == std::vector<int>{1,2,3,4}) && d.active);
    calls.clear();
    d.recover_output_if_stalled(); assert(calls.empty()); // Backoff.
    for (int i=0; i<10; i++) {
        OS::get_singleton()->now += 1000000;
        d.recover_output_if_stalled();
    }
    assert(d.recovery_attempts == 6 && calls.size() == 20); // Bounded retries.
    d = {}; d.age = 2; calls.clear(); activate_ok = false;
    d.recover_output_if_stalled(); assert(calls.empty() && d.recovery_attempts == 1);
    activate_ok = true; d = {}; d.age = 2; init_result = -1;
    d.recover_output_if_stalled();
    assert((calls == std::vector<int>{1,2,3}) && !d.active); // No start after failed init.
    calls.clear(); d = {}; d.age = 2; init_result = 0; start_result = -1;
    d.recover_output_if_stalled(); assert(!d.active && calls.size() == 4);
    calls.clear(); d = {}; d.audio_unit = nullptr;
    d.recover_output_if_stalled(); assert(calls.empty());
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "recovery.mm"
            binary = Path(directory) / "recovery"
            source.write_text(harness)
            subprocess.run(["xcrun", "clang++", "-std=c++17", "-framework", "Foundation",
                            str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
