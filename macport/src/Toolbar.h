#import <Cocoa/Cocoa.h>

// Toolbar buttons mirror Notepad++'s toolBarIcons[] table in Notepad_Plus.cpp:
// same order, same grouping (separators included), same commands.
typedef NS_ENUM(NSInteger, ToolbarItemKind) {
    ToolbarItemKindButton,
    ToolbarItemKindToggle,
    ToolbarItemKindSeparator,
};

@class ToolbarView;

@protocol ToolbarViewDelegate <NSObject>
- (void)toolbar:(ToolbarView *)toolbar didActivateItemAtIndex:(NSInteger)index;
// A toggle's current state, queried from the active document.
- (BOOL)toolbar:(ToolbarView *)toolbar isItemToggledAtIndex:(NSInteger)index;
// Whether the command can run right now (e.g. nothing to paste).
- (BOOL)toolbar:(ToolbarView *)toolbar isItemEnabledAtIndex:(NSInteger)index;
@end

@interface ToolbarView : NSView
@property (nonatomic, weak) id<ToolbarViewDelegate> toolbarDelegate;
@property (nonatomic, copy) NSString *resourceDirectory;
- (void)refresh;

- (NSInteger)itemCount;
- (NSString *)commandAtIndex:(NSInteger)index;
- (ToolbarItemKind)kindAtIndex:(NSInteger)index;
- (NSInteger)indexOfCommand:(NSString *)command;
- (NSRect)buttonRectAtIndex:(NSInteger)index;
- (NSInteger)indexAtPoint:(NSPoint)point;
@end
