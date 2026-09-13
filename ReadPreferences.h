// Shared preferences for the tweak and its Settings page.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#define MR_DOMAIN CFSTR("com.551uk.markmutedchatsread16")
#define MR_CHANGED CFSTR("com.551uk.markmutedchatsread16/changed")
static inline BOOL MREnabled(void) {
    CFPreferencesAppSynchronize(MR_DOMAIN);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), MR_DOMAIN);
    BOOL enabled = value == NULL || (CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value));
    if (value) CFRelease(value);
    return enabled;
}
static inline void MRSetEnabled(BOOL enabled) {
    CFPreferencesSetAppValue(CFSTR("Enabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse, MR_DOMAIN);
    CFPreferencesAppSynchronize(MR_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), MR_CHANGED, NULL, NULL, true);
}
