#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>
#include <QuartzCore/QuartzCore.h>

static void UKLog(NSString *msg) {
    @try {
        FILE *f = fopen("/var/mobile/unikey.log", "a");
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

// ===== 配置：/var/mobile/unikey.conf 每行 "键码=动作" =====
// 动作: home | volup | voldown | shortcut:名字
static NSDictionary *LoadConfig(void) {
    static NSMutableDictionary *cached = nil;
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
                long kt = [key longLongValue];
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

// ===== 动作执行 =====
static void RunAction(NSString *action) {
    @try {
        if ([action isEqualToString:@"home"]) {
            Class c = objc_getClass("SBUIController");
            if (!c) { UKLog(@"home: SBUIController nil"); return; }
            id ctrl = SafeMsgObj(c, sel_registerName("sharedInstance"));
            if (!ctrl) { UKLog(@"home: sharedInstance nil"); return; }
            SEL sel = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:withSourceType:");
            if (![ctrl respondsToSelector:sel]) { UKLog(@"home: selector missing"); return; }
            id scenes = SafeMsgObj(objc_getClass("UIApplication"), sel_registerName("connectedScenes"));
            if (![scenes isKindOfClass:[NSSet class]]) { UKLog(@"home: no scenes"); return; }
            id scene = nil;
            for (id s in scenes) {
                @try {
                    SEL st = sel_registerName("activationState");
                    if ([s respondsToSelector:st] && (((NSInteger(*)(id, SEL))objc_msgSend)(s, st)) == 0) {
                        scene = s; break;
                    }
                } @catch (NSException *e) { }
            }
            if (!scene) scene = [scenes anyObject];
            if (!scene) { UKLog(@"home: no scene"); return; }
            UKLog(@"home: dispatching press");
            ((void(*)(id, SEL, id, id))objc_msgSend)(ctrl, sel, scene, nil);
            UKLog(@"home: press done");
            return;
        }
        if ([action isEqualToString:@"volup"] || [action isEqualToString:@"voldown"]) {
            // 首选：模拟系统音量键（实测 type=103=音量加，104=音量减推断）
            long vtype = [action isEqualToString:@"volup"] ? 103 : 104;
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
            // 备胎：AVSystemController 相对调整
            Class avc = objc_getClass("AVSystemController");
            id svc = SafeMsgObj(avc, sel_registerName("sharedAVSystemController"));
            SEL chgSel = NSSelectorFromString(@"changeVolumeBy:forCategory:");
            if (svc && [svc respondsToSelector:chgSel]) {
                float delta = [action isEqualToString:@"volup"] ? 0.0625f : -0.0625f;
                UKLog(@"vol: changeVolumeBy fallback");
                ((int(*)(id, SEL, float, id))objc_msgSend)(svc, chgSel, delta, @"Audio/Video");
            } else {
                UKLog(@"vol: no path available");
            }
            return;
        }
        if ([action hasPrefix:@"shortcut:"]) {
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
    } @catch (NSException *e) {
        UKLog([NSString stringWithFormat:@"action exception: %@", action]);
    }
}

static void DispatchAction(NSString *action) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RunAction(action);
    });
}

// 音量键枚举侦察：用户按实体音量键时记录 type
%hook SBUIController
- (void)handleVolumeButtonWithType:(long long)type down:(BOOL)down {
    @try {
        static CFTimeInterval lastLog = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastLog > 0.5) {
            UKLog([NSString stringWithFormat:@"real volume key: type=%lld down=%d", type, down]);
            lastLog = now;
        }
    } @catch (NSException *e) { }
    %orig;
}
%end

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        if (event.type == 4) {
            NSDictionary *cfg = LoadConfig();
            if (cfg.count) {
                id presses = SafeMsgObj(event, sel_registerName("allPresses"));
                if ([presses isKindOfClass:[NSSet class]]) {
                    for (id press in presses) {
                        long ptype = SafeMsgInt(press, sel_registerName("type"));
                        long pphase = SafeMsgInt(press, sel_registerName("phase"));
                        if (ptype > 0 && pphase == 0) {
                            NSString *action = [cfg objectForKey:@(ptype)];
                            if (action) {
                                static long lastType = 0;
                                static CFTimeInterval lastTime = 0;
                                CFTimeInterval now = CACurrentMediaTime();
                                if (ptype == lastType && (now - lastTime) < 0.2) {
                                    return; // 双投递去重
                                }
                                lastType = ptype; lastTime = now;
                                UKLog([NSString stringWithFormat:@"remap %ld -> %@", (long)ptype, action]);
                                DispatchAction(action);
                                return; // 吞掉事件
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) { }
    %orig;
}

%end

%ctor {
    %init;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    UKLog(@"unikey 0.5 loaded (remap engine)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            Class avc = objc_getClass("AVSystemController");
            if (!avc) return;
            FILE *f = fopen("/var/mobile/unikey.log", "a");
            if (!f) return;
            fprintf(f, "===== AVSystemController methods =====\n");
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(avc, &mcount);
            for (unsigned int j = 0; j < mcount; j++)
                fprintf(f, "    - %s\n", sel_getName(method_getName(methods[j])));
            if (methods) free(methods);
            fclose(f);
        } @catch (NSException *e) { }
    });
}
