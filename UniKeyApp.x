#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>
#include <QuartzCore/QuartzCore.h>

#define LOG_PATH "/var/mobile/unikey_app.log"
#define LOG_CAP (180*1024)

static void UKLog(NSString *msg) {
    @try {
        struct stat st;
        if (stat(LOG_PATH, &st) == 0 && st.st_size > LOG_CAP) {
            remove(LOG_PATH); // 200kB自动封顶，重新开始
        }
        FILE *f = fopen(LOG_PATH, "a");
        if (!f) return;
        time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
        fprintf(f, "[APP %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
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

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        if (event.type == 4) {
            NSDictionary *cfg = LoadConfig();
            if (cfg.count) {
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
                                NSString *action = [cfg objectForKey:@(ptype)];
                                if (action) {
                                    UKLog([NSString stringWithFormat:@"remap %ld -> %@", (long)ptype, action]);
                                    // 写触发文件 + 通知SB执行
                                    [@action writeToFile:@"/var/mobile/unikey_trigger.txt"
                                              atomically:YES encoding:NSUTF8StringEncoding error:nil];
                                    notify_post("com.user.unikey.run");
                                    return; // 吞掉事件
                                } else {
                                    static long lastUType = 0;
                                    static CFTimeInterval lastUTime = 0;
                                    if (ptype != lastUType || (now - lastUTime) >= 0.2) {
                                        lastUType = ptype; lastUTime = now;
                                        UKLog([NSString stringWithFormat:@"key %ld (unbound)", (long)ptype]);
                                    }
                                }
                            }
                        } @catch (NSException *e) { }
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
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid || [bid isEqualToString:@"com.apple.springboard"]) return;
    UKLog([NSString stringWithFormat:@"unikey app component 2.0 loaded in %@", bid]);
}
