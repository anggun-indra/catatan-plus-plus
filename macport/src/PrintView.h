#import <Cocoa/Cocoa.h>

@class ScintillaView;

// Renders the document for the print system.
//
// Scintilla's Cocoa layer has no print support: handing ScintillaView to
// NSPrintOperation yields a blank page, because the view only draws into its
// own window-backed context. This view owns nothing and paints the text itself,
// paginating by line so long documents flow across pages.
@interface PrintTextView : NSView

- (instancetype)initWithEditor:(ScintillaView *)editor
                          text:(NSString *)text
                     pageRange:(NSRange)pageRange;

@property (nonatomic) NSInteger pageCount;   // 0 = compute lazily
+ (NSInteger)pageCountForText:(NSString *)text
                        width:(CGFloat)width
                       height:(CGFloat)height;

@end
