#import "GlorySignInNative.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <map>

using namespace godot;
static NSString *native_string(const String &s) {
    return [NSString stringWithUTF8String:s.utf8().get_data()];
}
static void on_main(void (^operation)(void)) {
    if ([NSThread isMainThread]) operation();
    else dispatch_sync(dispatch_get_main_queue(), operation);
}

// Godot owns UIApplicationDelegate. Intercept just its URL method and preserve
// the original implementation for every URL the Google SDK does not handle.
// This also handles the app-switch redirect used by managed Google accounts.
static IMP previous_open_url = nullptr;
static Class delegate_class = Nil;
static std::map<Class, IMP> previous_scene_urls;
static id scene_observer = nil;
static IMP original_scene_handler(Class type) {
    for (Class current = type; current; current = class_getSuperclass(current)) {
        auto entry = previous_scene_urls.find(current);
        if (entry != previous_scene_urls.end()) return entry->second;
    }
    return nullptr;
}
static BOOL open_url(id delegate, SEL selector, UIApplication *app, NSURL *url, NSDictionary *options) {
    if ([[GlorySignInNative shared] handleURL:url]) return YES;
    if (previous_open_url) {
        using Callback = BOOL (*)(id, SEL, UIApplication *, NSURL *, NSDictionary *);
        return reinterpret_cast<Callback>(previous_open_url)(delegate, selector, app, url, options);
    }
    return NO;
}
static void scene_open_urls(id delegate, SEL selector, UIScene *scene, NSSet<UIOpenURLContext *> *contexts) {
    NSMutableSet<UIOpenURLContext *> *unhandled = [NSMutableSet set];
    for (UIOpenURLContext *context in contexts) {
        if (![[GlorySignInNative shared] handleURL:context.URL]) [unhandled addObject:context];
    }
    IMP original = original_scene_handler(object_getClass(delegate));
    if (unhandled.count && original) {
        using Callback = void (*)(id, SEL, UIScene *, NSSet<UIOpenURLContext *> *);
        reinterpret_cast<Callback>(original)(delegate, selector, scene, unhandled);
    }
}
static void install_scene_handlers() {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        id delegate = scene.delegate;
        if (!delegate) continue;
        Class type = object_getClass(delegate);
        if (previous_scene_urls.count(type)) continue;
        SEL selector = @selector(scene:openURLContexts:);
        Method method = class_getInstanceMethod(type, selector);
        IMP original = method ? method_getImplementation(method) : nullptr;
        if (original == reinterpret_cast<IMP>(scene_open_urls)) original = original_scene_handler(class_getSuperclass(type));
        previous_scene_urls[type] = original;
        class_replaceMethod(type, selector, reinterpret_cast<IMP>(scene_open_urls),
                            method ? method_getTypeEncoding(method) : "v@:@@");
    }
}
static void install_url_handler() {
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate || delegate_class) return;
    delegate_class = object_getClass(delegate);
    SEL selector = @selector(application:openURL:options:);
    Method method = class_getInstanceMethod(delegate_class, selector);
    previous_open_url = method ? method_getImplementation(method) : nullptr;
    const char *types = method ? method_getTypeEncoding(method) : "B@:@@@";
    class_replaceMethod(delegate_class, selector, reinterpret_cast<IMP>(open_url), types);
    install_scene_handlers();
    scene_observer = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        install_scene_handlers();
    }];
}

class GlorySignInIOS : public Object {
    GDCLASS(GlorySignInIOS, Object)
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("isGoogleAvailable"), &GlorySignInIOS::isGoogleAvailable);
        ClassDB::bind_method(D_METHOD("isAppleAvailable"), &GlorySignInIOS::isAppleAvailable);
        ClassDB::bind_method(D_METHOD("beginGoogleSignIn", "web_client_id", "nonce"), &GlorySignInIOS::beginGoogleSignIn);
        ClassDB::bind_method(D_METHOD("beginAppleSignIn", "nonce"), &GlorySignInIOS::beginAppleSignIn);
        ClassDB::bind_method(D_METHOD("pollSignIn", "request_id"), &GlorySignInIOS::pollSignIn);
        ClassDB::bind_method(D_METHOD("cancelSignIn", "request_id"), &GlorySignInIOS::cancelSignIn);
    }
public:
    bool isGoogleAvailable() {
        __block bool value = false;
        on_main(^{ value = [[GlorySignInNative shared] isGoogleAvailable]; });
        return value;
    }
    bool isAppleAvailable() {
        __block bool value = false;
        on_main(^{ value = [[GlorySignInNative shared] isAppleAvailable]; });
        return value;
    }
    int64_t beginGoogleSignIn(const String &web_id, const String &nonce) {
        NSString *client = native_string(web_id), *hash = native_string(nonce);
        __block NSInteger value;
        on_main(^{ value = [[GlorySignInNative shared] beginGoogleSignIn:client nonce:hash]; });
        return value;
    }
    int64_t beginAppleSignIn(const String &nonce) {
        NSString *hash = native_string(nonce);
        __block NSInteger value;
        on_main(^{ value = [[GlorySignInNative shared] beginAppleSignIn:hash]; });
        return value;
    }
    String pollSignIn(int64_t request_id) {
        __block NSString *value;
        on_main(^{ value = [[GlorySignInNative shared] pollSignIn:request_id]; });
        return String::utf8(value.UTF8String);
    }
    void cancelSignIn(int64_t request_id) {
        on_main(^{ [[GlorySignInNative shared] cancelSignIn:request_id]; });
    }
};

static GlorySignInIOS *signin = nullptr;
void initialize_signin() {
    GDREGISTER_ABSTRACT_CLASS(GlorySignInIOS);
    signin = memnew(GlorySignInIOS);
    Engine::get_singleton()->register_singleton("GlorySignIn", signin);
    on_main(^{ install_url_handler(); });
}
void terminate_signin() {
    if (!signin) return;
    Engine::get_singleton()->unregister_singleton("GlorySignIn");
    on_main(^{
        [[GlorySignInNative shared] shutdown];
        if (scene_observer) {
            [NSNotificationCenter.defaultCenter removeObserver:scene_observer];
            scene_observer = nil;
        }
    });
    memdelete(signin);
    signin = nullptr;
}
