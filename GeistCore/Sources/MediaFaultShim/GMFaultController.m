#import "GMFaultController.h"

@implementation GMFaultController {
    NSRecursiveLock *_lock;
    NSMapTable<id, NSNumber *> *_starts;
    NSMapTable<id, NSError *> *_reservedFailures;
    NSMutableDictionary<NSString *, id> *_writerRule;
    NSMutableDictionary<NSString *, id> *_exportRule;
    NSUInteger _startOrder;
    NSUInteger _armedAfter;
    NSUInteger _armedThrough;
    NSInteger _writerCode;
    NSInteger _underlyingCode;
    void (^_logger)(NSString *);
}

- (instancetype)initWithWriterErrorCode:(NSInteger)code underlyingCode:(NSInteger)underlyingCode logger:(void (^)(NSString *))logger {
    if ((self = [super init])) {
        _lock = [NSRecursiveLock new];
        _starts = [NSMapTable weakToStrongObjectsMapTable];
        _reservedFailures = [NSMapTable weakToStrongObjectsMapTable];
        _writerRule = [@{@"remainingCount": @0, @"firedCount": @0} mutableCopy];
        _exportRule = [_writerRule mutableCopy];
        _writerCode = code;
        _underlyingCode = underlyingCode;
        _logger = [logger copy];
    }
    return self;
}

- (NSDictionary *)handle:(NSDictionary *)request {
    [_lock lock];
    @try { return [self handleLocked:request]; }
    @finally { [_lock unlock]; }
}

- (NSDictionary *)handleLocked:(NSDictionary *)request {
    NSString *kind = request[@"kind"];
    if (![@[@"writer", @"export"] containsObject:kind]) return @{@"error": @"Unknown fault kind"};
    NSMutableDictionary<NSString *, id> *rule = [kind isEqual:@"writer"] ? _writerRule : _exportRule;
    NSString *action = request[@"action"] ?: @"status";
    if ([action isEqual:@"arm"]) {
        return [self armRule:rule kind:kind request:request];
    } else if ([action isEqual:@"clear"]) {
        rule[@"remainingCount"] = @0;
        _logger([NSString stringWithFormat:@"%@ fault cleared", kind]);
    } else if (![action isEqual:@"status"]) {
        return @{@"error": @"Unknown fault action"};
    }
    return [self snapshot:rule];
}

- (NSDictionary *)armRule:(NSMutableDictionary<NSString *, id> *)rule kind:(NSString *)kind request:(NSDictionary *)request {
    NSDictionary<NSString *, id> *options = [self armOptions:request];
    if (!options) return @{@"error": @"Invalid fault options"};
    [rule setDictionary:options];
    if ([kind isEqual:@"writer"]) {
        _armedAfter = _startOrder;
        _armedThrough = _startOrder + [options[@"remainingCount"] unsignedIntegerValue];
    }
    _logger([NSString stringWithFormat:@"%@ fault armed count=%@ trigger=%@ mediaType=%@",
             kind, options[@"remainingCount"], options[@"trigger"], options[@"mediaType"]]);
    return [self snapshot:rule];
}

- (NSDictionary<NSString *, id> *)armOptions:(NSDictionary *)request {
    NSString *trigger = request[@"trigger"] ?: @"nextAppend";
    NSString *media = request[@"mediaType"] ?: @"either";
    NSNumber *count = request[@"count"] ?: @1;
    if (![@[@"nextAppend", @"nextWriter"] containsObject:trigger] ||
        ![@[@"video", @"audio", @"either"] containsObject:media] ||
        ![count isKindOfClass:NSNumber.class] || count.integerValue <= 0 || count.doubleValue != count.integerValue) return nil;
    return @{@"trigger": trigger, @"mediaType": media, @"remainingCount": count, @"firedCount": @0};
}

- (NSDictionary *)snapshot:(NSDictionary<NSString *, id> *)rule {
    NSMutableDictionary<NSString *, id> *result = [rule mutableCopy];
    result[@"armed"] = [rule[@"remainingCount"] integerValue] > 0 ? @YES : @NO;
    return result;
}

- (void)writerStarted:(id)writer {
    [_lock lock];
    [_starts setObject:@(++_startOrder) forKey:writer];
    [_lock unlock];
}

- (NSError *)failureForWriter:(id)writer mediaType:(NSString *)mediaType {
    [_lock lock];
    @try {
        NSError *existing = [_reservedFailures objectForKey:writer];
        if (existing) return existing;
        NSString *media = _writerRule[@"mediaType"];
        if (media && ![media isEqual:@"either"] && ![media isEqual:mediaType]) return nil;
        NSUInteger start = [[_starts objectForKey:writer] unsignedIntegerValue];
        if ([_writerRule[@"trigger"] isEqual:@"nextWriter"] &&
            (start <= _armedAfter || start > _armedThrough)) return nil;
        return [self consume:_writerRule object:writer code:_writerCode underlying:_underlyingCode kind:@"writer"];
    } @finally { [_lock unlock]; }
}

- (NSError *)failureForExport:(id)session {
    [_lock lock];
    @try {
        return [_reservedFailures objectForKey:session] ?: [self consume:_exportRule object:session code:-11847 underlying:0 kind:@"export"];
    } @finally { [_lock unlock]; }
}

- (NSError *)consume:(NSMutableDictionary<NSString *, id> *)rule object:(id)object code:(NSInteger)code underlying:(NSInteger)underlying kind:(NSString *)kind {
    NSInteger remaining = [rule[@"remainingCount"] integerValue];
    if (remaining <= 0) return nil;
    rule[@"remainingCount"] = @(remaining - 1);
    rule[@"firedCount"] = @([rule[@"firedCount"] integerValue] + 1);
    NSMutableDictionary<NSString *, id> *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = code == -11847 ? @"Operation Interrupted" : code == -11819 ? @"Cannot Complete Action" : @"The operation could not be completed";
    if (underlying) info[NSUnderlyingErrorKey] = [NSError errorWithDomain:NSOSStatusErrorDomain code:underlying userInfo:nil];
    NSError *error = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:code userInfo:info];
    [_reservedFailures setObject:error forKey:object];
    _logger([NSString stringWithFormat:@"%@ fault fired code=%ld remaining=%ld", kind, (long)code, (long)(remaining - 1)]);
    return error;
}

- (NSError *)errorForObject:(id)object {
    [_lock lock];
    NSError *error = [_reservedFailures objectForKey:object];
    [_lock unlock];
    return error;
}
@end
