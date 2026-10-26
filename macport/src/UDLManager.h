#import <Cocoa/Cocoa.h>

@interface UDLLanguage : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSArray<NSString *> *extensions;
@property (nonatomic, copy) NSString *keywords;
@property (nonatomic, copy) NSString *commentLine;
@property (nonatomic, copy) NSString *commentStart;
@property (nonatomic, copy) NSString *commentEnd;
@end

@interface UDLManager : NSObject
+ (instancetype)sharedManager;
- (void)loadSavedUDLs;
- (UDLLanguage *)importUDLFromURL:(NSURL *)url error:(NSError **)err;
- (UDLLanguage *)languageForExtension:(NSString *)ext;
- (UDLLanguage *)languageForName:(NSString *)name;
- (NSArray<UDLLanguage *> *)allLanguages;
@end
