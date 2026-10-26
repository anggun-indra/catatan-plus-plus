#import "ColumnEditor.h"

@interface ColumnEditorController ()
@property (nonatomic, strong) NSButton *radioText;
@property (nonatomic, strong) NSButton *radioNumber;
@property (nonatomic, strong) NSTextField *textInputField;
@property (nonatomic, strong) NSTextField *initialField;
@property (nonatomic, strong) NSTextField *increaseField;
@property (nonatomic, strong) NSTextField *repeatField;
@property (nonatomic, strong) NSPopUpButton *formatPopUp;
@property (nonatomic, strong) NSButton *leadingZerosCheck;
@end

@implementation ColumnEditorController

+ (NSString *)formatNumber:(NSInteger)val format:(NSString *)fmt leadingZeros:(BOOL)zeros width:(NSInteger)width {
    NSString *res = @"";
    if ([fmt isEqualToString:@"Hex"]) {
        res = [NSString stringWithFormat:@"%lX", (long)val];
    } else if ([fmt isEqualToString:@"Oct"]) {
        res = [NSString stringWithFormat:@"%lo", (long)val];
    } else if ([fmt isEqualToString:@"Bin"]) {
        // Binary string representation
        if (val == 0) {
            res = @"0";
        } else {
            NSMutableString *b = [NSMutableString string];
            NSUInteger v = (NSUInteger)val;
            while (v > 0) {
                [b insertString:(v & 1) ? @"1" : @"0" atIndex:0];
                v >>= 1;
            }
            res = b;
        }
    } else {
        res = [NSString stringWithFormat:@"%ld", (long)val];
    }

    if (zeros && width > 0 && res.length < (NSUInteger)width) {
        NSString *padding = [@"" stringByPaddingToLength:width - res.length withString:@"0" startingAtIndex:0];
        res = [padding stringByAppendingString:res];
    }
    return res;
}

+ (BOOL)applyText:(NSString *)text toEditor:(ScintillaView *)editor {
    if (!editor || text.length == 0) return NO;

    long selStart = [editor getGeneralProperty:SCI_GETSELECTIONSTART parameter:0];
    long selEnd = [editor getGeneralProperty:SCI_GETSELECTIONEND parameter:0];
    long startLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selStart];
    long endLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selEnd];
    long col = selStart - [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:startLine];

    if (startLine == endLine) {
        long count = [editor getGeneralProperty:SCI_GETLINECOUNT parameter:0];
        endLine = count - 1;
    }

    [editor setGeneralProperty:SCI_BEGINUNDOACTION parameter:0 value:0];
    const char *utf8 = [text UTF8String];
    for (long line = endLine; line >= startLine; line--) {
        long lineStart = [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];
        long lineLen = [editor getGeneralProperty:SCI_LINELENGTH parameter:line];
        long insertPos = lineStart + col;
        if (insertPos > lineStart + lineLen) insertPos = lineStart + lineLen;
        [editor setGeneralProperty:SCI_INSERTTEXT parameter:insertPos value:(sptr_t)utf8];
    }
    [editor setGeneralProperty:SCI_ENDUNDOACTION parameter:0 value:0];
    return YES;
}

+ (BOOL)applyNumbersInitial:(NSInteger)initial
                       step:(NSInteger)step
                     repeat:(NSInteger)repeat
                     format:(NSString *)format
               leadingZeros:(BOOL)leadingZeros
                   toEditor:(ScintillaView *)editor {
    if (!editor) return NO;
    if (repeat <= 0) repeat = 1;

    long selStart = [editor getGeneralProperty:SCI_GETSELECTIONSTART parameter:0];
    long selEnd = [editor getGeneralProperty:SCI_GETSELECTIONEND parameter:0];
    long startLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selStart];
    long endLine = [editor getGeneralProperty:SCI_LINEFROMPOSITION parameter:selEnd];
    long col = selStart - [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:startLine];

    if (startLine == endLine) {
        long count = [editor getGeneralProperty:SCI_GETLINECOUNT parameter:0];
        endLine = count - 1;
    }

    NSInteger lineCount = endLine - startLine + 1;
    NSInteger maxVal = initial + ((lineCount - 1) / repeat) * step;
    NSString *maxStr = [self formatNumber:maxVal format:format leadingZeros:NO width:0];
    NSInteger padWidth = maxStr.length;

    [editor setGeneralProperty:SCI_BEGINUNDOACTION parameter:0 value:0];
    for (long line = endLine; line >= startLine; line--) {
        NSInteger idx = line - startLine;
        NSInteger num = initial + (idx / repeat) * step;
        NSString *numStr = [self formatNumber:num format:format leadingZeros:leadingZeros width:padWidth];

        long lineStart = [editor getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];
        long lineLen = [editor getGeneralProperty:SCI_LINELENGTH parameter:line];
        long insertPos = lineStart + col;
        if (insertPos > lineStart + lineLen) insertPos = lineStart + lineLen;

        [editor setGeneralProperty:SCI_INSERTTEXT parameter:insertPos value:(sptr_t)[numStr UTF8String]];
    }
    [editor setGeneralProperty:SCI_ENDUNDOACTION parameter:0 value:0];
    return YES;
}

- (void)showColumnEditor {
    if (!self.window) {
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 380, 270)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.title = @"Column Editor";
        [win center];

        NSView *cv = win.contentView;

        // Group 1: Text to Insert
        self.radioText = [NSButton radioButtonWithTitle:@"Text to Insert" target:self action:@selector(toggleMode:)];
        self.radioText.frame = NSMakeRect(20, 230, 150, 20);
        self.radioText.state = NSControlStateValueOn;
        [cv addSubview:self.radioText];

        self.textInputField = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 200, 310, 22)];
        self.textInputField.placeholderString = @"e.g. prefix_";
        [cv addSubview:self.textInputField];

        // Group 2: Number to Insert
        self.radioNumber = [NSButton radioButtonWithTitle:@"Number to Insert" target:self action:@selector(toggleMode:)];
        self.radioNumber.frame = NSMakeRect(20, 165, 150, 20);
        [cv addSubview:self.radioNumber];

        NSTextField *lblInit = [NSTextField labelWithString:@"Initial number:"];
        lblInit.frame = NSMakeRect(40, 135, 100, 18);
        [cv addSubview:lblInit];

        self.initialField = [[NSTextField alloc] initWithFrame:NSMakeRect(145, 133, 70, 22)];
        self.initialField.stringValue = @"1";
        [cv addSubview:self.initialField];

        NSTextField *lblInc = [NSTextField labelWithString:@"Increase by:"];
        lblInc.frame = NSMakeRect(230, 135, 80, 18);
        [cv addSubview:lblInc];

        self.increaseField = [[NSTextField alloc] initWithFrame:NSMakeRect(310, 133, 40, 22)];
        self.increaseField.stringValue = @"1";
        [cv addSubview:self.increaseField];

        NSTextField *lblRep = [NSTextField labelWithString:@"Repeat:"];
        lblRep.frame = NSMakeRect(40, 100, 100, 18);
        [cv addSubview:lblRep];

        self.repeatField = [[NSTextField alloc] initWithFrame:NSMakeRect(145, 98, 70, 22)];
        self.repeatField.stringValue = @"1";
        [cv addSubview:self.repeatField];

        NSTextField *lblFmt = [NSTextField labelWithString:@"Format:"];
        lblFmt.frame = NSMakeRect(230, 100, 50, 18);
        [cv addSubview:lblFmt];

        self.formatPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(280, 96, 75, 24) pullsDown:NO];
        [self.formatPopUp addItemsWithTitles:@[@"Dec", @"Hex", @"Oct", @"Bin"]];
        [cv addSubview:self.formatPopUp];

        self.leadingZerosCheck = [NSButton checkboxWithTitle:@"Leading zeros" target:nil action:nil];
        self.leadingZerosCheck.frame = NSMakeRect(145, 65, 120, 20);
        [cv addSubview:self.leadingZerosCheck];

        // Buttons
        NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelAction:)];
        cancelBtn.frame = NSMakeRect(180, 15, 85, 28);
        [cv addSubview:cancelBtn];

        NSButton *okBtn = [NSButton buttonWithTitle:@"OK" target:self action:@selector(okAction:)];
        okBtn.frame = NSMakeRect(275, 15, 85, 28);
        okBtn.keyEquivalent = @"\r";
        [cv addSubview:okBtn];

        self.window = win;
        [self updateEnabledStates];
    }
    [self.window makeKeyAndOrderFront:nil];
}

- (void)toggleMode:(id)sender {
    if (sender == self.radioText) {
        self.radioNumber.state = NSControlStateValueOff;
    } else {
        self.radioText.state = NSControlStateValueOff;
    }
    [self updateEnabledStates];
}

- (void)updateEnabledStates {
    BOOL isText = (self.radioText.state == NSControlStateValueOn);
    self.textInputField.enabled = isText;
    self.initialField.enabled = !isText;
    self.increaseField.enabled = !isText;
    self.repeatField.enabled = !isText;
    self.formatPopUp.enabled = !isText;
    self.leadingZerosCheck.enabled = !isText;
}

- (void)cancelAction:(id)sender {
    [self.window orderOut:nil];
}

- (void)okAction:(id)sender {
    if (self.radioText.state == NSControlStateValueOn) {
        [ColumnEditorController applyText:self.textInputField.stringValue toEditor:self.targetEditor];
    } else {
        NSInteger initVal = self.initialField.integerValue;
        NSInteger stepVal = self.increaseField.integerValue;
        NSInteger repVal = self.repeatField.integerValue;
        NSString *fmt = self.formatPopUp.titleOfSelectedItem ?: @"Dec";
        BOOL zeros = (self.leadingZerosCheck.state == NSControlStateValueOn);

        [ColumnEditorController applyNumbersInitial:initVal
                                               step:stepVal
                                             repeat:repVal
                                             format:fmt
                                       leadingZeros:zeros
                                           toEditor:self.targetEditor];
    }
    [self.window orderOut:nil];
}

@end
