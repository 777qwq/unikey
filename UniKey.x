#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>

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
            id ctrl = SafeMsgObj(c, sel_registerName("sharedInstance"));
            SEL sel = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:withSourceType:");
            if (ctrl && [ctrl respondsToSelector:sel]) {
                id scenes = SafeMsgObj(objc_getClass("UIApplication"), sel_registerName("connectedScenes"));
                id scene = nil;
                if ([scenes isKindOfClass:[NSSet class]]) scene = [scenes anyObject];
                if (scene) ((void(*)(id, SEL, id, id))objc_msgSend)(ctrl, sel, scene, nil);
            }
            return;
        }
        if ([action isEqualToString:@"volup"] || [action isEqualToString:@"voldown"]) {
            Class avc = objc_getClass("AVSystemController");
            id svc = SafeMsgObj(avc, sel_registerName("sharedAVSystemController"));
            if (!svc) return;
            SEL getSel = NSSelectorFromString(@"getVolumeForCategory:volume:");
            SEL setSel = NSSelectorFromString(@"setVolumeTo:forCategory:");
            if (![svc respondsToSelector:getSel] || ![svc respondsToSelector:setSel]) return;
            float vol = 0;
            Method gm = class_getInstanceMethod(object_getClass(svc), getSel);
            const char *ge = gm ? method_getTypeEncoding(gm) : "";
            // getVolumeForCategory:volume: 第二参为 float* 指针出参
            if (ge && ge[0]=='v') {
                ((void(*)(id, SEL, id, float*))objc_msgSend)(svc, getSel, @"Audio/Video", &vol);
            }
            float nv = vol + ([action isEqualToString:@"volup"] ? 6.25f : -6.25f);
            if (nv < 0) nv = 0; if (nv > 100) nv = 100;
            ((int(*)(id, SEL, float, id))objc_msgSend)(svc, setSel, nv, @"Audio/Video");
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
    UKLog(@"unikey 0.4 loaded (remap engine)");
}
