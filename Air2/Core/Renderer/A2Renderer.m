//
//  A2Renderer.m
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  见头文件：机制与决策收敛，加载归 Natives。
//  只用 Foundation；可空字符串一律按“未设置”处理，避免上层传 @"" 时误判。
//

#import "A2Renderer.h"

NSString *const A2RendererBridgeGL = @"gl";
NSString *const A2RendererBridgeOSMesa = @"osm";
NSString *const A2RendererBridgeVulkan = @"vk";

@implementation A2Renderer

- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                         dylibName:(NSString *)dylibName
                             notes:(NSString *)notes {
    self = [super init];
    if (!self) return nil;
    _identifier = [identifier copy];
    _displayName = [displayName copy];
    _dylibName = [dylibName copy];
    _notes = [notes copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    // 不可变对象，直接返回 self（ARC 下安全，ZL2 的 data class 同理不可变）。
    return self;
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:A2Renderer.class]) return NO;
    return [self.identifier isEqualToString:((A2Renderer *)object).identifier];
}

- (NSUInteger)hash {
    return self.identifier.hash;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<A2Renderer %@ %@>", self.identifier, self.displayName];
}

@end

@interface A2Renderers ()
@property (nonatomic, strong) NSMutableArray<A2Renderer *> *ordered;
@property (nonatomic, strong) NSMutableDictionary<NSString *, A2Renderer *> *byIdentifier;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@end

@implementation A2Renderers

+ (instancetype)shared {
    static A2Renderers *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[A2Renderers alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _ordered = [NSMutableArray array];
    _byIdentifier = [NSMutableDictionary dictionary];
    _syncQueue = dispatch_queue_create("dev.airdevs.air2.renderers", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)resetForTesting {
    dispatch_sync(self.syncQueue, ^{
        [self.ordered removeAllObjects];
        [self.byIdentifier removeAllObjects];
    });
}

- (BOOL)registerRenderer:(A2Renderer *)renderer {
    // identifier 为空是调用方 bug，直接拒绝，避免污染注册表。
    if (!renderer || renderer.identifier.length == 0) return NO;
    __block BOOL ok = NO;
    dispatch_sync(self.syncQueue, ^{
        if (self.byIdentifier[renderer.identifier]) {
            ok = NO;
            return;
        }
        [self.ordered addObject:renderer];
        self.byIdentifier[renderer.identifier] = renderer;
        ok = YES;
    });
    return ok;
}

- (NSArray<NSString *> *)allIdentifiers {
    __block NSArray<NSString *> *out = @[];
    dispatch_sync(self.syncQueue, ^{
        NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:self.ordered.count];
        for (A2Renderer *r in self.ordered) [ids addObject:r.identifier];
        out = [ids copy];
    });
    return out;
}

- (A2Renderer *)rendererForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    __block A2Renderer *out = nil;
    dispatch_sync(self.syncQueue, ^{
        out = self.byIdentifier[identifier];
    });
    return out;
}

- (NSString *)resolveEffectiveIdentifierWithVersionRenderer:(NSString *)versionRenderer
                                            globalRenderer:(NSString *)globalRenderer
                                             allowFallback:(BOOL)allowFallback {
    // 版本级优先（非空才算覆盖，空串按跟随全局处理）。
    NSString *candidate = versionRenderer.length ? versionRenderer : nil;
    if (!candidate) candidate = globalRenderer.length ? globalRenderer : nil;
    if (candidate && [self rendererForIdentifier:candidate]) return candidate;
    // 指定了但未注册：allowFallback 时回落首个，否则 nil 让调用方明确报错。
    if (!allowFallback) return nil;
    __block NSString *first = nil;
    dispatch_sync(self.syncQueue, ^{
        first = self.ordered.firstObject.identifier;
    });
    return first;
}

@end
