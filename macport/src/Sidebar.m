#import "Sidebar.h"

@implementation SidebarItem
+ (instancetype)itemWithTitle:(NSString *)title {
    SidebarItem *i = [SidebarItem new];
    i.title = title;
    i.line = -1;
    return i;
}

+ (instancetype)itemWithTitle:(NSString *)title detail:(NSString *)detail line:(NSInteger)line {
    SidebarItem *i = [self itemWithTitle:title];
    i.detail = detail;
    i.line = line;
    return i;
}
@end

static const CGFloat kHeaderHeight = 26.0;
static const CGFloat kRowHeight = 20.0;

@interface SidebarView () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (nonatomic, strong) NSTextField *header;
@property (nonatomic, strong) NSButton *closeButton;
@property (nonatomic, strong) NSOutlineView *outline;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, copy) NSArray<SidebarItem *> *rootItems;
@property (nonatomic, copy) NSString *title;
@end

@implementation SidebarView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.header = [[NSTextField alloc] initWithFrame:NSMakeRect(10, frame.size.height - kHeaderHeight + 5,
                                                                frame.size.width - 40, 16)];
    self.header.bezeled = NO;
    self.header.drawsBackground = NO;
    self.header.editable = NO;
    self.header.selectable = NO;
    self.header.font = [NSFont boldSystemFontOfSize:11];
    self.header.textColor = [NSColor secondaryLabelColor];
    self.header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:self.header];

    self.closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 26,
                                                                  frame.size.height - kHeaderHeight + 3,
                                                                  18, 18)];
    self.closeButton.bezelStyle = NSBezelStyleInline;
    self.closeButton.bordered = NO;
    self.closeButton.title = @"✕";
    self.closeButton.font = [NSFont systemFontOfSize:11];
    self.closeButton.target = self;
    self.closeButton.action = @selector(closeTapped:);
    self.closeButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self addSubview:self.closeButton];

    self.outline = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width,
                                                                   frame.size.height - kHeaderHeight)];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.width = frame.size.width;
    [self.outline addTableColumn:col];
    self.outline.outlineTableColumn = col;
    self.outline.headerView = nil;
    self.outline.rowHeight = kRowHeight;
    self.outline.dataSource = self;
    self.outline.delegate = self;
    self.outline.floatsGroupRows = NO;
    self.outline.focusRingType = NSFocusRingTypeNone;
    self.outline.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width,
                                                                 frame.size.height - kHeaderHeight)];
    self.scroll.documentView = self.outline;
    self.scroll.hasVerticalScroller = YES;
    self.scroll.drawsBackground = YES;
    self.scroll.backgroundColor = [NSColor controlBackgroundColor];
    self.scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:self.scroll];

    self.autoresizingMask = NSViewHeightSizable;
    return self;
}

- (BOOL)isFlipped { return NO; }

- (NSString *)panelTitle { return self.title; }

- (NSArray<SidebarItem *> *)items { return self.rootItems ?: @[]; }

- (void)setPanelTitle:(NSString *)title items:(NSArray<SidebarItem *> *)items {
    self.title = title;
    self.header.stringValue = title.uppercaseString;
    self.rootItems = items ?: @[];
    [self.outline reloadData];
    [self.outline expandItem:nil expandChildren:YES];
}

- (void)closeTapped:(id)sender {
    [self.sidebarDelegate sidebarDidRequestClose:self];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(self.bounds);

    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight, 1, kHeaderHeight));
    NSRectFill(NSMakeRect(NSMaxX(self.bounds) - 1, 0, 1, NSMaxY(self.bounds)));
    NSRectFill(NSMakeRect(0, NSMaxY(self.bounds) - 1, NSMaxX(self.bounds), 1));
}

#pragma mark Outline data

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return (NSInteger)self.rootItems.count;
    return (NSInteger)((SidebarItem *)item).children.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return self.rootItems[index];
    return ((SidebarItem *)item).children[index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return ((SidebarItem *)item).children.count > 0;
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    SidebarItem *row = item;
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, col.width, kRowHeight)];
        cell.identifier = @"cell";
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(2, 1, col.width - 4, 16)];
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.editable = NO;
        label.selectable = NO;
        label.font = [NSFont systemFontOfSize:11];
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        label.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:label];
        cell.textField = label;
    }
    NSString *text = row.title;
    if (row.detail.length) {
        cell.textField.stringValue = [NSString stringWithFormat:@"%@  %@", text, row.detail];
    } else {
        cell.textField.stringValue = text;
    }
    cell.textField.textColor = row.isDirectory ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)note {
    NSInteger row = self.outline.selectedRow;
    if (row < 0) return;
    SidebarItem *item = [self.outline itemAtRow:row];
    if (item) [self.sidebarDelegate sidebar:self didChooseItem:item];
}

@end
