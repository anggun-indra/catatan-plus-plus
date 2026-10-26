#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

@interface ColumnEditorController : NSWindowController
@property (nonatomic, weak) ScintillaView *targetEditor;
- (void)showColumnEditor;

+ (BOOL)applyText:(NSString *)text
         toEditor:(ScintillaView *)editor;

+ (BOOL)applyNumbersInitial:(NSInteger)initial
                       step:(NSInteger)step
                     repeat:(NSInteger)repeat
                     format:(NSString *)format
               leadingZeros:(BOOL)leadingZeros
                   toEditor:(ScintillaView *)editor;
@end
