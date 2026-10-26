#import "AutoUpdater.h"
#import <sys/stat.h>

@interface AutoUpdater ()
@property (nonatomic, assign) AutoUpdateStatus status;
@property (nonatomic, copy) NSString *latestVersion;
@property (nonatomic, copy) NSString *releaseNotes;
@property (nonatomic, copy) NSString *downloadURL;
@property (nonatomic, copy) NSString *stagedAppPath;
@property (nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@end

@implementation AutoUpdater

+ (instancetype)sharedUpdater {
    static AutoUpdater *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[AutoUpdater alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = AutoUpdateStatusIdle;
        _repoOwner = @"anggun-indra";
        _repoName = @"catatan-plus-plus";
    }
    return self;
}

+ (NSComparisonResult)compareVersion:(NSString *)vA toVersion:(NSString *)vB {
    if (!vA) vA = @"0";
    if (!vB) vB = @"0";
    if ([vA hasPrefix:@"v"] || [vA hasPrefix:@"V"]) vA = [vA substringFromIndex:1];
    if ([vB hasPrefix:@"v"] || [vB hasPrefix:@"V"]) vB = [vB substringFromIndex:1];

    NSArray *compA = [vA componentsSeparatedByString:@"."];
    NSArray *compB = [vB componentsSeparatedByString:@"."];
    NSUInteger maxLen = MAX(compA.count, compB.count);

    for (NSUInteger i = 0; i < maxLen; i++) {
        NSInteger numA = i < compA.count ? [compA[i] integerValue] : 0;
        NSInteger numB = i < compB.count ? [compB[i] integerValue] : 0;
        if (numA > numB) return NSOrderedDescending;
        if (numA < numB) return NSOrderedAscending;
    }
    return NSOrderedSame;
}

- (NSString *)currentAppVersion {
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return ver.length > 0 ? ver : @"1.0.0";
}

- (void)checkForUpdatesManual:(BOOL)isManual {
    if (self.status == AutoUpdateStatusChecking || self.status == AutoUpdateStatusDownloading) {
        if (isManual) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Update in Progress";
            alert.informativeText = @"Catatan++ is currently checking for or downloading an update.";
            [alert runModal];
        }
        return;
    }

    if (self.status == AutoUpdateStatusReadyToInstall) {
        if (isManual) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = [NSString stringWithFormat:@"Catatan++ v%@ is Ready to Install", self.latestVersion];
            alert.informativeText = @"The update has already been downloaded in the background. Would you like to restart Catatan++ now to apply the update?";
            [alert addButtonWithTitle:@"Restart to Update"];
            [alert addButtonWithTitle:@"Later"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [self relaunchAndInstallUpdate];
            }
        }
        return;
    }

    self.status = AutoUpdateStatusChecking;
    if ([self.delegate respondsToSelector:@selector(autoUpdater:didChangeStatus:)]) {
        [self.delegate autoUpdater:self didChangeStatus:self.status];
    }

    NSString *apiURLStr = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
                           self.repoOwner, self.repoName];
    NSURL *url = [NSURL URLWithString:apiURLStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"application/vnd.github.v3+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"CatatanPlusPlus/1.0 (Macintosh; Apple Silicon)" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 12.0;

    __weak AutoUpdater *weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleReleaseResponse:data response:response error:error manual:isManual];
            });
        }];
    [task resume];
}

- (void)handleReleaseResponse:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error manual:(BOOL)isManual {
    NSHTTPURLResponse *httpRes = (NSHTTPURLResponse *)response;
    if (error || (httpRes && httpRes.statusCode != 200) || !data) {
        self.status = AutoUpdateStatusError;
        if ([self.delegate respondsToSelector:@selector(autoUpdater:didChangeStatus:)]) {
            [self.delegate autoUpdater:self didChangeStatus:self.status];
        }
        if (isManual) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Check for Updates Failed";
            NSString *msg = error ? error.localizedDescription : [NSString stringWithFormat:@"Server returned HTTP %ld", (long)httpRes.statusCode];
            alert.informativeText = [NSString stringWithFormat:@"Could not fetch latest release info from GitHub (%@). Please check your internet connection.", msg];
            [alert runModal];
        }
        return;
    }

    NSError *jsonErr = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (!json || ![json isKindOfClass:[NSDictionary class]]) {
        self.status = AutoUpdateStatusError;
        if (isManual) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Invalid Release Data";
            alert.informativeText = @"Received invalid response from update server.";
            [alert runModal];
        }
        return;
    }

    NSString *tag = json[@"tag_name"] ?: @"";
    NSString *cleanTag = tag;
    if ([cleanTag hasPrefix:@"v"] || [cleanTag hasPrefix:@"V"]) {
        cleanTag = [cleanTag substringFromIndex:1];
    }
    self.latestVersion = cleanTag;
    self.releaseNotes = json[@"body"] ?: @"";

    // Find downloadable zip asset (e.g. Catatan++-vX.X.X-macOS-arm64.zip)
    NSString *foundURL = nil;
    NSArray *assets = json[@"assets"];
    if ([assets isKindOfClass:[NSArray class]]) {
        for (NSDictionary *asset in assets) {
            NSString *name = asset[@"name"];
            if ([name hasSuffix:@"-macOS-arm64.zip"] || [name hasSuffix:@".zip"]) {
                foundURL = asset[@"browser_download_url"];
                break;
            }
        }
    }
    self.downloadURL = foundURL;

    NSString *curVersion = [self currentAppVersion];
    NSComparisonResult comp = [AutoUpdater compareVersion:self.latestVersion toVersion:curVersion];

    if (comp == NSOrderedDescending && self.downloadURL.length > 0) {
        // Newer version is available!
        self.status = AutoUpdateStatusAvailable;
        if ([self.delegate respondsToSelector:@selector(autoUpdater:didChangeStatus:)]) {
            [self.delegate autoUpdater:self didChangeStatus:self.status];
        }
        if ([self.delegate respondsToSelector:@selector(autoUpdater:didFindUpdateWithVersion:notes:)]) {
            [self.delegate autoUpdater:self didFindUpdateWithVersion:self.latestVersion notes:self.releaseNotes];
        }

        if (isManual) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = [NSString stringWithFormat:@"Catatan++ v%@ is Available!", self.latestVersion];
            alert.informativeText = [NSString stringWithFormat:@"You are currently using Catatan++ v%@.\n\nRelease Notes:\n%@",
                                     curVersion, self.releaseNotes.length > 0 ? self.releaseNotes : @"Performance improvements and bug fixes."];
            [alert addButtonWithTitle:@"Download & Install"];
            [alert addButtonWithTitle:@"Remind Me Later"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [self startBackgroundDownload];
            }
        } else {
            // Background check: start silent background download automatically (like VS Code/Antigravity)
            [self startBackgroundDownload];
        }
    } else {
        self.status = AutoUpdateStatusUpToDate;
        if ([self.delegate respondsToSelector:@selector(autoUpdater:didChangeStatus:)]) {
            [self.delegate autoUpdater:self didChangeStatus:self.status];
        }
        if (isManual) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"You're Up to Date!";
            alert.informativeText = [NSString stringWithFormat:@"Catatan++ v%@ is currently the newest version available.", curVersion];
            [alert runModal];
        }
    }
}

- (void)startBackgroundDownload {
    if (!self.downloadURL || self.status == AutoUpdateStatusDownloading || self.status == AutoUpdateStatusReadyToInstall) {
        return;
    }

    self.status = AutoUpdateStatusDownloading;
    if ([self.delegate respondsToSelector:@selector(autoUpdater:didChangeStatus:)]) {
        [self.delegate autoUpdater:self didChangeStatus:self.status];
    }

    NSURL *url = [NSURL URLWithString:self.downloadURL];
    __weak AutoUpdater *weakSelf = self;
    self.downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleDownloadFinished:location response:response error:error];
            });
        }];
    [self.downloadTask resume];
}

- (void)handleDownloadFinished:(NSURL *)tempLocation response:(NSURLResponse *)response error:(NSError *)error {
    if (error || !tempLocation) {
        self.status = AutoUpdateStatusError;
        if ([self.delegate respondsToSelector:@selector(autoUpdater:didChangeStatus:)]) {
            [self.delegate autoUpdater:self didChangeStatus:self.status];
        }
        return;
    }

    // Move downloaded zip to cache
    NSString *cacheDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"CatatanUpdate"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *zipTarget = [cacheDir stringByAppendingPathComponent:@"latest_update.zip"];
    [[NSFileManager defaultManager] removeItemAtPath:zipTarget error:NULL];
    [[NSFileManager defaultManager] moveItemAtPath:tempLocation.path toPath:zipTarget error:NULL];

    // Extract zip using ditto
    NSString *stagedDir = [cacheDir stringByAppendingPathComponent:@"staged"];
    [[NSFileManager defaultManager] removeItemAtPath:stagedDir error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:stagedDir withIntermediateDirectories:YES attributes:nil error:NULL];

    NSTask *extractTask = [[NSTask alloc] init];
    extractTask.launchPath = @"/usr/bin/ditto";
    extractTask.arguments = @[@"-x", @"-k", zipTarget, stagedDir];
    [extractTask launch];
    [extractTask waitUntilExit];

    NSString *extractedApp = [stagedDir stringByAppendingPathComponent:@"Catatan++.app"];
    NSString *binary = [extractedApp stringByAppendingPathComponent:@"Contents/MacOS/Catatan++"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:binary]) {
        // Maybe extracted directly inside without container
        NSArray *subpaths = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:stagedDir error:NULL];
        for (NSString *sub in subpaths) {
            if ([sub hasSuffix:@".app"]) {
                extractedApp = [stagedDir stringByAppendingPathComponent:sub];
                binary = [extractedApp stringByAppendingPathComponent:@"Contents/MacOS/Catatan++"];
                break;
            }
        }
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:binary]) {
        self.stagedAppPath = extractedApp;
        self.status = AutoUpdateStatusReadyToInstall;
        if ([self.delegate respondsToSelector:@selector(autoUpdater:didChangeStatus:)]) {
            [self.delegate autoUpdater:self didChangeStatus:self.status];
        }
        if ([self.delegate respondsToSelector:@selector(autoUpdaterDidBecomeReadyToInstall:)]) {
            [self.delegate autoUpdaterDidBecomeReadyToInstall:self];
        }
    } else {
        self.status = AutoUpdateStatusError;
        if ([self.delegate respondsToSelector:@selector(autoUpdater:didChangeStatus:)]) {
            [self.delegate autoUpdater:self didChangeStatus:self.status];
        }
    }
}

- (BOOL)relaunchAndInstallUpdate {
    if (!self.stagedAppPath || ![[NSFileManager defaultManager] fileExistsAtPath:self.stagedAppPath]) {
        return NO;
    }

    NSString *currentBundle = [[NSBundle mainBundle] bundlePath];
    if (!currentBundle || currentBundle.length == 0) return NO;

    // Check if writable
    NSString *parentDir = [currentBundle stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] isWritableFileAtPath:parentDir]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Cannot Update In-Place";
        alert.informativeText = [NSString stringWithFormat:@"Catatan++ is located in a read-only directory:\n%@\n\nPlease move Catatan++.app to your /Applications folder to allow seamless auto-updates.", currentBundle];
        [alert addButtonWithTitle:@"Open /Applications"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [[NSWorkspace sharedWorkspace] openFile:@"/Applications"];
        }
        return NO;
    }

    // Write atomic helper swap script
    NSString *scriptPath = @"/tmp/catatan_apply_update.sh";
    NSString *script = [NSString stringWithFormat:
        @"#!/bin/bash\n"
        @"PID=\"$1\"\n"
        @"TARGET=\"$2\"\n"
        @"SOURCE=\"$3\"\n"
        @"\n"
        @"# Wait for running app to exit (up to 10s)\n"
        @"for i in {1..100}; do\n"
        @"  if ! kill -0 \"$PID\" 2>/dev/null; then break; fi\n"
        @"  sleep 0.1\n"
        @"done\n"
        @"\n"
        @"# Atomic swap bundle\n"
        @"if [ -d \"$SOURCE\" ] && [ -n \"$TARGET\" ]; then\n"
        @"  rm -rf \"$TARGET.old\" 2>/dev/null || true\n"
        @"  mv \"$TARGET\" \"$TARGET.old\" 2>/dev/null || rm -rf \"$TARGET\"\n"
        @"  cp -R \"$SOURCE\" \"$TARGET\"\n"
        @"  rm -rf \"$TARGET.old\" 2>/dev/null || true\n"
        @"  rm -rf \"$SOURCE\" 2>/dev/null || true\n"
        @"  xattr -dr com.apple.quarantine \"$TARGET\" 2>/dev/null || true\n"
        @"  open -n \"$TARGET\"\n"
        @"fi\n"
    ];

    NSError *err = nil;
    [script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) return NO;

    chmod([scriptPath UTF8String], 0755);

    // Detach update runner process
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/bash";
    task.arguments = @[scriptPath, [NSString stringWithFormat:@"%d", getpid()], currentBundle, self.stagedAppPath];
    [task launch];

    // Terminate current app to let helper swap and relaunch
    [NSApp terminate:nil];
    return YES;
}

@end
