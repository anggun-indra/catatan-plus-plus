#import <Cocoa/Cocoa.h>

@interface SidebarItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *path;   // file path for workspace/opening
@property (nonatomic) NSInteger line;         // 1-based, -1 when not a location
@property (nonatomic) BOOL isDirectory;
@property (nonatomic, strong) NSArray<SidebarItem *> *children;
+ (instancetype)itemWithTitle:(NSString *)title;
+ (instancetype)itemWithTitle:(NSString *)title detail:(NSString *)detail line:(NSInteger)line;
@end

@protocol SidebarViewDelegate <NSObject>
- (void)sidebar:(id)sidebar didChooseItem:(SidebarItem *)item;
- (void)sidebarDidRequestClose:(id)sidebar;
@end

// A docked panel: title bar with a close button plus an outline list.
@interface SidebarView : NSView
@property (nonatomic, weak) id<SidebarViewDelegate> sidebarDelegate;
@property (nonatomic, readonly) NSString *panelTitle;
- (void)setPanelTitle:(NSString *)title items:(NSArray<SidebarItem *> *)items;
- (NSArray<SidebarItem *> *)items;
@end
