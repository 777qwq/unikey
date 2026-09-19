#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
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
        // delay:秒,动作 —— 按下后延迟 N 秒执行（可嵌套 shortcut:/home/volup）
        if ([action length] > 6 && [[action substringToIndex:6] caseInsensitiveCompare:@"delay:"] == NSOrderedSame) {
            NSRange comma = [action rangeOfString:@","];
            if (comma.location == NSNotFound || comma.location <= 6) { UKLog(@"delay: syntax error (need delay:秒,动作)"); return; }
            NSString *secStr = [action substringWithRange:NSMakeRange(6, comma.location - 6)];
            NSString *sub = [action substringFromIndex:comma.location + 1];
            double sec = [secStr doubleValue];
            if (sec < 0.0) sec = 0.5;
            if (sec > 60.0) sec = 60.0; // 封顶一分钟，防误配
            UKLog([NSString stringWithFormat:@"delay: %@s -> %@", secStr, sub]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                RunAction(sub);
            });
            return;
        }
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

// ---- SB 侧主动 HID 订阅（v2.8.0 新增，backboardd 注入失败的 Plan B）----
// 在 SpringBoard 内创建自己的 IOHIDEventSystemClient 订阅系统键盘流，
// 不依赖 backboardd 注入；成败由 9993（创建成功）诊断码说话
typedef struct __IOHIDEvent *UKHIDEventRef;
static unsigned int (*sb_evGetType)(UKHIDEventRef);
static int (*sb_evGetInt)(UKHIDEventRef, unsigned int);
static unsigned int g_seenTypes = 0; // 每类型一次性诊断位图

static void sb_hid_cb(void *target, void *refcon, void *queue, UKHIDEventRef ev) {
    @try {
        if (!ev || !sb_evGetType || !sb_evGetInt) return;
        unsigned int t = sb_evGetType(ev);
        if (t == 11) return; // 触摸高频滤除
        if (t < 32 && !(g_seenTypes & (1u << t))) {
            g_seenTypes |= (1u << t);
            notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%lu", 3000UL + (unsigned long)t] UTF8String]);
        }
        if (t == 3) { // 键盘
            static BOOL saw = NO;
            if (!saw) { saw = YES; notify_post("com.user.unikey.key.9992"); }
            int repeat = sb_evGetInt(ev, 0x30003);
            if (repeat != 0) return;
            int down = sb_evGetInt(ev, 0x30002);
            int usage = sb_evGetInt(ev, 0x30001);
            if (down > 0 && usage > 0) notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%ld", 2000 + (long)usage] UTF8String]);
        } else if (t == 2) { // Button/手柄
            static BOOL sawB = NO;
            if (!sawB) { sawB = YES; notify_post("com.user.unikey.key.9995"); }
            int down = sb_evGetInt(ev, 0x20004);
            int btn = sb_evGetInt(ev, 0x20001);
            if (down == 1 && btn > 0) notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%ld", 2600 + (long)btn] UTF8String]);
        }
    } @catch (NSException *e) { }
}

static void UKSBHIDSetup(void) {
    @try {
        void *(*create)(void *) = (void *(*)(void *))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        void (*sched)(void *, CFRunLoopRef, CFStringRef) = (void (*)(void *, CFRunLoopRef, CFStringRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
        void (*reg)(void *, void *, void *, void *) = (void (*)(void *, void *, void *, void *))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventCallback");
        sb_evGetType = (unsigned int (*)(UKHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        sb_evGetInt = (int (*)(UKHIDEventRef, unsigned int))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
        if (!create || !sched || !reg || !sb_evGetType || !sb_evGetInt) { UKLog(@"SB HID: dlsym incomplete"); return; }
        void *client = create(NULL);
        if (!client) { UKLog(@"SB HID: client create failed (entitlement?)"); return; }
        // 2.8.1: 不再限定键盘页，订阅全部（盒子的游戏模式可能用别的 usage page）
        reg(client, sb_hid_cb, NULL, NULL);
        sched(client, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        notify_post("com.user.unikey.key.9993");
        UKLog(@"SB HID client registered");
    } @catch (NSException *e) { UKLog(@"SB HID setup exception"); }
}

static void KeyNotifyCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @try {
        NSString *nameStr = (__bridge NSString *)name;
        if (![nameStr hasPrefix:@"com.user.unikey.key."]) return;
        long code = [[nameStr substringFromIndex:20] longLongValue];
        if (code <= 0) return;
        if (code >= 3000 && code <= 3020) {
            UKLog([NSString stringWithFormat:@"diag: HID event type %ld seen", (long)code - 3000]);
            return;
        }
        if (code == 9989) { UKLog(@"diag 9989: injected into ldysdaemon!"); return; }
        if (code == 9988) { UKLog(@"diag 9988: DAEMON saw keyboard event"); return; }
        if (code >= 9990 && code <= 9999) {
            NSString *m = (code==9990) ? @"diag 9990: HID hooks installed in app"
                        : (code==9991) ? @"diag 9991: IOKit never loaded (10s timeout)"
                        : (code==9992) ? @"diag 9992: keyboard event SEEN via HID path"
                        : (code==9995) ? @"diag 9995: gamepad BUTTON events flowing"
                        : (code==9996) ? @"diag 9996: backboardd relay installed"
                        : (code==9997) ? @"diag 9997: BKB saw keyboard event"
                        : (code==9993) ? @"diag 9993: SB HID client created OK"
                        : (code==9998) ? @"diag 9998: BKB saw button event"
                        : (code==9994) ? @"diag 9994: HID callback register wrapped"
                        : nil;
            if (m) UKLog(m);
            return;
        }
        NSDictionary *cfg = LoadConfig();
        // 跨进程统一去重：backboardd 与 App 进程各发一次（各自去重互不可见）
        static long s_lastCode = 0;
        static CFTimeInterval s_lastT = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (code == s_lastCode && (now - s_lastT) < 0.25) return;
        s_lastCode = code; s_lastT = now;
        NSString *action = [cfg objectForKey:@(code)];
        if (action) {
            UKLog([NSString stringWithFormat:@"app key %ld -> %@", (long)code, action]);
            dispatch_async(dispatch_get_main_queue(), ^{
                RunAction(action);
            });
        } else {
            UKLog([NSString stringWithFormat:@"code %ld received (unbound)", (long)code]);
        }
    } @catch (NSException *e) { }
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    UKLog(@"unikey 2.8.5 loaded (SB side)");
    // 延迟创建 SB 侧 HID 客户端（构造函数延迟执行铁律）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UKSBHIDSetup();
    });
    for (int code = 2000; code <= 2600; code++) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, KeyNotifyCallback,
                                        (__bridge CFStringRef)[NSString stringWithFormat:@"com.user.unikey.key.%d", code],
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    for (int code = 9990; code <= 9999; code++) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, KeyNotifyCallback,
                                        (__bridge CFStringRef)[NSString stringWithFormat:@"com.user.unikey.key.%d", code],
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    for (int code = 3000; code <= 3020; code++) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, KeyNotifyCallback,
                                        (__bridge CFStringRef)[NSString stringWithFormat:@"com.user.unikey.key.%d", code],
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    for (int code = 2600; code <= 2680; code++) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, KeyNotifyCallback,
                                        (__bridge CFStringRef)[NSString stringWithFormat:@"com.user.unikey.key.%d", code],
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    UKLog(@"key notify observers registered (2000-2600 + 2600-2680 gamepad + diag)");
}
