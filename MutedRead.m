#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <string.h>
#import "ReadPreferences.h"
static BOOL enabled = YES;

// Only invoke selectors whose runtime ABI matches the signature we use.
static BOOL Matches(Class cls, SEL sel, const char *result, NSArray<NSString *> *args) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != args.count + 2) return NO;
    char type[128] = {0};
    method_getReturnType(m, type, sizeof(type));
    if (!strchr(result, type[0])) return NO;
    for (NSUInteger i = 0; i < args.count; i++) {
        method_getArgumentType(m, (unsigned)i + 2, type, sizeof(type));
        if (!strchr(args[i].UTF8String, type[0])) return NO;
    }
    return YES;
}

static BOOL Supports(id obj, SEL sel, const char *result) {
    return obj && Matches(object_getClass(obj), sel, result, @[]);
}

static void MarkChat(id chat) {
    if (!enabled) return;
    SEL muted = sel_registerName("__ck_isMuted");
    SEL unread = sel_registerName("unreadMessageCount");
    SEL mark = sel_registerName("markAllMessagesAsRead");
    if (!Supports(chat, muted, "Bc") || !Supports(chat, unread, "Q") ||
        !Supports(chat, mark, "v")) return;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(chat, muted) ||
        !((unsigned long long (*)(id, SEL))objc_msgSend)(chat, unread)) return;
    // Bound feedback from Apple's own unread-count updates; never alter counts ourselves.
    static char lastAttemptKey;
    NSNumber *last = objc_getAssociatedObject(chat, &lastAttemptKey);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (last && now - last.doubleValue < 1.0) return;
    objc_setAssociatedObject(chat, &lastAttemptKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL))objc_msgSend)(chat, mark);
}

static void QueueChat(id chat) {
    if (!chat) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static char pendingKey;
        if (objc_getAssociatedObject(chat, &pendingKey)) return;
        objc_setAssociatedObject(chat, &pendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0), dispatch_get_main_queue(), ^{
            MarkChat(chat); // Recheck mute status after updates, including an intervening unmute.
            // A single catch-up covers bursts arriving during the feedback cooldown.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                MarkChat(chat);
                objc_setAssociatedObject(chat, &pendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
        });
    });
}

static void QueueConversation(id conversation) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL sel = sel_registerName("chat");
        if (Supports(conversation, sel, "@"))
            QueueChat(((id (*)(id, SEL))objc_msgSend)(conversation, sel));
    });
}

static void ScanChats(void) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    SEL shared = sel_registerName("sharedInstance");
    SEL all = sel_registerName("allExistingChats");
    if (!Supports(registryClass, shared, "@")) return;
    id registry = ((id (*)(id, SEL))objc_msgSend)(registryClass, shared);
    if (!Supports(registry, all, "@")) return;
    id chats = ((id (*)(id, SEL))objc_msgSend)(registry, all);
    if (![chats isKindOfClass:NSArray.class]) return;
    for (id chat in [chats copy]) QueueChat(chat);
}

static void HookObject(Class cls, NSString *name, BOOL conversation) {
    SEL sel = NSSelectorFromString(name);
    if (!Matches(cls, sel, "v", @[@"@"])) return;
    Method method = class_getInstanceMethod(cls, sel);
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id obj, id value) {
        ((void (*)(id, SEL, id))original)(obj, sel, value);
        if (conversation) QueueConversation(obj); else QueueChat(obj);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
}

static void PreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{ enabled = MREnabled(); if (enabled) ScanChats(); });
}

static void Install(void) {
    enabled = MREnabled();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PreferencesChanged, MR_CHANGED, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dlopen("/System/Library/PrivateFrameworks/ChatKit.framework/ChatKit", RTLD_LAZY);
    Class chat = NSClassFromString(@"IMChat");
    HookObject(chat, @"__ck_setMuteUntilDate:", NO);
    HookObject(chat, @"_setChatProperties:", NO);
    HookObject(chat, @"updateMessage:", NO);
    SEL count = sel_registerName("_setDBUnreadCount:");
    if (Matches(chat, count, "v", @[@"Q"])) {
        Method m = class_getInstanceMethod(chat, count);
        IMP original = method_getImplementation(m);
        IMP replacement = imp_implementationWithBlock(^(id obj, unsigned long long n) {
            ((void (*)(id, SEL, unsigned long long))original)(obj, count, n);
            if (n) QueueChat(obj);
        });
        class_replaceMethod(chat, count, replacement, method_getTypeEncoding(m));
    }
    SEL countPost = sel_registerName("_setDBUnreadCount:postNotification:");
    if (Matches(chat, countPost, "v", @[@"Q", @"Bc"])) {
        Method m = class_getInstanceMethod(chat, countPost);
        IMP original = method_getImplementation(m);
        IMP replacement = imp_implementationWithBlock(^(id obj, unsigned long long n, BOOL post) {
            ((void (*)(id, SEL, unsigned long long, BOOL))original)(obj, countPost, n, post);
            if (n) QueueChat(obj);
        });
        class_replaceMethod(chat, countPost, replacement, method_getTypeEncoding(m));
    }
    Class conversation = NSClassFromString(@"CKConversation");
    HookObject(conversation, @"setMutedUntilDate:", YES);
    HookObject(conversation, @"_chatPropertiesChanged:", YES);
    HookObject(conversation, @"_chatItemsDidChange:", YES);
    // Event-driven catch-up for existing muted conversations and registry reloads.
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[@"UIApplicationDidBecomeActiveNotification", @"IMChatRegistryDidLoadNotification"]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            ScanChats();
        }];
    }
    for (NSNumber *delay in @[@2, @8]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay.longLongValue * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ ScanChats(); });
    }
    NSLog(@"[MutedRead] Installed in %@; mute API available: %@", NSProcessInfo.processInfo.processName,
          Matches(chat, sel_registerName("__ck_isMuted"), "Bc", @[]) ? @"yes" : @"no");
}

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (![bundle isEqualToString:@"com.apple.MobileSMS"] && ![bundle isEqualToString:@"com.apple.springboard"]) return;
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 16) return;
        dispatch_async(dispatch_get_main_queue(), ^{ Install(); });
    }
}
