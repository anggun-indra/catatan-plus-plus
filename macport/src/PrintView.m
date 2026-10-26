#import "PrintView.h"
#import "ScintillaView.h"
#include "ILexer.h"
#include "Scintilla.h"

static NSString *const kPrintFontName = @"Menlo";
static const CGFloat kPrintFontSize = 9.0;
static const CGFloat kPrintLineHeight = 12.0;
static const CGFloat kSideMargin = 54.0;   // ~19mm at 72dpi
static const CGFloat kTopMargin = 54.0;
static const CGFloat kBottomMargin = 48.0;

@interface PrintTextView ()
@property (nonatomic, strong) ScintillaView *editor;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSArray<NSString *> *lines;
@property (nonatomic) NSRange pageRange;
@property (nonatomic, assign) CGFloat usableHeight;
@end

@implementation PrintTextView

+ (NSArray<NSString *> *)linesForText:(NSString *)text {
    if (text.length == 0) return @[@""];
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *lines = [normalized componentsSeparatedByString:@"\n"];
    // A trailing newline produces an empty last element; keep it so line numbers
    // still match the editor, but do not paginate an entirely blank final page.
    if (lines.count > 1 && [[lines lastObject] length] == 0)
        lines = [lines subarrayWithRange:NSMakeRange(0, lines.count - 1)];
    return lines;
}

+ (NSInteger)linesPerPageForHeight:(CGFloat)height {
    CGFloat usable = height - kTopMargin - kBottomMargin;
    if (usable < kPrintLineHeight) return 1;
    return (NSInteger)floor(usable / kPrintLineHeight);
}

+ (NSInteger)pageCountForText:(NSString *)text width:(CGFloat)width height:(CGFloat)height {
    NSInteger perPage = [self linesPerPageForHeight:height];
    NSArray<NSString *> *lines = [self linesForText:text];
    return MAX(1, (NSInteger)ceil((double)lines.count / (double)perPage));
}

- (instancetype)initWithEditor:(ScintillaView *)editor
                          text:(NSString *)text
                     pageRange:(NSRange)pageRange {
    self = [super initWithFrame:NSMakeRect(0, 0, 595, 842)];
    if (!self) return nil;
    _editor = editor;
    _text = [text copy];
    _lines = [[self class] linesForText:text];
    _pageRange = pageRange;
    // Page count depends on the paper size, which is only known once the print
    // operation is set up; recompute lazily instead of assuming a size here.
    self.pageCount = 0;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSInteger)pageCount {
    if (self->_pageCount > 0) return self->_pageCount;
    NSSize paper = [self printPaperSize];
    return [[self class] pageCountForText:self.text width:paper.width height:paper.height];
}

- (BOOL)knowsPageRange:(NSRangePointer)range {
    range->location = 1;
    range->length = MAX(1, self.pageCount);
    return YES;
}

- (NSRect)rectForPage:(NSInteger)page {
    // AppKit asks for each page's rect; derive it from the actual paper size so
    // the view never reports zero area (which draws nothing at all).
    NSSize paper = self.printPaperSize;
    if (paper.width <= 0 || paper.height <= 0) paper = NSMakeSize(595, 842);
    return NSMakeRect(0, 0, paper.width, paper.height);
}

- (NSSize)printPaperSize {
    NSPrintInfo *info = [NSPrintOperation currentOperation].printInfo;
    NSSize size = info ? info.paperSize : NSMakeSize(595, 842);
    if (size.width <= 0 || size.height <= 0) size = NSMakeSize(595, 842);
    return size;
}

// Vertical offset of the first line of a given page.
- (NSInteger)firstLineForPage:(NSInteger)page pageHeight:(CGFloat)height {
    NSInteger perPage = [[self class] linesPerPageForHeight:height];
    return (page - 1) * perPage;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSSize paper = NSWidth(self.bounds) > 1 ? self.bounds.size : [self printPaperSize];
    if (paper.width <= 1 || paper.height <= 1) paper = [self printPaperSize];

    // Paper. Without this the page inherits whatever context it is drawn into,
    // which renders as a solid black sheet in a bitmap context.
    [[NSColor whiteColor] setFill];
    NSRectFill(NSMakeRect(0, 0, paper.width, paper.height));
    NSInteger page = (NSInteger)self.pageRange.location;
    if (page < 1) page = 1;

    NSInteger perPage = [[self class] linesPerPageForHeight:paper.height];
    NSInteger first = (page - 1) * perPage;
    if (first >= (NSInteger)self.lines.count) return;

    NSFont *baseFont = [NSFont fontWithName:kPrintFontName size:kPrintFontSize]
                       ?: [NSFont userFixedPitchFontOfSize:kPrintFontSize];
    NSDictionary *defaultAttrs = @{
        NSFontAttributeName: baseFont,
        NSForegroundColorAttributeName: [NSColor blackColor],
    };

    NSMutableDictionary<NSNumber *, NSDictionary *> *styleCache = [NSMutableDictionary dictionary];
    long sciLength = self.editor ? [self.editor getGeneralProperty:SCI_GETLENGTH parameter:0] : 0;

    CGFloat y = kTopMargin;
    NSInteger last = MIN((NSInteger)self.lines.count, first + perPage);
    for (NSInteger i = first; i < last; i++) {
        NSString *line = self.lines[i];
        if (line.length == 0) {
            y += kPrintLineHeight;
            continue;
        }

        NSAttributedString *drawString = nil;
        long lineStartPos = self.editor ? [self.editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:i] : -1;

        if (self.editor && lineStartPos >= 0 && lineStartPos < sciLength) {
            NSMutableAttributedString *attrLine = [[NSMutableAttributedString alloc] initWithString:line attributes:defaultAttrs];
            NSUInteger strCharIndex = 0;
            NSUInteger byteOffset = 0;
            NSData *lineUtf8Data = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSUInteger utf8Len = lineUtf8Data.length;

            while (byteOffset < utf8Len && (lineStartPos + (long)byteOffset) < sciLength && strCharIndex < line.length) {
                long pos = lineStartPos + (long)byteOffset;
                int style = (int)[self.editor getGeneralProperty:SCI_GETSTYLEAT parameter:pos];

                NSDictionary *attrs = styleCache[@(style)];
                if (!attrs) {
                    NSColor *fg = [self.editor getColorProperty:SCI_STYLEGETFORE parameter:style];
                    if (!fg) {
                        fg = [NSColor blackColor];
                    } else if (fg.brightnessComponent > 0.88) {
                        // Invert near-white colours so text is visible on white paper
                        fg = [NSColor colorWithCalibratedWhite:0.25 alpha:1.0];
                    }
                    BOOL bold = [self.editor getGeneralProperty:SCI_STYLEGETBOLD parameter:style] != 0;
                    BOOL italic = [self.editor getGeneralProperty:SCI_STYLEGETITALIC parameter:style] != 0;
                    NSFont *font = baseFont;
                    if (bold || italic) {
                        NSFontManager *fm = [NSFontManager sharedFontManager];
                        NSFontTraitMask traits = 0;
                        if (bold) traits |= NSBoldFontMask;
                        if (italic) traits |= NSItalicFontMask;
                        NSFont *styledFont = [fm convertFont:font toHaveTrait:traits];
                        if (styledFont) font = styledFont;
                    }
                    attrs = @{
                        NSFontAttributeName: font,
                        NSForegroundColorAttributeName: fg,
                    };
                    styleCache[@(style)] = attrs;
                }

                NSRange charRange = [line rangeOfComposedCharacterSequenceAtIndex:strCharIndex];
                [attrLine setAttributes:attrs range:charRange];

                NSData *charData = [[line substringWithRange:charRange] dataUsingEncoding:NSUTF8StringEncoding];
                byteOffset += charData.length;
                strCharIndex += charRange.length;
            }
            drawString = attrLine;
        } else {
            drawString = [[NSAttributedString alloc] initWithString:line attributes:defaultAttrs];
        }

        [drawString drawAtPoint:NSMakePoint(kSideMargin, y)];
        y += kPrintLineHeight;
    }

    // Page footer: "page N of M"
    NSString *footer = [NSString stringWithFormat:@"%ld / %ld",
                        (long)page, (long)MAX(1, self.pageCount)];
    NSDictionary *footerAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:8],
        NSForegroundColorAttributeName: [NSColor darkGrayColor],
    };
    NSSize size = [footer sizeWithAttributes:footerAttrs];
    [footer drawAtPoint:NSMakePoint((paper.width - size.width) / 2.0,
                                    paper.height - kBottomMargin / 2.0)
         withAttributes:footerAttrs];
}

@end
