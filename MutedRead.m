// Mark Hide Alerts conversations read in both the UI and the message-receiving daemon.
// Never change the read state of conversations whose mute status is unknown.
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

// A muted conversation's incoming unread-count event is enough to trigger one read.
// No background polling, recurring timers, or repeated mark-as-read attempts.
static BOOL IsMuted(id chat) {
    // iOS 14-15 IMCore runtime headers expose isMuted / muteUntilDate directly.
    // The former __ck_ selectors were ChatKit-only compatibility names and
    // may not exist in iOS 16, causing every chat to be silently skipped.
    SEL modern = sel_registerName("isMuted");
    if (Supports(chat, modern, "Bc"))
        return ((BOOL (*)(id, SEL))objc_msgSend)(chat, modern);

    SEL dateSelector = sel_registerName("muteUntilDate");
    if (Supports(chat, dateSelector, "@")) {
        id muteUntil = ((id (*)(id, SEL))objc_msgSend)(chat, dateSelector);
        if ([muteUntil isKindOfClass:NSDate.class])
            return [(NSDate *)muteUntil timeIntervalSinceNow] > 0;
    }

    // Compatibility fallback for older ChatKit versions only.
    SEL legacy = sel_registerName("__ck_isMuted");
    if (Supports(chat, legacy, "Bc"))
        return ((BOOL (*)(id, SEL))objc_msgSend)(chat, legacy);

    SEL legacyDate = sel_registerName("__ck_muteUntilDate");
    if (Supports(chat, legacyDate, "@")) {
        id muteUntil = ((id (*)(id, SEL))objc_msgSend)(chat, legacyDate);
        if ([muteUntil isKindOfClass:NSDate.class])
            return [(NSDate *)muteUntil timeIntervalSinceNow] > 0;
    }
    return NO; // Unknown status: do not touch unmuted conversations.
}

static void MarkChat(id chat) {
    if (!enabled) return;
    SEL unread = sel_registerName("unreadMessageCount");
    SEL mark = sel_registerName("markAllMessagesAsRead");
    if (!Supports(chat, unread, "QqIi") || !Supports(chat, mark, "v")) return;
    unsigned long long count = ((unsigned long long (*)(id, SEL))objc_msgSend)(chat, unread);
    if (!count) return;
    if (!IsMuted(chat)) return;
    // The mark-as-read request is asynchronous. Remember this one event briefly,
    // rather than issuing the same request on adjacent registry callbacks.
    static char lastAttemptKey;
    NSNumber *last = objc_getAssociatedObject(chat, &lastAttemptKey);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (last && now - last.doubleValue < 0.5) return;
    objc_setAssociatedObject(chat, &lastAttemptKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[MutedRead] Marking muted conversation read in %@ (unread=%llu)",
          NSProcessInfo.processInfo.processName, count);
    ((void (*)(id, SEL))objc_msgSend)(chat, mark);
}

static void QueueChat(id chat) {
    if (!chat) return;
    // Coalesce multiple callbacks for the same incoming event onto one main-queue pass.
    dispatch_async(dispatch_get_main_queue(), ^{
        static char pendingKey;
        if (objc_getAssociatedObject(chat, &pendingKey)) return;
        objc_setAssociatedObject(chat, &pendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        MarkChat(chat);
        objc_setAssociatedObject(chat, &pendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static void QueueConversation(id conversation) {
    if (!conversation || !enabled) return;
    // CKConversation updates its IMChat properties asynchronously when Hide Alerts
    // is toggled. Make one delayed read attempt after the mute change is committed.
    // This is event-driven, NOT a repeating poll or retry loop.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        SEL sel = sel_registerName("chat");
        if (Supports(conversation, sel, "@"))
            QueueChat(((id (*)(id, SEL))objc_msgSend)(conversation, sel));
    });
}

static void ScanChats(void) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    SEL shared = sel_registerName("sharedInstance");
    if (!Supports(registryClass, shared, "@")) return;
    id registry = ((id (*)(id, SEL))objc_msgSend)(registryClass, shared);
    if (!registry) return;
    // Different IMCore builds expose different cached-chat collection methods.
    // Never enumerate unrelated objects or fabricate new chats.
    for (NSString *selectorName in @[@"allExistingChats", @"cachedChats"]) {
        SEL all = NSSelectorFromString(selectorName);
        if (!Supports(registry, all, "@")) continue;
        id chats = ((id (*)(id, SEL))objc_msgSend)(registry, all);
        id values = chats;
        if ([chats isKindOfClass:NSDictionary.class]) values = [chats allValues];
        if (![values isKindOfClass:NSArray.class] && ![values isKindOfClass:NSSet.class] &&
            ![values isKindOfClass:NSOrderedSet.class]) continue;
        for (id chat in [values copy]) {
            if ([chat isKindOfClass:NSClassFromString(@"IMChat")]) QueueChat(chat);
        }
        return;
    }
}

// Called by IMCore after it finishes loading previously stored chats.
// The initial one-shot scan may run before the registry is populated.
static void HookRegistryLoaded(Class cls, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!Matches(cls, sel, "v", @[@"@", @"@"])) return;
    Method method = class_getInstanceMethod(cls, sel);
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id obj, id identifier, id chats) {
        ((void (*)(id, SEL, id, id))original)(obj, sel, identifier, chats);
        if (!enabled) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            id values = chats;
            if ([values isKindOfClass:NSDictionary.class]) values = [values allValues];
            if ([values isKindOfClass:NSArray.class] || [values isKindOfClass:NSSet.class]) {
                for (id chat in values) {
                    if ([chat isKindOfClass:NSClassFromString(@"IMChat")]) QueueChat(chat);
                }
            }
            // The returned chat array may not contain all persisted conversations.
            ScanChats();
        });
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    NSLog(@"[MutedRead] Installed registry load callback %@", name);
}

// IMChatRegistry publishes changes when a chat receives or updates items.
// Two-object callback signatures are runtime-verified before hooking.
static void HookRegistryChatUpdated(Class cls) {
    SEL sel = sel_registerName("chat:updated:");
    if (!Matches(cls, sel, "v", @[@"@", @"@"])) return;
    Method method = class_getInstanceMethod(cls, sel);
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id obj, id chat, id update) {
        ((void (*)(id, SEL, id, id))original)(obj, sel, chat, update);
        if (enabled && [chat isKindOfClass:NSClassFromString(@"IMChat")]) QueueChat(chat);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
}

// Background IMCore updates its unread state through IMChatRegistry as well as IMChat.
// These methods are present in published IMCore runtime headers; only hook when their
// exact signature matches on the installed iOS build.
static void HookRegistryUnread(Class cls) {
    SEL single = sel_registerName("_updateUnreadCountForChat:");
    if (Matches(cls, single, "v", @[@"@"])) {
        Method m = class_getInstanceMethod(cls, single);
        IMP original = method_getImplementation(m);
        IMP replacement = imp_implementationWithBlock(^(id obj, id chat) {
            ((void (*)(id, SEL, id))original)(obj, single, chat);
            if (enabled && [chat isKindOfClass:NSClassFromString(@"IMChat")])
                QueueChat(chat);
        });
        class_replaceMethod(cls, single, replacement, method_getTypeEncoding(m));
        NSLog(@"[MutedRead] Hooked registry unread update (one argument)");
    } else NSLog(@"[MutedRead] Registry unread update (one argument) unavailable");

    SEL withNotification = sel_registerName("_updateUnreadCountForChat:shouldPostNotification:");
    if (Matches(cls, withNotification, "v", @[@"@", @"Bc"])) {
        Method m = class_getInstanceMethod(cls, withNotification);
        IMP original = method_getImplementation(m);
        IMP replacement = imp_implementationWithBlock(^(id obj, id chat, BOOL shouldPost) {
            ((void (*)(id, SEL, id, BOOL))original)(obj, withNotification, chat, shouldPost);
            if (enabled && [chat isKindOfClass:NSClassFromString(@"IMChat")])
                QueueChat(chat);
        });
        class_replaceMethod(cls, withNotification, replacement, method_getTypeEncoding(m));
        NSLog(@"[MutedRead] Hooked registry unread update (with notification)");
    } else NSLog(@"[MutedRead] Registry unread update (with notification) unavailable");
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
    dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_LAZY | RTLD_GLOBAL);
    // Modern IMChat exposes isMuted/muteUntilDate in IMCore directly.
    // Loading ChatKit in a background daemon is unnecessary and may pull in UIKit.
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"])
        dlopen("/System/Library/PrivateFrameworks/ChatKit.framework/ChatKit", RTLD_LAZY);
    Class chat = NSClassFromString(@"IMChat");
    HookObject(chat, @"__ck_setMuteUntilDate:", NO);
    HookObject(chat, @"_setChatProperties:", NO);
    HookObject(chat, @"updateMessage:", NO); // Event-driven fallback if unread count is not surfaced.
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
    Class registry = NSClassFromString(@"IMChatRegistry");
    HookRegistryLoaded(registry, @"chatLoadedWithChatIdentifier:chats:");
    HookRegistryLoaded(registry, @"_chatLoadedWithChatIdentifier:chats:");
    HookRegistryChatUpdated(registry);
    HookRegistryUnread(registry);
    // This callback occurs after an initial chat-list load, not merely at app startup.
    HookRegistryLoaded(registry, @"loadedChats:queryID:");
    // Foreground activation is another actual event, not a repeating poll.
    // It makes older unread chats visible even if startup ran before IMCore loaded them.
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) { ScanChats(); }];
    }
    if (enabled) ScanChats();
    NSLog(@"[MutedRead] Installed in %@; IMChat=%@, mute API=%@, unread API=%@, read API=%@",
          NSProcessInfo.processInfo.processName, chat ? @"yes" : @"no",
          Matches(chat, sel_registerName("isMuted"), "Bc", @[]) ? @"modern yes" :
          (Matches(chat, sel_registerName("__ck_isMuted"), "Bc", @[]) ? @"legacy yes" : @"no"),
          Matches(chat, sel_registerName("unreadMessageCount"), "QqIi", @[]) ? @"yes" : @"no",
          Matches(chat, sel_registerName("markAllMessagesAsRead"), "v", @[]) ? @"yes" : @"no");
}

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        NSString *process = NSProcessInfo.processInfo.processName;
        if (![bundle isEqualToString:@"com.apple.MobileSMS"] &&
            ![process isEqualToString:@"imagent"]) return;
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 16) return;
        dispatch_async(dispatch_get_main_queue(), ^{ Install(); });
    }
}
