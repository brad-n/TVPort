// One environment switch file into the environment (main.m boot_env; dm/ios/tests/test_tv_options.py runs it on the Mac): one KEY=VALUE per line, # starts a comment, the first = splits.
// A key nothing set yet is set and added to `set`; a key already set (by the launch, an earlier file, or on the Apple TV SwitchTV's saved choices) keeps its value, and the log names the source that
// won, as `winner` says. `skip` drops a key before either (a player build's launcher keys); nil drops none. `name` is the file as the log names it.
#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// What set a variable an env file finds set, for its log line: the launch environment, the player's env.txt, SwitchTV's saved choice, or an earlier line of the same file
static inline NSString *dm_env_source(NSString *key, NSArray<NSString *> *launch, NSArray<NSString *> *player, NSArray<NSString *> *switchtv) {
    return [launch containsObject:key] ? @"the launch environment" : [player containsObject:key] ? @"the player's env.txt" : [switchtv containsObject:key] ? @"SwitchTV's choice" : @"an earlier line";
}

static inline void dm_env_file_apply(NSString *path, const char *name, NSMutableArray<NSString *> *set, BOOL (^skip)(NSString *key), NSString *(^winner)(NSString *key)) {
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
        if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
        NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
        if (skip && skip(k)) continue;
        const char *have = getenv(k.UTF8String);
        if (!have) { setenv(k.UTF8String, v.UTF8String, 0); [set addObject:k]; fprintf(stderr, "boot: env %s=%s (%s)\n", k.UTF8String, v.UTF8String, name); }
        else if (strcmp(have, v.UTF8String)) fprintf(stderr, "boot: env %s=%s (%s) not applied: %s=%s from %s wins\n", k.UTF8String, v.UTF8String, name, k.UTF8String, have, winner ? winner(k).UTF8String : "an earlier source");
    }
}
