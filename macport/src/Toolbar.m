#import "Toolbar.h"

static const CGFloat kToolbarHeight = 34.0;
static const CGFloat kButtonSize = 26.0;
static const CGFloat kIconSize = 18.0;
static const CGFloat kGap = 2.0;
static const CGFloat kSeparatorWidth = 9.0;

typedef struct {
    const char *slug;       // icon file name in icons/
    const char *tooltip;    // Notepad++ english.xml wording
    ToolbarItemKind kind;
    const char *command;    // action key used by the delegate
} ToolbarItem;

// Order and grouping copied from Notepad++ toolBarIcons[].
// Tooltips use the strings from PowerEditor/installer/nativeLang/english.xml.
static const ToolbarItem kItems[] = {
    {"file_new",          "New",                          ToolbarItemKindButton,    "file_new"},
    {"file_open",         "Open...",                      ToolbarItemKindButton,    "file_open"},
    {"file_save",         "Save",                         ToolbarItemKindButton,    "file_save"},
    {"file_save_all",     "Save All",                     ToolbarItemKindButton,    "file_save_all"},
    {"file_close",        "Close",                        ToolbarItemKindButton,    "file_close"},
    {"file_close_all",    "Close All",                    ToolbarItemKindButton,    "file_close_all"},
    {"file_print",        "Print...",                     ToolbarItemKindButton,    "file_print"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"edit_cut",          "Cut",                          ToolbarItemKindButton,    "edit_cut"},
    {"edit_copy",         "Copy",                         ToolbarItemKindButton,    "edit_copy"},
    {"edit_paste",        "Paste",                        ToolbarItemKindButton,    "edit_paste"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"edit_undo",         "Undo",                         ToolbarItemKindButton,    "edit_undo"},
    {"edit_redo",         "Redo",                         ToolbarItemKindButton,    "edit_redo"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"search_find",       "Find...",                      ToolbarItemKindButton,    "search_find"},
    {"search_replace",    "Replace...",                   ToolbarItemKindButton,    "search_replace"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"view_zoom_in",      "Zoom In",                      ToolbarItemKindButton,    "view_zoom_in"},
    {"view_zoom_out",     "Zoom Out",                     ToolbarItemKindButton,    "view_zoom_out"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"view_sync_v",       "Synchronize Vertical Scrolling", ToolbarItemKindToggle,  "view_sync_v"},
    {"view_sync_h",       "Synchronize Horizontal Scrolling", ToolbarItemKindToggle,"view_sync_h"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"view_wrap",         "Word wrap",                    ToolbarItemKindToggle,    "view_wrap"},
    {"view_all_chars",    "Show All Characters",          ToolbarItemKindToggle,    "view_all_chars"},
    {"view_indent_guide", "Show Indent Guide",            ToolbarItemKindToggle,    "view_indent_guide"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"lang_def",          "Define your language...",      ToolbarItemKindButton,    "lang_def"},
    {"view_doc_map",      "Toggle Document Map",          ToolbarItemKindToggle,    "view_doc_map"},
    {"view_doc_list",     "Toggle Document List",         ToolbarItemKindToggle,    "view_doc_list"},
    {"view_func_list",    "Toggle Function List",         ToolbarItemKindToggle,    "view_func_list"},
    {"view_file_browser", "Toggle Folder as Workspace",   ToolbarItemKindToggle,    "view_file_browser"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"view_monitoring",   "Monitoring (tail -f)",         ToolbarItemKindToggle,    "view_monitoring"},
    {NULL,                NULL,                           ToolbarItemKindSeparator, NULL},

    {"macro_record",      "Start Recording",              ToolbarItemKindButton,    "macro_record"},
    {"macro_stop",        "Stop Recording",               ToolbarItemKindButton,    "macro_stop"},
    {"macro_play",        "Playback",                     ToolbarItemKindButton,    "macro_play"},
    {"macro_multi",       "Run a Macro Multiple Times...", ToolbarItemKindButton,   "macro_multi"},
    {"macro_save",        "Save Currently Recorded Macro...", ToolbarItemKindButton, "macro_save"},
};

static const NSInteger kItemCount = (NSInteger)(sizeof(kItems) / sizeof(kItems[0]));

@implementation ToolbarView {
    NSMutableArray<NSValue *> *_rects;      // one per item, NSZeroRect for separators
    NSMutableArray *_icons;
    NSMutableArray *_whiteIcons;
    NSInteger _hoverIndex;
    NSInteger _pressedIndex;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _rects = [NSMutableArray array];
        _icons = [NSMutableArray array];
        _whiteIcons = [NSMutableArray array];
        _hoverIndex = -1;
        _pressedIndex = -1;
        for (NSInteger i = 0; i < kItemCount; i++) {
            [_icons addObject:[NSNull null]];
            [_whiteIcons addObject:[NSNull null]];
        }
        [self setAutoresizingMask:NSViewWidthSizable];
        [self addTrackingArea:[[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                          NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
                   owner:self
                userInfo:nil]];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setResourceDirectory:(NSString *)dir {
    _resourceDirectory = [dir copy];
    for (NSInteger i = 0; i < kItemCount; i++) {
        [_icons replaceObjectAtIndex:i withObject:[NSNull null]];
        [_whiteIcons replaceObjectAtIndex:i withObject:[NSNull null]];
    }
    [self refresh];
}

- (NSImage *)iconAtIndex:(NSInteger)index {
    id cached = _icons[index];
    if (cached != [NSNull null]) return cached;

    NSImage *image = nil;
    const char *slug = kItems[index].slug;
    if (slug && self.resourceDirectory) {
        NSString *path = [self.resourceDirectory
            stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.svg", slug]];
        image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image) {
            [image setTemplate:YES];   // tint with the system label colour
            image.size = NSMakeSize(kIconSize, kIconSize);
        }
    }
    _icons[index] = image ?: (id)[NSNull null];
    return image;
}

- (NSImage *)whiteIconAtIndex:(NSInteger)index {
    id cached = _whiteIcons[index];
    if (cached != [NSNull null]) return cached;

    NSImage *base = [self iconAtIndex:index];
    if (!base) return nil;

    NSImage *whiteIcon = [NSImage imageWithSize:base.size flipped:YES drawingHandler:^BOOL(NSRect dstRect) {
        [base drawInRect:dstRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        [[NSColor whiteColor] setFill];
        NSRectFillUsingOperation(dstRect, NSCompositingOperationSourceAtop);
        return YES;
    }];
    [whiteIcon setTemplate:NO];
    _whiteIcons[index] = whiteIcon;
    return whiteIcon;
}

- (void)recomputeLayout {
    [_rects removeAllObjects];
    CGFloat x = 8;
    CGFloat y = (kToolbarHeight - kButtonSize) / 2.0;

    for (NSInteger i = 0; i < kItemCount; i++) {
        if (kItems[i].kind == ToolbarItemKindSeparator) {
            [_rects addObject:[NSValue valueWithRect:NSMakeRect(x, 7, kSeparatorWidth, kToolbarHeight - 14)]];
            x += kSeparatorWidth;
        } else {
            [_rects addObject:[NSValue valueWithRect:NSMakeRect(x, y, kButtonSize, kButtonSize)]];
            x += kButtonSize + kGap;
        }
    }
}

- (void)rebuildToolTips {
    [self removeAllToolTips];
    for (NSInteger i = 0; i < kItemCount; i++) {
        if (kItems[i].kind == ToolbarItemKindSeparator || !kItems[i].tooltip) continue;
        [self addToolTipRect:_rects[i].rectValue
                       owner:self
                    userData:(void *)(intptr_t)i];
    }
}

- (void)refresh {
    [self recomputeLayout];
    [self rebuildToolTips];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(self.bounds);

    // Bottom hairline, as in a native toolbar.
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(0, NSMaxY(self.bounds) - 1, self.bounds.size.width, 1));

    [self recomputeLayout];

    for (NSInteger i = 0; i < kItemCount; i++) {
        NSRect r = _rects[i].rectValue;

        if (kItems[i].kind == ToolbarItemKindSeparator) {
            [[NSColor separatorColor] setFill];
            NSRectFill(NSMakeRect(NSMidX(r), NSMinY(r) + 2, 1, r.size.height - 4));
            continue;
        }

        BOOL enabled = [self.toolbarDelegate toolbar:self isItemEnabledAtIndex:i];
        BOOL toggled = (kItems[i].kind == ToolbarItemKindToggle) &&
                       [self.toolbarDelegate toolbar:self isItemToggledAtIndex:i];

        if (toggled) {
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1)
                                                             xRadius:5 yRadius:5];
            [[NSColor controlAccentColor] setFill];
            [p fill];
        } else if (i == _pressedIndex) {
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1)
                                                             xRadius:5 yRadius:5];
            [[NSColor quaternaryLabelColor] setFill];
            [p fill];
        } else if (i == _hoverIndex) {
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1)
                                                             xRadius:5 yRadius:5];
            [[NSColor unemphasizedSelectedContentBackgroundColor] setFill];
            [p fill];
        }

        NSImage *icon = [self iconAtIndex:i];
        if (!icon) continue;

        NSRect iconRect = NSMakeRect(NSMidX(r) - kIconSize / 2,
                                     NSMidY(r) - kIconSize / 2,
                                     kIconSize, kIconSize);

        if (!enabled) {
            NSImage *dimmed = [icon copy];
            [dimmed setTemplate:YES];
            [dimmed drawInRect:iconRect
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:0.3
                respectFlipped:YES
                         hints:nil];
            continue;
        }

        // Toggled buttons get a crisp white glyph against the accent fill.
        if (toggled) {
            NSImage *whiteIcon = [self whiteIconAtIndex:i];
            if (whiteIcon) {
                [whiteIcon drawInRect:iconRect
                             fromRect:NSZeroRect
                            operation:NSCompositingOperationSourceOver
                             fraction:1.0
                       respectFlipped:YES
                                hints:nil];
            }
            continue;
        }

        [icon drawInRect:iconRect
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0
          respectFlipped:YES
                   hints:nil];
    }
}

- (NSInteger)indexAtPoint:(NSPoint)p {
    [self recomputeLayout];
    for (NSInteger i = 0; i < kItemCount; i++) {
        if (NSPointInRect(p, _rects[i].rectValue)) return i;
    }
    return -1;
}

- (void)updateHover:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:p];
    if (idx >= 0 && kItems[idx].kind == ToolbarItemKindSeparator) idx = -1;
    if (idx != _hoverIndex) {
        _hoverIndex = idx;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseEntered:(NSEvent *)event { [self updateHover:event]; }
- (void)mouseMoved:(NSEvent *)event { [self updateHover:event]; }

- (void)mouseExited:(NSEvent *)event {
    _hoverIndex = -1;
    _pressedIndex = -1;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:p];
    if (idx < 0 || kItems[idx].kind == ToolbarItemKindSeparator) return;

    _pressedIndex = idx;
    [self setNeedsDisplay:YES];

    // Press-and-release must stay on the same button, like a real toolbar.
    while (YES) {
        NSEvent *next = [self.window nextEventMatchingMask:
            (NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged)];
        NSPoint q = [self convertPoint:next.locationInWindow fromView:nil];
        NSInteger over = [self indexAtPoint:q];
        if (next.type == NSEventTypeLeftMouseUp) {
            _pressedIndex = -1;
            [self setNeedsDisplay:YES];
            if (over == idx) [self.toolbarDelegate toolbar:self didActivateItemAtIndex:idx];
            return;
        }
        _pressedIndex = (over == idx) ? idx : -1;
        [self setNeedsDisplay:YES];
    }
}

- (NSInteger)itemCount { return kItemCount; }

- (NSRect)buttonRectAtIndex:(NSInteger)index {
    [self recomputeLayout];
    if (index < 0 || index >= (NSInteger)_rects.count) return NSZeroRect;
    return _rects[index].rectValue;
}

- (NSString *)commandAtIndex:(NSInteger)index {
    if (index < 0 || index >= kItemCount || !kItems[index].command) return nil;
    return @(kItems[index].command);
}

- (ToolbarItemKind)kindAtIndex:(NSInteger)index {
    if (index < 0 || index >= kItemCount) return ToolbarItemKindSeparator;
    return kItems[index].kind;
}

- (NSInteger)indexOfCommand:(NSString *)command {
    for (NSInteger i = 0; i < kItemCount; i++) {
        if (kItems[i].command && [command isEqualToString:@(kItems[i].command)]) return i;
    }
    return -1;
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag
             point:(NSPoint)point userData:(void *)data {
    NSInteger idx = (NSInteger)(intptr_t)data;
    if (idx < 0 || idx >= kItemCount || !kItems[idx].tooltip) return nil;
    return @(kItems[idx].tooltip);
}

- (NSToolTipTag)addToolTipRect:(NSRect)rect owner:(id)owner userData:(void *)data {
    return [super addToolTipRect:rect owner:owner userData:data];
}

@end
