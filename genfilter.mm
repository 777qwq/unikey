#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#include <stdio.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        NSMutableString *xml = [NSMutableString string];
        [xml appendString:@"{ Filter = { Bundles = (\n"];
        NSFileManager *fm = [NSFileManager defaultManager];
        int count = 0;
        NSArray *bases = @[@"/var/containers/Bundle/Application",
                           @"/var/staged_system_apps",
                           @"/var/jb/Applications",
                           @"/var/staged_system_apps",
                           @"/var/jb/Applications"];
        for (NSString *base in bases) {
            for (NSString *uuid in [fm contentsOfDirectoryAtPath:base error:nil]) {
                NSString *dir = [base stringByAppendingPathComponent:uuid];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
                NSString *infoPath = nil;
                if ([dir hasSuffix:@".app"]) {
                    infoPath = [dir stringByAppendingPathComponent:@"Info.plist"];
                } else {
                    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                        if (![item hasSuffix:@".app"]) continue;
                        infoPath = [[dir stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"];
                        NSData *d = [NSData dataWithContentsOfFile:infoPath];
                        if (!d) continue;
                        @try {
                            id plist = [NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil];
                            NSString *bid = [plist objectForKey:@"CFBundleIdentifier"];
                            if (bid.length > 0 && [bid containsString:@"."]) {
                                [xml appendFormat:@"\"%@\",\n", bid];
                                count++;
                            }
                        } @catch (NSException *e) {}
                    }
                    continue;
                }
                NSData *d = [NSData dataWithContentsOfFile:infoPath];
                if (!d) continue;
                @try {
                    id plist = [NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil];
                    NSString *bid = [plist objectForKey:@"CFBundleIdentifier"];
                    if (bid.length > 0 && [bid containsString:@"."]) {
                        [xml appendFormat:@"\"%@\",\n", bid];
                        count++;
                    }
                } @catch (NSException *e) {}
            }
        }
        [xml appendString:@"); } }"];
        printf("%s", xml.UTF8String);
        printf("generated %d bundles -> %s\n", count, argv[1]);
        return 0;
        printf("generated %d bundles -> %s\n", count, argv[1]);
        return 0;
    }
}
