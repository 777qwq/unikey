#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static void UKLog(NSString *msg) {
    @try {
        FILE *f = fopen("/var/mobile/unikey.log", "a");
        if (!f) return;
        time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
        fprintf(f, "[UK %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
        fclose(f);
    } @catch (NSException *e) { }
}

static void ClassRecon(void) {
    @try {
        FILE *f = fopen("/var/mobile/unikey_recon.log", "w");
        if (!f) return;
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            const char *nm = class_getName(classes[i]);
            if (!nm) continue;
            if (strstr(nm, "HardwareKey") || strstr(nm, "KeyCommand") ||
                (strstr(nm, "Keyboard") && !strstr(nm, "KB"))) {
                fprintf(f, "=== %s\n", nm);
                unsigned int mcount = 0;
                Method *methods = class_copyMethodList(classes[i], &mcount);
                for (unsigned int j = 0; j < mcount && j < 40; j++)
                    fprintf(f, "    - %s\n", sel_getName(method_getName(methods[j])));
                if (methods) free(methods);
            }
        }
        free(classes);
        fclose(f);
        UKLog(@"class recon done");
    } @catch (NSException *e) { }
}

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        UIEventType type = event.type;
        // 只关注非触摸事件（键盘/按键/HID）
        if (type != UIEventTypeTouches) {
            NSString *desc = [event description];
            if (desc.length > 500) desc = [desc substringToIndex:500];
            UKLog([NSString stringWithFormat:@"type=%ld subtype=%ld desc=%@",
                  (long)type, (long)event.subtype, desc]);
        }
    } @catch (NSException *e) { }
    %orig;
}

%end

%ctor {
    %init;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    UKLog(@"unikey 0.1 loaded (recon)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ClassRecon();
    });
}
