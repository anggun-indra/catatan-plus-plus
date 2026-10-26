#import "UDLManager.h"

@implementation UDLLanguage
@end

@interface UDLManager ()
@property (nonatomic, strong) NSMutableArray<UDLLanguage *> *languages;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation UDLManager

+ (instancetype)sharedManager {
    static UDLManager *sInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstance = [UDLManager new];
    });
    return sInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _languages = [NSMutableArray array];
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        _storagePath = [paths.firstObject stringByAppendingPathComponent:@"catatan++/udl"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_storagePath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    return self;
}

- (NSArray<UDLLanguage *> *)allLanguages {
    return [self.languages copy];
}

- (UDLLanguage *)languageForExtension:(NSString *)ext {
    if (ext.length == 0) return nil;
    NSString *low = ext.lowercaseString;
    for (UDLLanguage *lang in self.languages) {
        for (NSString *e in lang.extensions) {
            if ([e.lowercaseString isEqualToString:low]) return lang;
        }
    }
    return nil;
}

- (UDLLanguage *)languageForName:(NSString *)name {
    if (name.length == 0) return nil;
    for (UDLLanguage *lang in self.languages) {
        if ([lang.name isEqualToString:name] ||
            [[NSString stringWithFormat:@"udl_%@", lang.name] isEqualToString:name]) {
            return lang;
        }
    }
    return nil;
}

- (UDLLanguage *)parseUDLDocument:(NSXMLDocument *)doc {
    NSError *err = nil;
    NSArray *userLangs = [doc nodesForXPath:@"//UserLang" error:&err];
    if (userLangs.count == 0) return nil;

    NSXMLElement *elem = (NSXMLElement *)userLangs.firstObject;
    NSString *name = [elem attributeForName:@"name"].stringValue ?: @"CustomUDL";
    NSString *extString = [elem attributeForName:@"ext"].stringValue ?: @"";

    NSMutableArray *exts = [NSMutableArray array];
    for (NSString *s in [extString componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) [exts addObject:trimmed.lowercaseString];
    }

    NSMutableString *allWords = [NSMutableString string];
    NSArray *kwNodes = [elem nodesForXPath:@".//Keywords" error:nil];
    for (NSXMLElement *kw in kwNodes) {
        NSString *kwType = [kw attributeForName:@"name"].stringValue;
        NSString *val = kw.stringValue ?: @"";
        if ([kwType hasPrefix:@"Words"] || [kwType isEqualToString:@"Operators"]) {
            if (val.length > 0) {
                if (allWords.length > 0) [allWords appendString:@" "];
                [allWords appendString:val];
            }
        }
    }

    UDLLanguage *lang = [UDLLanguage new];
    lang.name = name;
    lang.extensions = exts;
    lang.keywords = allWords;

    // Check if already in languages list
    for (NSInteger i = (NSInteger)self.languages.count - 1; i >= 0; i--) {
        if ([self.languages[i].name isEqualToString:name]) {
            [self.languages removeObjectAtIndex:i];
        }
    }
    [self.languages addObject:lang];
    return lang;
}

- (UDLLanguage *)importUDLFromURL:(NSURL *)url error:(NSError **)err {
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:0 error:err];
    if (!doc) return nil;

    UDLLanguage *lang = [self parseUDLDocument:doc];
    if (lang) {
        // Save to storage folder
        NSString *dest = [self.storagePath stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.xml", lang.name]];
        [[NSFileManager defaultManager] copyItemAtURL:url
                                                toURL:[NSURL fileURLWithPath:dest]
                                                error:nil];
    }
    return lang;
}

- (void)loadSavedUDLs {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:self.storagePath error:nil];
    for (NSString *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"xml"]) {
            NSString *full = [self.storagePath stringByAppendingPathComponent:file];
            NSURL *u = [NSURL fileURLWithPath:full];
            NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:u options:0 error:nil];
            if (doc) [self parseUDLDocument:doc];
        }
    }
}

@end
