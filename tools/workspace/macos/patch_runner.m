#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <unistd.h>

static int child(NSString *binary, NSArray<NSString *> *args) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:binary];
    task.arguments = args;
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "Launch failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    [task waitUntilExit];
    return task.terminationStatus;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Glory-Patch"];
        [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
        freopen([[logDir stringByAppendingPathComponent:@"runner.log"] fileSystemRepresentation], "a", stdout);
        dup2(fileno(stdout), fileno(stderr));
        setvbuf(stdout, NULL, _IONBF, 0);
        NSLog(@"GLory Patch Runner starting, mode=%s", argc > 1 ? argv[1] : "--preflight");
        [NSApplication sharedApplication];
        NSString *root = @"/Volumes/repository/github/GLory";
        NSError *error = nil;
        NSString *script = [root stringByAppendingPathComponent:@"tools/nightly_patch.sh"];
        NSData *contents = [NSData dataWithContentsOfFile:script options:0 error:&error];
        if (!contents) {
            NSLog(@"Volume access failed: %@", error);
            return 77;
        }
        NSString *probe = [root stringByAppendingPathComponent:[@"build/.runner-access-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if (![@"GLory runner access check" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            NSLog(@"Volume write failed: %@", error);
            return 77;
        }
        [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
        NSString *python = [root stringByAppendingPathComponent:@".glory-tools/venv/bin/python"];
        int checked = child(python, @[@"-B", @"-c", @"import sys; sys.path.insert(0, '/Volumes/repository/github/GLory/GLory-v1.0/tools/workspace'); from glory_patch_nightly import token_from_keychain; assert token_from_keychain(); print('RUNNER_PREFLIGHT_OK volume_read_write=yes child_python=yes keychain=yes', flush=True)"]);
        if (checked) return checked;
        if (argc == 2 && strcmp(argv[1], "--run") == 0) {
            int result = child(@"/usr/bin/caffeinate", @[@"-i", @"/bin/bash", script]);
            NSLog(@"GLory patch task finished with exit=%d", result);
            return result;
        }
        return 0;
    }
}
