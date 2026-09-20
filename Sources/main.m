#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <errno.h>
#import <math.h>
#import <poll.h>
#import <unistd.h>

static NSString * const CUBErrorDomain = @"com.local.codexusagemenubar";
static NSString * const CUBLastResetKey = @"lastManualResetRecord";

typedef NS_ENUM(NSInteger, CUBErrorCode) {
    CUBErrorExecutableNotFound = 1,
    CUBErrorLaunchFailed,
    CUBErrorTimedOut,
    CUBErrorConnectionClosed,
    CUBErrorInvalidResponse,
    CUBErrorServer
};

static NSError *CUBError(CUBErrorCode code, NSString *message) {
    return [NSError errorWithDomain:CUBErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"未知错误"}];
}

static NSString *CUBCodexExecutable(void) {
    NSArray<NSString *> *candidates = @[
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        @"/Applications/Codex.app/Contents/Resources/codex",
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex"
    ];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *path in candidates) {
        if ([manager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSInteger CUBInteger(id value, NSInteger fallback) {
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static NSString *CUBMaskEmail(NSString *email) {
    if (email.length == 0) return nil;
    NSRange at = [email rangeOfString:@"@"];
    if (at.location == NSNotFound) return email;
    NSString *local = [email substringToIndex:at.location];
    NSString *domain = [email substringFromIndex:at.location];
    if (local.length <= 2) return [@"••" stringByAppendingString:domain];
    return [NSString stringWithFormat:@"%@•••%@", [local substringToIndex:2], domain];
}

static NSString *CUBDurationText(NSInteger minutes) {
    if (minutes >= 10080 && minutes % 10080 == 0) {
        return [NSString stringWithFormat:@"%ld 周窗口", (long)(minutes / 10080)];
    }
    if (minutes >= 1440 && minutes % 1440 == 0) {
        return [NSString stringWithFormat:@"%ld 天窗口", (long)(minutes / 1440)];
    }
    if (minutes >= 60 && minutes % 60 == 0) {
        return [NSString stringWithFormat:@"%ld 小时窗口", (long)(minutes / 60)];
    }
    return [NSString stringWithFormat:@"%ld 分钟窗口", (long)minutes];
}

static NSString *CUBOutcomeText(NSString *outcome) {
    if ([outcome isEqualToString:@"reset"]) return @"成功";
    if ([outcome isEqualToString:@"alreadyRedeemed"]) return @"已兑换（幂等成功）";
    if ([outcome isEqualToString:@"nothingToReset"]) return @"没有符合条件的用量窗口";
    if ([outcome isEqualToString:@"noCredit"]) return @"没有可用 reset";
    if ([outcome isEqualToString:@"failed"]) return @"失败";
    return @"服务器返回未知结果";
}

@interface CUBRPCSession : NSObject
@property(nonatomic, strong) NSTask *task;
@property(nonatomic, strong) NSFileHandle *input;
@property(nonatomic, strong) NSFileHandle *output;
@property(nonatomic, strong) NSFileHandle *errorOutput;
@property(nonatomic, strong) NSMutableData *buffer;
- (instancetype)initWithExecutable:(NSString *)path error:(NSError **)error;
- (BOOL)initializeSession:(NSError **)error;
- (NSDictionary *)requestMethod:(NSString *)method
                         params:(NSDictionary *)params
                             id:(NSInteger)requestID
                          error:(NSError **)error;
- (void)stop;
@end

@implementation CUBRPCSession

- (instancetype)initWithExecutable:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _task = [[NSTask alloc] init];
    _task.executableURL = [NSURL fileURLWithPath:path];
    _task.arguments = @[@"app-server", @"--stdio"];

    NSPipe *inputPipe = [NSPipe pipe];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    _task.standardInput = inputPipe;
    _task.standardOutput = outputPipe;
    _task.standardError = errorPipe;
    _input = inputPipe.fileHandleForWriting;
    _output = outputPipe.fileHandleForReading;
    _errorOutput = errorPipe.fileHandleForReading;
    _buffer = [NSMutableData data];

    NSError *launchError = nil;
    if (![_task launchAndReturnError:&launchError]) {
        if (error) {
            *error = CUBError(
                CUBErrorLaunchFailed,
                [NSString stringWithFormat:@"无法启动 Codex App Server：%@",
                 launchError.localizedDescription ?: @"未知原因"]
            );
        }
        return nil;
    }
    return self;
}

- (BOOL)writeObject:(NSDictionary *)object error:(NSError **)error {
    NSError *jsonError = nil;
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:object
                                                           options:0
                                                             error:&jsonError] mutableCopy];
    if (!data) {
        if (error) *error = jsonError;
        return NO;
    }
    const uint8_t newline = '\n';
    [data appendBytes:&newline length:1];
    @try {
        [self.input writeData:data];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = CUBError(CUBErrorConnectionClosed,
                              [NSString stringWithFormat:@"写入 Codex App Server 失败：%@", exception.reason]);
        }
        return NO;
    }
}

- (NSDictionary *)readMessage:(NSError **)error {
    while (YES) {
        const uint8_t *bytes = self.buffer.bytes;
        NSUInteger length = self.buffer.length;
        for (NSUInteger index = 0; index < length; index++) {
            if (bytes[index] != '\n') continue;
            NSData *line = [self.buffer subdataWithRange:NSMakeRange(0, index)];
            [self.buffer replaceBytesInRange:NSMakeRange(0, index + 1)
                                   withBytes:NULL
                                      length:0];
            if (line.length == 0) break;

            NSError *jsonError = nil;
            id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:&jsonError];
            if (![object isKindOfClass:NSDictionary.class]) {
                if (error) {
                    NSString *text = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] ?: @"";
                    *error = CUBError(CUBErrorInvalidResponse,
                                      [NSString stringWithFormat:@"Codex App Server 返回了无法识别的数据：%@", text]);
                }
                return nil;
            }
            return object;
        }

        struct pollfd descriptor;
        descriptor.fd = self.output.fileDescriptor;
        descriptor.events = POLLIN | POLLHUP;
        descriptor.revents = 0;

        int result;
        do {
            result = poll(&descriptor, 1, 15000);
        } while (result < 0 && errno == EINTR);

        if (result == 0) {
            if (error) *error = CUBError(CUBErrorTimedOut, @"连接 Codex App Server 超时。");
            return nil;
        }
        if (result < 0) {
            if (error) *error = CUBError(CUBErrorConnectionClosed, @"Codex App Server 连接读取失败。");
            return nil;
        }

        uint8_t chunk[8192];
        ssize_t count;
        do {
            count = read(self.output.fileDescriptor, chunk, sizeof(chunk));
        } while (count < 0 && errno == EINTR);

        if (count <= 0) {
            NSData *errorData = self.errorOutput.availableData;
            NSString *errorText = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSString *message = errorText.length > 0
                ? [NSString stringWithFormat:@"Codex App Server：%@",
                   [errorText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]
                : @"Codex App Server 提前关闭了连接。";
            if (error) *error = CUBError(CUBErrorConnectionClosed, message);
            return nil;
        }
        [self.buffer appendBytes:chunk length:(NSUInteger)count];
    }
}

- (NSDictionary *)waitForRequestID:(NSInteger)requestID error:(NSError **)error {
    while (YES) {
        NSDictionary *message = [self readMessage:error];
        if (!message) return nil;
        id rawID = message[@"id"];
        if (![rawID respondsToSelector:@selector(integerValue)] ||
            [rawID integerValue] != requestID) {
            continue;
        }
        id serverError = message[@"error"];
        if (serverError) {
            if (error) {
                *error = CUBError(CUBErrorServer,
                                  [NSString stringWithFormat:@"Codex App Server 返回错误：%@", serverError]);
            }
            return nil;
        }
        id result = message[@"result"];
        if (![result isKindOfClass:NSDictionary.class]) {
            if (error) {
                *error = CUBError(CUBErrorInvalidResponse,
                                  [NSString stringWithFormat:@"响应缺少 result：%@", message]);
            }
            return nil;
        }
        return result;
    }
}

- (NSDictionary *)requestMethod:(NSString *)method
                         params:(NSDictionary *)params
                             id:(NSInteger)requestID
                          error:(NSError **)error {
    NSMutableDictionary *message = [@{@"method": method, @"id": @(requestID)} mutableCopy];
    if (params) message[@"params"] = params;
    if (![self writeObject:message error:error]) return nil;
    return [self waitForRequestID:requestID error:error];
}

- (BOOL)initializeSession:(NSError **)error {
    NSDictionary *params = @{
        @"clientInfo": @{
            @"name": @"codex_usage_bar",
            @"title": @"Codex Usage Bar",
            @"version": @"1.0.0"
        }
    };
    if (![self requestMethod:@"initialize" params:params id:0 error:error]) return NO;
    return [self writeObject:@{@"method": @"initialized", @"params": @{}} error:error];
}

- (void)stop {
    @try {
        [self.input closeFile];
    } @catch (__unused NSException *exception) {}
    if (self.task.running) {
        [self.task terminate];
        [self.task waitUntilExit];
    }
}

- (void)dealloc {
    [self stop];
}

@end

@interface CUBClient : NSObject
- (NSDictionary *)fetchUsage:(NSError **)error;
- (NSDictionary *)consumeResetWithCreditID:(NSString *)creditID error:(NSError **)error;
+ (NSDictionary *)parseAccount:(NSDictionary *)accountResult
                        limits:(NSDictionary *)limitsResult
                     fetchedAt:(NSDate *)fetchedAt;
@end

@implementation CUBClient

+ (NSArray<NSDictionary *> *)windowsFromLimits:(NSDictionary *)limitsResult {
    NSMutableArray<NSDictionary *> *windows = [NSMutableArray array];
    NSDictionary *byID = [limitsResult[@"rateLimitsByLimitId"] isKindOfClass:NSDictionary.class]
        ? limitsResult[@"rateLimitsByLimitId"] : nil;
    if (byID) {
        [byID enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSDictionary.class]) return;
            NSDictionary *primary = value[@"primary"];
            if (![primary isKindOfClass:NSDictionary.class]) return;
            NSInteger used = MAX(0, MIN(100, CUBInteger(primary[@"usedPercent"], 0)));
            NSInteger duration = CUBInteger(primary[@"windowDurationMins"], 0);
            NSString *name = [value[@"limitName"] isKindOfClass:NSString.class] ? value[@"limitName"] : nil;
            if (name.length == 0) name = [key isEqualToString:@"codex"] ? @"Codex 用量" : key;
            NSMutableDictionary *window = [@{
                @"id": key,
                @"name": name,
                @"usedPercent": @(used),
                @"remainingPercent": @(MAX(0, 100 - used)),
                @"windowDurationMins": @(duration)
            } mutableCopy];
            if ([primary[@"resetsAt"] respondsToSelector:@selector(doubleValue)]) {
                window[@"resetsAt"] = [NSDate dateWithTimeIntervalSince1970:[primary[@"resetsAt"] doubleValue]];
            }
            [windows addObject:window];
        }];
    } else {
        NSDictionary *single = [limitsResult[@"rateLimits"] isKindOfClass:NSDictionary.class]
            ? limitsResult[@"rateLimits"] : nil;
        NSDictionary *primary = [single[@"primary"] isKindOfClass:NSDictionary.class]
            ? single[@"primary"] : nil;
        if (primary) {
            NSString *identifier = [single[@"limitId"] isKindOfClass:NSString.class]
                ? single[@"limitId"] : @"codex";
            NSInteger used = MAX(0, MIN(100, CUBInteger(primary[@"usedPercent"], 0)));
            NSInteger duration = CUBInteger(primary[@"windowDurationMins"], 0);
            NSString *name = [single[@"limitName"] isKindOfClass:NSString.class]
                ? single[@"limitName"] : nil;
            if (name.length == 0) name = [identifier isEqualToString:@"codex"] ? @"Codex 用量" : identifier;
            NSMutableDictionary *window = [@{
                @"id": identifier,
                @"name": name,
                @"usedPercent": @(used),
                @"remainingPercent": @(MAX(0, 100 - used)),
                @"windowDurationMins": @(duration)
            } mutableCopy];
            if ([primary[@"resetsAt"] respondsToSelector:@selector(doubleValue)]) {
                window[@"resetsAt"] = [NSDate dateWithTimeIntervalSince1970:[primary[@"resetsAt"] doubleValue]];
            }
            [windows addObject:window];
        }
    }

    [windows sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        if ([left[@"id"] isEqualToString:@"codex"]) return NSOrderedAscending;
        if ([right[@"id"] isEqualToString:@"codex"]) return NSOrderedDescending;
        return [left[@"name"] localizedStandardCompare:right[@"name"]];
    }];
    return windows;
}

+ (NSDictionary *)parseAccount:(NSDictionary *)accountResult
                        limits:(NSDictionary *)limitsResult
                     fetchedAt:(NSDate *)fetchedAt {
    NSDictionary *account = [accountResult[@"account"] isKindOfClass:NSDictionary.class]
        ? accountResult[@"account"] : @{};
    NSDictionary *resetObject = [limitsResult[@"rateLimitResetCredits"] isKindOfClass:NSDictionary.class]
        ? limitsResult[@"rateLimitResetCredits"] : @{};
    NSInteger available = MAX(0, CUBInteger(resetObject[@"availableCount"], 0));
    NSArray *rawCredits = [resetObject[@"credits"] isKindOfClass:NSArray.class]
        ? resetObject[@"credits"] : @[];
    NSMutableArray *credits = [NSMutableArray array];
    for (id rawCredit in rawCredits) {
        if (![rawCredit isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier = [rawCredit[@"id"] isKindOfClass:NSString.class] ? rawCredit[@"id"] : nil;
        if (identifier.length == 0) continue;
        NSMutableDictionary *credit = [@{@"id": identifier} mutableCopy];
        if ([rawCredit[@"expiresAt"] respondsToSelector:@selector(doubleValue)]) {
            credit[@"expiresAt"] = [NSDate dateWithTimeIntervalSince1970:[rawCredit[@"expiresAt"] doubleValue]];
        }
        [credits addObject:credit];
    }

    return @{
        @"email": [account[@"email"] isKindOfClass:NSString.class] ? account[@"email"] : @"",
        @"planType": [account[@"planType"] isKindOfClass:NSString.class] ? account[@"planType"] : @"",
        @"ordinaryUsageAllowed": @([limitsResult[@"ordinaryUsageAllowed"] boolValue]),
        @"windows": [self windowsFromLimits:limitsResult],
        @"availableResetCount": @(available),
        @"resetCredits": credits,
        @"fetchedAt": fetchedAt ?: NSDate.date
    };
}

- (CUBRPCSession *)newSession:(NSError **)error {
    NSString *executable = CUBCodexExecutable();
    if (!executable) {
        if (error) *error = CUBError(CUBErrorExecutableNotFound,
                                     @"未找到 Codex 可执行文件。请确认 ChatGPT/Codex App 已安装。");
        return nil;
    }
    CUBRPCSession *session = [[CUBRPCSession alloc] initWithExecutable:executable error:error];
    if (session && ![session initializeSession:error]) {
        [session stop];
        return nil;
    }
    return session;
}

- (NSDictionary *)fetchUsage:(NSError **)error {
    CUBRPCSession *session = [self newSession:error];
    if (!session) return nil;
    NSDictionary *account = [session requestMethod:@"account/read"
                                            params:@{@"refreshToken": @NO}
                                                id:1
                                             error:error];
    NSDictionary *limits = account ? [session requestMethod:@"account/rateLimits/read"
                                                     params:nil
                                                         id:2
                                                      error:error] : nil;
    [session stop];
    if (!account || !limits) return nil;
    return [CUBClient parseAccount:account limits:limits fetchedAt:NSDate.date];
}

- (NSDictionary *)consumeResetWithCreditID:(NSString *)creditID error:(NSError **)error {
    CUBRPCSession *session = [self newSession:error];
    if (!session) return nil;
    NSMutableDictionary *params = [@{@"idempotencyKey": NSUUID.UUID.UUIDString} mutableCopy];
    if (creditID.length > 0) params[@"creditId"] = creditID;
    NSDictionary *consume = [session requestMethod:@"account/rateLimitResetCredit/consume"
                                            params:params
                                                id:3
                                             error:error];
    if (!consume) {
        [session stop];
        return nil;
    }
    NSDictionary *account = [session requestMethod:@"account/read"
                                            params:@{@"refreshToken": @NO}
                                                id:4
                                             error:error];
    NSDictionary *limits = account ? [session requestMethod:@"account/rateLimits/read"
                                                     params:nil
                                                         id:5
                                                      error:error] : nil;
    [session stop];
    if (!account || !limits) return nil;
    return @{
        @"outcome": [consume[@"outcome"] isKindOfClass:NSString.class] ? consume[@"outcome"] : @"unknown",
        @"snapshot": [CUBClient parseAccount:account limits:limits fetchedAt:NSDate.date]
    };
}

@end

static NSDictionary *CUBPrimaryWindow(NSDictionary *snapshot) {
    NSArray *windows = snapshot[@"windows"];
    for (NSDictionary *window in windows) {
        if ([window[@"id"] isEqualToString:@"codex"]) return window;
    }
    return windows.firstObject;
}

static NSInteger CUBProgressPercent(NSDictionary *window) {
    return MAX(0, MIN(100, CUBInteger(window[@"usedPercent"], 0)));
}

static NSString *CUBStatusTitle(NSDictionary *snapshot) {
    NSDictionary *window = CUBPrimaryWindow(snapshot);
    if (!window) return @"—";
    return [NSString stringWithFormat:@"%@%%", window[@"remainingPercent"]];
}

static NSImage *CUBSymbol(NSString *name, CGFloat pointSize, NSFontWeight weight) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImageSymbolConfiguration *configuration =
        [NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight];
    image = [image imageWithSymbolConfiguration:configuration] ?: image;
    image.template = YES;
    return image;
}

static NSImage *CUBCodexIcon(CGFloat size) {
    NSString *path = [NSBundle.mainBundle pathForResource:@"codex-menubar"
                                                   ofType:@"svg"];
    NSImage *source = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (!source) {
        return CUBSymbol(@"chevron.left.forwardslash.chevron.right",
                         size,
                         NSFontWeightSemibold);
    }
    NSImage *image = [source copy];
    image.size = NSMakeSize(size, size);
    image.template = YES;
    return image;
}

static NSImage *CUBResetCDIcon(CGFloat size) {
    NSString *path = [NSBundle.mainBundle pathForResource:@"resetcd-menubar"
                                                   ofType:@"svg"];
    NSImage *source = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (!source) {
        return CUBSymbol(@"arrow.clockwise", size, NSFontWeightSemibold);
    }
    NSImage *image = [source copy];
    image.size = NSMakeSize(size, size);
    image.template = YES;
    return image;
}

static CGFloat CUBStatusGlyphSize(CGFloat statusBarThickness) {
    CGFloat opticalSize = round(statusBarThickness * 0.70);
    return MIN(16.0, MAX(15.0, opticalSize));
}

static NSImage *CUBStatusIcon(void) {
    CGFloat thickness = NSStatusBar.systemStatusBar.thickness;
    CGFloat glyphSize = CUBStatusGlyphSize(thickness);
    return CUBResetCDIcon(glyphSize);
}

static NSDateFormatter *CUBDateFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"M月d日 HH:mm";
    });
    return formatter;
}

static NSDateFormatter *CUBTimeFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"HH:mm:ss";
    });
    return formatter;
}

@interface CUBSummaryView : NSView
- (instancetype)initWithSnapshot:(NSDictionary *)snapshot;
@end

@interface CUBUsageProgressView : NSView
@property(nonatomic) NSInteger percent;
- (instancetype)initWithFrame:(NSRect)frame percent:(NSInteger)percent;
@end

@implementation CUBUsageProgressView

- (instancetype)initWithFrame:(NSRect)frame percent:(NSInteger)percent {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _percent = MAX(0, MIN(100, percent));
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityProgressIndicatorRole;
    self.accessibilityLabel = @"已用用量";
    self.accessibilityValue = @(_percent);
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect bounds = NSInsetRect(self.bounds, 0, 0.5);
    CGFloat radius = NSHeight(bounds) / 2.0;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:bounds
                                                         xRadius:radius
                                                         yRadius:radius];
    [[NSColor.separatorColor colorWithAlphaComponent:0.42] setFill];
    [track fill];

    CGFloat fillWidth = NSWidth(bounds) * self.percent / 100.0;
    if (fillWidth <= 0) return;
    NSRect fillRect = bounds;
    fillRect.size.width = fillWidth;
    CGFloat fillRadius = MIN(radius, fillWidth / 2.0);
    NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:fillRect
                                                        xRadius:fillRadius
                                                        yRadius:fillRadius];
    [NSColor.systemBlueColor setFill];
    [fill fill];
}

@end

@implementation CUBSummaryView

- (NSTextField *)labelWithFrame:(NSRect)frame
                           text:(NSString *)text
                           font:(NSFont *)font
                          color:(NSColor *)color
                      alignment:(NSTextAlignment)alignment {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.frame = frame;
    label.font = font;
    label.textColor = color;
    label.alignment = alignment;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (instancetype)initWithSnapshot:(NSDictionary *)snapshot {
    self = [super initWithFrame:NSMakeRect(0, 0, 316, 104)];
    if (!self) return nil;

    NSDictionary *window = CUBPrimaryWindow(snapshot);
    NSInteger remaining = CUBInteger(window[@"remainingPercent"], 0);
    NSInteger used = CUBProgressPercent(window);
    NSInteger duration = CUBInteger(window[@"windowDurationMins"], 0);

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(16, 67, 20, 20)];
    icon.image = CUBCodexIcon(20);
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.contentTintColor = NSColor.labelColor;
    [self addSubview:icon];

    NSTextField *title = [self labelWithFrame:NSMakeRect(46, 70, 120, 18)
                                         text:@"Codex"
                                         font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                                        color:NSColor.labelColor
                                    alignment:NSTextAlignmentLeft];
    [self addSubview:title];

    NSString *masked = CUBMaskEmail(snapshot[@"email"]);
    NSString *plan = [snapshot[@"planType"] capitalizedString];
    NSString *account = masked.length
        ? [NSString stringWithFormat:@"%@ · %@", masked, plan.length ? plan : @"ChatGPT"]
        : (plan.length ? plan : @"ChatGPT");
    NSTextField *accountLabel = [self labelWithFrame:NSMakeRect(46, 51, 174, 16)
                                                text:account
                                                font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                               color:NSColor.secondaryLabelColor
                                           alignment:NSTextAlignmentLeft];
    [self addSubview:accountLabel];

    NSTextField *remainingLabel = [self labelWithFrame:NSMakeRect(214, 63, 84, 26)
                                                  text:[NSString stringWithFormat:@"%ld%%", (long)remaining]
                                                  font:[NSFont monospacedDigitSystemFontOfSize:20
                                                                                       weight:NSFontWeightSemibold]
                                                 color:NSColor.labelColor
                                             alignment:NSTextAlignmentRight];
    [self addSubview:remainingLabel];

    CUBUsageProgressView *progress = [[CUBUsageProgressView alloc]
        initWithFrame:NSMakeRect(16, 38, 282, 5)
              percent:used];
    [self addSubview:progress];

    NSTextField *usage = [self labelWithFrame:NSMakeRect(16, 14, 140, 16)
                                         text:[NSString stringWithFormat:@"已用 %ld%% · %@",
                                               (long)used, CUBDurationText(duration)]
                                         font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                        color:NSColor.secondaryLabelColor
                                    alignment:NSTextAlignmentLeft];
    [self addSubview:usage];

    NSDate *resetsAt = window[@"resetsAt"];
    NSString *resetText = resetsAt
        ? [NSString stringWithFormat:@"%@恢复", [CUBDateFormatter() stringFromDate:resetsAt]]
        : @"恢复时间未知";
    NSTextField *reset = [self labelWithFrame:NSMakeRect(152, 14, 146, 16)
                                         text:resetText
                                         font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                        color:NSColor.secondaryLabelColor
                                    alignment:NSTextAlignmentRight];
    [self addSubview:reset];

    self.accessibilityLabel = [NSString stringWithFormat:
        @"Codex 剩余 %ld%%，已用 %ld%%，%@，%@",
        (long)remaining, (long)used, account, resetText];
    return self;
}

@end

@interface CUBAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) CUBClient *client;
@property(nonatomic, strong) NSDictionary *snapshot;
@property(nonatomic, strong) NSError *lastError;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic) BOOL refreshing;
@end

@implementation CUBAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.client = [[CUBClient alloc] init];
    self.menu = [[NSMenu alloc] init];
    self.menu.delegate = self;
    self.menu.autoenablesItems = NO;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.menu = self.menu;
    self.statusItem.button.image = CUBStatusIcon();
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.imageScaling = NSImageScaleNone;
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12
                                                                  weight:NSFontWeightSemibold];
    self.statusItem.button.toolTip = @"Codex 剩余用量";
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(screenParametersChanged:)
                                               name:NSApplicationDidChangeScreenParametersNotification
                                             object:nil];
    [self rebuildMenu];
    [self refresh];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:300
                                                        target:self
                                                      selector:@selector(refreshTimerFired:)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)screenParametersChanged:(NSNotification *)notification {
    (void)notification;
    self.statusItem.button.image = CUBStatusIcon();
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)refreshTimerFired:(NSTimer *)timer {
    (void)timer;
    [self refresh];
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    NSDate *fetchedAt = self.snapshot[@"fetchedAt"];
    if (!fetchedAt || [NSDate.date timeIntervalSinceDate:fetchedAt] > 30) {
        [self refresh];
    }
}

- (void)addDisabledItem:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    [self.menu addItem:item];
}

- (void)rebuildMenu {
    [self.menu removeAllItems];
    NSString *statusTitle = CUBStatusTitle(self.snapshot);
    if (self.refreshing && !self.snapshot) statusTitle = @"…";
    if (self.lastError && !self.snapshot) statusTitle = @"!";
    self.statusItem.button.title = statusTitle;
    NSString *accessibleTitle = self.snapshot
        ? [NSString stringWithFormat:@"Codex 剩余用量 %@", statusTitle]
        : @"Codex 用量暂不可用";
    self.statusItem.button.toolTip = accessibleTitle;
    self.statusItem.button.accessibilityLabel = accessibleTitle;

    if (self.snapshot) {
        NSMenuItem *summary = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        summary.view = [[CUBSummaryView alloc] initWithSnapshot:self.snapshot];
        [self.menu addItem:summary];

        [self.menu addItem:NSMenuItem.separatorItem];
        NSInteger count = CUBInteger(self.snapshot[@"availableResetCount"], 0);
        NSString *title = count > 0
            ? [NSString stringWithFormat:@"使用 reset · %ld 次可用", (long)count]
            : @"当前没有可用 reset";
        NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:title
                                                          action:@selector(useReset:)
                                                   keyEquivalent:@""];
        resetItem.target = self;
        resetItem.enabled = count > 0 && !self.refreshing;
        resetItem.image = CUBSymbol(@"arrow.counterclockwise.circle", 13, NSFontWeightRegular);
        [self.menu addItem:resetItem];
    } else if (self.refreshing) {
        [self addDisabledItem:@"正在读取账户用量…"];
    }

    if (self.lastError) {
        [self.menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *errorItem = [[NSMenuItem alloc] initWithTitle:@"更新失败 · 点击刷新重试"
                                                           action:nil
                                                    keyEquivalent:@""];
        errorItem.enabled = NO;
        errorItem.image = CUBSymbol(@"exclamationmark.triangle", 13, NSFontWeightRegular);
        errorItem.toolTip = self.lastError.localizedDescription;
        [self.menu addItem:errorItem];
    }

    NSDictionary *record = [NSUserDefaults.standardUserDefaults dictionaryForKey:CUBLastResetKey];
    if (record) {
        [self.menu addItem:NSMenuItem.separatorItem];
        NSDate *date = record[@"attemptedAt"];
        NSMenuItem *historyItem = [[NSMenuItem alloc] initWithTitle:
            [NSString stringWithFormat:@"上次 reset · %@ · %@",
             date ? [CUBDateFormatter() stringFromDate:date] : @"时间未知",
             CUBOutcomeText(record[@"outcome"])]
                                                   action:nil
                                            keyEquivalent:@""];
        historyItem.enabled = NO;
        historyItem.image = CUBSymbol(@"clock.arrow.circlepath", 13, NSFontWeightRegular);
        [self.menu addItem:historyItem];
    }

    [self.menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:self.refreshing ? @"正在刷新…" : @"刷新用量"
                                                     action:@selector(refreshNow:)
                                              keyEquivalent:@"r"];
    refresh.target = self;
    refresh.enabled = !self.refreshing;
    refresh.image = CUBSymbol(@"arrow.clockwise", 13, NSFontWeightRegular);
    NSDate *fetchedAt = self.snapshot[@"fetchedAt"];
    if (fetchedAt) {
        refresh.toolTip = [NSString stringWithFormat:@"上次更新 %@",
                           [CUBTimeFormatter() stringFromDate:fetchedAt]];
    }
    [self.menu addItem:refresh];

    SMAppService *loginService = SMAppService.mainAppService;
    NSString *loginTitle = loginService.status == SMAppServiceStatusRequiresApproval
        ? @"登录时自动启动 · 待系统允许"
        : @"登录时自动启动";
    NSMenuItem *launchAtLogin = [[NSMenuItem alloc] initWithTitle:loginTitle
                                                          action:@selector(toggleLaunchAtLogin:)
                                                   keyEquivalent:@""];
    launchAtLogin.target = self;
    launchAtLogin.enabled = loginService.status != SMAppServiceStatusNotFound;
    launchAtLogin.state = loginService.status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn
        : (loginService.status == SMAppServiceStatusRequiresApproval
           ? NSControlStateValueMixed
           : NSControlStateValueOff);
    launchAtLogin.image = CUBSymbol(@"power", 13, NSFontWeightRegular);
    [self.menu addItem:launchAtLogin];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    quit.target = NSApplication.sharedApplication;
    quit.enabled = YES;
    quit.image = CUBSymbol(@"xmark.circle", 13, NSFontWeightRegular);
    [self.menu addItem:quit];
}

- (void)refreshNow:(id)sender {
    (void)sender;
    [self refresh];
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
        return;
    }

    NSError *error = nil;
    BOOL enabling = service.status != SMAppServiceStatusEnabled;
    BOOL succeeded = enabling
        ? [service registerAndReturnError:&error]
        : [service unregisterAndReturnError:&error];

    [self rebuildMenu];
    if (!succeeded) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = enabling ? @"无法开启登录时自动启动" : @"无法关闭登录时自动启动";
        alert.informativeText = error.localizedDescription ?: @"请在系统设置的“通用 → 登录项”中检查权限。";
        [alert addButtonWithTitle:@"好"];
        [alert runModal];
        return;
    }

    if (service.status == SMAppServiceStatusRequiresApproval) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"还需要系统允许";
        alert.informativeText = @"请在“通用 → 登录项”中允许 Codex 用量自动启动。";
        [alert addButtonWithTitle:@"打开系统设置"];
        [alert addButtonWithTitle:@"稍后"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [SMAppService openSystemSettingsLoginItems];
        }
    }
}

- (void)refresh {
    if (self.refreshing) return;
    self.refreshing = YES;
    if (!self.snapshot) self.statusItem.button.title = @"…";
    [self rebuildMenu];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSDictionary *snapshot = [self.client fetchUsage:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (snapshot) self.snapshot = snapshot;
            self.lastError = error;
            self.refreshing = NO;
            [self rebuildMenu];
        });
    });
}

- (void)useReset:(id)sender {
    (void)sender;
    NSInteger count = CUBInteger(self.snapshot[@"availableResetCount"], 0);
    if (count <= 0 || self.refreshing) return;

    NSAlert *confirmation = [[NSAlert alloc] init];
    confirmation.alertStyle = NSAlertStyleWarning;
    confirmation.messageText = @"使用一次 reset？";
    confirmation.informativeText = @"这会消耗 1 次已获得的 Codex reset。完成后将重新读取账户用量。";
    [confirmation addButtonWithTitle:@"确认使用"];
    [confirmation addButtonWithTitle:@"取消"];
    if ([confirmation runModal] != NSAlertFirstButtonReturn) return;

    NSArray *credits = self.snapshot[@"resetCredits"];
    NSString *creditID = [credits.firstObject[@"id"] isKindOfClass:NSString.class]
        ? credits.firstObject[@"id"] : nil;
    self.refreshing = YES;
    [self rebuildMenu];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSDictionary *result = [self.client consumeResetWithCreditID:creditID error:&error];
        NSDate *attemptedAt = NSDate.date;
        NSString *outcome = result ? result[@"outcome"] : @"failed";
        NSMutableDictionary *record = [@{@"attemptedAt": attemptedAt, @"outcome": outcome} mutableCopy];
        if (error.localizedDescription.length > 0) record[@"detail"] = error.localizedDescription;
        [NSUserDefaults.standardUserDefaults setObject:record forKey:CUBLastResetKey];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (result[@"snapshot"]) self.snapshot = result[@"snapshot"];
            self.lastError = error;
            self.refreshing = NO;
            [self rebuildMenu];

            NSAlert *alert = [[NSAlert alloc] init];
            BOOL success = [outcome isEqualToString:@"reset"] || [outcome isEqualToString:@"alreadyRedeemed"];
            alert.alertStyle = success ? NSAlertStyleInformational : NSAlertStyleWarning;
            alert.messageText = [NSString stringWithFormat:@"reset 结果：%@", CUBOutcomeText(outcome)];
            alert.informativeText = error.localizedDescription ?: @"用量和 reset 数量已从 Codex 账户重新读取。";
            [alert addButtonWithTitle:@"好"];
            [alert runModal];
        });
    });
}

@end

static int CUBRunSelfTest(void) {
    NSDictionary *account = @{@"account": @{@"email": @"example@gmail.com", @"planType": @"pro"}};
    NSDictionary *limits = @{
        @"ordinaryUsageAllowed": @YES,
        @"rateLimitsByLimitId": @{
            @"codex": @{
                @"limitName": @"Codex",
                @"primary": @{
                    @"usedPercent": @88,
                    @"windowDurationMins": @10080,
                    @"resetsAt": @2000000000
                }
            }
        },
        @"rateLimitResetCredits": @{
            @"availableCount": @0,
            @"credits": @[]
        }
    };
    NSDictionary *snapshot = [CUBClient parseAccount:account limits:limits fetchedAt:NSDate.date];
    NSDictionary *primary = CUBPrimaryWindow(snapshot);
    BOOL passed = [primary[@"remainingPercent"] integerValue] == 12
        && CUBProgressPercent(primary) == 88
        && CUBStatusGlyphSize(18.0) == 15.0
        && CUBStatusGlyphSize(22.0) == 15.0
        && CUBStatusGlyphSize(30.0) == 16.0
        && [snapshot[@"availableResetCount"] integerValue] == 0
        && [CUBStatusTitle(snapshot) isEqualToString:@"12%"]
        && [CUBMaskEmail(@"example@gmail.com") isEqualToString:@"ex•••@gmail.com"];
    if (!passed) {
        fprintf(stderr, "self_test=failed\n");
        return 1;
    }
    printf("self_test=passed\n");
    return 0;
}

static int CUBRunDiagnostics(void) {
    @autoreleasepool {
        NSError *error = nil;
        NSDictionary *snapshot = [[[CUBClient alloc] init] fetchUsage:&error];
        if (!snapshot) {
            fprintf(stderr, "status=error\nmessage=%s\n",
                    error.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
        NSDictionary *primary = CUBPrimaryWindow(snapshot);
        NSInteger resetCount = CUBInteger(snapshot[@"availableResetCount"], 0);
        printf("status=ok\n");
        printf("remaining_percent=%ld\n", (long)CUBInteger(primary[@"remainingPercent"], -1));
        printf("reset_count=%ld\n", (long)resetCount);
        printf("reset_label=%s\n",
               (resetCount > 0
                ? [NSString stringWithFormat:@"可用 reset：%ld", (long)resetCount]
                : @"当前没有可用 reset").UTF8String);
        printf("status_title=%s\n", CUBStatusTitle(snapshot).UTF8String);
        return 0;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if ([arguments containsObject:@"--self-test"]) return CUBRunSelfTest();
        if ([arguments containsObject:@"--diagnose"]) return CUBRunDiagnostics();

        NSApplication *application = NSApplication.sharedApplication;
        CUBAppDelegate *delegate = [[CUBAppDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
        (void)argc;
        (void)argv;
    }
    return 0;
}
