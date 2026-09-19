#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#include <stdio.h>
#include <sys/stat.h>
#include <QuartzCore/QuartzCore.h>

// UniKey 2.9.0 定版（SB侧）：通知 → 动作执行。零日志、零诊断。
// 键码表 /var/mobile/unikey.conf，保存即生效
// 动作: home | volup | voldown | shortcut:名 | delay:秒,动作

static void UKLog(NSString *msg) {
    (void)msg; // 定版：日志关闭
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
        return map;
    } @catch (NSException *e) { return cached; }
}

static void RunAction(NSString *action) {
    @try {
        // delay:秒,动作 —— 按下后延迟 N 秒执行（可嵌套 shortcut:/home/volup）
        if ([action length] > 6 && [[action substringToIndex:6] caseInsensitiveCompare:@"delay:"] == NSOrderedSame) {
            NSRange comma = [action rangeOfString:@","];
            if (comma.location == NSNotFound || comma.location <= 6) return;
            NSString *secStr = [action substringWithRange:NSMakeRange(6, comma.location - 6)];
            NSString *sub = [action substringFromIndex:comma.location + 1];
            double sec = [secStr doubleValue];
            if (sec < 0.0) sec = 0.5;
            if (sec > 60.0) sec = 60.0; // 封顶一分钟，防误配
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                RunAction(sub);
            });
            return;
        }
        if ([action caseInsensitiveCompare:@"home"] == NSOrderedSame) {
            Class c = objc_getClass("SBUIController");
            if (!c) return;
            id ctrl = SafeMsgObj(c, sel_registerName("sharedInstance"));
            if (!ctrl) return;
            SEL sel = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:withSourceType:");
            if (![ctrl respondsToSelector:sel]) return;
            id app = SafeMsgObj(objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
            id keyWin = SafeMsgObj(app, NSSelectorFromString(@"_keyWindow"));
            if (!keyWin) keyWin = SafeMsgObj(app, sel_registerName("keyWindow"));
            id scene = SafeMsgObj(keyWin, sel_registerName("windowScene"));
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
                }
            }
            if (!scene) {
                Class mw = objc_getClass("SBMainWorkspace");
                id ws = SafeMsgObj(mw, sel_registerName("sharedInstance"));
                if (ws) {
                    scene = SafeMsgObj(ws, NSSelectorFromString(@"_mainScene"));
                    if (!scene) scene = SafeMsgObj(ws, NSSelectorFromString(@"mainScene"));
                }
            }
            ((void(*)(id, SEL, id, id))objc_msgSend)(ctrl, sel, scene, nil);
            return;
        }
        if ([action caseInsensitiveCompare:@"volup"] == NSOrderedSame || [action caseInsensitiveCompare:@"voldown"] == NSOrderedSame) {
            // 模拟系统音量键（实测 103=音量减，102=音量加）
            long vtype = ([action caseInsensitiveCompare:@"volup"] == NSOrderedSame) ? 102 : 103;
            Class c = objc_getClass("SBUIController");
            id ctrl = SafeMsgObj(c, sel_registerName("sharedInstance"));
            SEL sel = NSSelectorFromString(@"handleVolumeButtonWithType:down:");
            if (ctrl && [ctrl respondsToSelector:sel]) {
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
                ((int(*)(id, SEL, float, id))objc_msgSend)(svc, chgSel, delta, @"Audio/Video");
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
    } @catch (NSException *e) { }
}

static void KeyNotifyCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @try {
        NSString *nameStr = (__bridge NSString *)name;
        if (![nameStr hasPrefix:@"com.user.unikey.key."]) return;
        long code = [[nameStr substringFromIndex:20] longLongValue];
        if (code <= 0) return;
        // 跨进程统一去重（App 侧 L1/L2 可能各发一次）
        static long s_lastCode = 0;
        static CFTimeInterval s_lastT = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (code == s_lastCode && (now - s_lastT) < 0.25) return;
        s_lastCode = code; s_lastT = now;
        NSDictionary *cfg = LoadConfig();
        NSString *action = [cfg objectForKey:@(code)];
        if (action) {
            dispatch_async(dispatch_get_main_queue(), ^{
                RunAction(action);
            });
        }
    } @catch (NSException *e) { }
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    for (int code = 2000; code <= 2600; code++) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, KeyNotifyCallback,
                                        (__bridge CFStringRef)[NSString stringWithFormat:@"com.user.unikey.key.%d", code],
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
