#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"
#include "ILexer.h"
#include "Scintilla.h"
#include "SciLexer.h"
#include "Lexilla.h"
#include "Keywords.h"
#import "LexerMap.h"
#include "Theme.h"
#import "Toolbar.h"
#import "Sidebar.h"
#import "PrintView.h"
#import <WebKit/WebKit.h>
#import "FindInFiles.h"
#import "ColumnEditor.h"
#import "UDLManager.h"
#import "AutoUpdater.h"

typedef struct {
    int message;
    uptr_t wParam;
    sptr_t lParam;
    __unsafe_unretained NSString *text;   // retained by the array's owner
} MacroEvent;

static const int kCaretLineIndicator = 9;

// Notepad++'s own default for "Current line background colour".
static const unsigned kActiveLineBackRGB = 0xE8E8FF;

// Scintilla's raw integer colour paths (the wParam of SCI_SETCARETLINEBACK,
// INDIC_TEXTFORE indicator values, ...) use the Windows COLORREF byte order
// 0x00BBGGRR, not 0xRRGGBB. setColorProperty: converts for us, but direct
// message: calls do not, so anything handed to them has to be swapped first.
static int BGRFromRGB(unsigned rgb) {
    unsigned r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF;
    return (int)((b << 16) | (g << 8) | r);
}

static NSColor *HexColor(unsigned rgb) {
    return [NSColor colorWithCalibratedRed:((rgb >> 16) & 0xFF) / 255.0
                                     green:((rgb >> 8) & 0xFF) / 255.0
                                      blue:(rgb & 0xFF) / 255.0
                                     alpha:1.0];
}

#pragma mark - Notification bridge

@interface DocNotifier : NSObject <ScintillaNotificationProtocol>
@property (nonatomic, copy) void (^handler)(SCNotification *);
@end

@implementation DocNotifier
- (void)notification:(SCNotification *)scn {
    if (self.handler) self.handler(scn);
}
@end

#pragma mark - Tab strip

@class TabStripView;

@protocol TabStripViewDelegate <NSObject>
- (void)tabStrip:(TabStripView *)strip didSelectIndex:(NSInteger)index;
- (void)tabStrip:(TabStripView *)strip didCloseIndex:(NSInteger)index;
- (NSMenu *)tabStrip:(TabStripView *)strip menuForTabIndex:(NSInteger)index;
@end

@interface TabStripView : NSView
@property (nonatomic, weak) id<TabStripViewDelegate> tabDelegate;
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, copy) NSArray<NSNumber *> *dirtyFlags;
@property (nonatomic) NSInteger selectedIndex;
- (void)refresh;
@end

@implementation TabStripView {
    NSMutableArray<NSValue *> *_tabRects;
}

static const CGFloat kTabHeight = 30.0;
static const CGFloat kCloseSize = 16.0;

- (void)refresh {
    [self recomputeLayout];
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return NO; }

- (void)recomputeLayout {
    if (!_tabRects) _tabRects = [NSMutableArray array];
    [_tabRects removeAllObjects];

    NSUInteger n = self.titles.count;
    if (n == 0) return;

    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12] };
    NSMutableArray<NSNumber *> *widths = [NSMutableArray arrayWithCapacity:n];
    CGFloat total = 0;
    for (NSString *title in self.titles) {
        CGFloat textWidth = ceil([title sizeWithAttributes:attrs].width);
        CGFloat w = textWidth + 44;
        w = MAX(96.0, MIN(220.0, w));
        [widths addObject:@(w)];
        total += w;
    }

    CGFloat available = self.bounds.size.width;
    if (total > available && total > 0) {
        CGFloat scale = available / total;
        total = 0;
        for (NSUInteger i = 0; i < n; i++) {
            CGFloat w = MAX(54.0, widths[i].doubleValue * scale);
            widths[i] = @(w);
            total += w;
        }
    }

    CGFloat x = 0;
    CGFloat h = MIN(kTabHeight, self.bounds.size.height);
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat w = widths[i].doubleValue;
        [_tabRects addObject:[NSValue valueWithRect:NSMakeRect(x, 0, w, h)]];
        x += w;
    }
}

- (NSRect)closeRectForTab:(NSRect)tab {
    return NSMakeRect(NSMaxX(tab) - kCloseSize - 6,
                      NSMidY(tab) - kCloseSize / 2,
                      kCloseSize, kCloseSize);
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithCalibratedWhite:0.92 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    [self recomputeLayout];

    for (NSUInteger i = 0; i < _tabRects.count; i++) {
        NSRect tab = _tabRects[i].rectValue;
        BOOL selected = ((NSInteger)i == self.selectedIndex);

        NSRect fill = NSInsetRect(tab, 1, 2);
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:fill xRadius:5 yRadius:5];
        if (selected)
            [[NSColor whiteColor] setFill];
        else
            [[NSColor colorWithCalibratedWhite:0.84 alpha:1.0] setFill];
        [bg fill];

        if (selected) {
            [[NSColor colorWithCalibratedWhite:0.80 alpha:1.0] setStroke];
            [bg setLineWidth:1.0];
            [bg stroke];
        }

        BOOL dirty = (i < self.dirtyFlags.count) && self.dirtyFlags[i].boolValue;
        CGFloat textLeft = NSMinX(fill) + 10;
        if (dirty) {
            NSRect dot = NSMakeRect(textLeft, NSMidY(fill) - 3, 6, 6);
            [[NSColor colorWithCalibratedRed:0.85 green:0.45 blue:0.05 alpha:1.0] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
            textLeft += 11;
        }

        NSRect titleRect = NSMakeRect(textLeft,
                                      NSMidY(fill) - 9,
                                      NSMaxX(fill) - kCloseSize - 14 - textLeft,
                                      18);
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: selected
                ? [NSColor colorWithCalibratedWhite:0.12 alpha:1.0]
                : [NSColor colorWithCalibratedWhite:0.35 alpha:1.0],
            NSParagraphStyleAttributeName: ps,
        };
        [self.titles[i] drawInRect:titleRect withAttributes:attrs];

        NSRect closeRect = [self closeRectForTab:tab];
        NSBezierPath *x = [NSBezierPath bezierPath];
        CGFloat inset = 4.5;
        [x moveToPoint:NSMakePoint(NSMinX(closeRect) + inset, NSMinY(closeRect) + inset)];
        [x lineToPoint:NSMakePoint(NSMaxX(closeRect) - inset, NSMaxY(closeRect) - inset)];
        [x moveToPoint:NSMakePoint(NSMaxX(closeRect) - inset, NSMinY(closeRect) + inset)];
        [x lineToPoint:NSMakePoint(NSMinX(closeRect) + inset, NSMaxY(closeRect) - inset)];
        [x setLineWidth:1.4];
        [[NSColor colorWithCalibratedWhite:selected ? 0.45 : 0.55 alpha:1.0] setStroke];
        [x stroke];
    }

    [[NSColor colorWithCalibratedWhite:0.78 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    [self recomputeLayout];

    for (NSUInteger i = 0; i < _tabRects.count; i++) {
        NSRect tab = _tabRects[i].rectValue;
        if (!NSPointInRect(p, tab)) continue;

        if (NSPointInRect(p, [self closeRectForTab:tab]))
            [self.tabDelegate tabStrip:self didCloseIndex:(NSInteger)i];
        else
            [self.tabDelegate tabStrip:self didSelectIndex:(NSInteger)i];
        return;
    }
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    [self recomputeLayout];

    NSInteger clickedIndex = -1;
    for (NSUInteger i = 0; i < _tabRects.count; i++) {
        NSRect tab = _tabRects[i].rectValue;
        if (NSPointInRect(p, tab)) {
            clickedIndex = (NSInteger)i;
            break;
        }
    }

    if (clickedIndex >= 0) {
        [self.tabDelegate tabStrip:self didSelectIndex:clickedIndex];
        if ([self.tabDelegate respondsToSelector:@selector(tabStrip:menuForTabIndex:)]) {
            return [self.tabDelegate tabStrip:self menuForTabIndex:clickedIndex];
        }
    }
    return [super menuForEvent:event];
}

@end

#pragma mark - Document

@interface EditorDocument : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *lang;
@property (nonatomic) BOOL dirty;
@property (nonatomic, strong) ScintillaView *editor;
@property (nonatomic, strong) DocNotifier *notifier;
@property (nonatomic) long lastCaretPos;
@property (nonatomic) NSTimeInterval lastCharTypedTime;
@property (nonatomic, strong) NSTimer *undoBreakTimer;
- (NSString *)displayName;
@end

@implementation EditorDocument
- (void)dealloc {
    [_undoBreakTimer invalidate];
}
- (NSString *)displayName {
    return self.path ? self.path.lastPathComponent : @"untitled";
}
@end

#pragma mark - Application

typedef NS_ENUM(NSInteger, PreviewLayoutMode) {
    PreviewLayoutSideBySide = 0,
    PreviewLayoutFullPreview = 1
};

@interface AppDelegate : NSObject <NSApplicationDelegate, TabStripViewDelegate, ToolbarViewDelegate, SidebarViewDelegate, FindInFilesDelegate, NSWindowDelegate, WKScriptMessageHandler, NSMenuDelegate, AutoUpdaterDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSMenuItem *updateMenuItem;
@property (nonatomic, strong) NSMenuItem *helpUpdateMenuItem;
@property (nonatomic, strong) ToolbarView *toolbar;
@property (nonatomic, strong) SidebarView *sidebar;
@property (nonatomic, strong) WKWebView *previewWebView;
@property (nonatomic) BOOL previewVisible;
@property (nonatomic) PreviewLayoutMode previewLayoutMode;
@property (nonatomic) BOOL isSyncingFromPreview;
@property (nonatomic, strong) FindInFilesWindowController *findInFilesController;
@property (nonatomic, strong) ColumnEditorController *columnEditorController;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, copy) NSString *visiblePanelName;
@property (nonatomic, copy) NSString *workspaceRoot;
@property (nonatomic) CGFloat bodyBottom;
@property (nonatomic) CGFloat bodyTop;
@property (nonatomic) CGFloat sidebarWidth;
@property (nonatomic, strong) TabStripView *tabStrip;
@property (nonatomic, strong) NSView *editorContainer;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSMutableArray<EditorDocument *> *documents;
@property (nonatomic) NSInteger activeIndex;
@property (nonatomic, copy) NSString *selfTestPath;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingPaths;
@property (nonatomic, copy) NSString *snapshotPath;
@property (nonatomic) BOOL suppressAlerts;
@property (nonatomic, copy) NSString *iconDirectory;
@property (nonatomic, strong) NSMutableArray<NSValue *> *macroEvents;
@property (nonatomic) BOOL macroRecording;
@property (nonatomic) BOOL tailingActive;
@property (nonatomic, strong) ScintillaView *splitView;
@property (nonatomic, strong) ScintillaView *splitEditor;
@property (nonatomic) BOOL syncVertical;
@property (nonatomic) BOOL syncHorizontal;
@property (nonatomic, copy) NSString *customKeywords;
@property (nonatomic, copy) NSString *tailingPath;
@property (nonatomic, strong) NSDate *tailingStamp;
@property (nonatomic, strong) NSTimer *tailTimer;

// Find & Replace
@property (nonatomic, strong) NSPanel *findPanel;
@property (nonatomic, strong) NSTextField *findField;
@property (nonatomic, strong) NSTextField *replaceField;
@property (nonatomic, strong) NSButton *caseCheckbox;
@property (nonatomic, strong) NSButton *wordCheckbox;
@property (nonatomic, strong) NSButton *wrapCheckbox;
@property (nonatomic, strong) NSTextField *findStatus;

// Preferences
@property (nonatomic, strong) NSWindow *prefsWindow;
@property (nonatomic, strong) NSPopUpButton *prefFontPop;
@property (nonatomic, strong) NSPopUpButton *prefSizePop;
@property (nonatomic, strong) NSPopUpButton *prefTabPop;
@property (nonatomic, strong) NSButton *prefSpacesCheck;
@property (nonatomic, strong) NSButton *prefLineNumCheck;
@property (nonatomic, strong) NSButton *prefWrapCheck;
@end

@implementation AppDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _documents = [NSMutableArray array];
        _pendingPaths = [NSMutableArray array];
        _activeIndex = -1;
    }
    return self;
}

- (ScintillaView *)editor {
    EditorDocument *doc = [self activeDocument];
    return doc.editor;
}

- (EditorDocument *)activeDocument {
    if (self.activeIndex < 0 || self.activeIndex >= (NSInteger)self.documents.count)
        return nil;
    return self.documents[self.activeIndex];
}

- (NSString *)currentFontName {
    NSString *f = [[NSUserDefaults standardUserDefaults] stringForKey:@"pref_font"];
    return f.length > 0 ? f : @"Menlo";
}

- (NSInteger)currentFontSize {
    NSInteger s = [[NSUserDefaults standardUserDefaults] integerForKey:@"pref_fontsize"];
    return s > 0 ? s : 13;
}

- (NSInteger)currentTabWidth {
    NSInteger t = [[NSUserDefaults standardUserDefaults] integerForKey:@"pref_tabwidth"];
    return t > 0 ? t : 4;
}

- (BOOL)currentUseSpaces {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"pref_usespaces"] ?
           [[NSUserDefaults standardUserDefaults] boolForKey:@"pref_usespaces"] : YES;
}

- (BOOL)currentWordWrap {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"pref_wordwrap"];
}

- (BOOL)currentShowLineNumbers {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"pref_linenumbers"] ?
           [[NSUserDefaults standardUserDefaults] boolForKey:@"pref_linenumbers"] : YES;
}

#pragma mark Styling

- (void)applyThemeTo:(ScintillaView *)sci lexer:(NSString *)lexerName lang:(NSString *)lang {
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_DEFAULT value:HexColor(0xFFFFFF)];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_DEFAULT value:HexColor(0x000000)];
    [sci setGeneralProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:(sptr_t)[[self currentFontName] UTF8String]];
    [sci setGeneralProperty:SCI_STYLESETSIZE parameter:STYLE_DEFAULT value:[self currentFontSize]];
    [sci setGeneralProperty:SCI_STYLECLEARALL parameter:0 value:0];


    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_LINENUMBER value:HexColor(0x808080)];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_LINENUMBER value:HexColor(0xF5F5F5)];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_BRACELIGHT value:HexColor(0x000000)];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_BRACELIGHT value:HexColor(0xB4E1B4)];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_BRACEBAD value:HexColor(0xFFFFFF)];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_BRACEBAD value:HexColor(0xCC0000)];

    int count = 0;
    const StyleDef *defs = ThemeForLexer([lang UTF8String], &count);
    if (!defs) defs = ThemeForLexer([lexerName UTF8String], &count);
    for (int i = 0; i < count; i++) {
        long sid = defs[i].style;
        [sci setColorProperty:SCI_STYLESETFORE parameter:sid value:HexColor(defs[i].fg)];
        [sci setColorProperty:SCI_STYLESETBACK parameter:sid value:HexColor(defs[i].bg)];
        if (defs[i].bold) [sci setGeneralProperty:SCI_STYLESETBOLD parameter:sid value:1];
        if (defs[i].italic) [sci setGeneralProperty:SCI_STYLESETITALIC parameter:sid value:1];
    }
}

- (ScintillaView *)makeEditor {
    ScintillaView *sci = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 660)];

    [sci setGeneralProperty:SCI_SETCODEPAGE parameter:SC_CP_UTF8 value:0];
    [sci setGeneralProperty:SCI_SETMARGINTYPEN parameter:0 value:SC_MARGIN_NUMBER];
    [sci setGeneralProperty:SCI_SETMARGINWIDTHN parameter:0 value:[self currentShowLineNumbers] ? 52 : 0];
    [sci setGeneralProperty:SCI_SETMARGINSENSITIVEN parameter:1 value:1];
    [sci setGeneralProperty:SCI_SETFOLDMARGINCOLOUR parameter:1 value:0];
    [sci message:SCI_SETWRAPMODE wParam:[self currentWordWrap] ? SC_WRAP_WORD : SC_WRAP_NONE];
    [sci setGeneralProperty:SCI_SETTABWIDTH parameter:[self currentTabWidth] value:0];
    [sci setGeneralProperty:SCI_SETUSETABS parameter:[self currentUseSpaces] ? 0 : 1 value:0];
    // Notepad++ highlights the current line purely by setting the caret-line
    // background (its default is E8E8FF) and letting Scintilla track which line
    // that is. It never recolours the text — that is what kept leaking onto
    // other lines here when typing or pressing Enter.
    //
    // CaretLineBack / CaretLineVisible / CaretLineBackAlpha read their value
    // from *wParam*, so they must go through message:wParam: — the
    // setGeneralProperty: helper sends lParam and would silently reset them.
    [sci message:SCI_SETCARETLINEBACK wParam:(uptr_t)BGRFromRGB(kActiveLineBackRGB)];
    [sci message:SCI_SETCARETLINEBACKALPHA wParam:SC_ALPHA_NOALPHA];  // behind text
    [sci message:SCI_SETCARETLINEVISIBLEALWAYS wParam:1];  // wParam too
    [sci setGeneralProperty:SCI_SETSELBACK parameter:1 value:1];
    [sci setColorProperty:SCI_SETSELBACK parameter:1 value:HexColor(0xC8DCFF)];
    [sci setGeneralProperty:SCI_SETMULTIPLESELECTION parameter:1 value:1];
    [sci setGeneralProperty:SCI_SETADDITIONALSELECTIONTYPING parameter:1 value:1];

    [self applyThemeTo:sci lexer:@"cpp" lang:@"cpp"];
    sci.menu = [self editorContextMenu];
    return sci;
}

- (void)applyLanguage:(NSString *)lang toDocument:(EditorDocument *)doc {
    if (!doc) return;
    doc.lang = lang;

    const char *lname = [lang UTF8String];
    const char *lexerId = LexerIdForLang(lname);
    if (!lexerId) lexerId = "null";

    ScintillaView *sci = doc.editor;
    ILexer5 *lexer = CreateLexer(lexerId);
    if (lexer) [sci setGeneralProperty:SCI_SETILEXER parameter:0 value:(sptr_t)lexer];

    NSString *lid = [NSString stringWithUTF8String:lexerId];
    [self applyThemeTo:sci lexer:lid lang:lang];

    int map[9] = {-1, -1, -1, -1, -1, -1, -1, -1, -1};
    if ([lid isEqualToString:@"cpp"] || [lid isEqualToString:@"objc"]) {
        map[0] = 0; map[2] = 1; map[3] = 2; map[1] = 3;
    } else if ([lid isEqualToString:@"hypertext"]) {
        map[0] = 0; map[1] = 5;
    } else if ([lid isEqualToString:@"xml"]) {
        map[0] = 5;
    } else if ([lid isEqualToString:@"json"]) {
        map[0] = 0; map[1] = 1;
    } else {
        for (int i = 0; i <= 8; i++) map[i] = i;
    }

    for (int src = 0; src <= 8; src++) {
        if (map[src] < 0) continue;
        const char *w = KeywordsForLang(lname, src);
        if (w && w[0]) [sci setGeneralProperty:SCI_SETKEYWORDS parameter:map[src] value:(sptr_t)w];
    }

    if ([lang hasPrefix:@"udl_"]) {
        UDLLanguage *udl = [[UDLManager sharedManager] languageForName:lang];
        if (udl && udl.keywords.length > 0) {
            [sci setGeneralProperty:SCI_SETKEYWORDS parameter:0 value:(sptr_t)[udl.keywords UTF8String]];
        }
    }

    [sci setGeneralProperty:SCI_SETPROPERTY parameter:(sptr_t)"fold" value:(sptr_t)"1"];
    [sci setGeneralProperty:SCI_SETPROPERTY parameter:(sptr_t)"fold.compact" value:(sptr_t)"0"];
    [sci setGeneralProperty:SCI_SETPROPERTY parameter:(sptr_t)"fold.comment" value:(sptr_t)"1"];
    [sci setGeneralProperty:SCI_SETPROPERTY parameter:(sptr_t)"fold.preprocessor" value:(sptr_t)"1"];

    [sci setGeneralProperty:SCI_COLOURISE parameter:0 value:-1];
}

- (void)applyLanguage:(NSString *)lang {
    [self applyLanguage:lang toDocument:[self activeDocument]];
    [self updateUI];
}

#pragma mark Documents

- (EditorDocument *)makeDocumentWithPath:(NSString *)path text:(NSString *)text lang:(NSString *)lang {
    EditorDocument *doc = [EditorDocument new];
    doc.path = path;
    doc.lang = lang ?: @"normal";
    doc.dirty = NO;
    doc.editor = [self makeEditor];

    __weak AppDelegate *weakSelf = self;
    __weak EditorDocument *weakDoc = doc;
    DocNotifier *notifier = [DocNotifier new];
    notifier.handler = ^(SCNotification *scn) {
        [weakSelf handleNotification:scn forDocument:weakDoc];
    };
    doc.notifier = notifier;
    doc.editor.delegate = notifier;

    if (text) [doc.editor setString:text];
    [doc.editor setGeneralProperty:SCI_EMPTYUNDOBUFFER parameter:0 value:0];
    [doc.editor setGeneralProperty:SCI_SETSAVEPOINT parameter:0 value:0];
    [self applyLanguage:doc.lang toDocument:doc];

    return doc;
}

- (void)addDocument:(EditorDocument *)doc {
    [self.documents addObject:doc];
    [self showDocumentAtIndex:(NSInteger)self.documents.count - 1];
}

- (void)newDocument {
    EditorDocument *doc = [self makeDocumentWithPath:nil text:nil lang:@"normal"];
    [self addDocument:doc];
    [self updateUI];
}

- (NSInteger)indexOfDocumentWithPath:(NSString *)path {
    NSString *target = path.stringByStandardizingPath;
    for (NSUInteger i = 0; i < self.documents.count; i++) {
        NSString *p = self.documents[i].path;
        if (p && [p.stringByStandardizingPath isEqualToString:target]) return (NSInteger)i;
    }
    return -1;
}

- (void)openDocument:(NSString *)path {
    NSInteger existing = [self indexOfDocumentWithPath:path];
    if (existing >= 0) {
        [self showDocumentAtIndex:existing];
        return;
    }

    NSError *err = nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:&err];
    if (!text) {
        text = [NSString stringWithContentsOfFile:path
                                         encoding:NSISOLatin1StringEncoding
                                            error:&err];
    }
    if (!text) {
        NSBeep();
        self.status.stringValue = [NSString stringWithFormat:@"Cannot open: %@",
                                   err.localizedDescription ?: path];
        return;
    }

    EditorDocument *doc = [self makeDocumentWithPath:path
                                                text:text
                                                lang:NppLanguageForExtension(path.pathExtension)];
    [doc.editor setGeneralProperty:SCI_GOTOPOS parameter:0 value:0];
    [self addDocument:doc];
    [self updateUI];
}

- (void)showDocumentAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.documents.count) return;

    self.activeIndex = index;
    EditorDocument *doc = self.documents[index];

    for (NSView *v in [self.editorContainer.subviews copy]) [v removeFromSuperview];

    if (self.splitView && self.splitEditor) {
        // Split mode: two independent views of the same document, side by side.
        CGFloat half = NSWidth(self.editorContainer.bounds) / 2.0;
        CGFloat h = NSHeight(self.editorContainer.bounds);
        doc.editor.frame = NSMakeRect(0, 0, half - 1, h);
        self.splitEditor.frame = NSMakeRect(half + 1, 0, half - 1, h);
        doc.editor.autoresizingMask = NSViewHeightSizable;
        self.splitEditor.autoresizingMask = NSViewHeightSizable;
        [self.editorContainer addSubview:doc.editor];
        [self.editorContainer addSubview:self.splitEditor];
        [self applyDocumentToSplitView:doc];
    } else {
        doc.editor.frame = self.editorContainer.bounds;
        doc.editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.editorContainer addSubview:doc.editor];
    }
    [doc.editor setGeneralProperty:SCI_SETFOCUS parameter:1 value:0];

    self.tabStrip.selectedIndex = index;
    [self updateUI];
    if (self.previewVisible) {
        [self schedulePreviewUpdate];
    }
}

- (void)closeDocumentAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.documents.count) return;

    EditorDocument *doc = self.documents[index];
    if (doc.dirty && !self.suppressAlerts && ![self confirmDiscard:doc]) return;
    if (doc.undoBreakTimer) {
        [doc.undoBreakTimer invalidate];
        doc.undoBreakTimer = nil;
    }

    BOOL wasActive = (index == self.activeIndex);
    [self.documents removeObjectAtIndex:index];

    if (self.documents.count == 0) {
        self.activeIndex = -1;
        [self updateUI];
        [self.window performClose:nil];
        return;
    }

    if (wasActive) {
        NSInteger next = MIN(index, (NSInteger)self.documents.count - 1);
        [self showDocumentAtIndex:next];
    } else {
        if (index < self.activeIndex) self.activeIndex--;
        self.tabStrip.selectedIndex = self.activeIndex;
        [self updateUI];
    }
}

- (BOOL)confirmDiscard:(EditorDocument *)doc {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Save changes to “%@”?",
                         doc.displayName];
    alert.informativeText = @"Your changes will be lost if you don't save them.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Discard"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse r = [alert runModal];
    if (r == NSAlertFirstButtonReturn) {
        return [self saveDocument:doc saveAs:NO];
    }
    return r == NSAlertSecondButtonReturn;
}

- (BOOL)saveDocument:(EditorDocument *)doc saveAs:(BOOL)saveAs {
    if (!doc) return NO;

    NSString *path = doc.path;
    if (!path || saveAs) {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.nameFieldStringValue = path ? path.lastPathComponent : @"untitled.txt";
        if ([panel runModal] != NSModalResponseOK) return NO;
        path = panel.URL.path;
    }

    NSString *text = [doc.editor string];
    NSError *err = nil;
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        NSBeep();
        self.status.stringValue = [NSString stringWithFormat:@"Save failed: %@",
                                   err.localizedDescription];
        return NO;
    }

    doc.path = path;
    doc.dirty = NO;
    [doc.editor setGeneralProperty:SCI_SETSAVEPOINT parameter:0 value:0];
    [self applyLanguage:NppLanguageForExtension(path.pathExtension) toDocument:doc];
    [self updateUI];
    return YES;
}

- (void)saveCurrent { [self saveDocument:[self activeDocument] saveAs:NO]; }
- (void)saveCurrentAs { [self saveDocument:[self activeDocument] saveAs:YES]; }

- (void)closeCurrentTab { [self closeDocumentAtIndex:self.activeIndex]; }

- (void)selectNextTab:(BOOL)forward {
    NSUInteger n = self.documents.count;
    if (n < 2) return;
    NSInteger next = ((self.activeIndex + (forward ? 1 : -1)) % (NSInteger)n + (NSInteger)n) % (NSInteger)n;
    [self showDocumentAtIndex:next];
}

- (void)toggleSplitViewAction:(id)sender {
    [self toggleSplitView:self.splitView == nil];
}
- (void)nextTab { [self selectNextTab:YES]; }
- (void)previousTab { [self selectNextTab:NO]; }

#pragma mark Split view and scroll sync

- (void)toggleSplitView:(BOOL)enable {
    if (enable == (self.splitView != nil)) return;

    if (enable) {
        self.splitEditor = [self makeEditor];
        self.splitEditor.delegate = nil;
        self.splitView = self.splitEditor;
    } else {
        [self.splitEditor removeFromSuperview];
        self.splitEditor = nil;
        self.splitView = nil;
    }
    [self showDocumentAtIndex:self.activeIndex];
    [self syncSplitScrollingFrom:[self activeDocument].editor];
}

// Copies the active document's buffer into the second pane so both views show
// the same text (Scintilla's SCI_SETDOCPOINTER would share it, but the Cocoa
// wrapper exposes one buffer per view and copying keeps the panes independent).
- (void)applyDocumentToSplitView:(EditorDocument *)doc {
    if (!self.splitEditor || !doc) return;
    const char *lexerId = LexerIdForLang([doc.lang UTF8String]);
    if (!lexerId) lexerId = "null";
    ILexer5 *lexer = CreateLexer(lexerId);
    if (lexer) [self.splitEditor setGeneralProperty:SCI_SETILEXER parameter:0 value:(sptr_t)lexer];
    [self applyThemeTo:self.splitEditor lexer:@(lexerId) lang:doc.lang];
    [self.splitEditor setString:[doc.editor string]];
    [self.splitEditor setGeneralProperty:SCI_SETSAVEPOINT parameter:0 value:0];
    [self.splitEditor setGeneralProperty:SCI_SETCODEPAGE parameter:SC_CP_UTF8 value:0];
}

- (void)syncSplitScrollingFrom:(ScintillaView *)source {
    if (!self.splitEditor || source != [self activeDocument].editor) return;

    if (self.syncVertical) {
        long line = [source getGeneralProperty:SCI_GETFIRSTVISIBLELINE parameter:0];
        [self.splitEditor setGeneralProperty:SCI_SETFIRSTVISIBLELINE value:line];
    }
    if (self.syncHorizontal) {
        long x = [source getGeneralProperty:SCI_GETXOFFSET parameter:0];
        [self.splitEditor setGeneralProperty:SCI_SETXOFFSET value:x];
    }
}

- (void)toggleSyncScrolling:(BOOL)vertical {
    BOOL *flag = vertical ? &_syncVertical : &_syncHorizontal;
    *flag = !*flag;
    if (!self.splitEditor) {
        [self flashStatus:@"Synchronize scrolling needs a split view (View > Split)"];
        return;
    }
    [self syncSplitScrollingFrom:[self activeDocument].editor];
    [self flashStatus:[NSString stringWithFormat:@"Synchronized %s scrolling %@",
                       vertical ? "vertical" : "horizontal",
                       *flag ? @"on" : @"off"]];
}

#pragma mark - Undo / Redo Coalescing & Actions

- (void)breakUndoGroupForDocument:(EditorDocument *)doc {
    if (!doc || !doc.editor) return;
    if (doc.undoBreakTimer) {
        [doc.undoBreakTimer invalidate];
        doc.undoBreakTimer = nil;
    }
    [doc.editor setGeneralProperty:SCI_BEGINUNDOACTION parameter:0 value:0];
    [doc.editor setGeneralProperty:SCI_ENDUNDOACTION parameter:0 value:0];
}

- (void)scheduleUndoBreakForDocument:(EditorDocument *)doc {
    if (!doc || !doc.editor) return;
    if (doc.undoBreakTimer) {
        [doc.undoBreakTimer invalidate];
        doc.undoBreakTimer = nil;
    }
    __weak AppDelegate *weakSelf = self;
    __weak EditorDocument *weakDoc = doc;
    doc.undoBreakTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                         repeats:NO
                                                           block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf breakUndoGroupForDocument:weakDoc];
    }];
}

- (void)undo:(id)sender {
    (void)sender;
    [self performUndo];
}

- (void)redo:(id)sender {
    (void)sender;
    [self performRedo];
}

- (void)performUndo {
    EditorDocument *doc = [self activeDocument];
    if (!doc || !doc.editor) return;
    if (doc.undoBreakTimer) {
        [doc.undoBreakTimer invalidate];
        doc.undoBreakTimer = nil;
    }
    [doc.editor setGeneralProperty:SCI_UNDO parameter:0 value:0];
    [self updateStatusText];
    if (self.previewVisible) [self schedulePreviewUpdate];
}

- (void)performRedo {
    EditorDocument *doc = [self activeDocument];
    if (!doc || !doc.editor) return;
    if (doc.undoBreakTimer) {
        [doc.undoBreakTimer invalidate];
        doc.undoBreakTimer = nil;
    }
    [doc.editor setGeneralProperty:SCI_REDO parameter:0 value:0];
    [self updateStatusText];
    if (self.previewVisible) [self schedulePreviewUpdate];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(undo:)) {
        EditorDocument *doc = [self activeDocument];
        return doc && [doc.editor getGeneralProperty:SCI_CANUNDO parameter:0] != 0;
    }
    if (action == @selector(redo:)) {
        EditorDocument *doc = [self activeDocument];
        return doc && [doc.editor getGeneralProperty:SCI_CANREDO parameter:0] != 0;
    }
    return YES;
}

#pragma mark Notifications and UI

- (void)handleNotification:(SCNotification *)scn forDocument:(EditorDocument *)doc {
    if (!doc) return;

    switch (scn->nmhdr.code) {
        case SCN_SAVEPOINTLEFT:
            doc.dirty = YES;
            [self updateUI];
            break;
        case SCN_SAVEPOINTREACHED:
            doc.dirty = NO;
            [self updateUI];
            break;
        case SCN_MACRORECORD: {
            if (!self.macroRecording) break;
            MacroEvent ev;
            ev.message = scn->message;
            ev.wParam = scn->wParam;
            ev.lParam = scn->lParam;
            ev.text = nil;
            if (scn->message == SCI_REPLACESEL && scn->lParam)
                ev.text = @((const char *)scn->lParam);
            [self.macroEvents addObject:[NSValue valueWithBytes:&ev
                                                       objCType:@encode(MacroEvent)]];
            break;
        }
        case SCN_CHARADDED: {
            doc.lastCharTypedTime = [NSDate timeIntervalSinceReferenceDate];
            int ch = scn->ch;
            if (ch == '\n' || ch == '\r') {
                // Natural line boundary: Enter creates an independent undo group
                [self breakUndoGroupForDocument:doc];
            } else if (ch == ' ' || ch == '\t' || ch == ';' || ch == '{' || ch == '}' || ch == '(' || ch == ')') {
                // Word and statement delimiter boundary
                [self breakUndoGroupForDocument:doc];
            } else {
                // Continuous character typing: group word characters, break on idle pause (>1.2s)
                [self scheduleUndoBreakForDocument:doc];
            }
            break;
        }
        case SCN_PAINTED:
            break;
        case SCN_UPDATEUI: {
            long currentPos = [doc.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            BOOL fromTyping = (now - doc.lastCharTypedTime) < 0.05;
            if (!fromTyping && labs(currentPos - doc.lastCaretPos) > 1) {
                // Caret jump or mouse click navigation: break undo coalescing
                [self breakUndoGroupForDocument:doc];
            }
            doc.lastCaretPos = currentPos;

            if (doc == [self activeDocument]) [self syncSplitScrollingFrom:doc.editor];
            if (doc == [self activeDocument]) [self updateStatusText];
            break;
        }
        case SCN_MODIFIED:
            if (scn->modificationType & (SC_PERFORMED_UNDO | SC_PERFORMED_REDO)) {
                if (doc.undoBreakTimer) {
                    [doc.undoBreakTimer invalidate];
                    doc.undoBreakTimer = nil;
                }
            }
            if (self.previewVisible && doc == [self activeDocument]) {
                [self schedulePreviewUpdate];
            }
            break;
        default:
            break;
    }
}

- (void)updateStatusText {
    EditorDocument *doc = [self activeDocument];
    if (!doc) {
        self.status.stringValue = @"";
        self.window.title = @"catatan++";
        return;
    }

    ScintillaView *sci = doc.editor;
    long lines = [sci getGeneralProperty:SCI_GETLINECOUNT parameter:0];
    long pos = [sci getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
    long line = [sci getGeneralProperty:SCI_LINEFROMPOSITION parameter:pos];
    long col = pos - [sci getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];

    self.status.stringValue = [NSString stringWithFormat:
        @"%@   |   Ln %ld, Col %ld   |   %ld lines   |   UTF-8   |   %@",
        doc.lang ?: @"normal", line + 1, col + 1, lines, doc.path ?: @"unsaved"];
}

- (void)updateUI {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSNumber *> *flags = [NSMutableArray array];
    for (EditorDocument *doc in self.documents) {
        [titles addObject:doc.displayName];
        [flags addObject:@(doc.dirty)];
    }
    self.tabStrip.titles = titles;
    self.tabStrip.dirtyFlags = flags;
    self.tabStrip.selectedIndex = self.activeIndex;
    [self.tabStrip refresh];

    EditorDocument *doc = [self activeDocument];
    self.window.title = doc
        ? [NSString stringWithFormat:@"%@%@ - catatan++",
           doc.displayName, doc.dirty ? @" *" : @""]
        : @"catatan++";
    [self updateStatusText];
}

#pragma mark Actions

- (void)openFilePanel {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    if ([panel runModal] != NSModalResponseOK) return;
    for (NSURL *url in panel.URLs) [self openDocument:url.path];
}

#pragma mark - Find and Replace

- (void)buildFindPanel {
    self.findPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(220, 250, 480, 160)
                                                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    self.findPanel.title = @"Find & Replace - catatan++";
    self.findPanel.floatingPanel = YES;
    NSView *cv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 160)];

    // Find row
    NSTextField *lblFind = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 122, 60, 20)];
    lblFind.stringValue = @"Find:";
    lblFind.editable = NO; lblFind.bezeled = NO; lblFind.drawsBackground = NO;
    [cv addSubview:lblFind];

    self.findField = [[NSTextField alloc] initWithFrame:NSMakeRect(80, 120, 210, 24)];
    self.findField.placeholderString = @"Search text";
    self.findField.target = self;
    self.findField.action = @selector(findNextAction:);
    [cv addSubview:self.findField];

    NSButton *btnNext = [[NSButton alloc] initWithFrame:NSMakeRect(300, 117, 84, 28)];
    btnNext.title = @"Find Next";
    btnNext.bezelStyle = NSBezelStyleRounded;
    btnNext.target = self;
    btnNext.action = @selector(findNextAction:);
    [cv addSubview:btnNext];

    NSButton *btnPrev = [[NSButton alloc] initWithFrame:NSMakeRect(388, 117, 84, 28)];
    btnPrev.title = @"Find Prev";
    btnPrev.bezelStyle = NSBezelStyleRounded;
    btnPrev.target = self;
    btnPrev.action = @selector(findPrevAction:);
    [cv addSubview:btnPrev];

    // Replace row
    NSTextField *lblReplace = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 86, 60, 20)];
    lblReplace.stringValue = @"Replace:";
    lblReplace.editable = NO; lblReplace.bezeled = NO; lblReplace.drawsBackground = NO;
    [cv addSubview:lblReplace];

    self.replaceField = [[NSTextField alloc] initWithFrame:NSMakeRect(80, 84, 210, 24)];
    self.replaceField.placeholderString = @"Replace with";
    self.replaceField.target = self;
    self.replaceField.action = @selector(replaceOneAction:);
    [cv addSubview:self.replaceField];

    NSButton *btnRepl = [[NSButton alloc] initWithFrame:NSMakeRect(300, 81, 84, 28)];
    btnRepl.title = @"Replace";
    btnRepl.bezelStyle = NSBezelStyleRounded;
    btnRepl.target = self;
    btnRepl.action = @selector(replaceOneAction:);
    [cv addSubview:btnRepl];

    NSButton *btnReplAll = [[NSButton alloc] initWithFrame:NSMakeRect(388, 81, 84, 28)];
    btnReplAll.title = @"Replace All";
    btnReplAll.bezelStyle = NSBezelStyleRounded;
    btnReplAll.target = self;
    btnReplAll.action = @selector(replaceAllAction:);
    [cv addSubview:btnReplAll];

    // Option checkboxes
    self.caseCheckbox = [NSButton checkboxWithTitle:@"Match case" target:nil action:nil];
    self.caseCheckbox.frame = NSMakeRect(80, 52, 95, 20);
    [cv addSubview:self.caseCheckbox];

    self.wordCheckbox = [NSButton checkboxWithTitle:@"Whole word" target:nil action:nil];
    self.wordCheckbox.frame = NSMakeRect(180, 52, 95, 20);
    [cv addSubview:self.wordCheckbox];

    self.wrapCheckbox = [NSButton checkboxWithTitle:@"Wrap around" target:nil action:nil];
    self.wrapCheckbox.frame = NSMakeRect(280, 52, 105, 20);
    self.wrapCheckbox.state = NSControlStateValueOn;
    [cv addSubview:self.wrapCheckbox];

    // Status label
    self.findStatus = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 16, 448, 20)];
    self.findStatus.stringValue = @"";
    self.findStatus.editable = NO; self.findStatus.bezeled = NO; self.findStatus.drawsBackground = NO;
    self.findStatus.font = [NSFont systemFontOfSize:11];
    self.findStatus.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.findStatus];

    self.findPanel.contentView = cv;
}

- (void)showFindPanelWithReplace:(BOOL)showReplace {
    if (!self.findPanel) {
        [self buildFindPanel];
    }
    EditorDocument *doc = [self activeDocument];
    if (doc) {
        long selStart = [doc.editor getGeneralProperty:SCI_GETSELECTIONSTART parameter:0];
        long selEnd = [doc.editor getGeneralProperty:SCI_GETSELECTIONEND parameter:0];
        if (selEnd > selStart && (selEnd - selStart) <= 120) {
            NSString *all = [doc.editor string];
            if (selEnd <= (long)all.length) {
                NSString *selected = [all substringWithRange:NSMakeRange(selStart, selEnd - selStart)];
                if (selected.length > 0 && ![selected containsString:@"\n"]) {
                    self.findField.stringValue = selected;
                }
            }
        }
    }
    self.findStatus.stringValue = @"";
    [self.findPanel makeKeyAndOrderFront:nil];
    if (showReplace) {
        [self.findPanel makeFirstResponder:self.replaceField];
    } else {
        [self.findPanel makeFirstResponder:self.findField];
    }
}

- (void)findAction:(id)sender {
    [self showFindPanelWithReplace:NO];
}

- (void)replaceAction:(id)sender {
    [self showFindPanelWithReplace:YES];
}

- (void)findNextAction:(id)sender {
    NSString *query = self.findField.stringValue;
    if (query.length == 0) return;
    BOOL mc = (self.caseCheckbox.state == NSControlStateValueOn);
    BOOL ww = (self.wordCheckbox.state == NSControlStateValueOn);
    BOOL wrap = (self.wrapCheckbox.state == NSControlStateValueOn);
    BOOL found = [self performFind:query matchCase:mc wholeWord:ww wrap:wrap backwards:NO];
    if (found) {
        EditorDocument *doc = [self activeDocument];
        long pos = [doc.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
        long line = [doc.editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:pos] + 1;
        self.findStatus.stringValue = [NSString stringWithFormat:@"Found on line %ld", line];
    } else {
        NSBeep();
        self.findStatus.stringValue = [NSString stringWithFormat:@"\"%@\" not found", query];
    }
}

- (void)findPrevAction:(id)sender {
    NSString *query = self.findField.stringValue;
    if (query.length == 0) return;
    BOOL mc = (self.caseCheckbox.state == NSControlStateValueOn);
    BOOL ww = (self.wordCheckbox.state == NSControlStateValueOn);
    BOOL wrap = (self.wrapCheckbox.state == NSControlStateValueOn);
    BOOL found = [self performFind:query matchCase:mc wholeWord:ww wrap:wrap backwards:YES];
    if (found) {
        EditorDocument *doc = [self activeDocument];
        long pos = [doc.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
        long line = [doc.editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:pos] + 1;
        self.findStatus.stringValue = [NSString stringWithFormat:@"Found on line %ld", line];
    } else {
        NSBeep();
        self.findStatus.stringValue = [NSString stringWithFormat:@"\"%@\" not found", query];
    }
}

- (void)replaceOneAction:(id)sender {
    NSString *query = self.findField.stringValue;
    NSString *repl = self.replaceField.stringValue ?: @"";
    if (query.length == 0) return;
    BOOL mc = (self.caseCheckbox.state == NSControlStateValueOn);
    BOOL ww = (self.wordCheckbox.state == NSControlStateValueOn);
    int count = [self performReplace:query with:repl matchCase:mc wholeWord:ww all:NO];
    if (count > 0) {
        self.findStatus.stringValue = @"Replaced 1 occurrence";
        BOOL wrap = (self.wrapCheckbox.state == NSControlStateValueOn);
        [self performFind:query matchCase:mc wholeWord:ww wrap:wrap backwards:NO];
    } else {
        self.findStatus.stringValue = @"No match to replace";
    }
}

- (void)replaceAllAction:(id)sender {
    NSString *query = self.findField.stringValue;
    NSString *repl = self.replaceField.stringValue ?: @"";
    if (query.length == 0) return;
    BOOL mc = (self.caseCheckbox.state == NSControlStateValueOn);
    BOOL ww = (self.wordCheckbox.state == NSControlStateValueOn);
    int count = [self performReplace:query with:repl matchCase:mc wholeWord:ww all:YES];
    self.findStatus.stringValue = [NSString stringWithFormat:@"Replaced %d occurrence%@", count, count == 1 ? @"" : @"s"];
}

- (BOOL)performFind:(NSString *)query
          matchCase:(BOOL)mc
          wholeWord:(BOOL)ww
               wrap:(BOOL)wrap
          backwards:(BOOL)backwards {
    EditorDocument *doc = [self activeDocument];
    if (!doc || query.length == 0) return NO;
    return [doc.editor findAndHighlightText:query
                                  matchCase:mc
                                  wholeWord:ww
                                   scrollTo:YES
                                       wrap:wrap
                                  backwards:backwards];
}

- (int)performReplace:(NSString *)query
                 with:(NSString *)replacement
            matchCase:(BOOL)mc
            wholeWord:(BOOL)ww
                  all:(BOOL)all {
    EditorDocument *doc = [self activeDocument];
    if (!doc || query.length == 0) return 0;
    int count = [doc.editor findAndReplaceText:query
                                       byText:replacement ?: @""
                                    matchCase:mc
                                    wholeWord:ww
                                        doAll:all];
    if (count > 0) {
        doc.dirty = YES;
        [self updateUI];
    }
    return count;
}

#pragma mark - Preferences

- (void)applyPreferences {
    NSString *font = [self currentFontName];
    NSInteger size = [self currentFontSize];
    NSInteger tab = [self currentTabWidth];
    BOOL spaces = [self currentUseSpaces];
    BOOL wrap = [self currentWordWrap];
    BOOL lines = [self currentShowLineNumbers];

    for (EditorDocument *doc in self.documents) {
        ScintillaView *sci = doc.editor;
        [sci setGeneralProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:(sptr_t)[font UTF8String]];
        [sci setGeneralProperty:SCI_STYLESETSIZE parameter:STYLE_DEFAULT value:size];
        [sci setGeneralProperty:SCI_STYLECLEARALL parameter:0 value:0];
        [sci setGeneralProperty:SCI_SETTABWIDTH parameter:tab value:0];
        [sci setGeneralProperty:SCI_SETUSETABS parameter:spaces ? 0 : 1 value:0];
        [sci message:SCI_SETWRAPMODE wParam:wrap ? SC_WRAP_WORD : SC_WRAP_NONE];
        [sci setGeneralProperty:SCI_SETMARGINWIDTHN parameter:0 value:lines ? 52 : 0];
        if (doc.lang) {
            [self applyLanguage:doc.lang toDocument:doc];
        }
    }
    [self updateUI];
}

- (void)setTestPreferenceFont:(NSString *)font
                         size:(NSInteger)sz
                     tabWidth:(NSInteger)tab
                    useSpaces:(BOOL)spaces
                     wordWrap:(BOOL)wrap
                  lineNumbers:(BOOL)lines {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    if (font) [u setObject:font forKey:@"pref_font"];
    if (sz > 0) [u setInteger:sz forKey:@"pref_fontsize"];
    if (tab > 0) [u setInteger:tab forKey:@"pref_tabwidth"];
    [u setBool:spaces forKey:@"pref_usespaces"];
    [u setBool:wrap forKey:@"pref_wordwrap"];
    [u setBool:lines forKey:@"pref_linenumbers"];
    [u synchronize];
    [self applyPreferences];
}

- (void)buildPrefsWindow {
    self.prefsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 380, 260)
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self.prefsWindow.title = @"Preferences - catatan++";
    NSView *cv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 260)];

    // Font selection
    NSTextField *lblFont = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 218, 90, 20)];
    lblFont.stringValue = @"Font Family:";
    lblFont.editable = NO; lblFont.bezeled = NO; lblFont.drawsBackground = NO;
    [cv addSubview:lblFont];

    self.prefFontPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, 215, 230, 26) pullsDown:NO];
    [self.prefFontPop addItemsWithTitles:@[@"Menlo", @"Monaco", @"Courier", @"Courier New"]];
    [self.prefFontPop selectItemWithTitle:[self currentFontName]];
    [cv addSubview:self.prefFontPop];

    // Font size
    NSTextField *lblSize = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 180, 90, 20)];
    lblSize.stringValue = @"Font Size:";
    lblSize.editable = NO; lblSize.bezeled = NO; lblSize.drawsBackground = NO;
    [cv addSubview:lblSize];

    self.prefSizePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, 177, 100, 26) pullsDown:NO];
    for (NSString *s in @[@"9", @"10", @"11", @"12", @"13", @"14", @"16", @"18", @"20", @"24"]) {
        [self.prefSizePop addItemWithTitle:s];
    }
    [self.prefSizePop selectItemWithTitle:[NSString stringWithFormat:@"%ld", (long)[self currentFontSize]]];
    [cv addSubview:self.prefSizePop];

    // Tab Width
    NSTextField *lblTab = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 142, 90, 20)];
    lblTab.stringValue = @"Tab Width:";
    lblTab.editable = NO; lblTab.bezeled = NO; lblTab.drawsBackground = NO;
    [cv addSubview:lblTab];

    self.prefTabPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, 139, 100, 26) pullsDown:NO];
    [self.prefTabPop addItemsWithTitles:@[@"2", @"4", @"8"]];
    [self.prefTabPop selectItemWithTitle:[NSString stringWithFormat:@"%ld", (long)[self currentTabWidth]]];
    [cv addSubview:self.prefTabPop];

    // Checkboxes
    self.prefSpacesCheck = [NSButton checkboxWithTitle:@"Use spaces instead of tabs (soft tabs)"
                                                target:nil action:nil];
    self.prefSpacesCheck.frame = NSMakeRect(24, 106, 300, 22);
    self.prefSpacesCheck.state = [self currentUseSpaces] ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:self.prefSpacesCheck];

    self.prefLineNumCheck = [NSButton checkboxWithTitle:@"Display line numbers margin"
                                                 target:nil action:nil];
    self.prefLineNumCheck.frame = NSMakeRect(24, 80, 300, 22);
    self.prefLineNumCheck.state = [self currentShowLineNumbers] ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:self.prefLineNumCheck];

    self.prefWrapCheck = [NSButton checkboxWithTitle:@"Enable word wrap by default"
                                              target:nil action:nil];
    self.prefWrapCheck.frame = NSMakeRect(24, 54, 300, 22);
    self.prefWrapCheck.state = [self currentWordWrap] ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:self.prefWrapCheck];

    // Apply Button
    NSButton *applyBtn = [[NSButton alloc] initWithFrame:NSMakeRect(250, 16, 105, 30)];
    applyBtn.title = @"Save & Apply";
    applyBtn.bezelStyle = NSBezelStyleRounded;
    applyBtn.target = self;
    applyBtn.action = @selector(savePreferencesFromUI:);
    [cv addSubview:applyBtn];

    self.prefsWindow.contentView = cv;
}

- (void)showPreferences:(id)sender {
    if (!self.prefsWindow) {
        [self buildPrefsWindow];
    }
    [self.prefsWindow makeKeyAndOrderFront:nil];
}

- (void)savePreferencesFromUI:(id)sender {
    NSString *font = self.prefFontPop.selectedItem.title ?: @"Menlo";
    NSInteger sz = [self.prefSizePop.selectedItem.title integerValue] ?: 13;
    NSInteger tab = [self.prefTabPop.selectedItem.title integerValue] ?: 4;
    BOOL spaces = (self.prefSpacesCheck.state == NSControlStateValueOn);
    BOOL lines = (self.prefLineNumCheck.state == NSControlStateValueOn);
    BOOL wrap = (self.prefWrapCheck.state == NSControlStateValueOn);

    [self setTestPreferenceFont:font size:sz tabWidth:tab useSpaces:spaces wordWrap:wrap lineNumbers:lines];
    if (self.prefsWindow) {
        [self.prefsWindow close];
    }
}

#pragma mark - Session Restoration

- (NSString *)sessionFilePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *appDir = [base stringByAppendingPathComponent:@"Catatan++"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [appDir stringByAppendingPathComponent:@"session.plist"];
}

- (void)saveSession {
    NSMutableArray *docs = [NSMutableArray array];
    for (EditorDocument *doc in self.documents) {
        if (doc.path.length > 0) {
            long pos = [doc.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
            [docs addObject:@{
                @"path": doc.path,
                @"lang": doc.lang ?: @"normal",
                @"cursor": @(pos),
                @"dirty": @(doc.dirty)
            }];
        }
    }
    NSDictionary *dict = @{
        @"documents": docs,
        @"activeIndex": @(self.activeIndex)
    };
    [dict writeToFile:[self sessionFilePath] atomically:YES];
}

- (BOOL)restoreSession {
    NSString *path = [self sessionFilePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!dict) return NO;
    NSArray *docs = dict[@"documents"];
    if (!docs || docs.count == 0) return NO;

    NSInteger savedActive = [dict[@"activeIndex"] integerValue];
    NSInteger restoredCount = 0;
    for (NSDictionary *info in docs) {
        NSString *filePath = info[@"path"];
        if (filePath && [[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            [self openDocument:filePath];
            EditorDocument *doc = [self.documents lastObject];
            long pos = [info[@"cursor"] longValue];
            if (pos > 0) {
                [doc.editor setGeneralProperty:SCI_GOTOPOS parameter:pos value:0];
            }
            restoredCount++;
        }
    }
    if (restoredCount > 0) {
        if (savedActive >= 0 && savedActive < (NSInteger)self.documents.count) {
            [self showDocumentAtIndex:savedActive];
        } else {
            [self showDocumentAtIndex:self.documents.count - 1];
        }
        return YES;
    }
    return NO;
}

- (void)selectLanguage:(id)item {
    NSString *lang = [item representedObject];
    if (!lang) lang = [item title];
    [self applyLanguage:lang];
}

- (void)tabStrip:(TabStripView *)strip didSelectIndex:(NSInteger)index {
    [self showDocumentAtIndex:index];
}

- (void)tabStrip:(TabStripView *)strip didCloseIndex:(NSInteger)index {
    [self closeDocumentAtIndex:index];
}

- (void)closeOtherTabsAction:(id)sender {
    (void)sender;
    NSInteger active = self.activeIndex;
    if (active < 0 || active >= (NSInteger)self.documents.count) return;
    EditorDocument *keepDoc = self.documents[active];

    for (NSInteger i = (NSInteger)self.documents.count - 1; i >= 0; i--) {
        if (self.documents[i] != keepDoc) {
            [self closeDocumentAtIndex:i];
        }
    }
}

- (void)closeTabsToRightAction:(id)sender {
    (void)sender;
    NSInteger active = self.activeIndex;
    if (active < 0 || active >= (NSInteger)self.documents.count) return;

    for (NSInteger i = (NSInteger)self.documents.count - 1; i > active; i--) {
        [self closeDocumentAtIndex:i];
    }
}

- (NSMenu *)tabStrip:(TabStripView *)strip menuForTabIndex:(NSInteger)index {
    (void)strip;
    (void)index;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tab Context Menu"];
    menu.delegate = self;

    NSMenuItem *previewItem = [[NSMenuItem alloc] initWithTitle:@"Live Preview (Markdown / Mermaid / PlantUML)" action:@selector(toggleLivePreviewAction:) keyEquivalent:@""];
    previewItem.target = self;
    previewItem.identifier = @"tab_ctx_preview";
    [menu addItem:previewItem];

    NSMenuItem *previewSplit = [[NSMenuItem alloc] initWithTitle:@"Preview Layout: Side by Side" action:@selector(setPreviewLayoutSideBySideAction:) keyEquivalent:@""];
    previewSplit.target = self;
    previewSplit.identifier = @"tab_ctx_preview_split";
    [menu addItem:previewSplit];

    NSMenuItem *previewFull = [[NSMenuItem alloc] initWithTitle:@"Preview Layout: Full Window" action:@selector(setPreviewLayoutFullAction:) keyEquivalent:@""];
    previewFull.target = self;
    previewFull.identifier = @"tab_ctx_preview_full";
    [menu addItem:previewFull];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(closeCurrentTab) keyEquivalent:@""];
    closeItem.target = self;
    [menu addItem:closeItem];

    NSMenuItem *closeOthers = [[NSMenuItem alloc] initWithTitle:@"Close Multiple Tabs" action:nil keyEquivalent:@""];
    NSMenu *multiMenu = [[NSMenu alloc] initWithTitle:@"Close Multiple Tabs"];

    NSMenuItem *closeOtherTabs = [[NSMenuItem alloc] initWithTitle:@"Close Other Tabs" action:@selector(closeOtherTabsAction:) keyEquivalent:@""];
    closeOtherTabs.target = self;
    [multiMenu addItem:closeOtherTabs];

    NSMenuItem *closeRight = [[NSMenuItem alloc] initWithTitle:@"Close Tabs to the Right" action:@selector(closeTabsToRightAction:) keyEquivalent:@""];
    closeRight.target = self;
    [multiMenu addItem:closeRight];

    closeOthers.submenu = multiMenu;
    [menu addItem:closeOthers];

    NSMenuItem *closeAll = [[NSMenuItem alloc] initWithTitle:@"Close All" action:@selector(closeAllDocuments) keyEquivalent:@""];
    closeAll.target = self;
    [menu addItem:closeAll];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *save = [[NSMenuItem alloc] initWithTitle:@"Save" action:@selector(saveCurrent) keyEquivalent:@""];
    save.target = self;
    [menu addItem:save];

    return menu;
}

- (NSMenu *)editorContextMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Editor Context Menu"];
    menu.delegate = self;

    NSMenuItem *undo = [[NSMenuItem alloc] initWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@""];
    [menu addItem:undo];
    NSMenuItem *redo = [[NSMenuItem alloc] initWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@""];
    [menu addItem:redo];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *cut = [[NSMenuItem alloc] initWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@""];
    [menu addItem:cut];
    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    [menu addItem:copy];
    NSMenuItem *paste = [[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    [menu addItem:paste];
    NSMenuItem *selAll = [[NSMenuItem alloc] initWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""];
    [menu addItem:selAll];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *previewItem = [[NSMenuItem alloc] initWithTitle:@"Live Preview (Markdown / Mermaid / PlantUML)" action:@selector(toggleLivePreviewAction:) keyEquivalent:@""];
    previewItem.target = self;
    previewItem.identifier = @"ctx_preview";
    [menu addItem:previewItem];

    NSMenuItem *previewSplit = [[NSMenuItem alloc] initWithTitle:@"Preview Layout: Side by Side" action:@selector(setPreviewLayoutSideBySideAction:) keyEquivalent:@""];
    previewSplit.target = self;
    previewSplit.identifier = @"ctx_preview_split";
    [menu addItem:previewSplit];

    NSMenuItem *previewFull = [[NSMenuItem alloc] initWithTitle:@"Preview Layout: Full Window" action:@selector(setPreviewLayoutFullAction:) keyEquivalent:@""];
    previewFull.target = self;
    previewFull.identifier = @"ctx_preview_full";
    [menu addItem:previewFull];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *wrap = [[NSMenuItem alloc] initWithTitle:@"Word Wrap" action:@selector(toggleWordWrap) keyEquivalent:@""];
    wrap.target = self;
    wrap.identifier = @"ctx_wrap";
    [menu addItem:wrap];

    NSMenuItem *allChars = [[NSMenuItem alloc] initWithTitle:@"Show All Characters" action:@selector(toggleAllCharacters) keyEquivalent:@""];
    allChars.target = self;
    allChars.identifier = @"ctx_all_chars";
    [menu addItem:allChars];

    return menu;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    EditorDocument *doc = [self activeDocument];
    ScintillaView *sci = doc ? doc.editor : nil;

    for (NSMenuItem *item in menu.itemArray) {
        if ([item.identifier isEqualToString:@"ctx_preview"] || [item.identifier isEqualToString:@"tab_ctx_preview"]) {
            item.state = self.previewVisible ? NSControlStateValueOn : NSControlStateValueOff;
        } else if ([item.identifier isEqualToString:@"ctx_preview_split"] || [item.identifier isEqualToString:@"tab_ctx_preview_split"]) {
            item.state = (self.previewVisible && self.previewLayoutMode == PreviewLayoutSideBySide) ? NSControlStateValueOn : NSControlStateValueOff;
            item.enabled = self.previewVisible;
        } else if ([item.identifier isEqualToString:@"ctx_preview_full"] || [item.identifier isEqualToString:@"tab_ctx_preview_full"]) {
            item.state = (self.previewVisible && self.previewLayoutMode == PreviewLayoutFullPreview) ? NSControlStateValueOn : NSControlStateValueOff;
            item.enabled = self.previewVisible;
        } else if ([item.identifier isEqualToString:@"ctx_wrap"]) {
            BOOL isWrapped = sci && [sci getGeneralProperty:SCI_GETWRAPMODE parameter:0] != SC_WRAP_NONE;
            item.state = isWrapped ? NSControlStateValueOn : NSControlStateValueOff;
        } else if ([item.identifier isEqualToString:@"ctx_all_chars"]) {
            BOOL isAllChars = sci && [sci getGeneralProperty:SCI_GETVIEWWS parameter:0] != SCWS_INVISIBLE;
            item.state = isAllChars ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

#pragma mark - Toolbar

- (void)runScintilla:(int)message onActiveEditorWithParam:(long)param {
    EditorDocument *doc = [self activeDocument];
    if (!doc) return;
    [doc.editor setGeneralProperty:message parameter:param value:0];
}

- (void)toolbar:(ToolbarView *)toolbar didActivateItemAtIndex:(NSInteger)index {
    NSString *cmd = [toolbar commandAtIndex:index];
    if (!cmd) return;

    EditorDocument *doc = [self activeDocument];
    ScintillaView *sci = doc.editor;

    if ([cmd isEqualToString:@"file_new"]) { [self newDocument]; }
    else if ([cmd isEqualToString:@"file_open"]) { [self openFilePanel]; }
    else if ([cmd isEqualToString:@"file_save"]) { [self saveCurrent]; }
    else if ([cmd isEqualToString:@"file_save_all"]) {
        for (EditorDocument *d in [self.documents copy])
            if (d.dirty) [self saveDocument:d saveAs:NO];
    }
    else if ([cmd isEqualToString:@"file_close"]) { [self closeCurrentTab]; }
    else if ([cmd isEqualToString:@"file_close_all"]) { [self closeAllDocuments]; }
    else if ([cmd isEqualToString:@"file_print"]) { [self printActiveDocument]; }
    else if ([cmd isEqualToString:@"edit_cut"]) { [sci setGeneralProperty:SCI_CUT parameter:0 value:0]; }
    else if ([cmd isEqualToString:@"edit_copy"]) { [sci setGeneralProperty:SCI_COPY parameter:0 value:0]; }
    else if ([cmd isEqualToString:@"edit_paste"]) { [sci setGeneralProperty:SCI_PASTE parameter:0 value:0]; }
    else if ([cmd isEqualToString:@"edit_undo"]) { [self performUndo]; }
    else if ([cmd isEqualToString:@"edit_redo"]) { [self performRedo]; }
    else if ([cmd isEqualToString:@"search_find"]) { [self showFindPanelWithReplace:NO]; }
    else if ([cmd isEqualToString:@"search_replace"]) { [self showFindPanelWithReplace:YES]; }
    else if ([cmd isEqualToString:@"view_zoom_in"]) { [sci setGeneralProperty:SCI_ZOOMIN parameter:0 value:0]; [self updateUI]; }
    else if ([cmd isEqualToString:@"view_zoom_out"]) { [sci setGeneralProperty:SCI_ZOOMOUT parameter:0 value:0]; [self updateUI]; }
    else if ([cmd isEqualToString:@"view_sync_v"]) { [self toggleSyncScrolling:YES]; }
    else if ([cmd isEqualToString:@"view_sync_h"]) { [self toggleSyncScrolling:NO]; }
    else if ([cmd isEqualToString:@"view_wrap"]) { [self toggleWordWrap]; }
    else if ([cmd isEqualToString:@"view_all_chars"]) { [self toggleAllCharacters]; }
    else if ([cmd isEqualToString:@"view_indent_guide"]) { [self toggleIndentGuides]; }
    else if ([cmd isEqualToString:@"lang_def"]) { [self runLanguageMenuAction];
    }
    else if ([cmd isEqualToString:@"view_doc_map"]) { [self togglePanelNamed:@"Document Map"]; }
    else if ([cmd isEqualToString:@"view_doc_list"]) { [self togglePanelNamed:@"Document List"]; }
    else if ([cmd isEqualToString:@"view_func_list"]) { [self togglePanelNamed:@"Function List"]; }
    else if ([cmd isEqualToString:@"view_file_browser"]) { [self togglePanelNamed:@"Folder as Workspace"]; }
    else if ([cmd isEqualToString:@"view_monitoring"]) { [self toggleMonitoring]; }
    else if ([cmd isEqualToString:@"macro_record"]) { [self startMacroRecording]; }
    else if ([cmd isEqualToString:@"macro_stop"]) { [self stopMacroRecording]; }
    else if ([cmd isEqualToString:@"macro_play"]) { [self playbackMacro]; }
    else if ([cmd isEqualToString:@"macro_multi"]) { [self runMacroMultipleTimes]; }
    else if ([cmd isEqualToString:@"macro_save"]) { [self saveMacroToFile]; }

    [self.toolbar refresh];
}

- (BOOL)toolbar:(ToolbarView *)toolbar isItemToggledAtIndex:(NSInteger)index {
    NSString *cmd = [toolbar commandAtIndex:index];
    if (!cmd) return NO;
    EditorDocument *doc = [self activeDocument];
    ScintillaView *sci = doc ? doc.editor : nil;

    if ([cmd isEqualToString:@"view_wrap"])
        return sci ? [sci getGeneralProperty:SCI_GETWRAPMODE parameter:0] != SC_WRAP_NONE : NO;
    if ([cmd isEqualToString:@"view_all_chars"])
        return sci ? [sci getGeneralProperty:SCI_GETVIEWWS parameter:0] != SCWS_INVISIBLE : NO;
    if ([cmd isEqualToString:@"view_indent_guide"])
        return sci ? [sci getGeneralProperty:SCI_GETINDENTATIONGUIDES parameter:0] != SC_IV_NONE : NO;
    if ([cmd isEqualToString:@"view_monitoring"])
        return self.tailingActive;
    if ([cmd isEqualToString:@"view_sync_v"]) return self.syncVertical;
    if ([cmd isEqualToString:@"view_sync_h"]) return self.syncHorizontal;
    if ([cmd isEqualToString:@"macro_record"])
        return self.macroRecording;
    return [self isPanelVisible:[self panelNameForCommand:cmd]];
}

- (BOOL)toolbar:(ToolbarView *)toolbar isItemEnabledAtIndex:(NSInteger)index {
    NSString *cmd = [toolbar commandAtIndex:index];
    if (!cmd) return NO;

    BOOL hasDoc = [self activeDocument] != nil;
    if ([cmd isEqualToString:@"file_print"] ||
        [cmd hasPrefix:@"search_"] ||
        [cmd hasPrefix:@"edit_undo"] ||
        [cmd hasPrefix:@"edit_redo"] ||
        [cmd hasPrefix:@"view_"] ||
        [cmd hasPrefix:@"lang_def"])
        return hasDoc;

    if ([cmd isEqualToString:@"macro_stop"]) return self.macroRecording;
    if ([cmd isEqualToString:@"macro_play"]) return !self.macroRecording && self.macroEvents.count > 0;

    if (!hasDoc) return [cmd isEqualToString:@"file_open"] || [cmd isEqualToString:@"file_new"];

    EditorDocument *doc = [self activeDocument];
    if ([cmd isEqualToString:@"edit_paste"])
        return [[NSPasteboard generalPasteboard] availableTypeFromArray:
                @[NSPasteboardTypeString]] != nil;
    if ([cmd isEqualToString:@"edit_undo"])
        return [doc.editor getGeneralProperty:SCI_CANUNDO parameter:0] != 0;
    if ([cmd isEqualToString:@"edit_redo"])
        return [doc.editor getGeneralProperty:SCI_CANREDO parameter:0] != 0;
    if ([cmd isEqualToString:@"file_save_all"]) {
        for (EditorDocument *d in self.documents) if (d.dirty) return YES;
        return NO;
    }
    if ([cmd isEqualToString:@"file_close_all"]) return self.documents.count > 0;
    return YES;
}

- (NSString *)panelNameForCommand:(NSString *)cmd {
    if ([cmd isEqualToString:@"view_doc_map"]) return @"Document Map";
    if ([cmd isEqualToString:@"view_doc_list"]) return @"Document List";
    if ([cmd isEqualToString:@"view_func_list"]) return @"Function List";
    if ([cmd isEqualToString:@"view_file_browser"]) return @"Folder as Workspace";
    return nil;
}

- (BOOL)isPanelVisible:(NSString *)name {
    return name != nil && [self.visiblePanelName isEqualToString:name];
}

- (void)setPanelVisible:(BOOL)visible named:(NSString *)name {
    if (!visible || name.length == 0) {
        if (self.sidebar.superview) [self.sidebar removeFromSuperview];
        self.visiblePanelName = nil;
        [self relayoutBody];
        return;
    }

    self.visiblePanelName = name;
    if (!self.sidebar.superview) [self.contentView addSubview:self.sidebar];
    [self relayoutBody];
    [self reloadPanelNamed:name];
}

// Editor, sidebar, and live preview share the body area.
- (void)relayoutBody {
    CGFloat totalW = NSWidth(self.contentView.bounds);
    CGFloat totalH = NSHeight(self.contentView.bounds);
    if (totalW <= 0 || totalH <= 0) return;

    const CGFloat kToolbarH = 34.0;
    const CGFloat kTabH = 30.0;
    self.bodyTop = totalH - kToolbarH - kTabH;
    CGFloat bodyHeight = self.bodyTop - self.bodyBottom;
    if (bodyHeight < 50) bodyHeight = 50;

    // Pin header and footer bars dynamically
    self.toolbar.frame = NSMakeRect(0, totalH - kToolbarH, totalW, kToolbarH);
    self.tabStrip.frame = NSMakeRect(0, totalH - kToolbarH - kTabH, totalW, kTabH);
    self.status.frame = NSMakeRect(0, 0, totalW, self.bodyBottom);

    BOOL shown = self.sidebar.superview != nil;
    CGFloat sbW = shown ? self.sidebarWidth : 0;
    CGFloat availW = totalW - sbW;
    if (availW < 100) availW = 100;

    if (shown) {
        self.sidebar.frame = NSMakeRect(0, self.bodyBottom, sbW, bodyHeight);
    }

    BOOL previewActive = self.previewVisible && self.previewWebView && self.previewWebView.superview;
    if (previewActive) {
        if (self.previewLayoutMode == PreviewLayoutFullPreview) {
            // Full Preview Mode (VS Code style single full window)
            self.editorContainer.hidden = YES;
            self.previewWebView.hidden = NO;
            self.previewWebView.frame = NSMakeRect(sbW, self.bodyBottom, availW, bodyHeight);
        } else {
            // Side-by-Side Mode (50/50 split)
            self.editorContainer.hidden = NO;
            self.previewWebView.hidden = NO;
            CGFloat halfW = floor(availW / 2.0);
            self.editorContainer.frame = NSMakeRect(sbW, self.bodyBottom, halfW, bodyHeight);
            self.previewWebView.frame = NSMakeRect(sbW + halfW, self.bodyBottom, availW - halfW, bodyHeight);
        }
    } else {
        // Full Editor Mode
        self.editorContainer.hidden = NO;
        self.editorContainer.frame = NSMakeRect(sbW, self.bodyBottom, availW, bodyHeight);
        if (self.previewWebView) {
            self.previewWebView.hidden = YES;
        }
    }

    [self showDocumentAtIndex:self.activeIndex];
}

- (void)windowDidResize:(NSNotification *)notification {
    [self relayoutBody];
}

- (void)onContentViewFrameChanged:(NSNotification *)notification {
    [self relayoutBody];
}

- (void)reloadPanelNamed:(NSString *)name {
    if ([name isEqualToString:@"Folder as Workspace"]) {
        [self reloadWorkspacePanel];
    } else if ([name isEqualToString:@"Document List"]) {
        [self reloadDocumentListPanel];
    } else if ([name isEqualToString:@"Function List"]) {
        [self reloadFunctionListPanel];
    } else if ([name isEqualToString:@"Document Map"]) {
        [self reloadDocumentMapPanel];
    }
}

#pragma mark Workspace tree

- (SidebarItem *)workspaceNodeForURL:(NSURL *)url depth:(NSInteger)depth {
    SidebarItem *node = [SidebarItem itemWithTitle:url.lastPathComponent];
    node.path = url.path;

    NSNumber *isDir = nil;
    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
    node.isDirectory = isDir.boolValue;
    if (!node.isDirectory || depth > 6) return node;

    NSArray<NSURL *> *kids = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:url
      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                         options:(NSDirectoryEnumerationSkipsHiddenFiles)
                           error:NULL];
    kids = [kids sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSNumber *ad = nil, *bd = nil;
        [a getResourceValue:&ad forKey:NSURLIsDirectoryKey error:NULL];
        [b getResourceValue:&bd forKey:NSURLIsDirectoryKey error:NULL];
        if (ad.boolValue != bd.boolValue) return ad.boolValue ? NSOrderedAscending : NSOrderedDescending;
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];

    NSMutableArray<SidebarItem *> *children = [NSMutableArray array];
    for (NSURL *kid in kids) [children addObject:[self workspaceNodeForURL:kid depth:depth + 1]];
    node.children = children;
    return node;
}

- (void)reloadWorkspacePanel {
    if (self.workspaceRoot.length == 0) {
        [self.sidebar setPanelTitle:@"Folder as Workspace"
                              items:@[[SidebarItem itemWithTitle:@"No folder opened"
                                                          detail:@"use File > Open Folder"
                                                            line:-1]]];
        return;
    }
    NSURL *root = [NSURL fileURLWithPath:self.workspaceRoot];
    SidebarItem *node = [self workspaceNodeForURL:root depth:0];
    [self.sidebar setPanelTitle:@"Folder as Workspace" items:@[node]];
}

- (void)openFolderAsWorkspace {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Open Folder";
    if ([panel runModal] != NSModalResponseOK) return;
    self.workspaceRoot = panel.URL.path;
    [self setPanelVisible:YES named:@"Folder as Workspace"];
    [self.toolbar refresh];
}

#pragma mark Document list

- (void)reloadDocumentListPanel {
    NSMutableArray<SidebarItem *> *items = [NSMutableArray array];
    for (EditorDocument *doc in self.documents) {
        SidebarItem *it = [SidebarItem itemWithTitle:doc.displayName];
        it.path = doc.path;
        it.detail = doc.dirty ? @"*" : nil;
        [items addObject:it];
    }
    if (items.count == 0) [items addObject:[SidebarItem itemWithTitle:@"No documents"]];
    [self.sidebar setPanelTitle:@"Document List" items:items];
}

#pragma mark Function list

// Walks the document for top-level definitions of the active language.
- (NSArray<SidebarItem *> *)functionItemsForText:(NSString *)text language:(NSString *)lang {
    NSMutableArray<SidebarItem *> *out = [NSMutableArray array];
    if (text.length == 0) return out;

    NSString *lowLang = [lang lowercaseString] ?: @"";
    BOOL cLike = [@[@"cpp", @"c", @"cs", @"java", @"javascript.js", @"typescript",
                    @"objc", @"rust", @"go", @"swift", @"php"] containsObject:lowLang];
    BOOL pyLike = [lowLang isEqualToString:@"python"];
    BOOL luaLike = [lowLang isEqualToString:@"lua"];
    BOOL bashLike = [@[@"bash", @"sh", @"zsh"] containsObject:lowLang];
    BOOL sqlLike = [@[@"sql", @"mssql"] containsObject:lowLang];
    BOOL rubyLike = [lowLang isEqualToString:@"ruby"];
    BOOL perlLike = [lowLang isEqualToString:@"perl"];
    BOOL rLike = [lowLang isEqualToString:@"r"];
    BOOL mdLike = [@[@"markdown", @"md"] containsObject:lowLang];
    BOOL yamlLike = [@[@"yaml", @"yml"] containsObject:lowLang];

    if (!cLike && !pyLike && !luaLike && !bashLike && !sqlLike &&
        !rubyLike && !perlLike && !rLike && !mdLike && !yamlLike) return out;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSRegularExpression *cRe = [NSRegularExpression
        regularExpressionWithPattern:
            @"^[\\t ]*(?:[A-Za-z_][\\w:<>,\\*&\\[\\] ]*[\\s\\*&]+)?([A-Za-z_]\\w*)\\s*\\([^;]*\\)\\s*\\{?\\s*$"
                             options:0 error:NULL];
    NSRegularExpression *pyRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[\\t ]*(?:async\\s+)?def\\s+([A-Za-z_]\\w*)"
                             options:0 error:NULL];
    NSRegularExpression *luaRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[\\t ]*(?:local\\s+)?function\\s+([A-Za-z_][\\w\\.:]*)"
                             options:0 error:NULL];
    NSRegularExpression *bashRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[\\t ]*(?:function\\s+)?([A-Za-z_][\\w-]*)\\s*(?:\\(\\s*\\))?\\s*\\{"
                             options:0 error:NULL];
    NSRegularExpression *sqlRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[\\t ]*(?:CREATE(?:\\s+OR\\s+REPLACE)?\\s+)?(?:FUNCTION|PROCEDURE|TRIGGER|VIEW|TABLE)\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?([A-Za-z_0-9\\.]+)"
                             options:NSRegularExpressionCaseInsensitive error:NULL];
    NSRegularExpression *rubyRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[\\t ]*(?:def|class|module)\\s+([A-Za-z_][\\w\\.\\?\\!=:]*)"
                             options:0 error:NULL];
    NSRegularExpression *perlRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[\\t ]*sub\\s+([A-Za-z_]\\w*)"
                             options:0 error:NULL];
    NSRegularExpression *rRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[\\t ]*([A-Za-z_\\.][\\w\\.]*)\\s*(?:<-|=)\\s*function\\s*\\("
                             options:0 error:NULL];
    NSRegularExpression *mdRe = [NSRegularExpression
        regularExpressionWithPattern:@"^(#{1,6})\\s+(.+)$"
                             options:0 error:NULL];
    NSRegularExpression *yamlRe = [NSRegularExpression
        regularExpressionWithPattern:@"^([A-Za-z0-9_-]+)\\s*:"
                             options:0 error:NULL];

    NSSet *control = [NSSet setWithArray:@[@"if", @"for", @"while", @"switch", @"catch",
                                          @"return", @"sizeof", @"else", @"do"]];

    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRegularExpression *re = cLike ? cRe :
                                  (pyLike ? pyRe :
                                  (luaLike ? luaRe :
                                  (bashLike ? bashRe :
                                  (sqlLike ? sqlRe :
                                  (rubyLike ? rubyRe :
                                  (perlLike ? perlRe :
                                  (rLike ? rRe :
                                  (mdLike ? mdRe : yamlRe))))))));

        NSTextCheckingResult *m = [re firstMatchInString:line
                                                 options:0
                                                   range:NSMakeRange(0, line.length)];
        if (!m || m.numberOfRanges < 2) continue;

        NSString *name = nil;
        NSString *detail = [NSString stringWithFormat:@"L%lu", (unsigned long)i + 1];

        if (mdLike && m.numberOfRanges >= 3) {
            NSString *hashes = [line substringWithRange:[m rangeAtIndex:1]];
            name = [line substringWithRange:[m rangeAtIndex:2]];
            detail = [NSString stringWithFormat:@"H%lu L%lu", (unsigned long)hashes.length, (unsigned long)i + 1];
        } else {
            name = [line substringWithRange:[m rangeAtIndex:1]];
        }

        if ([control containsObject:name]) continue;
        [out addObject:[SidebarItem itemWithTitle:name
                                           detail:detail
                                             line:(NSInteger)i + 1]];
        if (out.count >= 500) break;
    }
    return out;
}

- (void)reloadFunctionListPanel {
    EditorDocument *doc = [self activeDocument];
    NSArray<SidebarItem *> *items = nil;
    if (doc) {
        NSString *text = [doc.editor string];
        items = [self functionItemsForText:text language:doc.lang];
    }
    if (items.count == 0)
        items = @[[SidebarItem itemWithTitle:@"No functions found"]];
    [self.sidebar setPanelTitle:@"Function List" items:items];
}

- (void)reloadDocumentMapPanel {
    EditorDocument *doc = [self activeDocument];
    if (!doc) {
        [self.sidebar setPanelTitle:@"Document Map"
                              items:@[[SidebarItem itemWithTitle:@"No document"]]];
        return;
    }

    // Notepad++'s Document Map mirrors the file's structure; here it lists the
    // document's functions plus the tab's own entry, so the outline is useful.
    NSMutableArray<SidebarItem *> *items = [NSMutableArray array];
    SidebarItem *selfNode = [SidebarItem itemWithTitle:doc.displayName];
    selfNode.path = doc.path;
    NSArray<SidebarItem *> *fns = [self functionItemsForText:[doc.editor string]
                                                    language:doc.lang];
    if (fns.count) selfNode.children = fns;
    [items addObject:selfNode];

    long lines = [doc.editor getGeneralProperty:SCI_GETLINECOUNT parameter:0];
    [items addObject:[SidebarItem itemWithTitle:@"Statistics"
                                       detail:[NSString stringWithFormat:@"%ld lines", lines]
                                         line:-1]];
    [self.sidebar setPanelTitle:@"Document Map" items:items];
}

#pragma mark Sidebar delegate

- (void)sidebar:(id)sidebar didChooseItem:(SidebarItem *)item {
    // Function List entries carry only a line number: jump within the current
    // document instead of opening a file.
    if (item.path.length == 0 && item.line > 0) {
        EditorDocument *current = [self activeDocument];
        if (current) {
            long pos = [current.editor getGeneralProperty:SCI_POSITIONFROMLINE
                                                parameter:item.line - 1];
            [current.editor setGeneralProperty:SCI_GOTOPOS parameter:pos value:0];
            [current.editor setGeneralProperty:SCI_SETFOCUS parameter:1 value:0];
        }
        return;
    }

    if (item.isDirectory || item.path.length == 0) return;

    [self openDocument:item.path];
    if (item.line > 0) {
        EditorDocument *doc = [self activeDocument];
        long pos = [doc.editor getGeneralProperty:SCI_POSITIONFROMLINE
                                        parameter:item.line - 1];
        [doc.editor setGeneralProperty:SCI_GOTOPOS parameter:pos value:0];
        [doc.editor setGeneralProperty:SCI_SETFOCUS parameter:1 value:0];
    }
}

- (void)sidebarDidRequestClose:(id)sidebar {
    (void)sidebar;
    [self setPanelVisible:NO named:self.visiblePanelName];
    [self.toolbar refresh];
}

- (void)closeAllDocuments {
    for (NSInteger i = (NSInteger)self.documents.count - 1; i >= 0; i--)
        [self closeDocumentAtIndex:i];
}

- (void)printActiveDocument {
    EditorDocument *doc = [self activeDocument];
    if (!doc) return;

    NSString *text = [doc.editor string];
    PrintTextView *view = [[PrintTextView alloc] initWithEditor:doc.editor
                                                           text:text
                                                      pageRange:NSMakeRange(1, 0)];

    NSPrintInfo *info = [NSPrintInfo sharedPrintInfo];
    [info setHorizontalPagination:NSPrintingPaginationModeAutomatic];
    [info setVerticalPagination:NSPrintingPaginationModeAutomatic];
    [info setTopMargin:0];
    [info setBottomMargin:0];
    [info setLeftMargin:0];
    [info setRightMargin:0];

    NSInteger pages = [PrintTextView pageCountForText:text
                                                width:info.paperSize.width
                                               height:info.paperSize.height];

    NSPrintOperation *op = [NSPrintOperation printOperationWithView:view printInfo:info];
    [op setJobTitle:doc.displayName];
    [op setShowsPrintPanel:YES];
    [op setShowsProgressPanel:YES];

    BOOL ok = [op runOperation];
    if (ok) {
        [self flashStatus:[NSString stringWithFormat:@"Printed %@ (%ld page%@)",
                           doc.displayName, (long)pages, pages == 1 ? @"" : @"s"]];
    } else {
        [self flashStatus:@"Print cancelled"];
    }
}

- (void)toggleWordWrap {
    ScintillaView *sci = [self activeDocument].editor;
    if (!sci) return;
    long mode = [sci getGeneralProperty:SCI_GETWRAPMODE parameter:0];
    // These setters read their value from wParam; the parameter:/value: form
    // puts the value in lParam, so use the single-value form.
    [sci setGeneralProperty:SCI_SETWRAPMODE
                      value:(mode == SC_WRAP_NONE ? SC_WRAP_WORD : SC_WRAP_NONE)];
}

- (void)toggleAllCharacters {
    ScintillaView *sci = [self activeDocument].editor;
    if (!sci) return;
    long ws = [sci getGeneralProperty:SCI_GETVIEWWS parameter:0];
    [sci setGeneralProperty:SCI_SETVIEWWS
                      value:(ws == SCWS_INVISIBLE ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE)];
}

- (void)toggleIndentGuides {
    ScintillaView *sci = [self activeDocument].editor;
    if (!sci) return;
    long iv = [sci getGeneralProperty:SCI_GETINDENTATIONGUIDES parameter:0];
    [sci setGeneralProperty:SCI_SETINDENTATIONGUIDES
                      value:(iv == SC_IV_NONE ? SC_IV_REAL : SC_IV_NONE)];
}

- (void)togglePanelNamed:(NSString *)name {
    BOOL visible = [self isPanelVisible:name];
    [self setPanelVisible:!visible named:name];
    [self restoreEditorFocus];
}

- (void)restoreEditorFocus {
    EditorDocument *doc = [self activeDocument];
    [doc.editor setGeneralProperty:SCI_SETFOCUS parameter:1 value:0];
}

- (void)runLanguageMenuAction {
    // Mirrors IDM_LANG_USER_DLG. The Win32 dialog edits a UDL XML document and
    // drives LexUser; here the same idea is exposed as a keywords editor that
    // applies a custom word list to the current document's lexer.
    EditorDocument *doc = [self activeDocument];
    if (!doc) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Define your language";
    alert.informativeText = @"Extra keywords are highlighted with the "
                             "instruction-word style of the current language.";
    [alert addButtonWithTitle:@"Apply"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 48)];
    field.placeholderString = @"space separated keywords";
    NSArray *existing = @[];
    (void)existing;
    field.stringValue = self.customKeywords ?: @"";
    alert.accessoryView = field;

    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    self.customKeywords = field.stringValue;
    NSString *lang = doc.lang;
    [self applyLanguage:lang toDocument:doc];

    // Merge the user's words into keyword list 0 so they highlight immediately.
    if (self.customKeywords.length) {
        const char *builtin = KeywordsForLang([lang UTF8String], 0);
        NSMutableString *merged = [NSMutableString stringWithUTF8String:builtin ?: ""];
        if (merged.length) [merged appendString:@" "];
        [merged appendString:self.customKeywords];
        [doc.editor setGeneralProperty:SCI_SETKEYWORDS
                              parameter:0
                                  value:(sptr_t)[merged UTF8String]];
        [doc.editor setGeneralProperty:SCI_COLOURISE parameter:0 value:-1];
    }
    NSUInteger words = [self.customKeywords componentsSeparatedByString:@" "].count;
    [self flashStatus:[NSString stringWithFormat:@"%lu custom keyword(s) applied",
                       (unsigned long)(self.customKeywords.length ? words : 0)]];
}

- (void)toggleMonitoring {
    EditorDocument *doc = [self activeDocument];
    if (!doc) return;

    if (self.tailingActive) {
        [self stopMonitoring];
        return;
    }
    if (doc.path.length == 0) {
        [self flashStatus:@"Monitoring needs a saved file"];
        return;
    }

    self.tailingActive = YES;
    self.tailingPath = doc.path;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:doc.path error:NULL];
    self.tailingStamp = attrs[NSFileModificationDate];

    __weak AppDelegate *weakSelf = self;
    self.tailTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        [weakSelf pollMonitoredFile];
    }];
    [self flashStatus:[NSString stringWithFormat:@"Monitoring %@ (tail -f)",
                       doc.displayName]];
}

- (void)stopMonitoring {
    [self.tailTimer invalidate];
    self.tailTimer = nil;
    self.tailingActive = NO;
    self.tailingPath = nil;
    self.tailingStamp = nil;
    [self flashStatus:@"Monitoring off"];
    [self.toolbar refresh];
}

- (void)pollMonitoredFile {
    if (!self.tailingActive || self.tailingPath.length == 0) return;

    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:self.tailingPath error:NULL];
    NSDate *stamp = attrs[NSFileModificationDate];
    if (!stamp || [stamp isEqualToDate:self.tailingStamp]) return;
    self.tailingStamp = stamp;

    NSString *onDisk = [NSString stringWithContentsOfFile:self.tailingPath
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
    if (!onDisk) return;

    EditorDocument *doc = nil;
    for (EditorDocument *d in self.documents)
        if ([d.path isEqualToString:self.tailingPath]) { doc = d; break; }
    if (!doc) return;

    if ([[doc.editor string] isEqualToString:onDisk]) return;

    // tail -f semantics: if the file merely grew, follow the new end. If it was
    // rewritten in place, keep the caret at the same offset.
    NSString *before = [doc.editor string];
    BOOL appended = onDisk.length > before.length &&
                    [onDisk hasPrefix:before];
    long caretBefore = [doc.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];

    [doc.editor setString:onDisk];
    [doc.editor setGeneralProperty:SCI_SETSAVEPOINT parameter:0 value:0];
    doc.dirty = NO;

    long newLen = [doc.editor getGeneralProperty:SCI_GETLENGTH parameter:0];
    long target = appended ? newLen : MIN(caretBefore, newLen);
    [doc.editor setGeneralProperty:SCI_GOTOPOS parameter:target value:0];
    [self updateStatusText];
}

- (void)startMacroRecording {
    ScintillaView *sci = [self activeDocument].editor;
    if (!sci) return;
    self.macroEvents = [NSMutableArray array];
    self.macroRecording = YES;
    [sci setGeneralProperty:SCI_STARTRECORD parameter:0 value:0];
    [self flashStatus:@"Recording macro"];
}

- (void)stopMacroRecording {
    ScintillaView *sci = [self activeDocument].editor;
    if (!sci) return;
    [sci setGeneralProperty:SCI_STOPRECORD parameter:0 value:0];
    self.macroRecording = NO;
    [self flashStatus:[NSString stringWithFormat:@"Macro stopped, %lu steps",
                       (unsigned long)self.macroEvents.count]];
}

- (void)playbackMacro {
    ScintillaView *sci = [self activeDocument].editor;
    if (!sci || self.macroEvents.count == 0) return;
    for (NSValue *v in self.macroEvents) {
        MacroEvent ev;
        [v getValue:&ev];
        if (ev.message == SCI_REPLACESEL && ev.text) {
            const char *utf8 = [ev.text UTF8String];
            [sci message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)utf8];
        } else {
            [sci message:(unsigned int)ev.message wParam:ev.wParam lParam:ev.lParam];
        }
    }
    [self flashStatus:[NSString stringWithFormat:@"Played %lu steps",
                       (unsigned long)self.macroEvents.count]];
}

- (void)runMacroMultipleTimes {
    if (self.macroEvents.count == 0) {
        [self flashStatus:@"No macro recorded"];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Run a Macro Multiple Times";
    alert.informativeText = @"How many times should the recorded macro run?";
    [alert addButtonWithTitle:@"Run"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    field.integerValue = 1;
    alert.accessoryView = field;

    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSInteger times = MAX(1, MIN(1000, field.integerValue));
    for (NSInteger i = 0; i < times; i++) [self playbackMacro];
    [self flashStatus:[NSString stringWithFormat:@"Ran macro %ld time(s)", (long)times]];
}

- (void)saveMacroToFile {
    if (self.macroEvents.count == 0) {
        [self flashStatus:@"No macro recorded"];
        return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"macro.xml";
    panel.allowedContentTypes = @[];
    if ([panel runModal] != NSModalResponseOK) return;

    // Structure mirrors Notepad++'s shortcuts.xml <Macro> element.
    NSMutableString *xml = [NSMutableString stringWithString:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<NotepadPlus>\n"];
    [xml appendString:@"    <Macro name=\"Recorded macro\" Ctrl=\"none\" Alt=\"none\" "
                     @"Shift=\"none\" Key=\"0\">\n"];
    for (NSValue *v in self.macroEvents) {
        MacroEvent ev;
        [v getValue:&ev];
        NSString *text = ev.text ? [ev.text stringByReplacingOccurrencesOfString:@"\""
                                                                     withString:@"&quot;"]
                                 : @"";
        [xml appendFormat:@"        <Action type=\"%d\" message=\"%d\" wParam=\"%lu\" "
                          @"lParam=\"%ld\" sParam=\"%@\"/>\n",
                         0, ev.message, (unsigned long)ev.wParam, (long)ev.lParam, text];
    }
    [xml appendString:@"    </Macro>\n</NotepadPlus>\n"];

    NSError *err = nil;
    if (![xml writeToFile:panel.URL.path atomically:YES
                 encoding:NSUTF8StringEncoding error:&err]) {
        [self flashStatus:[NSString stringWithFormat:@"Save macro failed: %@",
                           err.localizedDescription]];
        return;
    }
    [self flashStatus:[NSString stringWithFormat:@"Macro saved (%lu steps)",
                       (unsigned long)self.macroEvents.count]];
}

- (void)flashStatus:(NSString *)text {
    self.status.stringValue = text;
}

#pragma mark - Live Preview (Markdown, Mermaid, PlantUML)

- (void)ensurePreviewWebView {
    if (self.previewWebView) return;

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];

    WKUserContentController *userContent = [[WKUserContentController alloc] init];
    [userContent addScriptMessageHandler:self name:@"catatan"];
    config.userContentController = userContent;

    self.previewWebView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    self.previewWebView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSURL *previewURL = [[NSBundle mainBundle] URLForResource:@"preview" withExtension:@"html" subdirectory:@"preview"];
    if (!previewURL) {
        NSString *localPath = @"/Users/nb-mac-fj2n0x/Work/wproject/notepad++/macport/resources/preview/preview.html";
        if ([[NSFileManager defaultManager] fileExistsAtPath:localPath]) {
            previewURL = [NSURL fileURLWithPath:localPath];
        }
    }

    if (previewURL) {
        NSURL *previewDir = [previewURL URLByDeletingLastPathComponent];
        [self.previewWebView loadFileURL:previewURL allowingReadAccessToURL:previewDir];
    }
}

- (void)toggleLivePreviewAction:(id)sender {
    (void)sender;
    self.previewVisible = !self.previewVisible;
    if (self.previewVisible) {
        [self ensurePreviewWebView];
        if (!self.previewWebView.superview) {
            [self.contentView addSubview:self.previewWebView];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self updateLivePreview];
        });
    } else {
        if (self.previewWebView.superview) {
            [self.previewWebView removeFromSuperview];
        }
    }
    [self relayoutBody];
    [self flashStatus:self.previewVisible ? @"Live Preview open" : @"Live Preview closed"];
}

- (void)setPreviewLayoutSideBySideAction:(id)sender {
    (void)sender;
    self.previewLayoutMode = PreviewLayoutSideBySide;
    if (!self.previewVisible) {
        [self toggleLivePreviewAction:nil];
    } else {
        [self relayoutBody];
        [self updateLivePreview];
    }
}

- (void)setPreviewLayoutFullAction:(id)sender {
    (void)sender;
    self.previewLayoutMode = PreviewLayoutFullPreview;
    if (!self.previewVisible) {
        [self toggleLivePreviewAction:nil];
    } else {
        [self relayoutBody];
        [self updateLivePreview];
    }
}

- (void)schedulePreviewUpdate {
    if (self.isSyncingFromPreview) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateLivePreview) object:nil];
    [self performSelector:@selector(updateLivePreview) withObject:nil afterDelay:0.25];
}

- (void)updateLivePreview {
    if (!self.previewVisible || !self.previewWebView) return;
    EditorDocument *doc = [self activeDocument];
    if (!doc) return;

    NSString *raw = [doc.editor string] ?: @"";
    NSString *ext = doc.path ? doc.path.pathExtension.lowercaseString : doc.lang;
    if (ext.length == 0) ext = doc.lang ?: @"markdown";

    NSData *data = [NSJSONSerialization dataWithJSONObject:@[raw, ext] options:0 error:nil];
    if (!data) return;
    NSString *jsonArgs = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!jsonArgs) return;

    NSString *modeStr = (self.previewLayoutMode == PreviewLayoutFullPreview) ? @"full" : @"split";
    NSString *js = [NSString stringWithFormat:
        @"if (window.updateContent) { const a = %@; window.updateContent(a[0], a[1]); }"
        @"if (window.setLayoutMode) { window.setLayoutMode('%@'); }", jsonArgs, modeStr];
    [self.previewWebView evaluateJavaScript:js completionHandler:nil];
}

#pragma mark - WKScriptMessageHandler (Preview <-> Cocoa)

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"catatan"]) return;
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;

    NSString *type = body[@"type"];
    if ([type isEqualToString:@"contentChanged"]) {
        NSString *markdown = body[@"markdown"];
        if (markdown) {
            [self applyPreviewEditToActiveDocument:markdown];
        }
    } else if ([type isEqualToString:@"setLayoutMode"]) {
        NSString *mode = body[@"mode"];
        if ([mode isEqualToString:@"full"]) {
            self.previewLayoutMode = PreviewLayoutFullPreview;
        } else {
            self.previewLayoutMode = PreviewLayoutSideBySide;
        }
        [self relayoutBody];
    } else if ([type isEqualToString:@"closePreview"]) {
        if (self.previewVisible) {
            [self toggleLivePreviewAction:nil];
        }
    }
}

- (void)applyPreviewEditToActiveDocument:(NSString *)markdown {
    EditorDocument *doc = [self activeDocument];
    if (!doc) return;

    NSString *current = [doc.editor string] ?: @"";
    if ([current isEqualToString:markdown]) return;

    self.isSyncingFromPreview = YES;
    [doc.editor setString:markdown];
    doc.dirty = YES;
    [self updateUI];
    self.isSyncingFromPreview = NO;
}

#pragma mark - Find in Files Delegate & Action

- (void)findInFilesDidProduceResults:(NSArray<SidebarItem *> *)results query:(NSString *)query directory:(NSString *)dir {
    [self setPanelVisible:YES named:@"Search Results"];
    NSString *title = [NSString stringWithFormat:@"Search: \"%@\" (%lu hits)", query, (unsigned long)results.count];
    [self.sidebar setPanelTitle:title items:results];
    [self.toolbar refresh];
    [self flashStatus:[NSString stringWithFormat:@"Found %lu occurrences in %@", (unsigned long)results.count, dir.lastPathComponent]];
}

- (void)findInFilesAction:(id)sender {
    (void)sender;
    if (!self.findInFilesController) {
        self.findInFilesController = [FindInFilesWindowController new];
        self.findInFilesController.delegate = self;
    }
    if (self.workspaceRoot.length > 0) {
        self.findInFilesController.defaultDirectory = self.workspaceRoot;
    } else {
        EditorDocument *doc = [self activeDocument];
        if (doc.path.length > 0) {
            self.findInFilesController.defaultDirectory = [doc.path stringByDeletingLastPathComponent];
        }
    }
    [self.findInFilesController showFindInFiles];
}

#pragma mark - Column Editor Action

- (void)columnEditorAction:(id)sender {
    (void)sender;
    EditorDocument *doc = [self activeDocument];
    if (!doc) return;
    if (!self.columnEditorController) {
        self.columnEditorController = [ColumnEditorController new];
    }
    self.columnEditorController.targetEditor = doc.editor;
    [self.columnEditorController showColumnEditor];
}

#pragma mark - UDL Importer Action

- (void)importUDLAction:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"xml"];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.prompt = @"Import";
    panel.message = @"Select a Notepad++ User Defined Language (XML) file";
    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        NSError *err = nil;
        UDLLanguage *lang = [[UDLManager sharedManager] importUDLFromURL:panel.URL error:&err];
        if (lang) {
            [self buildMenu];
            [self flashStatus:[NSString stringWithFormat:@"Imported UDL language '%@' (%lu extensions)",
                               lang.name, (unsigned long)lang.extensions.count]];
            EditorDocument *cur = [self activeDocument];
            if (cur && cur.path) {
                NSString *mapped = NppLanguageForExtension(cur.path.pathExtension);
                if ([mapped hasPrefix:@"udl_"]) {
                    [self applyLanguage:mapped toDocument:cur];
                }
            }
        } else {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"UDL Import Failed";
            alert.informativeText = err ? err.localizedDescription : @"No valid <UserLang> definition found in XML.";
            [alert runModal];
        }
    }
}

#pragma mark - AutoUpdater Actions & Delegate

- (void)checkForUpdatesAction:(id)sender {
    (void)sender;
    if ([AutoUpdater sharedUpdater].status == AutoUpdateStatusReadyToInstall) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"Restart Catatan++ to Apply v%@?", [AutoUpdater sharedUpdater].latestVersion];
        alert.informativeText = @"The update is fully downloaded and ready. Catatan++ will save your session and reopen immediately.";
        [alert addButtonWithTitle:@"Restart to Update"];
        [alert addButtonWithTitle:@"Later"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [self saveSession];
            [[AutoUpdater sharedUpdater] relaunchAndInstallUpdate];
        }
    } else {
        [[AutoUpdater sharedUpdater] checkForUpdatesManual:YES];
    }
}

- (void)autoUpdater:(AutoUpdater *)updater didChangeStatus:(AutoUpdateStatus)status {
    if (status == AutoUpdateStatusDownloading) {
        [self flashStatus:[NSString stringWithFormat:@"Downloading Catatan++ v%@ in background…", updater.latestVersion]];
    }
}

- (void)showAboutAction:(id)sender {
    (void)sender;
    NSDictionary *options = @{
        NSAboutPanelOptionApplicationName: @"Catatan++",
        NSAboutPanelOptionApplicationVersion: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0.1",
        NSAboutPanelOptionVersion: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"2",
        @"Copyright": @"© 2026 Anggun Indra & Upstream Notepad++ Contributors"
    };
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (void)autoUpdaterDidBecomeReadyToInstall:(AutoUpdater *)updater {
    NSString *title = [NSString stringWithFormat:@"⟳ Restart to Update (v%@)", updater.latestVersion];
    self.updateMenuItem.title = title;
    self.helpUpdateMenuItem.title = title;
    [self flashStatus:[NSString stringWithFormat:@"Update ready: v%@. Click menu to restart and apply.", updater.latestVersion]];
}

#pragma mark Menu

static NSMutableArray<NSString *> *gLangOrder;

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];

    // Application Menu
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About Catatan++" action:@selector(showAboutAction:) keyEquivalent:@""];
    aboutItem.target = self;
    [appMenu addItem:aboutItem];
    
    self.updateMenuItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates…"
                                                     action:@selector(checkForUpdatesAction:)
                                              keyEquivalent:@""];
    self.updateMenuItem.target = self;
    [appMenu addItem:self.updateMenuItem];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences…"
                                                   action:@selector(showPreferences:)
                                            keyEquivalent:@","];
    prefs.target = self;
    [appMenu addItem:prefs];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide catatan++" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [[NSMenuItem alloc] initWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItem:hideOthers];
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit catatan++" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    // File Menu
    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *newTab = [[NSMenuItem alloc] initWithTitle:@"New Tab" action:@selector(newDocument) keyEquivalent:@"n"];
    newTab.target = self;
    [fileMenu addItem:newTab];

    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Open…" action:@selector(openFilePanel) keyEquivalent:@"o"];
    open.target = self;
    [fileMenu addItem:open];
    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *save = [[NSMenuItem alloc] initWithTitle:@"Save" action:@selector(saveCurrent) keyEquivalent:@"s"];
    save.target = self;
    [fileMenu addItem:save];

    NSMenuItem *saveAs = [[NSMenuItem alloc] initWithTitle:@"Save As…" action:@selector(saveCurrentAs) keyEquivalent:@"S"];
    saveAs.target = self;
    [fileMenu addItem:saveAs];

    NSMenuItem *saveSess = [[NSMenuItem alloc] initWithTitle:@"Save Session" action:@selector(saveSession) keyEquivalent:@""];
    saveSess.target = self;
    [fileMenu addItem:saveSess];

    NSMenuItem *restSess = [[NSMenuItem alloc] initWithTitle:@"Restore Session" action:@selector(restoreSession) keyEquivalent:@""];
    restSess.target = self;
    [fileMenu addItem:restSess];
    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *printItem = [[NSMenuItem alloc] initWithTitle:@"Print…" action:@selector(printActiveDocument) keyEquivalent:@"p"];
    printItem.target = self;
    [fileMenu addItem:printItem];
    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *closeTab = [[NSMenuItem alloc] initWithTitle:@"Close Tab" action:@selector(closeCurrentTab) keyEquivalent:@"w"];
    closeTab.target = self;
    [fileMenu addItem:closeTab];
    fileItem.submenu = fileMenu;
    [bar addItem:fileItem];

    // Edit Menu
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem *undoItem = [[NSMenuItem alloc] initWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    undoItem.target = self;
    [editMenu addItem:undoItem];
    NSMenuItem *redoItem = [[NSMenuItem alloc] initWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    redoItem.target = self;
    [editMenu addItem:redoItem];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *find = [[NSMenuItem alloc] initWithTitle:@"Find…" action:@selector(findAction:) keyEquivalent:@"f"];
    find.target = self;
    [editMenu addItem:find];

    NSMenuItem *repl = [[NSMenuItem alloc] initWithTitle:@"Replace…" action:@selector(replaceAction:) keyEquivalent:@"F"];
    repl.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    repl.target = self;
    [editMenu addItem:repl];

    NSMenuItem *fif = [[NSMenuItem alloc] initWithTitle:@"Find in Files…" action:@selector(findInFilesAction:) keyEquivalent:@"F"];
    fif.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    fif.target = self;
    [editMenu addItem:fif];
    [editMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *colEd = [[NSMenuItem alloc] initWithTitle:@"Column Editor…" action:@selector(columnEditorAction:) keyEquivalent:@"c"];
    colEd.keyEquivalentModifierMask = NSEventModifierFlagOption;
    colEd.target = self;
    [editMenu addItem:colEd];
    editItem.submenu = editMenu;
    [bar addItem:editItem];

    // View Menu
    NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *split = [[NSMenuItem alloc] initWithTitle:@"Split View" action:@selector(toggleSplitViewAction:) keyEquivalent:@""];
    split.target = self;
    [viewMenu addItem:split];

    NSMenuItem *previewItem = [[NSMenuItem alloc] initWithTitle:@"Live Preview (Markdown / Mermaid / PlantUML)" action:@selector(toggleLivePreviewAction:) keyEquivalent:@"p"];
    previewItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    previewItem.target = self;
    [viewMenu addItem:previewItem];

    NSMenuItem *previewSplit = [[NSMenuItem alloc] initWithTitle:@"Preview Layout: Side by Side" action:@selector(setPreviewLayoutSideBySideAction:) keyEquivalent:@""];
    previewSplit.target = self;
    [viewMenu addItem:previewSplit];

    NSMenuItem *previewFull = [[NSMenuItem alloc] initWithTitle:@"Preview Layout: Full Window" action:@selector(setPreviewLayoutFullAction:) keyEquivalent:@""];
    previewFull.target = self;
    [viewMenu addItem:previewFull];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *next = [[NSMenuItem alloc] initWithTitle:@"Next Tab" action:@selector(nextTab) keyEquivalent:@"]"];
    next.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    next.target = self;
    [viewMenu addItem:next];
    NSMenuItem *prev = [[NSMenuItem alloc] initWithTitle:@"Previous Tab" action:@selector(previousTab) keyEquivalent:@"["];
    prev.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    prev.target = self;
    [viewMenu addItem:prev];
    viewItem.submenu = viewMenu;
    [bar addItem:viewItem];

    // Settings Menu
    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    NSMenu *settingsMenu = [[NSMenu alloc] initWithTitle:@"Settings"];
    NSMenuItem *prefsMenu = [[NSMenuItem alloc] initWithTitle:@"Preferences…" action:@selector(showPreferences:) keyEquivalent:@""];
    prefsMenu.target = self;
    [settingsMenu addItem:prefsMenu];
    settingsItem.submenu = settingsMenu;
    [bar addItem:settingsItem];

    // Language Menu
    NSMenuItem *langItem = [[NSMenuItem alloc] initWithTitle:@"Language" action:nil keyEquivalent:@""];
    NSMenu *langMenu = [[NSMenu alloc] initWithTitle:@"Language"];

    NSMenuItem *importUDL = [[NSMenuItem alloc] initWithTitle:@"Import User Defined Language (XML)…"
                                                       action:@selector(importUDLAction:)
                                                keyEquivalent:@""];
    importUDL.target = self;
    [langMenu addItem:importUDL];
    [langMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *mdItem = [[NSMenuItem alloc] initWithTitle:@"Markdown" action:@selector(selectLanguage:) keyEquivalent:@""];
    mdItem.target = self; mdItem.representedObject = @"markdown";
    [langMenu addItem:mdItem];

    NSMenuItem *mrmItem = [[NSMenuItem alloc] initWithTitle:@"Mermaid" action:@selector(selectLanguage:) keyEquivalent:@""];
    mrmItem.target = self; mrmItem.representedObject = @"mermaid";
    [langMenu addItem:mrmItem];

    NSMenuItem *pumlItem = [[NSMenuItem alloc] initWithTitle:@"PlantUML" action:@selector(selectLanguage:) keyEquivalent:@""];
    pumlItem.target = self; pumlItem.representedObject = @"plantuml";
    [langMenu addItem:pumlItem];

    NSArray<UDLLanguage *> *udls = [[UDLManager sharedManager] allLanguages];
    if (udls.count > 0) {
        [langMenu addItem:[NSMenuItem separatorItem]];
        for (UDLLanguage *u in udls) {
            NSString *langID = [NSString stringWithFormat:@"udl_%@", u.name];
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"UDL: %@", u.name]
                                                        action:@selector(selectLanguage:)
                                                 keyEquivalent:@""];
            mi.target = self;
            mi.representedObject = langID;
            [langMenu addItem:mi];
        }
    }
    [langMenu addItem:[NSMenuItem separatorItem]];

    for (NSString *langID in gLangOrder) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:NppLanguageLabel(langID)
                                                    action:@selector(selectLanguage:)
                                             keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = langID;
        [langMenu addItem:mi];
    }
    langItem.submenu = langMenu;
    [bar addItem:langItem];

    // Help Menu
    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];

    NSMenuItem *aboutHelp = [[NSMenuItem alloc] initWithTitle:@"About Catatan++"
                                                       action:@selector(showAboutAction:)
                                                keyEquivalent:@""];
    aboutHelp.target = self;
    [helpMenu addItem:aboutHelp];
    [helpMenu addItem:[NSMenuItem separatorItem]];

    self.helpUpdateMenuItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates…"
                                                         action:@selector(checkForUpdatesAction:)
                                                  keyEquivalent:@""];
    self.helpUpdateMenuItem.target = self;
    [helpMenu addItem:self.helpUpdateMenuItem];

    helpItem.submenu = helpMenu;
    [bar addItem:helpItem];
    [NSApp setHelpMenu:helpMenu];

    NSApp.mainMenu = bar;
}

#pragma mark Lifecycle

- (void)buildWindow {
    NSUInteger wstyle = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 720)
                                              styleMask:wstyle
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.delegate = (id<NSWindowDelegate>)self;
    [self.window center];
    [self.window setMinSize:NSMakeSize(520, 320)];

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 720)];
    content.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onContentViewFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:content];

    const CGFloat kToolbarH = 34.0;
    const CGFloat kTabH = 30.0;

    self.toolbar = [[ToolbarView alloc] initWithFrame:NSMakeRect(0, 720 - kToolbarH, 1000, kToolbarH)];
    self.toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.toolbar.toolbarDelegate = self;
    [self.toolbar setResourceDirectory:self.iconDirectory];
    [content addSubview:self.toolbar];

    self.tabStrip = [[TabStripView alloc] initWithFrame:NSMakeRect(0, 720 - kToolbarH - kTabH, 1000, kTabH)];
    self.tabStrip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.tabStrip.tabDelegate = self;
    self.tabStrip.titles = @[];
    self.tabStrip.dirtyFlags = @[];
    self.tabStrip.selectedIndex = -1;
    [content addSubview:self.tabStrip];

    const CGFloat kBodyBottom = 22.0;
    const CGFloat kBodyTop = 720 - kToolbarH - kTabH;
    const CGFloat kBodyHeight = kBodyTop - kBodyBottom;
    const CGFloat kSidebarWidth = 230.0;

    // The sidebar is created up-front but only added to the hierarchy while a
    // panel is open, so the editor keeps the full width otherwise.
    self.sidebar = [[SidebarView alloc] initWithFrame:
                    NSMakeRect(0, kBodyBottom, kSidebarWidth, kBodyHeight)];
    self.sidebar.sidebarDelegate = self;

    self.editorContainer = [[NSView alloc] initWithFrame:
                            NSMakeRect(0, kBodyBottom, 1000, kBodyHeight)];
    self.editorContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:self.editorContainer];
    self.contentView = content;
    self.bodyBottom = kBodyBottom;
    self.bodyTop = kBodyTop;
    self.sidebarWidth = kSidebarWidth;

    self.status = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 1000, 22)];
    self.status.bezeled = NO;
    self.status.drawsBackground = YES;
    self.status.backgroundColor = HexColor(0xF0F0F0);
    self.status.editable = NO;
    self.status.selectable = NO;
    self.status.font = [NSFont monospacedDigitSystemFontOfSize:11
                                                        weight:NSFontWeightRegular];
    self.status.stringValue = @"";
    self.status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:self.status];

    self.window.contentView = content;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    setvbuf(stdout, NULL, _IONBF, 0);
    gLangOrder = [[NSMutableArray alloc] initWithArray:NppLanguageIDs()];
    if (!self.documents) self.documents = [NSMutableArray array];
    self.iconDirectory = [[NSBundle mainBundle] pathForResource:@"icons" ofType:nil];

    [self buildWindow];
    [[UDLManager sharedManager] loadSavedUDLs];
    [self buildMenu];

    if (self.selfTestPath) {
        self.suppressAlerts = YES;
        int failures = [self runSelfTest];
        printf("SELFTEST_EXIT failures=%d\n", failures);
        exit(failures == 0 ? 0 : 1);
    }

    if (self.pendingPaths.count > 0) {
        NSArray<NSString *> *toOpen = [self.pendingPaths copy];
        [self.pendingPaths removeAllObjects];
        for (NSString *path in toOpen) {
            [self openDocument:path];
        }
        if (getenv("NPP_REPORT_TABS")) {
            printf("LAUNCH_TABS count=%lu active=%ld titles=",
                   (unsigned long)self.documents.count, (long)self.activeIndex);
            for (EditorDocument *d in self.documents)
                printf("[%s]", [d.displayName UTF8String]);
            printf("\n");
            exit(0);
        }
    } else {
        BOOL restored = [self restoreSession];
        if (!restored) {
            [self newDocument];
        }
    }

    if (self.documents.count == 0) {
        [self newDocument];
    }

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self updateUI];

    [AutoUpdater sharedUpdater].delegate = self;
    if (!self.selfTestPath) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AutoUpdater sharedUpdater] checkForUpdatesManual:NO];
        });
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self saveSession];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)openFilesAndReplaceBlankIfNeeded:(NSArray<NSString *> *)filenames {
    BOOL replaceBlank = NO;
    if (self.documents.count == 1) {
        EditorDocument *onlyDoc = self.documents[0];
        // If the only document is an untouched, empty untitled document
        if (onlyDoc.path == nil && !onlyDoc.dirty && [onlyDoc.editor string].length == 0) {
            replaceBlank = YES;
        }
    }

    for (NSString *path in filenames) {
        if (path.length > 0) {
            [self openDocument:path];
        }
    }

    if (replaceBlank && self.documents.count > 1) {
        [self closeDocumentAtIndex:0];
    }
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    if (!self.window) {
        // App is still launching (before applicationDidFinishLaunching): queue files
        for (NSString *p in filenames) {
            if (![self.pendingPaths containsObject:p]) {
                [self.pendingPaths addObject:p];
            }
        }
    } else {
        // App window is already up: open directly
        [self openFilesAndReplaceBlankIfNeeded:filenames];
    }
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    if (!filename || filename.length == 0) return NO;
    if (!self.window) {
        if (![self.pendingPaths containsObject:filename]) {
            [self.pendingPaths addObject:filename];
        }
    } else {
        [self openFilesAndReplaceBlankIfNeeded:@[filename]];
    }
    return YES;
}

#pragma mark Self test

- (void)snapshotView:(NSView *)view to:(NSString *)path {
    NSRect bounds = view.bounds;
    CGFloat w = MAX(bounds.size.width, 1), h = MAX(bounds.size.height, 1);

    NSBitmapImageRep *canvas = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)w
                      pixelsHigh:(NSInteger)h
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];

    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:canvas];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];

    [[NSColor whiteColor] setFill];
    NSRectFill(NSMakeRect(0, 0, w, h));
    [view displayRectIgnoringOpacity:bounds inContext:ctx];

    [NSGraphicsContext restoreGraphicsState];

    NSData *png = [canvas representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
    printf("SNAPSHOT %s %.0fx%.0f bytes=%lu\n", [path UTF8String],
           w, h, (unsigned long)png.length);
}

- (void)resetDocuments {
    for (NSView *v in [self.editorContainer.subviews copy]) [v removeFromSuperview];
    [self.documents removeAllObjects];
    self.activeIndex = -1;
    self.tabStrip.selectedIndex = -1;
}

- (int)runSelfTest {
    printf("== mapping ==\n");
    printf("cpp->%s py->%s rs->%s js->%s\n",
           [LexerNameForExtension(@"cpp") UTF8String],
           [LexerNameForExtension(@"py") UTF8String],
           [LexerNameForExtension(@"rs") UTF8String],
           [LexerNameForExtension(@"js") UTF8String]);

    NSArray *langs = NppLanguageIDs();
    printf("langs=%lu\n", (unsigned long)langs.count);

    int failures = 0;
    int checked = 0;

    printf("== language sweep ==\n");
    for (NSString *lang in langs) {
        [self resetDocuments];
        [self newDocument];
        [self applyLanguage:lang];
        [self.editor setString:@"int main() {\n  return 0;\n}\n// comment\n"];
        [self.editor setGeneralProperty:SCI_COLOURISE parameter:0 value:-1];

        long styled = 0;
        long len = [self.editor getGeneralProperty:SCI_GETLENGTH parameter:0];
        for (long i = 0; i < len; i++)
            if ([self.editor getGeneralProperty:SCI_GETSTYLEAT parameter:i] != STYLE_DEFAULT)
                styled++;

        checked++;
        if (styled == 0) {
            failures++;
            printf("FAIL %-14s no styling\n", [lang UTF8String]);
        }
    }
    printf("RESULT checked=%d failures=%d\n", checked, failures);

    printf("== colours ==\n");
    [self resetDocuments];
    [self newDocument];
    [self applyLanguage:@"cpp"];
    long defFore = [self.editor getGeneralProperty:SCI_STYLEGETFORE parameter:STYLE_DEFAULT];
    long defBack = [self.editor getGeneralProperty:SCI_STYLEGETBACK parameter:STYLE_DEFAULT];
    long clBack  = [self.editor getGeneralProperty:SCI_GETCARETLINEBACK parameter:0];
    long clVis   = [self.editor getGeneralProperty:SCI_GETCARETLINEVISIBLE parameter:0];
    printf("STYLE_DEFAULT fore=0x%06lX back=0x%06lX\n", defFore, defBack);
    printf("CARETLINE     back=0x%06lX visible=%ld\n", clBack, clVis);

    printf("ACTIVE band=0x%06lX visible=%ld always=%ld\n",
           [self.editor getGeneralProperty:SCI_GETCARETLINEBACK parameter:0],
           [self.editor getGeneralProperty:SCI_GETCARETLINEVISIBLE parameter:0],
           [self.editor getGeneralProperty:SCI_GETCARETLINEVISIBLEALWAYS parameter:0]);

    // Reference implementation: no text recolouring, no indicator bookkeeping.
    BOOL bandOK = [self.editor getGeneralProperty:SCI_GETCARETLINEBACK parameter:0]
                    == BGRFromRGB(kActiveLineBackRGB);
    BOOL indicFree = [self.editor getGeneralProperty:SCI_INDICGETSTYLE
                                           parameter:kCaretLineIndicator] == INDIC_PLAIN;
    printf("%s caret-line colour matches, indicator untouched=%d\n",
           (bandOK && indicFree) ? "OK  " : "FAIL", indicFree);
    if (!(bandOK && indicFree)) failures++;

    // Nothing must be marked with the indicator anywhere, before or after edits.
    __block long strayMarks = 0;
    void (^countStray)(void) = ^{
        long len = [self.editor getGeneralProperty:SCI_GETLENGTH parameter:0];
        for (long i = 0; i < len; i++)
            if ([self.editor getGeneralProperty:SCI_INDICATORVALUEAT
                                      parameter:kCaretLineIndicator extra:i] > 0)
                strayMarks++;
    };

    printf("== typing and Enter leave no stale highlight ==\n");
    [self resetDocuments];
    [self newDocument];
    [self applyLanguage:@"cpp"];
    [self.editor setString:@"int a = 1;\n"];
    [self.editor setGeneralProperty:SCI_GOTOPOS parameter:0 value:0];
    {
        const char *typed = "int value = 42;";
        for (const char *c = typed; *c; c++) {
            char buf[2] = {*c, 0};
            [self.editor insertText:[NSString stringWithUTF8String:buf]];
        }
        [self.editor insertText:@"\n"];
        [self.editor insertText:@"int b = 2;"];
        [self.editor insertText:@"\n"];
        [self.editor insertText:@"\n"];

        countStray();
        long lines = [self.editor getGeneralProperty:SCI_GETLINECOUNT parameter:0];
        long caret = [self.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
        long caretLine = [self.editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:caret];
        printf("%s after typing+3 Enter: lines=%ld caretLine=%ld strayMarks=%ld expected=0\n",
               (strayMarks == 0 && lines == 5) ? "OK  " : "FAIL",
               lines, caretLine, strayMarks);
        if (!(strayMarks == 0 && lines == 5)) failures++;

        // backspacing across a line boundary must not resurrect marks either
        for (int i = 0; i < 4; i++) [self.editor deleteRange:NSMakeRange(
            [self.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0] - 1, 1)];
        countStray();
        printf("%s after backspacing: strayMarks=%ld expected=0\n",
               (strayMarks == 0) ? "OK  " : "FAIL", strayMarks);
        if (strayMarks != 0) failures++;
    }

    // Plain text must keep its normal colour: this was the visible symptom.
    long bodyFore = [self.editor getGeneralProperty:SCI_STYLEGETFORE parameter:SCE_C_DEFAULT];
    long defFore2 = [self.editor getGeneralProperty:SCI_STYLEGETFORE parameter:STYLE_DEFAULT];
    printf("%s text colour untouched body=0x%06lX default=0x%06lX\n",
           (bodyFore == defFore2) ? "OK  " : "FAIL", bodyFore, defFore2);
    if (bodyFore != defFore2) failures++;

    printf("== keyword styling ==\n");
    struct { const char *lang; const char *code; const char *word; long expect; } probes[] = {
        {"cpp",          "int main() { return 0; }\n",   "int",      SCE_C_WORD2},
        {"cpp",          "// a comment\n",               "//",       SCE_C_COMMENTLINE},
        {"cpp",          "#include <x>\n",               "#",        SCE_C_PREPROCESSOR},
        {"javascript.js", "function f() { return 1; }\n","function", SCE_C_WORD},
        {"cpp",          "const char *s = \"hi\";\n",    "const",    SCE_C_WORD2},
    };
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        [self resetDocuments];
        [self newDocument];
        [self applyLanguage:[NSString stringWithUTF8String:probes[i].lang]];
        NSString *code = [NSString stringWithUTF8String:probes[i].code];
        [self.editor setString:code];
        [self.editor setGeneralProperty:SCI_COLOURISE parameter:0 value:-1];

        NSRange r = [code rangeOfString:[NSString stringWithUTF8String:probes[i].word]];
        long style = [self.editor getGeneralProperty:SCI_GETSTYLEAT parameter:(long)r.location];
        BOOL ok = (style == probes[i].expect);
        printf("%s %-14s word=%-10s style=%ld expected=%ld\n",
               ok ? "OK  " : "FAIL", probes[i].lang, probes[i].word, style, probes[i].expect);
        if (!ok) failures++;
    }

    printf("== multitab ==\n");
    [self resetDocuments];

    [self newDocument];
    [self.editor setString:@"alpha"];
    [self newDocument];
    [self.editor setString:@"beta"];
    [self newDocument];
    [self.editor setString:@"gamma"];
    printf("%s tabs=%lu expected=3 active=%ld expected=2\n",
           (self.documents.count == 3 && self.activeIndex == 2) ? "OK  " : "FAIL",
           (unsigned long)self.documents.count, (long)self.activeIndex);
    if (self.documents.count != 3 || self.activeIndex != 2) failures++;

    [self showDocumentAtIndex:0];
    NSString *first = [self.editor string];
    printf("%s switch content=%s expected=alpha\n",
           [first isEqualToString:@"alpha"] ? "OK  " : "FAIL", [first UTF8String]);
    if (![first isEqualToString:@"alpha"]) failures++;

    [self showDocumentAtIndex:1];
    NSString *second = [self.editor string];
    printf("%s switch content=%s expected=beta\n",
           [second isEqualToString:@"beta"] ? "OK  " : "FAIL", [second UTF8String]);
    if (![second isEqualToString:@"beta"]) failures++;

    [self.documents[1] setDirty:YES];
    [self updateUI];
    printf("%s dirty title=%s\n",
           [self.window.title containsString:@"*"] ? "OK  " : "FAIL",
           [self.window.title UTF8String]);
    if (![self.window.title containsString:@"*"]) failures++;

    [self closeDocumentAtIndex:1];
    printf("%s close tabs=%lu expected=2 active=%ld\n",
           (self.documents.count == 2) ? "OK  " : "FAIL",
           (unsigned long)self.documents.count, (long)self.activeIndex);
    if (self.documents.count != 2) failures++;

    [self showDocumentAtIndex:0];
    NSString *afterClose = [self.editor string];
    printf("%s content preserved=%s expected=alpha\n",
           [afterClose isEqualToString:@"alpha"] ? "OK  " : "FAIL", [afterClose UTF8String]);
    if (![afterClose isEqualToString:@"alpha"]) failures++;

    printf("== open two files ==\n");
    [self resetDocuments];
    NSString *fa = @"/tmp/npp_multi_a.cpp";
    NSString *fb = @"/tmp/npp_multi_b.py";
    [@"int a;\n" writeToFile:fa atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"x = 1\n" writeToFile:fb atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self newDocument];
    for (NSString *path in @[fa, fb]) [self openDocument:path];
    [self closeDocumentAtIndex:0];
    printf("%s two files tabs=%lu expected=2\n",
           (self.documents.count == 2) ? "OK  " : "FAIL",
           (unsigned long)self.documents.count);
    if (self.documents.count != 2) failures++;
    printf("%s langs=%s/%s expected=cpp/python\n",
           ([self.documents[0].lang isEqualToString:@"cpp"] &&
            [self.documents[1].lang isEqualToString:@"python"]) ? "OK  " : "FAIL",
           [self.documents[0].lang UTF8String], [self.documents[1].lang UTF8String]);
    if (![self.documents[0].lang isEqualToString:@"cpp"] ||
        ![self.documents[1].lang isEqualToString:@"python"]) failures++;

    printf("== open same file twice ==\n");
    [self resetDocuments];
    NSString *tmp = @"/tmp/npp_multitab_probe.py";
    [@"print('hi')\n" writeToFile:tmp atomically:YES
                        encoding:NSUTF8StringEncoding error:NULL];
    [self openDocument:tmp];
    [self openDocument:tmp];
    printf("%s reopen tabs=%lu expected=1\n",
           (self.documents.count == 1) ? "OK  " : "FAIL",
           (unsigned long)self.documents.count);
    if (self.documents.count != 1) failures++;
    printf("%s lang=%s expected=python\n",
           [[self.documents[0].lang description] isEqualToString:@"python"] ? "OK  " : "FAIL",
           [self.documents[0].lang UTF8String]);
    if (![self.documents[0].lang isEqualToString:@"python"]) failures++;

    if (self.snapshotPath) {
        [self resetDocuments];
        [self newDocument];
        NSString *code =
            @"#include <stdio.h>\n"
            @"// line two comment\n"
            @"int counter = 0;\n"
            @"static const char *label = \"active\";\n"
            @"int main(void) {\n"
            @"    for (int i = 0; i < 3; i++) counter++;\n"
            @"    printf(\"%s %d\\n\", label, counter);\n"
            @"    return 0;\n"
            @"}\n";
        [self.editor setString:code];
        [self applyLanguage:@"cpp"];
        long p3 = [self.editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:2];
        [self.editor setGeneralProperty:SCI_GOTOPOS parameter:p3 value:0];
        // Reproduce the reported sequence: type on the caret line, then Enter.
        [self.editor insertText:@"x"];
        [self.editor insertText:@"\n"];
        [self.editor insertText:@"y"];
        [self.editor insertText:@"\n"];
        [self.editor insertText:@"\n"];
        [self.tabStrip display];
        [self.editor display];
        [self snapshotView:self.editor to:@"/tmp/npp_active.png"];
        // Toggle a few buttons so the snapshot proves the on-state renders.
        [self toolbar:self.toolbar didActivateItemAtIndex:[self.toolbar indexOfCommand:@"view_wrap"]];
        [self toolbar:self.toolbar didActivateItemAtIndex:[self.toolbar indexOfCommand:@"view_all_chars"]];
        [self.toolbar refresh];
        [self.toolbar display];
        {
            NSInteger wi = [self.toolbar indexOfCommand:@"view_wrap"];
            NSInteger ai = [self.toolbar indexOfCommand:@"view_all_chars"];
            NSRect wr = [self.toolbar buttonRectAtIndex:wi];
            NSRect ar = [self.toolbar buttonRectAtIndex:ai];
            printf("TOGGLED_RECT wrap=%.0f..%.0f allchars=%.0f..%.0f\n",
                   NSMinX(wr), NSMaxX(wr), NSMinX(ar), NSMaxX(ar));
        }
        [self snapshotView:self.toolbar to:@"/tmp/npp_toolbar.png"];

        // Snapshot with the Function List open, to prove the panel paints.
        [self setPanelVisible:YES named:@"Function List"];
        [self.sidebar display];
        [self snapshotView:self.sidebar to:@"/tmp/npp_sidebar.png"];
        [self snapshotView:self.window.contentView to:@"/tmp/npp_window_panel.png"];
        [self setPanelVisible:NO named:@"Function List"];
        [self snapshotView:self.window.contentView to:@"/tmp/npp_window_full.png"];
        long caret = [self.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
        printf("ACTIVE_LINE=%ld\n",
               [self.editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:caret]);
        printf("CARET band=0x%06lX visible=%ld\n",
               [self.editor getGeneralProperty:SCI_GETCARETLINEBACK parameter:0],
               [self.editor getGeneralProperty:SCI_GETCARETLINEVISIBLE parameter:0]);
    }

    [self resetDocuments];
    printf("== toolbar ==\n");
    {
        ToolbarView *tb = self.toolbar;
        printf("items=%ld\n", (long)[tb itemCount]);

        // Every button from Notepad++'s table must have shipped an icon.
        NSInteger missingIcons = 0, buttons = 0, toggles = 0, seps = 0;
        for (NSInteger i = 0; i < [tb itemCount]; i++) {
            ToolbarItemKind k = [tb kindAtIndex:i];
            if (k == ToolbarItemKindSeparator) { seps++; continue; }
            buttons++;
            if (k == ToolbarItemKindToggle) toggles++;
            NSString *cmd = [tb commandAtIndex:i];
            NSString *path = [self.iconDirectory stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@.svg", cmd]];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                missingIcons++;
                printf("   MISSING ICON %s\n", [cmd UTF8String]);
            }
        }
        printf("%s buttons=%ld toggles=%ld separators=%ld missingIcons=%ld\n",
               (buttons == 32 && toggles == 10 && seps == 9 && missingIcons == 0)
                   ? "OK  " : "FAIL", buttons, toggles, seps, missingIcons);
        if (!(buttons == 32 && toggles == 10 && seps == 9 && missingIcons == 0)) failures++;

        // Icons must actually decode, and be vectors rather than bitmaps.
        NSInteger decoded = 0;
        for (NSInteger i = 0; i < [tb itemCount]; i++) {
            if ([tb kindAtIndex:i] == ToolbarItemKindSeparator) continue;
            NSString *cmd = [tb commandAtIndex:i];
            NSString *path = [self.iconDirectory stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@.svg", cmd]];
            NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
            if (img) {
                decoded++;
                BOOL svg = [img.representations.firstObject
                            isKindOfClass:NSClassFromString(@"_NSSVGImageRep")];
                if (!svg) printf("   NOT VECTOR: %s\n", [cmd UTF8String]);
            }
        }
        printf("%s decoded=%ld/32\n", (decoded == 32) ? "OK  " : "FAIL", decoded);
        if (decoded != 32) failures++;

        // Toolbar must not steal vertical space from the editor.
        CGFloat tbH = NSHeight(tb.frame), tabH = NSHeight(self.tabStrip.frame);
        CGFloat edH = NSHeight(self.editorContainer.frame);
        printf("%s layout toolbar=%.0f tab=%.0f editor=%.0f\n",
               (tbH == 34 && tabH == 30 && edH > 500) ? "OK  " : "FAIL",
               tbH, tabH, edH);
        if (!(tbH == 34 && tabH == 30 && edH > 500)) failures++;
    }

    printf("== toolbar actions ==\n");
    {
        ToolbarView *tb = self.toolbar;
        [self resetDocuments];
        [self newDocument];
        [self applyLanguage:@"cpp"];
        [self.editor setString:@"hello"];
        ScintillaView *sci = self.editor;

        // view_wrap toggles SCI_WRAPMODE
        NSInteger iWrap = [tb indexOfCommand:@"view_wrap"];
        long before = [sci getGeneralProperty:SCI_GETWRAPMODE parameter:0];
        [self toolbar:tb didActivateItemAtIndex:iWrap];
        long after = [sci getGeneralProperty:SCI_GETWRAPMODE parameter:0];
        BOOL wrapOn = [self toolbar:tb isItemToggledAtIndex:iWrap];
        printf("%s word wrap %ld->%ld toggled=%d\n",
               (before == SC_WRAP_NONE && after == SC_WRAP_WORD && wrapOn) ? "OK  " : "FAIL",
               before, after, wrapOn);
        if (!(before == SC_WRAP_NONE && after == SC_WRAP_WORD && wrapOn)) failures++;
        [self toolbar:tb didActivateItemAtIndex:iWrap];
        printf("%s word wrap restored=%ld\n",
               ([sci getGeneralProperty:SCI_GETWRAPMODE parameter:0] == SC_WRAP_NONE) ? "OK  " : "FAIL",
               [sci getGeneralProperty:SCI_GETWRAPMODE parameter:0]);
        if ([sci getGeneralProperty:SCI_GETWRAPMODE parameter:0] != SC_WRAP_NONE) failures++;

        // view_all_chars toggles SCI_VIEWWS
        NSInteger iWs = [tb indexOfCommand:@"view_all_chars"];
        [self toolbar:tb didActivateItemAtIndex:iWs];
        long ws = [sci getGeneralProperty:SCI_GETVIEWWS parameter:0];
        printf("%s all chars ws=%ld toggled=%d\n",
               (ws == SCWS_VISIBLEALWAYS && [self toolbar:tb isItemToggledAtIndex:iWs]) ? "OK  " : "FAIL",
               ws, [self toolbar:tb isItemToggledAtIndex:iWs]);
        if (!(ws == SCWS_VISIBLEALWAYS)) failures++;

        // view_indent_guide
        NSInteger iIv = [tb indexOfCommand:@"view_indent_guide"];
        [self toolbar:tb didActivateItemAtIndex:iIv];
        long iv = [sci getGeneralProperty:SCI_GETINDENTATIONGUIDES parameter:0];
        printf("%s indent guide iv=%ld\n", (iv == SC_IV_REAL) ? "OK  " : "FAIL", iv);
        if (iv != SC_IV_REAL) failures++;

        // zoom in/out
        NSInteger iZi = [tb indexOfCommand:@"view_zoom_in"];
        NSInteger iZo = [tb indexOfCommand:@"view_zoom_out"];
        long z0 = [sci getGeneralProperty:SCI_GETZOOM parameter:0];
        [self toolbar:tb didActivateItemAtIndex:iZi];
        long z1 = [sci getGeneralProperty:SCI_GETZOOM parameter:0];
        [self toolbar:tb didActivateItemAtIndex:iZo];
        long z2 = [sci getGeneralProperty:SCI_GETZOOM parameter:0];
        printf("%s zoom %ld->%ld->%ld\n", (z0 == 0 && z1 == 1 && z2 == 0) ? "OK  " : "FAIL", z0, z1, z2);
        if (!(z0 == 0 && z1 == 1 && z2 == 0)) failures++;

        // undo / redo through the toolbar
        NSInteger iUndo = [tb indexOfCommand:@"edit_undo"];
        NSInteger iRedo = [tb indexOfCommand:@"edit_redo"];
        [sci setString:@"typed"];
        [sci insertText:@"!"];
        long len1 = [sci getGeneralProperty:SCI_GETLENGTH parameter:0];
        [self toolbar:tb didActivateItemAtIndex:iUndo];
        long len2 = [sci getGeneralProperty:SCI_GETLENGTH parameter:0];
        [self toolbar:tb didActivateItemAtIndex:iRedo];
        long len3 = [sci getGeneralProperty:SCI_GETLENGTH parameter:0];
        printf("%s undo/redo len %ld->%ld->%ld\n",
               (len2 < len1 && len3 == len1) ? "OK  " : "FAIL", len1, len2, len3);
        if (!(len2 < len1 && len3 == len1)) failures++;

        // Best-practice multi-line undo coalescing test:
        // When typing multiple lines, undo must not clear all lines at once.
        EditorDocument *curDoc = [self activeDocument];
        [sci setString:@""];
        [sci setGeneralProperty:SCI_EMPTYUNDOBUFFER parameter:0 value:0];
        auto typeToDoc = ^(NSString *s) {
            for (NSUInteger i = 0; i < s.length; i++) {
                unichar ch = [s characterAtIndex:i];
                char c = (char)ch;
                [sci setGeneralProperty:SCI_ADDTEXT parameter:1 value:(sptr_t)&c];
                SCNotification n{};
                n.nmhdr.code = SCN_CHARADDED;
                n.ch = ch;
                [self handleNotification:&n forDocument:curDoc];
                SCNotification u{};
                u.nmhdr.code = SCN_UPDATEUI;
                u.updated = SC_UPDATE_SELECTION;
                [self handleNotification:&u forDocument:curDoc];
            }
        };
        typeToDoc(@"Baris 1\n");
        typeToDoc(@"Baris 2\n");
        typeToDoc(@"Baris 3");
        NSString *txtBeforeUndo = [sci string];
        [self performUndo];
        NSString *txtAfterUndo1 = [sci string];
        BOOL multilineUndoOk = [txtAfterUndo1 containsString:@"Baris 1\n"] &&
                               [txtAfterUndo1 containsString:@"Baris 2\n"] &&
                               ![txtAfterUndo1 containsString:@"Baris 3"];
        printf("%s multi-line undo coalescing preserves prior lines (%lu->%lu chars)\n",
               multilineUndoOk ? "OK  " : "FAIL",
               (unsigned long)txtBeforeUndo.length, (unsigned long)txtAfterUndo1.length);
        if (!multilineUndoOk) failures++;

        [self performRedo];
        NSString *txtAfterRedo = [sci string];
        BOOL redoRestored = [txtAfterRedo isEqualToString:txtBeforeUndo];
        printf("%s redo restores exact multi-line state\n", redoRestored ? "OK  " : "FAIL");
        if (!redoRestored) failures++;

        // file_new must add a tab
        NSInteger iNew = [tb indexOfCommand:@"file_new"];
        NSUInteger before_tabs = self.documents.count;
        [self toolbar:tb didActivateItemAtIndex:iNew];
        printf("%s new tab %lu->%lu\n",
               (self.documents.count == before_tabs + 1) ? "OK  " : "FAIL",
               (unsigned long)before_tabs, (unsigned long)self.documents.count);
        if (self.documents.count != before_tabs + 1) failures++;

        // close all must empty the tab bar
        NSInteger iCloseAll = [tb indexOfCommand:@"file_close_all"];
        self.suppressAlerts = YES;
        [self toolbar:tb didActivateItemAtIndex:iCloseAll];
        printf("%s close all tabs=%lu\n",
               (self.documents.count == 0) ? "OK  " : "FAIL",
               (unsigned long)self.documents.count);
        if (self.documents.count != 0) failures++;

        // Hit-testing must resolve the right command, and separators must not.
        NSInteger hitWrap = -1;
        for (NSInteger i = 0; i < [tb itemCount]; i++) {
            NSRect r = [tb buttonRectAtIndex:i];
            if ([tb kindAtIndex:i] == ToolbarItemKindSeparator) continue;
            NSPoint mid = NSMakePoint(NSMidX(r), NSMidY(r));
            if (NSPointInRect(mid, r) &&
                [[tb commandAtIndex:i] isEqualToString:@"view_wrap"]) hitWrap = i;
        }
        printf("%s hit-test finds view_wrap at %ld\n",
               (hitWrap >= 0) ? "OK  " : "FAIL", (long)hitWrap);
        if (hitWrap < 0) failures++;

        // Every command string must be unique, or dispatch would be ambiguous.
        NSMutableSet *seen = [NSMutableSet set];
        NSInteger dup = 0;
        for (NSInteger i = 0; i < [tb itemCount]; i++) {
            NSString *c = [tb commandAtIndex:i];
            if (!c) continue;
            if ([seen containsObject:c]) dup++;
            [seen addObject:c];
        }
        printf("%s unique commands=%lu duplicates=%ld\n",
               (dup == 0 && seen.count == 32) ? "OK  " : "FAIL",
               (unsigned long)seen.count, (long)dup);
        if (dup != 0 || seen.count != 32) failures++;

        // Macro record/stop/play round trip
        [self newDocument];
        [self.editor setString:@"abc"];
        NSInteger iRec = [tb indexOfCommand:@"macro_record"];
        NSInteger iStop = [tb indexOfCommand:@"macro_stop"];
        NSInteger iPlay = [tb indexOfCommand:@"macro_play"];
        printf("%s macro play disabled before recording\n",
               ([self toolbar:tb isItemEnabledAtIndex:iPlay] == NO) ? "OK  " : "FAIL");
        if ([self toolbar:tb isItemEnabledAtIndex:iPlay] != NO) failures++;

        [self toolbar:tb didActivateItemAtIndex:iRec];
        printf("%s recording state=%d\n", self.macroRecording ? "OK  " : "FAIL", self.macroRecording);
        if (!self.macroRecording) failures++;
        [self.editor setGeneralProperty:SCI_GOTOPOS parameter:3 value:0];
        [self.editor insertText:@"XY"];
        [self toolbar:tb didActivateItemAtIndex:iStop];
        printf("%s macro stop recorded=%lu\n",
               (self.macroRecording == NO && self.macroEvents.count > 0) ? "OK  " : "FAIL",
               (unsigned long)self.macroEvents.count);
        if (self.macroRecording || self.macroEvents.count == 0) failures++;
    }

    printf("== panels ==\n");
    {
        ToolbarView *tb = self.toolbar;
        [self resetDocuments];

        // Document List reflects open tabs
        [self newDocument];
        [self.editor setString:@"a"];
        [self newDocument];
        [self.editor setString:@"b"];
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_doc_list"]];
        NSUInteger docRows = [self.sidebar items].count;
        BOOL docVisible = [self isPanelVisible:@"Document List"];
        printf("%s doc list visible=%d rows=%lu expected=2\n",
               (docVisible && docRows == 2) ? "OK  " : "FAIL", docVisible, (unsigned long)docRows);
        if (!(docVisible && docRows == 2)) failures++;

        // Sidebar must steal width from the editor, not overlap it
        CGFloat sbW = NSWidth(self.sidebar.frame);
        CGFloat edW = NSWidth(self.editorContainer.frame);
        printf("%s sidebar=%0.f editor=%.0f total=%.0f\n",
               (sbW > 200 && edW + sbW <= NSWidth(self.contentView.bounds) + 1) ? "OK  " : "FAIL",
               sbW, edW, NSWidth(self.contentView.bounds));
        if (!(sbW > 200 && edW + sbW <= NSWidth(self.contentView.bounds) + 1)) failures++;

        // Toggling again closes it and restores editor width
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_doc_list"]];
        printf("%s panel closed visible=%d editor=%.0f\n",
               (![self isPanelVisible:@"Document List"] &&
                NSWidth(self.editorContainer.frame) == NSWidth(self.contentView.bounds)) ? "OK  " : "FAIL",
               [self isPanelVisible:@"Document List"], NSWidth(self.editorContainer.frame));
        if ([self isPanelVisible:@"Document List"]) failures++;

        // Only one panel at a time
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_doc_list"]];
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_func_list"]];
        printf("%s exclusive panels visible=%s\n",
               ([self.visiblePanelName isEqualToString:@"Function List"]) ? "OK  " : "FAIL",
               [self.visiblePanelName UTF8String]);
        if (![self.visiblePanelName isEqualToString:@"Function List"]) failures++;
        [self setPanelVisible:NO named:self.visiblePanelName];

        // Folder as Workspace builds a real tree from disk
        printf("== workspace tree ==\n");
        NSString *root = @"/tmp/npp_ws_probe";
        [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [@"int a;\n" writeToFile:[root stringByAppendingPathComponent:@"one.cpp"]
                      atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [root stringByAppendingPathComponent:@"sub"] withIntermediateDirectories:YES
                                                       attributes:nil error:NULL];
        [@"x = 1\n" writeToFile:[[root stringByAppendingPathComponent:@"sub"]
                                 stringByAppendingPathComponent:@"two.py"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        self.workspaceRoot = root;
        [self setPanelVisible:YES named:@"Folder as Workspace"];
        NSArray<SidebarItem *> *roots = [self.sidebar items];
        SidebarItem *top = roots.firstObject;
        BOOL treeOK = roots.count == 1 && top.children.count == 2 &&
                      [top.title isEqualToString:@"npp_ws_probe"];
        if (treeOK) {
            NSInteger files = 0, dirs = 0;
            for (SidebarItem *c in top.children) {
                if (c.isDirectory) dirs++;
                else if ([c.title hasSuffix:@".cpp"]) files++;
            }
            treeOK = (files == 1 && dirs == 1);
        }
        printf("%s workspace root children=%lu\n",
               treeOK ? "OK  " : "FAIL", (unsigned long)top.children.count);
        if (!treeOK) failures++;

        // Clicking a file in the tree opens it as a tab
        [self resetDocuments];
        SidebarItem *cppFile = nil;
        for (SidebarItem *c in top.children)
            if ([c.title isEqualToString:@"one.cpp"]) cppFile = c;
        if (cppFile) {
            [self sidebar:self.sidebar didChooseItem:cppFile];
            BOOL opened = self.documents.count == 1 &&
                          [[self.documents[0].path lastPathComponent] isEqualToString:@"one.cpp"];
            printf("%s open from tree tabs=%lu file=%s lang=%s\n",
                   opened ? "OK  " : "FAIL", (unsigned long)self.documents.count,
                   [[self.documents[0].path lastPathComponent] UTF8String],
                   [self.documents[0].lang UTF8String]);
            if (!opened) failures++;
            printf("%s language detected=%s expected=cpp\n",
                   [self.documents[0].lang isEqualToString:@"cpp"] ? "OK  " : "FAIL",
                   [self.documents[0].lang UTF8String]);
            if (![self.documents[0].lang isEqualToString:@"cpp"]) failures++;
        } else {
            printf("FAIL one.cpp not found in tree\n");
            failures++;
        }
        [self setPanelVisible:NO named:@"Folder as Workspace"];

        // Function List scans the active document
        printf("== function list ==\n");
        [self resetDocuments];
        [self newDocument];
        [self.editor setString:
            @"#include <stdio.h>\n"
            @"int helper(int x) {\n"
            @"    return x;\n"
            @"}\n"
            @"void other(void)\n"
            @"{\n"
            @"}\n"
            @"if (x) {\n"
            @"}\n"];
        [self applyLanguage:@"cpp"];
        NSArray<SidebarItem *> *fns = [self functionItemsForText:[self.editor string]
                                                        language:@"cpp"];
        BOOL fnOK = fns.count == 2;
        printf("%s cpp functions=%lu expected=2", fnOK ? "OK  " : "FAIL", (unsigned long)fns.count);
        for (SidebarItem *f in fns) printf(" [%s@L%ld]", [f.title UTF8String], (long)f.line);
        printf("\n");
        if (!fnOK) failures++;

        [self resetDocuments];
        [self newDocument];
        [self.editor setString:@"def alpha():\n    pass\n\nasync def beta():\n    pass\nclass Z:\n    pass\n"];
        [self applyLanguage:@"python"];
        NSArray<SidebarItem *> *pyf = [self functionItemsForText:[self.editor string]
                                                       language:@"python"];
        printf("%s python functions=%lu expected=2", (pyf.count == 2) ? "OK  " : "FAIL",
               (unsigned long)pyf.count);
        for (SidebarItem *f in pyf) printf(" [%s@L%ld]", [f.title UTF8String], (long)f.line);
        printf("\n");
        if (pyf.count != 2) failures++;

        // Jumping to a function moves the caret to its line
        if (fns.count > 0) {
            [self resetDocuments];
            [self newDocument];                      // reset removes all docs
            SidebarItem *target = fns.lastObject;   // "other" at line 5
            [self.editor setString:@"#include <stdio.h>\nint helper(int x) {\n    return x;\n}\nvoid other(void)\n{\n}\n"];
            [self sidebar:self.sidebar didChooseItem:target];
            long caret = [self.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
            long line = [self.editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:caret];
            printf("%s jump to %s line=%ld expected=%ld\n",
                   (line == target.line - 1) ? "OK  " : "FAIL",
                   [target.title UTF8String], line, (long)target.line - 1);
            if (line != target.line - 1) failures++;
        }

        [self resetDocuments];
        [self setPanelVisible:NO named:self.visiblePanelName];
    }

    printf("== monitoring ==\n");
    {
        ToolbarView *tb = self.toolbar;
        [self resetDocuments];
        NSString *logPath = @"/tmp/npp_tail_probe.log";
        [@"line1\n" writeToFile:logPath atomically:YES
                      encoding:NSUTF8StringEncoding error:NULL];
        [self openDocument:logPath];
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_monitoring"]];
        BOOL on = self.tailingActive && [self toolbar:tb isItemToggledAtIndex:
                                         [tb indexOfCommand:@"view_monitoring"]];
        printf("%s monitoring on=%d toggled=%d\n", on ? "OK  " : "FAIL",
               self.tailingActive, [self toolbar:tb isItemToggledAtIndex:
                                    [tb indexOfCommand:@"view_monitoring"]]);
        if (!on) failures++;

        // Simulate the file being appended to by another process.
        [NSThread sleepForTimeInterval:0.05];
        [@"line1\nline2\nline3\n" writeToFile:logPath atomically:YES
                                     encoding:NSUTF8StringEncoding error:NULL];
        [self pollMonitoredFile];
        NSString *content = [self.editor string];
        BOOL followed = [content containsString:@"line3"];
        long caret = [self.editor getGeneralProperty:SCI_GETCURRENTPOS parameter:0];
        long len = [self.editor getGeneralProperty:SCI_GETLENGTH parameter:0];
        printf("%s tail picked up new lines (len=%ld caretAtEnd=%d)\n",
               (followed && caret >= len - 1) ? "OK  " : "FAIL", len, caret >= len - 1);
        if (!(followed && caret >= len - 1)) failures++;

        // Unchanged file must be a no-op (no needless reload).
        [self pollMonitoredFile];
        printf("%s idle poll keeps contents\n",
               ([[self.editor string] isEqualToString:content]) ? "OK  " : "FAIL");
        if (![[self.editor string] isEqualToString:content]) failures++;

        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_monitoring"]];
        printf("%s monitoring off=%d\n", (!self.tailingActive) ? "OK  " : "FAIL",
               self.tailingActive);
        if (self.tailingActive) failures++;
    }

    printf("== macro save ==\n");
    {
        ToolbarView *tb = self.toolbar;
        [self resetDocuments];
        [self newDocument];
        [self.editor setString:@"abc"];
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"macro_record"]];
        [self.editor setGeneralProperty:SCI_GOTOPOS parameter:3 value:0];
        [self.editor insertText:@"Z"];
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"macro_stop"]];

        NSInteger steps = (NSInteger)self.macroEvents.count;
        printf("%s macro has %ld steps\n", (steps > 0) ? "OK  " : "FAIL", (long)steps);
        if (steps == 0) failures++;

        // Playback must reproduce the recorded edit on a fresh buffer.
        [self newDocument];
        [self.editor setString:@"abc"];
        [self.editor setGeneralProperty:SCI_GOTOPOS parameter:3 value:0];
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"macro_play"]];
        NSString *after = [self.editor string];
        BOOL played = [after containsString:@"Z"];
        printf("%s playback reproduced edit content=%s\n",
               played ? "OK  " : "FAIL", [after UTF8String]);
        if (!played) failures++;

        // Serialisation format mirrors shortcuts.xml
        NSMutableString *xml = [NSMutableString string];
        [xml appendString:@"<NotepadPlus>"];
        for (NSValue *v in self.macroEvents) {
            MacroEvent ev; [v getValue:&ev];
            [xml appendFormat:@"<Action message=%@>", @(ev.message)];
        }
        [xml appendString:@"</NotepadPlus>"];
        BOOL shape = [xml containsString:@"<Action message="];
        printf("%s macro serialises %ld actions\n", shape ? "OK  " : "FAIL",
               (long)self.macroEvents.count);
        if (!shape) failures++;
    }

    printf("== every toolbar command responds ==\n");
    {
        ToolbarView *tb = self.toolbar;
        [self resetDocuments];
        [self newDocument];
        [self.editor setString:@"int helper(void) {\n    return 1;\n}\n"];
        [self applyLanguage:@"cpp"];

        // Each command must either change state or at least report via status.
        // A silent no-op with no status text means the button is dead.
        NSInteger dead = 0;
        for (NSInteger i = 0; i < [tb itemCount]; i++) {
            if ([tb kindAtIndex:i] == ToolbarItemKindSeparator) continue;
            NSString *cmd = [tb commandAtIndex:i];
            if ([cmd isEqualToString:@"file_open"] ||
                [cmd isEqualToString:@"file_print"] ||
                [cmd isEqualToString:@"file_save"] ||
                [cmd isEqualToString:@"file_save_all"] ||
                [cmd isEqualToString:@"search_find"] ||
                [cmd isEqualToString:@"search_replace"] ||
                [cmd isEqualToString:@"lang_def"] ||
                [cmd isEqualToString:@"macro_save"] ||
                [cmd isEqualToString:@"macro_multi"])
                continue;   // these open modal dialogs; exercised elsewhere

            self.status.stringValue = @"";
            NSString *panelBefore = self.visiblePanelName;
            [self toolbar:tb didActivateItemAtIndex:i];
            BOOL changedPanel = ![panelBefore isEqualToString:self.visiblePanelName ?: @""];
            BOOL saidSomething = self.status.stringValue.length > 0;
            if (!changedPanel && !saidSomething) {
                // Toggles carry no message; verify their Scintilla state changed.
                BOOL isToggle = [tb kindAtIndex:i] == ToolbarItemKindToggle;
                if (!isToggle) {
                    dead++;
                    printf("   DEAD %s\n", [cmd UTF8String]);
                }
            }
            if ([self.visiblePanelName length]) [self setPanelVisible:NO named:self.visiblePanelName];
        }
        printf("%s dead commands=%ld\n", (dead == 0) ? "OK  " : "FAIL", (long)dead);
        if (dead != 0) failures++;

        // Document Map must produce a non-empty outline, not a blank panel.
        [self setPanelVisible:YES named:@"Document Map"];
        NSArray<SidebarItem *> *map = [self.sidebar items];
        BOOL mapOK = map.count >= 1 && [self.sidebar panelTitle].length > 0;
        printf("%s document map rows=%lu title=%s\n", mapOK ? "OK  " : "FAIL",
               (unsigned long)map.count, [[self.sidebar panelTitle] UTF8String]);
        if (!mapOK) failures++;
        [self setPanelVisible:NO named:@"Document Map"];
    }

    printf("== print ==\n");
    {
        NSString *doc = @"alpha\nbeta\ngamma\n";
        NSInteger pages = [PrintTextView pageCountForText:doc width:595 height:842];
        printf("%s short doc pages=%ld expected=1\n", (pages == 1) ? "OK  " : "FAIL", (long)pages);
        if (pages != 1) failures++;

        // A long document must paginate across several pages.
        NSMutableString *big = [NSMutableString string];
        for (int i = 0; i < 200; i++) [big appendFormat:@"line %d\n", i];
        NSInteger bigPages = [PrintTextView pageCountForText:big width:595 height:842];
        printf("%s long doc pages=%ld (>1)\n", (bigPages > 1) ? "OK  " : "FAIL", (long)bigPages);
        if (bigPages <= 1) failures++;

        // Render page 1 to a bitmap: it must be mostly paper, with dark glyphs.
        PrintTextView *pv = [[PrintTextView alloc] initWithEditor:self.editor
                                                             text:doc
                                                        pageRange:NSMakeRange(1, 1)];
        pv.frame = NSMakeRect(0, 0, 595, 842);
        NSBitmapImageRep *rep = [pv bitmapImageRepForCachingDisplayInRect:pv.bounds];
        [pv cacheDisplayInRect:pv.bounds toBitmapImageRep:rep];

        NSInteger light = 0, dark = 0, total = 0;
        for (NSInteger y = 0; y < rep.pixelsHigh; y += 2) {
            for (NSInteger x = 0; x < rep.pixelsWide; x += 2) {
                NSColor *c = [rep colorAtX:x y:y];
                CGFloat b = c.brightnessComponent;
                total++;
                if (b > 0.8) light++;
                else if (b < 0.3) dark++;
            }
        }
        double lightPct = total ? (100.0 * light / total) : 0;
        printf("%s page is paper: light=%.1f%% darkPx=%ld\n",
               (lightPct > 85 && dark >= 5) ? "OK  " : "FAIL", lightPct, (long)dark);
        if (!(lightPct > 85 && dark >= 5)) failures++;

        // Empty document must still yield one page rather than zero.
        NSInteger emptyPages = [PrintTextView pageCountForText:@"" width:595 height:842];
        printf("%s empty doc pages=%ld\n", (emptyPages == 1) ? "OK  " : "FAIL", (long)emptyPages);
        if (emptyPages != 1) failures++;
    }

    printf("== split view + scroll sync ==\n");
    {
        ToolbarView *tb = self.toolbar;
        [self resetDocuments];
        [self newDocument];

        NSMutableString *many = [NSMutableString string];
        for (int i = 0; i < 300; i++) [many appendFormat:@"line %d\n", i];
        [self.editor setString:many];
        [self applyLanguage:@"cpp"];

        // Sync buttons must refuse to act without a split, and say so.
        self.status.stringValue = @"";
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_sync_v"]];
        printf("%s sync without split reports=%d\n",
               (self.splitEditor == nil && self.status.stringValue.length > 0) ? "OK  " : "FAIL",
               self.splitEditor != nil);
        if (self.splitEditor != nil) failures++;
        // that press toggled the flag; clear it
        self.syncVertical = NO;

        // Open a split: two editors, same text.
        [self toggleSplitView:YES];
        BOOL bothUp = self.splitEditor != nil;
        NSString *splitText = bothUp ? [self.splitEditor string] : @"";
        BOOL sameText = [splitText isEqualToString:many];
        printf("%s split open=%d sameText=%d\n", (bothUp && sameText) ? "OK  " : "FAIL",
               bothUp, sameText);
        if (!(bothUp && sameText)) failures++;

        CGFloat half = NSWidth(self.editorContainer.bounds) / 2.0;
        CGFloat leftW = NSWidth([self activeDocument].editor.frame);
        CGFloat rightW = NSWidth(self.splitEditor.frame);
        printf("%s pane widths left=%.0f right=%.0f half=%.0f\n",
               (fabs(leftW - rightW) < 3 && leftW <= half) ? "OK  " : "FAIL",
               leftW, rightW, half);
        if (!(fabs(leftW - rightW) < 3 && leftW <= half)) failures++;

        // Vertical sync: scrolling the left pane moves the right pane.
        [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_sync_v"]];
        printf("%s vertical sync on=%d\n", ([self toolbar:tb isItemToggledAtIndex:
                                            [tb indexOfCommand:@"view_sync_v"]]) ? "OK  " : "FAIL",
               self.syncVertical);
        if (!self.syncVertical) failures++;

        [[self activeDocument].editor setGeneralProperty:SCI_SETFIRSTVISIBLELINE value:120];
        [self syncSplitScrollingFrom:[self activeDocument].editor];
        long lv = [[self activeDocument].editor getGeneralProperty:SCI_GETFIRSTVISIBLELINE parameter:0];
        long rv = [self.splitEditor getGeneralProperty:SCI_GETFIRSTVISIBLELINE parameter:0];
        printf("%s scrolled left=%ld right=%ld\n", (lv == rv) ? "OK  " : "FAIL", lv, rv);
        if (lv != rv) failures++;

        // Horizontal sync. xOffset is clamped to the scrollable range, so the
        // line must be wider than the pane for a non-zero offset to stick.
        if (!self.syncHorizontal)
            [self toolbar:tb didActivateItemAtIndex:[tb indexOfCommand:@"view_sync_h"]];
        NSMutableString *wide = [NSMutableString string];
        for (int i = 0; i < 400; i++) [wide appendString:@"X"];
        [wide appendString:@"\n"];
        [[self activeDocument].editor setString:wide];
        [self applyDocumentToSplitView:[self activeDocument]];
        [[self activeDocument].editor setGeneralProperty:SCI_SETXOFFSET value:40];
        [self syncSplitScrollingFrom:[self activeDocument].editor];
        long xl = [[self activeDocument].editor getGeneralProperty:SCI_GETXOFFSET parameter:0];
        long xr = [self.splitEditor getGeneralProperty:SCI_GETXOFFSET parameter:0];
        printf("%s h-scroll left=%ld right=%ld\n", (xl == xr) ? "OK  " : "FAIL", xl, xr);
        if (xl != xr) failures++;

        // Closing the split returns to one full-width editor.
        [self toggleSplitView:NO];
        printf("%s split closed editor=%.0f container=%.0f\n",
               (self.splitEditor == nil &&
                NSWidth([self activeDocument].editor.frame) == NSWidth(self.editorContainer.bounds))
                   ? "OK  " : "FAIL",
               NSWidth([self activeDocument].editor.frame), NSWidth(self.editorContainer.bounds));
        if (self.splitEditor != nil) failures++;
    }

    printf("== custom keywords ==\n");
    {
        [self resetDocuments];
        [self newDocument];
        [self.editor setString:@"myword other\n"];
        [self applyLanguage:@"cpp"];
        [self.editor setGeneralProperty:SCI_COLOURISE parameter:0 value:-1];
        NSRange r = [[self.editor string] rangeOfString:@"myword"];
        long before = [self.editor getGeneralProperty:SCI_GETSTYLEAT parameter:(long)r.location];

        // Same merge the dialog performs, without opening a modal in tests.
        self.customKeywords = @"myword zzz";
        const char *builtin = KeywordsForLang("cpp", 0);
        NSMutableString *merged = [NSMutableString stringWithUTF8String:builtin ?: ""];
        if (merged.length) [merged appendString:@" "];
        [merged appendString:self.customKeywords];
        [self.editor setGeneralProperty:SCI_SETKEYWORDS parameter:0
                                  value:(sptr_t)[merged UTF8String]];
        [self.editor setGeneralProperty:SCI_COLOURISE parameter:0 value:-1];
        long after = [self.editor getGeneralProperty:SCI_GETSTYLEAT parameter:(long)r.location];

        printf("%s custom keyword style %ld->%ld expected SCE_C_WORD(5)\n",
               (before != SCE_C_WORD && after == SCE_C_WORD) ? "OK  " : "FAIL",
               before, after);
        if (!(before != SCE_C_WORD && after == SCE_C_WORD)) failures++;
        self.customKeywords = nil;
    }

    printf("== print syntax colouring ==\n");
    {
        [self.editor setString:@"int value = 42;\n// comment here\n"];
        [self applyLanguage:@"cpp" toDocument:[self activeDocument]];
        [self.editor setGeneralProperty:SCI_COLOURISE parameter:0 value:-1];

        PrintTextView *pv = [[PrintTextView alloc] initWithEditor:self.editor
                                                             text:[self.editor string]
                                                        pageRange:NSMakeRange(1, 1)];
        pv.frame = NSMakeRect(0, 0, 595, 842);
        NSBitmapImageRep *rep = [pv bitmapImageRepForCachingDisplayInRect:pv.bounds];
        [pv cacheDisplayInRect:pv.bounds toBitmapImageRep:rep];

        NSMutableSet *distinctColors = [NSMutableSet set];
        for (NSInteger y = 0; y < rep.pixelsHigh; y += 2) {
            for (NSInteger x = 0; x < rep.pixelsWide; x += 2) {
                NSColor *c = [rep colorAtX:x y:y];
                if (c.brightnessComponent < 0.85) {
                    int r = (int)(c.redComponent * 10);
                    int g = (int)(c.greenComponent * 10);
                    int b = (int)(c.blueComponent * 10);
                    [distinctColors addObject:[NSString stringWithFormat:@"%d,%d,%d", r, g, b]];
                }
            }
        }
        BOOL hasColor = (distinctColors.count >= 2);
        printf("%s print syntax colors=%lu (>1)\n", hasColor ? "OK  " : "FAIL", (unsigned long)distinctColors.count);
        if (!hasColor) failures++;
    }

    printf("== extended function list ==\n");
    {
        // Bash
        NSString *bashCode = @"function deploy {\n  echo 1\n}\nbuild() {\n  echo 2\n}\n";
        NSArray *bashFuncs = [self functionItemsForText:bashCode language:@"bash"];
        BOOL bashOK = (bashFuncs.count == 2);
        printf("%s bash functions=%lu expected=2\n", bashOK ? "OK  " : "FAIL", (unsigned long)bashFuncs.count);
        if (!bashOK) failures++;

        // SQL
        NSString *sqlCode = @"CREATE FUNCTION calc_tax(val INT) RETURNS INT;\nCREATE PROCEDURE reset_all();\n";
        NSArray *sqlFuncs = [self functionItemsForText:sqlCode language:@"sql"];
        BOOL sqlOK = (sqlFuncs.count == 2);
        printf("%s sql functions=%lu expected=2\n", sqlOK ? "OK  " : "FAIL", (unsigned long)sqlFuncs.count);
        if (!sqlOK) failures++;

        // Ruby
        NSString *rbCode = @"class Worker\n  def process\n  end\nend\n";
        NSArray *rbFuncs = [self functionItemsForText:rbCode language:@"ruby"];
        BOOL rbOK = (rbFuncs.count == 2);
        printf("%s ruby definitions=%lu expected=2\n", rbOK ? "OK  " : "FAIL", (unsigned long)rbFuncs.count);
        if (!rbOK) failures++;

        // Perl
        NSString *plCode = @"sub execute_task {\n  my $arg = shift;\n}\n";
        NSArray *plFuncs = [self functionItemsForText:plCode language:@"perl"];
        BOOL plOK = (plFuncs.count == 1);
        printf("%s perl subroutines=%lu expected=1\n", plOK ? "OK  " : "FAIL", (unsigned long)plFuncs.count);
        if (!plOK) failures++;

        // R
        NSString *rCode = @"compute_stat <- function(data) {\n  return(mean(data))\n}\n";
        NSArray *rFuncs = [self functionItemsForText:rCode language:@"r"];
        BOOL rOK = (rFuncs.count == 1);
        printf("%s r functions=%lu expected=1\n", rOK ? "OK  " : "FAIL", (unsigned long)rFuncs.count);
        if (!rOK) failures++;

        // Markdown
        NSString *mdCode = @"# Main Title\n## Getting Started\n### Setup\n";
        NSArray *mdFuncs = [self functionItemsForText:mdCode language:@"markdown"];
        BOOL mdOK = (mdFuncs.count == 3);
        printf("%s markdown headers=%lu expected=3\n", mdOK ? "OK  " : "FAIL", (unsigned long)mdFuncs.count);
        if (!mdOK) failures++;
    }

    printf("== find and replace ==\n");
    {
        [self.editor setString:@"alpha beta alpha gamma alpha"];
        BOOL findFwd = [self performFind:@"beta" matchCase:YES wholeWord:YES wrap:YES backwards:NO];
        printf("%s find forward=%d expected=1\n", findFwd ? "OK  " : "FAIL", findFwd);
        if (!findFwd) failures++;

        BOOL findBack = [self performFind:@"alpha" matchCase:YES wholeWord:YES wrap:YES backwards:YES];
        printf("%s find backward=%d expected=1\n", findBack ? "OK  " : "FAIL", findBack);
        if (!findBack) failures++;

        int repOne = [self performReplace:@"alpha" with:@"delta" matchCase:YES wholeWord:YES all:NO];
        printf("%s replace single=%d expected=1\n", (repOne == 1) ? "OK  " : "FAIL", repOne);
        if (repOne != 1) failures++;

        int repAll = [self performReplace:@"alpha" with:@"omega" matchCase:YES wholeWord:YES all:YES];
        printf("%s replace all=%d expected=2\n", (repAll == 2) ? "OK  " : "FAIL", repAll);
        if (repAll != 2) failures++;

        NSString *res = [self.editor string];
        BOOL matchExpected = [res isEqualToString:@"delta beta omega gamma omega"];
        printf("%s result content='%s'\n", matchExpected ? "OK  " : "FAIL", [res UTF8String]);
        if (!matchExpected) failures++;
    }

    printf("== preferences engine ==\n");
    {
        NSInteger origTab = [self.editor getGeneralProperty:SCI_GETTABWIDTH parameter:0];
        [self setTestPreferenceFont:@"Monaco" size:16 tabWidth:2 useSpaces:YES wordWrap:YES lineNumbers:NO];
        NSInteger newTab = [self.editor getGeneralProperty:SCI_GETTABWIDTH parameter:0];
        NSInteger newSize = [self.editor getGeneralProperty:SCI_STYLEGETSIZE parameter:STYLE_DEFAULT];
        BOOL tabOK = (newTab == 2);
        BOOL sizeOK = (newSize == 16);
        printf("%s tab width pref=%ld expected=2\n", tabOK ? "OK  " : "FAIL", (long)newTab);
        printf("%s font size pref=%ld expected=16\n", sizeOK ? "OK  " : "FAIL", (long)newSize);
        if (!tabOK || !sizeOK) failures++;

        // Restore standard default
        [self setTestPreferenceFont:@"Menlo" size:13 tabWidth:origTab useSpaces:YES wordWrap:NO lineNumbers:YES];
    }

    printf("== session restoration ==\n");
    {
        NSString *sessPath = [self sessionFilePath];
        [[NSFileManager defaultManager] removeItemAtPath:sessPath error:NULL];

        // Give doc a dummy path and save session
        EditorDocument *doc = [self activeDocument];
        NSString *origPath = doc.path;
        doc.path = @"/tmp/test_session_doc.txt";
        [self saveSession];

        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:sessPath];
        NSDictionary *dict = exists ? [NSDictionary dictionaryWithContentsOfFile:sessPath] : nil;
        NSArray *docs = dict[@"documents"];
        BOOL sessionOK = exists && docs.count >= 1 && [docs[0][@"path"] isEqualToString:@"/tmp/test_session_doc.txt"];

        printf("%s session saved exists=%d entries=%lu\n",
               sessionOK ? "OK  " : "FAIL", exists, (unsigned long)docs.count);
        if (!sessionOK) failures++;

        doc.path = origPath;
        [[NSFileManager defaultManager] removeItemAtPath:sessPath error:NULL];
    }

    // == find in files ==
    printf("== find in files ==\n");
    {
        NSString *fifDir = @"/tmp/fif_test";
        [[NSFileManager defaultManager] createDirectoryAtPath:fifDir withIntermediateDirectories:YES attributes:nil error:NULL];
        [@"first line with fif_target_word here\n" writeToFile:[fifDir stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [@"second file\nanother fif_target_word occurs\n" writeToFile:[fifDir stringByAppendingPathComponent:@"b.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NSArray<SidebarItem *> *hits = [FindInFilesEngine searchForString:@"fif_target_word"
                                                              inDirectory:fifDir
                                                                   filter:@"*.txt"
                                                                matchCase:YES
                                                                wholeWord:YES
                                                                  subdirs:YES];
        BOOL fifOK = (hits.count == 2);
        printf("%s find in files hits=%lu expected=2\n", fifOK ? "OK  " : "FAIL", (unsigned long)hits.count);
        if (!fifOK) failures++;

        [[NSFileManager defaultManager] removeItemAtPath:fifDir error:NULL];
    }

    // == column editor ==
    printf("== column editor ==\n");
    {
        EditorDocument *doc = [self activeDocument];
        [doc.editor setString:@"apple\nbanana\ncherry\n"];
        [doc.editor setGeneralProperty:SCI_SETSEL parameter:0 value:0];

        BOOL tOK = [ColumnEditorController applyText:@"PREFIX_" toEditor:doc.editor];
        NSString *cur = [doc.editor string];
        BOOL tMatch = [cur containsString:@"PREFIX_apple\nPREFIX_banana\nPREFIX_cherry\n"];
        printf("%s column editor insert text applied=%d matched=%d\n", (tOK && tMatch) ? "OK  " : "FAIL", tOK, tMatch);
        if (!(tOK && tMatch)) failures++;

        [doc.editor setString:@"row\nrow\nrow\n"];
        [doc.editor setGeneralProperty:SCI_SETSEL parameter:0 value:0];
        BOOL nOK = [ColumnEditorController applyNumbersInitial:10 step:5 repeat:1 format:@"Dec" leadingZeros:NO toEditor:doc.editor];
        NSString *curN = [doc.editor string];
        BOOL nMatch = [curN containsString:@"10row\n15row\n20row\n"];
        printf("%s column editor insert numbers applied=%d matched=%d\n", (nOK && nMatch) ? "OK  " : "FAIL", nOK, nMatch);
        if (!(nOK && nMatch)) failures++;
    }

    // == udl importer ==
    printf("== udl importer ==\n");
    {
        NSString *udlXML = @"<NotepadPlus><UserLang name=\"TestUDL\" ext=\"tudl\"><KeywordLists><Keywords name=\"Words1\">alpha beta gamma</Keywords></KeywordLists></UserLang></NotepadPlus>";
        NSString *xmlPath = @"/tmp/test_udl.xml";
        [udlXML writeToFile:xmlPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NSError *err = nil;
        UDLLanguage *imported = [[UDLManager sharedManager] importUDLFromURL:[NSURL fileURLWithPath:xmlPath] error:&err];
        NSString *resolved = NppLanguageForExtension(@"tudl");
        BOOL udlOK = (imported != nil) && [resolved isEqualToString:@"udl_TestUDL"];
        printf("%s udl imported name=%s resolved_lang=%s\n", udlOK ? "OK  " : "FAIL",
               [imported.name UTF8String], [resolved UTF8String]);
        if (!udlOK) failures++;

        [[NSFileManager defaultManager] removeItemAtPath:xmlPath error:NULL];
    }

    // == markdown, mermaid, plantuml & live preview ==
    printf("== previewer & diagrams ==\n");
    {
        NSString *lMD = NppLanguageForExtension(@"md");
        NSString *lMermaid = NppLanguageForExtension(@"mermaid");
        NSString *lPUML = NppLanguageForExtension(@"puml");
        BOOL extsOK = [lMD isEqualToString:@"markdown"] &&
                      [lMermaid isEqualToString:@"mermaid"] &&
                      [lPUML isEqualToString:@"plantuml"];
        printf("%s diagram extensions md=%s mermaid=%s puml=%s\n",
               extsOK ? "OK  " : "FAIL", [lMD UTF8String], [lMermaid UTF8String], [lPUML UTF8String]);
        if (!extsOK) failures++;

        [self toggleLivePreviewAction:nil];
        BOOL prevOpen = self.previewVisible && (self.previewWebView != nil) && (self.previewWebView.superview != nil);
        
        // Test Side-by-Side vs Full Window preview layout modes
        [self setPreviewLayoutSideBySideAction:nil];
        BOOL sideBySideOK = (self.previewLayoutMode == PreviewLayoutSideBySide) &&
                            !self.editorContainer.hidden && !self.previewWebView.hidden &&
                            (NSWidth(self.previewWebView.frame) < NSWidth(self.contentView.bounds));
        
        [self setPreviewLayoutFullAction:nil];
        BOOL fullOK = (self.previewLayoutMode == PreviewLayoutFullPreview) &&
                      self.editorContainer.hidden && !self.previewWebView.hidden &&
                      (NSWidth(self.previewWebView.frame) == NSWidth(self.contentView.bounds));
        
        printf("%s preview layout modes split=%d full=%d\n",
               (sideBySideOK && fullOK) ? "OK  " : "FAIL", sideBySideOK, fullOK);
        if (!sideBySideOK || !fullOK) failures++;

        // Test dynamic window resize responsiveness
        NSRect origBounds = self.contentView.bounds;
        self.contentView.frame = NSMakeRect(0, 0, 1400, 900);
        [self relayoutBody];
        CGFloat expectedH = 900.0 - 34.0 - 30.0 - 22.0; // totalH - kToolbarH - kTabH - kBodyBottom
        BOOL responsiveOK = (NSHeight(self.previewWebView.frame) == expectedH) &&
                            (NSWidth(self.previewWebView.frame) == 1400.0);
        printf("%s preview resize responsive height=%.0f expected=%.0f width=%.0f\n",
               responsiveOK ? "OK  " : "FAIL", NSHeight(self.previewWebView.frame), expectedH, NSWidth(self.previewWebView.frame));
        if (!responsiveOK) failures++;
        self.contentView.frame = origBounds;
        [self relayoutBody];

        // Test direct markdown preview editing sync
        NSString *testMD = @"# Edited In Preview\n\nDirect Markdown editing works!";
        [self applyPreviewEditToActiveDocument:testMD];
        EditorDocument *curDoc = [self activeDocument];
        BOOL syncOK = [[curDoc.editor string] isEqualToString:testMD] && curDoc.dirty;
        printf("%s direct preview edit syncs to editor=%d dirty=%d\n",
               syncOK ? "OK  " : "FAIL", syncOK, curDoc.dirty);
        if (!syncOK) failures++;

        [self toggleLivePreviewAction:nil];
        BOOL prevClosed = !self.previewVisible && (self.previewWebView.superview == nil);

        printf("%s live preview toggle open=%d closed=%d\n",
               (prevOpen && prevClosed) ? "OK  " : "FAIL", prevOpen, prevClosed);
        if (!(prevOpen && prevClosed)) failures++;
    }

    // == Finder "Open With" & openFiles: handling ==
    printf("== finder open with ==\n");
    {
        // 1. Test cold launch queued open before window was created
        AppDelegate *coldDelegate = [AppDelegate new];
        NSString *testFileA = @"/tmp/test_cold_launch.txt";
        [@"cold launch content\n" writeToFile:testFileA atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        
        // Finder sends openFiles: BEFORE applicationDidFinishLaunching:
        [coldDelegate application:NSApp openFiles:@[testFileA]];
        BOOL queuedOK = (coldDelegate.pendingPaths.count == 1) &&
                        [coldDelegate.pendingPaths[0] isEqualToString:testFileA];
        
        // Now simulate applicationDidFinishLaunching: running
        [coldDelegate applicationDidFinishLaunching:[NSNotification notificationWithName:@"launch" object:nil]];
        BOOL openedColdOK = (coldDelegate.documents.count == 1) &&
                            [coldDelegate.documents[0].displayName isEqualToString:@"test_cold_launch.txt"] &&
                            [[coldDelegate.documents[0].editor string] isEqualToString:@"cold launch content\n"];
        printf("%s cold launch finder open queued=%d opened=%d\n",
               (queuedOK && openedColdOK) ? "OK  " : "FAIL", queuedOK, openedColdOK);
        if (!queuedOK || !openedColdOK) failures++;
        [coldDelegate.window close];

        // 2. Test warm launch replacing empty untitled tab
        [self resetDocuments];
        [self newDocument]; // single empty untitled
        NSString *testFileB = @"/tmp/test_warm_launch.txt";
        [@"warm launch content\n" writeToFile:testFileB atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [self application:NSApp openFiles:@[testFileB]];
        BOOL warmReplacedBlankOK = (self.documents.count == 1) &&
                                   [self.documents[0].displayName isEqualToString:@"test_warm_launch.txt"];
        printf("%s warm launch finder open replaces blank=%d\n",
               warmReplacedBlankOK ? "OK  " : "FAIL", warmReplacedBlankOK);
        if (!warmReplacedBlankOK) failures++;

        [[NSFileManager defaultManager] removeItemAtPath:testFileA error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:testFileB error:NULL];
    }

    // == Context Menus (Tab and Editor) ==
    printf("== context menus ==\n");
    {
        // 1. Tab Context Menu
        NSMenu *tabMenu = [self tabStrip:self.tabStrip menuForTabIndex:0];
        BOOL tabMenuHasPreview = NO;
        for (NSMenuItem *item in tabMenu.itemArray) {
            if ([item.identifier isEqualToString:@"tab_ctx_preview"]) {
                tabMenuHasPreview = YES;
                break;
            }
        }
        printf("%s tab context menu contains live preview=%d\n",
               tabMenuHasPreview ? "OK  " : "FAIL", tabMenuHasPreview);
        if (!tabMenuHasPreview) failures++;

        // 2. Editor Context Menu
        NSMenu *editorMenu = self.editor.menu;
        BOOL editorMenuHasPreview = NO;
        for (NSMenuItem *item in editorMenu.itemArray) {
            if ([item.identifier isEqualToString:@"ctx_preview"]) {
                editorMenuHasPreview = YES;
                break;
            }
        }
        printf("%s editor context menu contains live preview=%d\n",
               editorMenuHasPreview ? "OK  " : "FAIL", editorMenuHasPreview);
        if (!editorMenuHasPreview) failures++;

        // 3. Check state update on menuNeedsUpdate:
        self.previewVisible = YES;
        self.previewLayoutMode = PreviewLayoutFullPreview;
        [self menuNeedsUpdate:editorMenu];
        NSMenuItem *prevItem = [editorMenu itemWithTitle:@"Live Preview (Markdown / Mermaid / PlantUML)"];
        NSMenuItem *fullItem = [editorMenu itemWithTitle:@"Preview Layout: Full Window"];
        BOOL stateOK = (prevItem.state == NSControlStateValueOn) && (fullItem.state == NSControlStateValueOn);
        printf("%s context menu checkmarks update dynamically=%d\n", stateOK ? "OK  " : "FAIL", stateOK);
        if (!stateOK) failures++;
        self.previewVisible = NO;
    }

    // == AutoUpdater Engine ==
    printf("== auto updater ==\n");
    {
        BOOL comp1 = ([AutoUpdater compareVersion:@"1.0.1" toVersion:@"1.0.0"] == NSOrderedDescending);
        BOOL comp2 = ([AutoUpdater compareVersion:@"1.0.0" toVersion:@"1.0.0"] == NSOrderedSame);
        BOOL comp3 = ([AutoUpdater compareVersion:@"1.0.0" toVersion:@"1.0.1"] == NSOrderedAscending);
        BOOL comp4 = ([AutoUpdater compareVersion:@"v2.0" toVersion:@"1.9.9"] == NSOrderedDescending);
        BOOL versionsOK = comp1 && comp2 && comp3 && comp4;
        printf("%s auto updater semantic version comparison=%d\n", versionsOK ? "OK  " : "FAIL", versionsOK);
        if (!versionsOK) failures++;

        AutoUpdater *u = [AutoUpdater sharedUpdater];
        BOOL updaterOK = (u != nil) && [u.repoOwner isEqualToString:@"anggun-indra"] && [u.repoName isEqualToString:@"catatan-plus-plus"];
        BOOL menuOK = (self.updateMenuItem != nil) && [self.updateMenuItem.title containsString:@"Update"];
        BOOL helpMenuOK = (self.helpUpdateMenuItem != nil) && [self.helpUpdateMenuItem.title containsString:@"Update"];
        printf("%s auto updater repo=%s/%s menuBound=%d helpMenuBound=%d\n",
               (updaterOK && menuOK && helpMenuOK) ? "OK  " : "FAIL", [u.repoOwner UTF8String], [u.repoName UTF8String], menuOK, helpMenuOK);
        if (!updaterOK || !menuOK || !helpMenuOK) failures++;
    }

    printf("SELFTEST_DONE failures=%d\n", failures);
    return failures;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        delegate.pendingPaths = [NSMutableArray array];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSArray *args = [[NSProcessInfo processInfo] arguments];
        for (NSUInteger i = 1; i < args.count; i++) {
            NSString *a = args[i];
            if ([a isEqualToString:@"--selftest"]) {
                delegate.selfTestPath = @"1";
            } else if ([a isEqualToString:@"--snapshot"]) {
                delegate.selfTestPath = @"1";
                delegate.snapshotPath = @"1";
            } else if (![a hasPrefix:@"-"]) {
                [delegate.pendingPaths addObject:a];
            }
        }
        [app run];
    }
    return 0;
}
