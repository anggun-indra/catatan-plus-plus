#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, AutoUpdateStatus) {
    AutoUpdateStatusIdle,
    AutoUpdateStatusChecking,
    AutoUpdateStatusAvailable,
    AutoUpdateStatusDownloading,
    AutoUpdateStatusReadyToInstall,
    AutoUpdateStatusUpToDate,
    AutoUpdateStatusError
};

@class AutoUpdater;

@protocol AutoUpdaterDelegate <NSObject>
@optional
- (void)autoUpdater:(AutoUpdater *)updater didChangeStatus:(AutoUpdateStatus)status;
- (void)autoUpdater:(AutoUpdater *)updater downloadProgress:(double)progress;
- (void)autoUpdater:(AutoUpdater *)updater didFindUpdateWithVersion:(NSString *)version notes:(NSString *)notes;
- (void)autoUpdaterDidBecomeReadyToInstall:(AutoUpdater *)updater;
@end

@interface AutoUpdater : NSObject

@property (nonatomic, weak) id<AutoUpdaterDelegate> delegate;
@property (nonatomic, readonly) AutoUpdateStatus status;
@property (nonatomic, readonly, copy) NSString *latestVersion;
@property (nonatomic, readonly, copy) NSString *releaseNotes;
@property (nonatomic, readonly, copy) NSString *downloadURL;
@property (nonatomic, readonly, copy) NSString *stagedAppPath;
@property (nonatomic, copy) NSString *repoOwner;
@property (nonatomic, copy) NSString *repoName;

+ (instancetype)sharedUpdater;

// Check for updates. If isManual=YES, interactive alerts are shown.
- (void)checkForUpdatesManual:(BOOL)isManual;

// Start downloading update archive in background
- (void)startBackgroundDownload;

// Swap application bundle and relaunch into new version
- (BOOL)relaunchAndInstallUpdate;

// Helper to compare two version strings
+ (NSComparisonResult)compareVersion:(NSString *)vA toVersion:(NSString *)vB;

@end
