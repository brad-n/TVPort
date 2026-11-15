// SwitchTV's Options page for this game (tvport/switchtv: the game's settings, chosen on the Apple TV before it starts). tvOS has no launcher screen (project_tv.yml leaves Launcher.swift out), so these
// are the Apple TV's saved choices. SwitchTV keeps them in the keychain access group it shares with the game apps (<team>.dev.tvport.switchtv, named by DMSwitchTVGroup in Info.plist, as for
// TVLastPlayed.m): one generic-password item per game, service dev.tvport.switchtv.options, account <TITLE ID IN CAPITALS>, value a JSON object {"DM_<NAME>": "<value>", ...} holding the choices that
// differ from the game's defaults. main.m applies them at boot, before the host reads its environment, with the precedence the iPhone launcher gives its saved choices (LauncherSettings.swift):
// the launch environment first, then an env file (Library/Caches/env.txt, then the bundle's dm/env.txt), then these, then the game's defaults; DM_SAVED_CHOICES=0 ignores them.
// Only the settings of this app's own list (dm/launcher.json, the rows dm/games/settings.py wrote for this game) are taken, each with a value its row offers: SwitchTV can set nothing a launcher could not.
// Without the group (an unsigned or sideloaded build) nothing is read, and the log says so. The format is written by tvport/switchtv/Shared/GameOptions.swift; keep the two in step.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kOptionsService = @"dev.tvport.switchtv.options";

typedef NSString *_Nullable (^TVEnvGet)(NSString *key);
typedef void (^TVEnvSet)(NSString *key, NSString *value);
typedef void (^TVLog)(NSString *line);

// The title ID in capitals of a switchtv-<title ID> URL scheme; nil for any other
NSString *tv_options_title_id(NSString *scheme) {
    if (![scheme.lowercaseString hasPrefix:@"switchtv-"]) return nil;
    NSString *titleID = [scheme substringFromIndex:9].uppercaseString;
    if (titleID.length != 16 || [titleID stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"]].length) return nil;
    return titleID;
}

// Whether a launcher.json row offers `value`, as LauncherSettings.swift's Setting.accepts decides for a saved choice (a kind it does not know takes nothing)
BOOL tv_option_accepts(NSDictionary *row, NSString *value) {
    if (![row isKindOfClass:NSDictionary.class] || ![value isKindOfClass:NSString.class]) return NO;
    NSString *kind = row[@"kind"];
    if ([kind isEqual:@"choice"]) {
        for (NSArray *option in row[@"options"])
            if ([option isKindOfClass:NSArray.class] && option.count == 2 && [option[0] isEqual:value]) return YES;
        return NO;
    }
    if ([kind isEqual:@"range"]) {
        NSNumber *lo = row[@"min"], *hi = row[@"max"];
        if (![lo isKindOfClass:NSNumber.class] || ![hi isKindOfClass:NSNumber.class] || !value.length || [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"xX"]].location != NSNotFound) return NO;   // no hex, as launcher.c
        const char *text = value.UTF8String; char *end = NULL;
        double n = strtod(text, &end);
        return end && !*end && isfinite(n) && n >= lo.doubleValue && n <= hi.doubleValue;
    }
    if ([kind isEqual:@"toggle"]) {
        NSString *on = [row[@"on"] isKindOfClass:NSString.class] ? row[@"on"] : @"1", *off = [row[@"off"] isKindOfClass:NSString.class] ? row[@"off"] : @"0";
        return [value isEqualToString:on] || [value isEqualToString:off];
    }
    return NO;
}

// Applies the saved choices (`saved`, the keychain item's JSON) of the settings `rows` (launcher.json's "settings") through `set`, each only where `get` finds the variable unset; `fromLaunch`: the
// variables the launch environment set (DM_ENV_LAUNCH_KEYS), for the log. Returns the variables set, in name order; every decision is a line through `log`
NSArray<NSString *> *tv_options_apply(NSData *saved, NSArray *rows, NSSet<NSString *> *fromLaunch, TVEnvGet get, TVEnvSet set, TVLog log) {
    NSMutableArray<NSString *> *applied = [NSMutableArray array];
    id choices = saved.length ? [NSJSONSerialization JSONObjectWithData:saved options:0 error:nil] : nil;
    if (![choices isKindOfClass:NSDictionary.class]) { log(saved.length ? @"[RED] boot: SwitchTV options: the saved item is not a JSON object; none applied" : @"boot: SwitchTV options: none saved"); return applied; }
    NSMutableDictionary<NSString *, NSDictionary *> *byName = [NSMutableDictionary dictionary];
    for (NSDictionary *row in [rows isKindOfClass:NSArray.class] ? rows : @[])
        if ([row isKindOfClass:NSDictionary.class] && [row[@"env"] isKindOfClass:NSString.class]) byName[row[@"env"]] = row;
    NSUInteger kept = 0, skipped = 0;
    for (NSString *key in [[choices allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id value = choices[key];
        NSDictionary *row = [key isKindOfClass:NSString.class] ? byName[key] : nil;
        if (!row) { skipped++; log([NSString stringWithFormat:@"[RED] boot: SwitchTV option %@ skipped: not a setting of this game", key]); continue; }
        if (!tv_option_accepts(row, value)) { skipped++; log([NSString stringWithFormat:@"[RED] boot: SwitchTV option %@=%@ skipped: not a value this game offers", key, value]); continue; }
        NSString *have = get(key);
        if (have) { kept++; log([NSString stringWithFormat:@"boot: SwitchTV option %@=%@ not applied: kept at %@ (%@)", key, value, have, [fromLaunch containsObject:key] ? @"launch environment" : @"env file"]); continue; }
        set(key, value); [applied addObject:key];
        log([NSString stringWithFormat:@"boot: SwitchTV option %@=%@", key, value]);
    }
    log([NSString stringWithFormat:@"boot: SwitchTV options: %lu applied, %lu kept, %lu skipped", (unsigned long)applied.count, (unsigned long)kept, (unsigned long)skipped]);
    return applied;
}

// The rows of this app's settings list: dm/launcher.json, or an app of several programs' first (dm/p0/launcher.json), which SwitchTV's catalogue reads too
static NSArray *launcher_rows(void) {
    NSString *dm = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"];
    for (NSString *name in @[@"launcher.json", @"p0/launcher.json"]) {
        NSData *data = [NSData dataWithContentsOfFile:[dm stringByAppendingPathComponent:name]];
        NSDictionary *file = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([file isKindOfClass:NSDictionary.class] && [file[@"settings"] isKindOfClass:NSArray.class]) return file[@"settings"];
    }
    return nil;
}

// main.m boot_env, after the env files: the choices SwitchTV saved for this game go into the environment
void tv_apply_switchtv_options(void) {
    @autoreleasepool {
        TVLog log = ^(NSString *line) { fprintf(stderr, "%s\n", line.UTF8String); };
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *group = info[@"DMSwitchTVGroup"], *titleID = nil;
        if (![group isKindOfClass:NSString.class] || !group.length) { log(@"boot: SwitchTV options: this build has no keychain group (unsigned or sideloaded), so none are read"); return; }
        const char *ignore = getenv("DM_SAVED_CHOICES");
        if (ignore && !strcmp(ignore, "0")) { log(@"boot: SwitchTV options ignored (DM_SAVED_CHOICES=0)"); return; }
        for (NSDictionary *type in info[@"CFBundleURLTypes"])
            for (NSString *scheme in type[@"CFBundleURLSchemes"]) if (!titleID && [scheme isKindOfClass:NSString.class]) titleID = tv_options_title_id(scheme);
        if (!titleID) { log(@"boot: SwitchTV options: no switchtv-<title ID> URL scheme in this build; none read"); return; }
        NSArray *rows = launcher_rows();
        if (!rows.count) { log(@"boot: SwitchTV options: this build has no settings list (dm/launcher.json); none read"); return; }
        NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: kOptionsService, (__bridge id)kSecAttrAccount: titleID,
                                (__bridge id)kSecAttrAccessGroup: group, (__bridge id)kSecReturnData: @YES, (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
        CFTypeRef found = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
        NSData *saved = status == errSecSuccess ? (__bridge_transfer NSData *)found : nil;
        if (status != errSecSuccess && status != errSecItemNotFound) { log([NSString stringWithFormat:@"boot: SwitchTV options: the keychain refused the group %@ (status %d); none read", group, (int)status]); return; }
        NSSet *fromLaunch = [NSSet setWithArray:[@(getenv("DM_ENV_LAUNCH_KEYS") ?: "") componentsSeparatedByString:@" "]];
        tv_options_apply(saved, rows, fromLaunch, ^NSString *(NSString *key) { const char *v = getenv(key.UTF8String); return v ? @(v) : nil; },
                         ^(NSString *key, NSString *value) { setenv(key.UTF8String, value.UTF8String, 1); }, log);
    }
}
