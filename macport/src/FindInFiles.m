#import "FindInFiles.h"
#import <fnmatch.h>

@implementation FindInFilesEngine

+ (BOOL)filename:(NSString *)name matchesFilters:(NSArray<NSString *> *)filters {
    if (filters.count == 0) return YES;
    for (NSString *f in filters) {
        NSString *trimmed = [f stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed isEqualToString:@"*.*"] || [trimmed isEqualToString:@"*"])
            return YES;
        if (fnmatch(trimmed.UTF8String, name.UTF8String, FNM_CASEFOLD) == 0)
            return YES;
    }
    return NO;
}

+ (NSArray<SidebarItem *> *)searchForString:(NSString *)query
                                inDirectory:(NSString *)dir
                                     filter:(NSString *)filter
                                  matchCase:(BOOL)matchCase
                                  wholeWord:(BOOL)wholeWord
                                    subdirs:(BOOL)subdirs {
    NSMutableArray<SidebarItem *> *results = [NSMutableArray array];
    if (query.length == 0 || dir.length == 0) return results;

    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir)
        return results;

    NSArray<NSString *> *filters = filter.length > 0 ?
        [filter componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",;"]] :
        @[@"*.*"];

    NSDirectoryEnumerationOptions options = NSDirectoryEnumerationSkipsHiddenFiles;
    if (!subdirs) options |= NSDirectoryEnumerationSkipsSubdirectoryDescendants;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:dir]
                                 includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLNameKey]
                                                    options:options
                                               errorHandler:nil];

    NSStringCompareOptions strOpts = 0;
    if (!matchCase) strOpts |= NSCaseInsensitiveSearch;

    for (NSURL *fileURL in enumerator) {
        NSNumber *isRegular = nil;
        [fileURL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
        if (!isRegular.boolValue) continue;

        NSString *name = fileURL.lastPathComponent;
        if (![self filename:name matchesFilters:filters]) continue;

        // Skip binary or huge files (> 10MB)
        NSDictionary *attrs = [fm attributesOfItemAtPath:fileURL.path error:nil];
        if (attrs.fileSize > 10 * 1024 * 1024) continue;

        NSError *readErr = nil;
        NSString *content = [NSString stringWithContentsOfFile:fileURL.path
                                                  usedEncoding:nil
                                                         error:&readErr];
        if (!content || readErr) continue;

        NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSInteger lineIdx = 0; lineIdx < (NSInteger)lines.count; lineIdx++) {
            NSString *line = lines[lineIdx];
            if (line.length == 0) continue;

            NSRange r = [line rangeOfString:query options:strOpts];
            if (r.location != NSNotFound) {
                if (wholeWord) {
                    BOOL leftOk = (r.location == 0);
                    if (!leftOk) {
                        unichar ch = [line characterAtIndex:r.location - 1];
                        leftOk = ![[NSCharacterSet alphanumericCharacterSet] characterIsMember:ch] && ch != '_';
                    }
                    BOOL rightOk = (NSMaxRange(r) == line.length);
                    if (!rightOk) {
                        unichar ch = [line characterAtIndex:NSMaxRange(r)];
                        rightOk = ![[NSCharacterSet alphanumericCharacterSet] characterIsMember:ch] && ch != '_';
                    }
                    if (!leftOk || !rightOk) continue;
                }

                NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length > 120) trimmed = [[trimmed substringToIndex:117] stringByAppendingString:@"..."];

                SidebarItem *item = [SidebarItem itemWithTitle:trimmed
                                                        detail:[NSString stringWithFormat:@"%@ : %ld", name, (long)(lineIdx + 1)]
                                                          line:lineIdx + 1];
                item.path = fileURL.path;
                [results addObject:item];
            }
        }
    }

    return results;
}

@end

@interface FindInFilesWindowController ()
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSTextField *dirField;
@property (nonatomic, strong) NSTextField *filterField;
@property (nonatomic, strong) NSButton *matchCaseBox;
@property (nonatomic, strong) NSButton *wholeWordBox;
@property (nonatomic, strong) NSButton *subdirsBox;
@property (nonatomic, strong) NSTextField *statusLabel;
@end

@implementation FindInFilesWindowController

- (void)showFindInFiles {
    if (!self.window) {
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 260)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.title = @"Find in Files";
        [win center];

        NSView *content = win.contentView;

        // Query field
        NSTextField *lbl1 = [NSTextField labelWithString:@"Find what:"];
        lbl1.frame = NSMakeRect(20, 215, 90, 20);
        [content addSubview:lbl1];

        self.searchField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, 215, 345, 22)];
        [content addSubview:self.searchField];

        // Directory field + browse button
        NSTextField *lbl2 = [NSTextField labelWithString:@"Directory:"];
        lbl2.frame = NSMakeRect(20, 175, 90, 20);
        [content addSubview:lbl2];

        self.dirField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, 175, 255, 22)];
        if (self.defaultDirectory) self.dirField.stringValue = self.defaultDirectory;
        [content addSubview:self.dirField];

        NSButton *browseBtn = [NSButton buttonWithTitle:@"Browse…" target:self action:@selector(browseDirectory:)];
        browseBtn.frame = NSMakeRect(380, 174, 80, 24);
        [content addSubview:browseBtn];

        // Filter field
        NSTextField *lbl3 = [NSTextField labelWithString:@"Filters:"];
        lbl3.frame = NSMakeRect(20, 135, 90, 20);
        [content addSubview:lbl3];

        self.filterField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, 135, 345, 22)];
        self.filterField.stringValue = @"*.*";
        [content addSubview:self.filterField];

        // Checkboxes
        self.matchCaseBox = [NSButton checkboxWithTitle:@"Match case" target:nil action:nil];
        self.matchCaseBox.frame = NSMakeRect(115, 95, 110, 20);
        [content addSubview:self.matchCaseBox];

        self.wholeWordBox = [NSButton checkboxWithTitle:@"Whole word" target:nil action:nil];
        self.wholeWordBox.frame = NSMakeRect(235, 95, 110, 20);
        [content addSubview:self.wholeWordBox];

        self.subdirsBox = [NSButton checkboxWithTitle:@"Subdirectories" target:nil action:nil];
        self.subdirsBox.frame = NSMakeRect(350, 95, 110, 20);
        self.subdirsBox.state = NSControlStateValueOn;
        [content addSubview:self.subdirsBox];

        // Status Label
        self.statusLabel = [NSTextField labelWithString:@""];
        self.statusLabel.frame = NSMakeRect(20, 55, 440, 20);
        self.statusLabel.textColor = [NSColor secondaryLabelColor];
        [content addSubview:self.statusLabel];

        // Buttons
        NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelAction:)];
        cancelBtn.frame = NSMakeRect(275, 15, 85, 28);
        [content addSubview:cancelBtn];

        NSButton *findBtn = [NSButton buttonWithTitle:@"Find All" target:self action:@selector(findAction:)];
        findBtn.frame = NSMakeRect(375, 15, 85, 28);
        findBtn.keyEquivalent = @"\r";
        [content addSubview:findBtn];

        self.window = win;
    }

    if (self.defaultDirectory.length > 0 && self.dirField.stringValue.length == 0) {
        self.dirField.stringValue = self.defaultDirectory;
    }
    [self.window makeKeyAndOrderFront:nil];
}

- (void)browseDirectory:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] == NSModalResponseOK) {
        self.dirField.stringValue = panel.URL.path ?: @"";
    }
}

- (void)cancelAction:(id)sender {
    [self.window orderOut:nil];
}

- (void)findAction:(id)sender {
    NSString *query = self.searchField.stringValue;
    NSString *dir = self.dirField.stringValue;
    NSString *filter = self.filterField.stringValue;
    BOOL matchCase = (self.matchCaseBox.state == NSControlStateValueOn);
    BOOL wholeWord = (self.wholeWordBox.state == NSControlStateValueOn);
    BOOL subdirs = (self.subdirsBox.state == NSControlStateValueOn);

    if (query.length == 0) {
        self.statusLabel.stringValue = @"Please enter a search query.";
        return;
    }
    if (dir.length == 0) {
        self.statusLabel.stringValue = @"Please select a directory.";
        return;
    }

    NSArray<SidebarItem *> *results = [FindInFilesEngine searchForString:query
                                                             inDirectory:dir
                                                                  filter:filter
                                                               matchCase:matchCase
                                                               wholeWord:wholeWord
                                                                 subdirs:subdirs];

    if (self.delegate) {
        [self.delegate findInFilesDidProduceResults:results query:query directory:dir];
    }
    [self.window orderOut:nil];
}

@end
