#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>
#include <QuartzCore/QuartzCore.h>

#define LOG_PATH "/var/mobile/unikey.log"
#define LOG_CAP (180*1024)

static void UKLog(NSString *msg) {
    @try {
        struct stat st;
        if (stat(LOG_PATH, &st) == 0 && st.st_size > LOG_CAP) {
            remove(LOG_PATH); // 200kB自动封顶
        }
        FILE *f = fopen(LOG_PATH, "a");
        if (!f) return;
        time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
        fprintf(f, "[UK %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
        fclose(f);
    } @catch (NSException *e) { }
}

static id SafeMsgObj(id obj, SEL sel) {
    @try {
        if (!obj || !sel) return nil;
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        if (!m) return nil;
        const char *enc = method_getTypeEncoding(m);
        if (!enc || enc[0] != '@') return nil;
        return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) { return nil; }
}

static long SafeMsgInt(id obj, SEL sel) {
    @try {
        if (!obj || !sel) return -1;
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        if (!m) return -1;
        const char *enc = method_getTypeEncoding(m);
        if (!enc) return -1;
        char r = enc[0];
        if (!(r=='q'||r=='Q'||r=='i'||r=='I'||r=='l'||r=='L'||r=='c'||r=='C'||r=='B')) return -1;
        return ((long(*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) { return -1; }
}

// 配置：/var/mobile/unikey.conf 每行 "键码=动作"
// 动作: home | volup | voldown | shortcut:名字
static NSDictionary *LoadConfig(void) {
    static NSDictionary *cached = nil;
    static time_t cachedMtime = 0;
    @try {
        struct stat st;
        if (stat("/var/mobile/unikey.conf", &st) != 0) return cached;
        if (st.st_mtime == cachedMtime && cached) return cached;
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        FILE *f = fopen("/var/mobile/unikey.conf", "r");
        if (f) {
            char line[512];
            while (fgets(line, sizeof(line), f)) {
                NSString *s = [NSString stringWithUTF8String:line];
                s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (s.length == 0 || [s hasPrefix:@"#"]) continue;
                NSRange eq = [s rangeOfString:@"="];
                if (eq.location == NSNotFound || eq.location == 0) continue;
                NSString *key = [[s substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString *val = [[s substringFromIndex:eq.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                long long kt = [key longLongValue];
                if (kt > 0 && val.length) [map setObject:val forKey:@(kt)];
            }
            fclose(f);
        }
        cachedMtime = st.st_mtime;
        cached = map;
        UKLog([NSString stringWithFormat:@"config loaded: %lu bindings", (unsigned long)map.count]);
        return map;
    } @catch (NSException *e) { return cached; }
}

static void RunAction(NSString *action) {
    @try {
        if ([action caseInsensitiveCompare:@"home"] == NSOrderedSame) {
            Class c = objc_getClass("SBUIController");
            if (!c) { UKLog(@"home: SBUIController nil"); return; }
            id ctrl = SafeMsgObj(c, sel_registerName("sharedInstance"));
            if (!ctrl) { UKLog(@"home: sharedInstance nil"); return; }
            SEL sel = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:withSourceType:");
            if (![ctrl respondsToSelector:sel]) { UKLog(@"home: selector missing"); return; }
            id app = SafeMsgObj(objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
            id keyWin = SafeMsgObj(app, NSSelectorFromString(@"_keyWindow"));
            if (!keyWin) keyWin = SafeMsgObj(app, sel_registerName("keyWindow"));
            id scene = SafeMsgObj(keyWin, sel_registerName("windowScene"));
            if (scene) UKLog(@"home: scene via keyWindow");
            if (!scene) {
                id scenes = SafeMsgObj(app, sel_registerName("connectedScenes"));
                if ([scenes isKindOfClass:[NSSet class]]) {
                    for (id s in scenes) {
                        @try {
                            SEL st = sel_registerName("activationState");
                            if ([s respondsToSelector:st] && (((NSInteger(*)(id, SEL))objc_msgSend)(s, st)) == 0) { scene = s; break; }
                        } @catch (NSException *e) { }
                    }
                    if (!scene) scene = [scenes anyObject];
                    if (scene) UKLog(@"home: scene via connectedScenes");
                }
            }
            if (!scene) {
                Class mw = objc_getClass("SBMainWorkspace");
                id ws = SafeMsgObj(mw, sel_registerName("sharedInstance"));
                if (ws) {
                    scene = SafeMsgObj(ws, NSSelectorFromString(@"_mainScene"));
                    if (!scene) scene = SafeMsgObj(ws, NSSelectorFromString(@"mainScene"));
                    if (scene) UKLog(@"home: scene via SBMainWorkspace");
                }
            }
            if (scene) {
                UKLog(@"home: dispatching press");
                ((void(*)(id, SEL, id, id))objc_msgSend)(ctrl, sel, scene, nil);
                UKLog(@"home: press done");
            } else {
                UKLog(@"home: trying nil-scene call");
                ((void(*)(id, SEL, id, id))objc_msgSend)(ctrl, sel, nil, nil);
                UKLog(@"home: nil-scene call done");
            }
            return;
        }
        if ([action caseInsensitiveCompare:@"volup"] == NSOrderedSame || [action caseInsensitiveCompare:@"voldown"] == NSOrderedSame) {
            // 模拟系统音量键（实测 103=音量减，102=音量加）
            long vtype = ([action caseInsensitiveCompare:@"volup"] == NSOrderedSame) ? 102 : 103;
            Class c = objc_getClass("SBUIController");
            id ctrl = SafeMsgObj(c, sel_registerName("sharedInstance"));
            SEL sel = NSSelectorFromString(@"handleVolumeButtonWithType:down:");
            if (ctrl && [ctrl respondsToSelector:sel]) {
                UKLog([NSString stringWithFormat:@"vol: simulating key %ld", vtype]);
                ((void(*)(id, SEL, long long, BOOL))objc_msgSend)(ctrl, sel, (long long)vtype, YES);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try {
                        ((void(*)(id, SEL, long long, BOOL))objc_msgSend)(ctrl, sel, (long long)vtype, NO);
                    } @catch (NSException *e) { }
                });
                return;
            }
            Class avc = objc_getClass("AVSystemController");
            id svc = SafeMsgObj(avc, sel_registerName("sharedAVSystemController"));
            SEL chgSel = NSSelectorFromString(@"changeVolumeBy:forCategory:");
            if (svc && [svc respondsToSelector:chgSel]) {
                float delta = ([action caseInsensitiveCompare:@"volup"] == NSOrderedSame) ? 0.0625f : -0.0625f;
                UKLog(@"vol: changeVolumeBy fallback");
                ((int(*)(id, SEL, float, id))objc_msgSend)(svc, chgSel, delta, @"Audio/Video");
            } else {
                UKLog(@"vol: no path available");
            }
            return;
        }
        if ([action length] > 9 && [[action substringToIndex:9] caseInsensitiveCompare:@"shortcut:"] == NSOrderedSame) {
            NSString *name = [action substringFromIndex:9];
            if (name.length == 0) return;
            NSString *enc = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"shortcuts://run-shortcut?name=%@", enc]];
            if (!u) return;
            id app = SafeMsgObj(objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
            SEL openSel = NSSelectorFromString(@"openURL:options:completionHandler:");
            if (app && [app respondsToSelector:openSel]) {
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(app, openSel, u, @{}, nil);
            }
            return;
        }
        UKLog([NSString stringWithFormat:@"  !! unknown action: %@ (available: home/volup/voldown/shortcut:name)", action]);
    } @catch (NSException *e) {
        UKLog(@"action exception caught");
    }
}

static void DispatchAction(NSString *action) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RunAction(action);
    });
}

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        if (event.type == 4) {
            NSDictionary *cfg = LoadConfig();
            id presses = SafeMsgObj(event, sel_registerName("allPresses"));
            if ([presses isKindOfClass:[NSSet class]]) {
                for (id press in presses) {
                    @try {
                        long ptype = SafeMsgInt(press, sel_registerName("type"));
                        long pphase = SafeMsgInt(press, sel_registerName("phase"));
                        if (ptype > 0 && pphase == 0) {
                            static long lastType = 0;
                            static CFTimeInterval lastTime = 0;
                            CFTimeInterval now = CACurrentMediaTime();
                            if (ptype == lastType && (now - lastTime) < 0.2) {
                                %orig;
                                return;
                            }
                            lastType = ptype; lastTime = now;
                            NSString *action = cfg.count ? [cfg objectForKey:@(ptype)] : nil;
                            if (action) {
                                UKLog([NSString stringWithFormat:@"remap %ld -> %@", (long)ptype, action]);
                                DispatchAction(action);
                                return; // 吞掉事件
                            } else {
                                UKLog([NSString stringWithFormat:@"key %ld (unbound)", (long)ptype]);
                            }
                        }
                    } @catch (NSException *e) { }
                }
            }
        }
    } @catch (NSException *e) { }
    %orig;
}

%end

static void TriggerCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                NSString *action = [NSString stringWithContentsOfFile:@"/var/mobile/unikey_trigger.txt"
                                                             encoding:NSUTF8StringEncoding error:nil];
                action = [action stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (action.length) {
                    UKLog([NSString stringWithFormat:@"app trigger: %@", action]);
                    RunAction(action);
                }
            } @catch (NSException *e) { }
        });
    } @catch (NSException *e) { }
}

%ctor {
    %init;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    UKLog(@"unikey 2.0 loaded (SB side)");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, TriggerCallback,
                                    CFSTR("com.user.unikey.run"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    // App白名单自生成（每次注销刷新，无需外部工具）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSMutableString *xml = [NSMutableString string];
            [xml appendString:@"{ Filter = { Bundles = (\n"];
            NSFileManager *fm = [NSFileManager defaultManager];
            int count = 0;
            NSArray *bases = @[@"/var/containers/Bundle/Application", @"/var/staged_system_apps", @"/var/jb/Applications"];
            for (NSString *base in bases) {
                for (NSString *uuid in [fm contentsOfDirectoryAtPath:base error:nil]) {
                    NSString *dir = [base stringByAppendingPathComponent:uuid];
                    BOOL isDir = NO;
                    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
                    NSString *appPath = nil;
                    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                        if ([item hasSuffix:@".app"]) { appPath = [dir stringByAppendingPathComponent:item]; break; }
                    }
                    if (!appPath) continue;
                    @try {
                        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
                        NSString *bid = info[@"CFBundleIdentifier"];
                        if (bid.length > 0 && [bid containsString:@"."] && ![bid isEqualToString:@"com.apple.springboard"]) {
                            [xml appendFormat:@"\"%@\",\n", bid];
                            count++;
                        }
                    } @catch (NSException *e) { }
                }
            }
            [xml appendString:@"); } }"];
            NSError *werr = nil;
            BOOL ok = [xml writeToFile:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/UniKeyApp.plist"
                            atomically:YES encoding:NSUTF8StringEncoding error:&werr];
            UKLog([NSString stringWithFormat:@"whitelist write: ok=%d err=%@", ok, werr ? werr.localizedDescription : @"none"]);
            UKLog([NSString stringWithFormat:@"app whitelist generated: %d bundles", count]);
            UKLog([NSString stringWithFormat:@"whitelist ids: %@", [[xml componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "]]);
        } @catch (NSException *e) {
            UKLog(@"whitelist generation exception");
        }
    });
}
