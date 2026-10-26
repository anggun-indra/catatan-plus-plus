#import <Cocoa/Cocoa.h>
#import "Sidebar.h"

@protocol FindInFilesDelegate <NSObject>
- (void)findInFilesDidProduceResults:(NSArray<SidebarItem *> *)results query:(NSString *)query directory:(NSString *)dir;
@end

@interface FindInFilesEngine : NSObject
+ (NSArray<SidebarItem *> *)searchForString:(NSString *)query
                                inDirectory:(NSString *)dir
                                     filter:(NSString *)filter
                                  matchCase:(BOOL)matchCase
                                  wholeWord:(BOOL)wholeWord
                                    subdirs:(BOOL)subdirs;
@end

@interface FindInFilesWindowController : NSWindowController
@property (nonatomic, weak) id<FindInFilesDelegate> delegate;
@property (nonatomic, copy) NSString *defaultDirectory;
- (void)showFindInFiles;
@end
