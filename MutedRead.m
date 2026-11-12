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
    SEL muted = sel_registerName("__ck_isMuted");
    if (Supports(chat, muted, "Bc"))
        return ((BOOL (*)(id, SEL))objc_msgSend)(chat, muted);
    // Some builds expose the persisted mute-until date rather than the convenience getter.
    SEL until = sel_registerName("__ck_muteUntilDate");
    if (Supports(chat, until, "@")) {
        id date = ((id (*)(id, SEL))objc_msgSend)(chat, until);
        return [date isKindOfClass:NSDate.class] &&
               [(NSDate *)date compare:[NSDate date]] == NSOrderedDescending;
    }
    return NO; // Unknown is not muted: never read another person's active chat.
}

static void MarkChat(id chat) {
    if (!enabled) return;
    SEL unread = sel_registerName("unreadMessageCount");
    SEL mark = sel_registerName("markAllMessagesAsRead");
    if (!Supports(chat, unread, "QqIi") || !Supports(chat, mark, "v")) return;
    if (!IsMuted(chat)) return;
    if (!((unsigned long long (*)(id, SEL))objc_msgSend)(chat, unread)) return;
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
    dispatch_async(dispatch_get_main_queue(), ^{
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
    // ChatKit supplies muted-state accessors; do not guess when they are unavailable.
    // Load it before hooking IMCore, including within imagent.
    void *chatKit = dlopen("/System/Library/PrivateFrameworks/ChatKit.framework/ChatKit", RTLD_LAZY | RTLD_GLOBAL);
    if (!chatKit) NSLog(@"[MutedRead] ChatKit unavailable in %@", NSProcessInfo.processInfo.processName);
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
    // A single catch-up on startup, and another only if the user enables the tweak.
    // All subsequent reads are triggered by unread-count/message events above.
    if (enabled) ScanChats();
    NSLog(@"[MutedRead] Installed in %@; IMChat=%@, mute API=%@, unread API=%@, read API=%@",
          NSProcessInfo.processInfo.processName, chat ? @"yes" : @"no",
          Matches(chat, sel_registerName("__ck_isMuted"), "Bc", @[]) ? @"yes" : @"no",
          Matches(chat, sel_registerName("unreadMessageCount"), "QqIi", @[]) ? @"yes" : @"no",
          Matches(chat, sel_registerName("markAllMessagesAsRead"), "v", @[]) ? @"yes" : @"no");
}

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        NSString *process = NSProcessInfo.processInfo.processName;
        if (![bundle isEqualToString:@"com.apple.MobileSMS"] &&
            ![bundle isEqualToString:@"com.apple.springboard"] &&
            ![process isEqualToString:@"imagent"]) return;
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 16) return;
        dispatch_async(dispatch_get_main_queue(), ^{ Install(); });
    }
}
