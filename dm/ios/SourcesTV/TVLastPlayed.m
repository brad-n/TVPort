// "Recently played" for SwitchTV (tvport/switchtv): when this game comes to the front it records its title ID and the time in a keychain access group that SwitchTV and its Top Shelf extension also
// use (<team>.dev.tvport.switchtv, named by DMSwitchTVGroup in Info.plist, set by build_ipa.sh and granted by the keychain-access-groups entitlement), so a game started from anywhere (the home screen,
// Siri, the Top Shelf) counts. One generic-password item per game: service dev.tvport.switchtv, account <TITLE ID IN CAPITALS>, value the Unix time in seconds as text. Harmless when the group is not
// available (an unsigned or sideloaded build): the keychain refuses and nothing happens.
// The format is read by tvport/switchtv/Shared/SharedStore.swift; keep the two in step.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static NSString *const kSchemePrefix = @"switchtv-";
static NSString *const kService = @"dev.tvport.switchtv";

typedef BOOL (^TVStorePut)(NSString *account, NSData *value);

// Records the play of the game whose URL scheme is `scheme` (switchtv-<title ID>) through `put`. Returns NO when the scheme is not a SwitchTV one or the store refused.
BOOL tv_last_played_write(TVStorePut put, NSString *scheme, NSDate *when) {
    if (!put || ![scheme.lowercaseString hasPrefix:kSchemePrefix]) return NO;
    NSString *titleID = [scheme substringFromIndex:kSchemePrefix.length].uppercaseString;
    if (titleID.length != 16) return NO;
    if ([titleID stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"]].length) return NO;
    return put(titleID, [[NSString stringWithFormat:@"%.0f", when.timeIntervalSince1970] dataUsingEncoding:NSUTF8StringEncoding]);
}

static BOOL keychain_put(NSString *group, NSString *account, NSData *value) {
    NSDictionary *key = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: kService, (__bridge id)kSecAttrAccount: account, (__bridge id)kSecAttrAccessGroup: group};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)key, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: value});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *add = [key mutableCopy];
        add[(__bridge id)kSecValueData] = value;
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    return status == errSecSuccess;
}

// Called whenever the game becomes active; the scheme is the one this app declares for SwitchTV (CFBundleURLTypes).
void tv_record_last_played(void) {
    @autoreleasepool {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *group = info[@"DMSwitchTVGroup"];
        if (![group isKindOfClass:NSString.class] || !group.length) return;
        for (NSDictionary *type in info[@"CFBundleURLTypes"])
            for (NSString *scheme in type[@"CFBundleURLSchemes"])
                if (tv_last_played_write(^BOOL(NSString *account, NSData *value) { return keychain_put(group, account, value); }, scheme, [NSDate date])) return;
    }
}
