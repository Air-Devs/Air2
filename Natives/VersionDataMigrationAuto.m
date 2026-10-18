// ★ [VI-MIGRATE-AUTO] 版本隔离「自动识别迁移」引擎实现。
// 纯 Foundation（自带 zip inflate + gzip/NBT，不依赖 zlib / UnzipKit），故可在 Mac 上
// 单独编一个 harness 直接跑真 mod jar / pack.mcmeta / level.dat 验证分类判定。
// 设计依据与约束见 VersionDataMigrationAuto.h 头部注释。

#import "VersionDataMigrationAuto.h"
#import "VersionDataMigration.h"   // ★ 复用既有迁移引擎（确认后执行）

NSString *const ameVIACatMod          = @"mods";
NSString *const ameVIACatResourcePack = @"resourcepacks";
NSString *const ameVIACatShaderPack   = @"shaderpacks";
NSString *const ameVIACatDataPack     = @"datapacks";
NSString *const ameVIACatWorld        = @"saves";
NSString *const ameVIACatConfig       = @"config";
NSString *const ameVIACatRoot         = @".";
NSString *const ameVIACatOther        = @"other";

NSString *const ameVIALoaderFabric  = @"fabric";
NSString *const ameVIALoaderQuilt   = @"quilt";
NSString *const ameVIALoaderForge   = @"forge";
NSString *const ameVIALoaderNeoForge= @"neoforge";
NSString *const ameVIALoaderVanilla = @"vanilla";

// ★ [VI-ORIGIN] 来源常量
NSString *const ameVIAOriginLoader  = @"loader";
NSString *const ameVIAOriginPlayer  = @"player";
NSString *const ameVIAOriginMod     = @"mod";
NSString *const ameVIAOriginUnknown = @"unknown";

#pragma mark - 小工具

static inline unsigned ameVIARd16(const unsigned char *p) { return p[0] | (p[1] << 8); }
static inline unsigned ameVIARd32(const unsigned char *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((unsigned)p[3] << 24); }
static inline unsigned ameVIARd16be(const unsigned char *p) { return (p[0] << 8) | p[1]; }
static inline unsigned ameVIARd32be(const unsigned char *p) { return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }
static inline long long ameVIARd64be(const unsigned char *p) {
    long long v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | p[i]; return v;
}

static NSString *ameVIAStr(id v) { return [v isKindOfClass:NSString.class] ? (NSString *)v : nil; }

#pragma mark - 自带 DEFLATE 解压（puff 风格，无 zlib 依赖）

#define AMEVIA_MAXBITS 15

typedef struct { short count[AMEVIA_MAXBITS + 1]; short symbol[288]; } ameVIAHuffman;

typedef struct {
    const unsigned char *in; size_t inlen, incnt;
    unsigned long bitbuf; int bitcnt;
    unsigned char *out; size_t outcap, outcnt;
    int err;
} ameVIAInf;

static const short kLens[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
static const short kLext[29] = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0};
static const short kDists[30] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
static const short kDext[30] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13};

static int ameVIBits(ameVIAInf *s, int need) {
    unsigned long val = s->bitbuf;
    while (s->bitcnt < need) {
        if (s->incnt >= s->inlen) { s->err = -101; return 0; }
        val |= (unsigned long)s->in[s->incnt++] << s->bitcnt;
        s->bitcnt += 8;
    }
    s->bitbuf = val >> need;
    s->bitcnt -= need;
    return (int)(val & ((1UL << need) - 1));
}

static int ameVIPut(ameVIAInf *s, int ch) {
    if (s->outcnt >= s->outcap) {
        size_t nc = s->outcap ? s->outcap * 2 : 65536;
        unsigned char *np = realloc(s->out, nc);
        if (!np) { s->err = -102; return -1; }
        s->out = np; s->outcap = nc;
    }
    s->out[s->outcnt++] = (unsigned char)ch;
    return 0;
}

static int ameVIADecode(ameVIAInf *s, ameVIAHuffman *h) {
    int len, code, first, count, index;
    code = first = index = 0;
    for (len = 1; len <= AMEVIA_MAXBITS; len++) {
        code |= ameVIBits(s, 1);
        count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -103;
}

static int ameVIAConstruct(ameVIAHuffman *h, short *length, int n) {
    int symbol, len, left;
    short offs[AMEVIA_MAXBITS + 1];
    for (len = 0; len <= AMEVIA_MAXBITS; len++) h->count[len] = 0;
    for (symbol = 0; symbol < n; symbol++) h->count[length[symbol]]++;
    if (h->count[0] == n) return 0;          // 全 0 长度：合法但无码
    left = 1;
    for (len = 1; len <= AMEVIA_MAXBITS; len++) {
        left <<= 1;
        left -= h->count[len];
        if (left < 0) return left;           // 过订阅
    }
    offs[1] = 0;
    for (len = 1; len < AMEVIA_MAXBITS; len++) offs[len + 1] = offs[len] + h->count[len];
    for (symbol = 0; symbol < n; symbol++)
        if (length[symbol] != 0) h->symbol[offs[length[symbol]]++] = symbol;
    return left;
}

static int ameVIAStored(ameVIAInf *s) {
    s->bitbuf = 0; s->bitcnt = 0;            // 丢弃到字节边界
    if (s->incnt + 4 > s->inlen) return -110;
    unsigned len  = ameVIARd16(s->in + s->incnt);
    unsigned nlen = ameVIARd16(s->in + s->incnt + 2);
    s->incnt += 4;
    if ((len ^ 0xffffu) != nlen) return -111;
    if (s->incnt + len > s->inlen) return -112;
    for (unsigned i = 0; i < len; i++) if (ameVIPut(s, s->in[s->incnt++])) return -113;
    return 0;
}

static int ameVIAFixed(ameVIAInf *s, ameVIAHuffman *lencode, ameVIAHuffman *distcode) {
    int symbol;
    short lengths[288];
    for (symbol = 0; symbol < 144; symbol++) lengths[symbol] = 8;
    for (; symbol < 256; symbol++) lengths[symbol] = 9;
    for (; symbol < 280; symbol++) lengths[symbol] = 7;
    for (; symbol < 288; symbol++) lengths[symbol] = 8;
    if (ameVIAConstruct(lencode, lengths, 288) < 0) return -120;
    for (symbol = 0; symbol < 30; symbol++) lengths[symbol] = 5;
    if (ameVIAConstruct(distcode, lengths, 30) < 0) return -121;
    return 0;
}

static int ameVIADynamic(ameVIAInf *s, ameVIAHuffman *lencode, ameVIAHuffman *distcode) {
    static const short order[19] = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};
    int symbol, left, index;
    short lengths[320];
    ameVIAHuffman lencnt;
    int hlit  = ameVIBits(s, 5) + 257;
    int hdist = ameVIBits(s, 5) + 1;
    int hclen = ameVIBits(s, 4) + 4;
    for (index = 0; index < 19; index++) lengths[index] = 0;
    for (index = 0; index < hclen; index++) lengths[order[index]] = (short)ameVIBits(s, 3);
    if (ameVIAConstruct(&lencnt, lengths, 19) < 0) return -130;
    index = 0;
    while (index < hlit + hdist) {
        symbol = ameVIADecode(s, &lencnt);
        if (symbol < 0) return -131;
        if (symbol < 16) { lengths[index++] = (short)symbol; }
        else {
            int len = 0, rep;
            if (symbol == 16) { if (index == 0) return -132; len = lengths[index - 1]; rep = 3 + ameVIBits(s, 2); }
            else if (symbol == 17) { rep = 3 + ameVIBits(s, 3); }
            else { rep = 11 + ameVIBits(s, 7); }
            while (rep--) { if (index >= hlit + hdist) return -133; lengths[index++] = (short)len; }
        }
    }
    if (lengths[256] == 0) return -134;
    if (ameVIAConstruct(lencode, lengths, hlit) < 0) return -135;
    if (ameVIAConstruct(distcode, lengths + hlit, hdist) < 0) return -136;
    left = 0; (void)left;
    return 0;
}

static int ameVIAInflateRaw(const unsigned char *in, size_t inlen,
                            unsigned char **outp, size_t *outlenp) {
    ameVIAInf s; memset(&s, 0, sizeof s);
    s.in = in; s.inlen = inlen;
    ameVIAHuffman lencode, distcode;
    int last, type, err = 0;
    do {
        last = ameVIBits(&s, 1);
        type = ameVIBits(&s, 2);
        if (s.err) { err = s.err; break; }
        if (type == 0) err = ameVIAStored(&s);
        else if (type == 1) err = ameVIAFixed(&s, &lencode, &distcode);
        else if (type == 2) err = ameVIADynamic(&s, &lencode, &distcode);
        else err = -140;
        if (err) break;
        for (;;) {
            int sym = ameVIADecode(&s, &lencode);
            if (sym < 0) { err = sym; break; }
            if (sym < 256) { if (ameVIPut(&s, sym)) { err = s.err; break; } }
            else if (sym == 256) break;
            else {
                sym -= 257;
                if (sym >= 29) { err = -141; break; }
                int len = kLens[sym] + ameVIBits(&s, kLext[sym]);
                int dsym = ameVIADecode(&s, &distcode);
                if (dsym < 0 || dsym >= 30) { err = -142; break; }
                int dist = kDists[dsym] + ameVIBits(&s, kDext[dsym]);
                if ((size_t)dist > s.outcnt) { err = -143; break; }
                while (len--) if (ameVIPut(&s, s.out[s.outcnt - dist])) { err = s.err; break; }
                if (s.err) { err = s.err; break; }
            }
        }
        if (err) break;
    } while (!last);
    if (err) { free(s.out); return err; }
    *outp = s.out; *outlenp = s.outcnt;
    return 0;
}

#pragma mark - zip 读取（EOCD → 中央目录 → 局部头 → inflate）

NSData *ameVIAReadZipEntry(NSString *zipPath, NSString *entryName) {
    NSData *file = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:nil];
    if (!file || file.length < 22) return nil;
    const unsigned char *p = file.bytes; size_t n = file.length;

    size_t back = n < (size_t)(22 + 65535) ? n : (size_t)(22 + 65535);
    long eocd = -1;
    for (size_t k = 22; k <= back; k++) {
        size_t off = n - k;
        if (p[off] == 0x50 && p[off+1] == 0x4b && p[off+2] == 0x05 && p[off+3] == 0x06) { eocd = (long)off; break; }
    }
    if (eocd < 0) return nil;
    unsigned cdoff = ameVIARd32(p + eocd + 16);
    unsigned cnt   = ameVIARd16(p + eocd + 10);
    if (cdoff >= n) return nil;

    NSData *want = [entryName dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *wn = want.bytes; size_t wl = want.length;
    size_t q = cdoff;
    for (unsigned i = 0; i < cnt && q + 46 <= n; i++) {
        if (!(p[q] == 0x50 && p[q+1] == 0x4b && p[q+2] == 0x01 && p[q+3] == 0x02)) break;
        unsigned method = ameVIARd16(p + q + 10);
        unsigned csize  = ameVIARd32(p + q + 20);
        unsigned nlen   = ameVIARd16(p + q + 28);
        unsigned elen   = ameVIARd16(p + q + 30);
        unsigned clen   = ameVIARd16(p + q + 32);
        unsigned lho    = ameVIARd32(p + q + 42);
        if (q + 46 + nlen <= n && nlen == wl && memcmp(p + q + 46, wn, wl) == 0) {
            if (lho + 30 > n) return nil;
            unsigned lnlen = ameVIARd16(p + lho + 26);
            unsigned lelen = ameVIARd16(p + lho + 28);
            size_t dataOff = (size_t)lho + 30 + lnlen + lelen;
            if (dataOff + csize > n) return nil;
            if (method == 0) return [NSData dataWithBytes:p + dataOff length:csize];
            if (method == 8) {
                unsigned char *out = NULL; size_t outlen = 0;
                if (ameVIAInflateRaw(p + dataOff, csize, &out, &outlen) != 0) return nil;
                NSData *d = [NSData dataWithBytes:out length:outlen];
                free(out);
                return d;
            }
            return nil;   // 不支持其它压缩方法
        }
        q += 46 + nlen + elen + clen;
    }
    return nil;
}

#pragma mark - gzip + NBT（level.dat）

static NSData *ameVIAGunzip(NSData *data) {
    const unsigned char *p = data.bytes; size_t n = data.length;
    if (n < 18 || p[0] != 0x1f || p[1] != 0x8b || p[2] != 8) return nil;
    int flg = p[3];
    size_t i = 10;
    if (flg & 4) { if (i + 2 > n) return nil; unsigned xl = ameVIARd16(p + i); i += 2 + xl; }
    if (flg & 8)  { while (i < n && p[i]) i++; i++; }
    if (flg & 16) { while (i < n && p[i]) i++; i++; }
    if (flg & 2)  i += 2;
    if (i >= n) return nil;
    unsigned char *out = NULL; size_t outlen = 0;
    if (ameVIAInflateRaw(p + i, n - i, &out, &outlen) != 0) return nil;
    NSData *d = [NSData dataWithBytes:out length:outlen];
    free(out);
    return d;
}

typedef struct { const unsigned char *p; size_t n, i; } ameVNB;

static NSString *ameVNBName(ameVNB *b) {
    if (b->i + 2 > b->n) return nil;
    unsigned l = ameVIARd16be(b->p + b->i); b->i += 2;
    if (b->i + l > b->n) return nil;
    NSString *s = [[NSString alloc] initWithBytes:b->p + b->i length:l encoding:NSUTF8StringEncoding];
    b->i += l;
    return s;
}

static id ameVNBValue(ameVNB *b, int type) {
    switch (type) {
        case 1: { if (b->i + 1 > b->n) return nil; int v = b->p[b->i]; b->i += 1; return @(v); }
        case 2: { if (b->i + 2 > b->n) return nil; short v = (short)ameVIARd16be(b->p + b->i); b->i += 2; return @(v); }
        case 3: { if (b->i + 4 > b->n) return nil; int v = (int)ameVIARd32be(b->p + b->i); b->i += 4; return @(v); }
        case 4: { if (b->i + 8 > b->n) return nil; long long v = ameVIARd64be(b->p + b->i); b->i += 8; return @(v); }
        case 5: { if (b->i + 4 > b->n) return nil; unsigned u = ameVIARd32be(b->p + b->i); float f; memcpy(&f, &u, 4); b->i += 4; return @(f); }
        case 6: { if (b->i + 8 > b->n) return nil; long long v = ameVIARd64be(b->p + b->i); double d; memcpy(&d, &v, 8); b->i += 8; return @(d); }
        case 7: { if (b->i + 4 > b->n) return nil; int l = (int)ameVIARd32be(b->p + b->i); b->i += 4;
                  if (l < 0 || b->i + (size_t)l > b->n) return nil; id v = [NSData dataWithBytes:b->p + b->i length:l]; b->i += l; return v; }
        case 8: { return ameVNBName(b); }
        case 9: {
            if (b->i + 5 > b->n) return nil;
            int et = b->p[b->i]; b->i += 1;
            int l = (int)ameVIARd32be(b->p + b->i); b->i += 4;
            if (l < 0) return nil;
            NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)MIN(l, 1024)];
            for (int k = 0; k < l; k++) { id v = ameVNBValue(b, et); if (!v) return nil; [a addObject:v]; }
            return a;
        }
        case 10: {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            for (;;) {
                if (b->i + 1 > b->n) return nil;
                int t = b->p[b->i]; b->i += 1;
                if (t == 0) break;
                NSString *name = ameVNBName(b);
                if (!name) return nil;
                id v = ameVNBValue(b, t);
                if (v) d[name] = v;
            }
            return d;
        }
        case 11: { if (b->i + 4 > b->n) return nil; int l = (int)ameVIARd32be(b->p + b->i); b->i += 4;
                   if (l < 0 || b->i + (size_t)l * 4 > b->n) return nil;
                   NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)MIN(l, 1024)];
                   for (int k = 0; k < l; k++) { [a addObject:@((int)ameVIARd32be(b->p + b->i))]; b->i += 4; } return a; }
        case 12: { if (b->i + 4 > b->n) return nil; int l = (int)ameVIARd32be(b->p + b->i); b->i += 4;
                   if (l < 0 || b->i + (size_t)l * 8 > b->n) return nil;
                   NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)MIN(l, 1024)];
                   for (int k = 0; k < l; k++) { [a addObject:@(ameVIARd64be(b->p + b->i))]; b->i += 8; } return a; }
        default: return nil;
    }
}

static NSDictionary *ameVIANBTParse(NSData *data) {
    if (!data || data.length < 3) return nil;
    ameVNB b = { data.bytes, data.length, 0 };
    if (b.i + 1 > b.n) return nil;
    int t = b.p[b.i]; b.i += 1;
    if (t != 10) return nil;
    (void)ameVNBName(&b);            // 根名（通常为空）
    id root = ameVNBValue(&b, 10);
    return [root isKindOfClass:NSDictionary.class] ? (NSDictionary *)root : nil;
}

NSDictionary *ameVIAReadLevelDat(NSString *levelDatPath) {
    NSData *raw = [NSData dataWithContentsOfFile:levelDatPath options:NSDataReadingMappedIfSafe error:nil];
    if (!raw || raw.length < 3) return nil;
    NSData *nbt = ameVIAGunzip(raw);
    if (!nbt) {
        const unsigned char *p = raw.bytes;
        if (p[0] == 0x0a) nbt = raw;   // 未压缩 NBT 兜底
        else return nil;
    }
    NSDictionary *root = ameVIANBTParse(nbt);
    if (!root) return nil;
    NSDictionary *data = [root[@"Data"] isKindOfClass:NSDictionary.class] ? root[@"Data"] : root;
    id dv = data[@"DataVersion"];
    NSString *vn = nil;
    id ver = data[@"Version"];
    if ([ver isKindOfClass:NSDictionary.class]) vn = ameVIAStr(((NSDictionary *)ver)[@"Name"]);
    return @{ @"dataVersion": [dv isKindOfClass:NSNumber.class] ? dv : NSNull.null,
              @"versionName": vn ?: NSNull.null };
}

#pragma mark - 版本号 / 加载器 解析

static BOOL ameVIAIsDigit(unichar c) { return c >= '0' && c <= '9'; }

/// 抽 MC 版本：优先第一个「像 MC 版本」的 a.b[.c]；否则快照 yy##w##[a-z]。
/// 「像 MC」= 主号 == 1 且次号 <= 21（1.0~1.21），或主号在 20..40 且恰好两段（26.2/26.3）。
NSString *ameVIAExtractMCVersion(NSString *s) {
    if (s.length == 0) return nil;
    NSArray<NSString *> *m = [s componentsSeparatedByCharactersInSet:
                              [NSCharacterSet characterSetWithCharactersInString:@" \t_/\\"]];
    NSString *joined = [m componentsJoinedByString:@"-"];
    NSUInteger n = joined.length;
    NSString *firstSnap = nil;
    for (NSUInteger i = 0; i < n; i++) {
        if (!ameVIAIsDigit([joined characterAtIndex:i])) continue;
        NSUInteger j = i;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        while (j < n) {
            NSUInteger k = j;
            while (k < n && ameVIAIsDigit([joined characterAtIndex:k])) k++;
            if (k == j) break;
            [parts addObject:[joined substringWithRange:NSMakeRange(j, k - j)]];
            if (k < n && [joined characterAtIndex:k] == '.') { j = k + 1; if ([parts count] >= 3) break; }
            else { j = k; break; }
        }
        if (parts.count < 2 || parts.count > 3) { continue; }
        NSInteger major = parts[0].integerValue;
        NSInteger minor = parts[1].integerValue;
        BOOL looksMC = (major == 1 && minor <= 21) || (major >= 20 && major <= 40 && parts.count == 2);
        if (!looksMC) { continue; }
        // 相邻快照写法 yy##w## 单独处理（不在 a.b 形态里）
        return [parts componentsJoinedByString:@"."];
    }
    // 快照 24w14a
    for (NSUInteger i = 0; i + 5 < n; i++) {
        if (ameVIAIsDigit([joined characterAtIndex:i]) && ameVIAIsDigit([joined characterAtIndex:i+1])
            && [joined characterAtIndex:i+2] == 'w'
            && ameVIAIsDigit([joined characterAtIndex:i+3]) && ameVIAIsDigit([joined characterAtIndex:i+4])) {
            NSUInteger k = i + 5;
            while (k < n && [joined characterAtIndex:k] >= 'a' && [joined characterAtIndex:k] <= 'z') k++;
            firstSnap = [joined substringWithRange:NSMakeRange(i, k - i)];
            break;
        }
    }
    return firstSnap;
}

NSString *ameVIAExtractLoader(NSString *s) {
    if (s.length == 0) return nil;
    NSString *low = s.lowercaseString;
    if ([low containsString:@"neoforge"]) return ameVIALoaderNeoForge;
    if ([low containsString:@"forge"]) return ameVIALoaderForge;
    if ([low containsString:@"quilt"]) return ameVIALoaderQuilt;
    if ([low containsString:@"fabric"]) return ameVIALoaderFabric;
    return nil;
}

static NSArray<NSString *> *ameVIAVersionParts(NSString *v) {
    if (v.length == 0) return @[];
    NSString *core = v;
    NSRange dash = [core rangeOfString:@"-"];
    if (dash.location != NSNotFound) core = [core substringToIndex:dash.location];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *seg in [core componentsSeparatedByString:@"."]) {
        if (seg.length == 0) continue;
        // 纯数字才作数（"21a" 之类截数字前缀）
        NSUInteger k = 0;
        while (k < seg.length && ameVIAIsDigit([seg characterAtIndex:k])) k++;
        if (k == 0) return @[core.lowercaseString];   // 非数值版本（快照）：整串比较
        [out addObject:[seg substringToIndex:k]];
    }
    return out;
}

static NSInteger ameVIACompareVersion(NSString *a, NSString *b) {
    NSArray *pa = ameVIAVersionParts(a), *pb = ameVIAVersionParts(b);
    if (pa.count && [pa[0] isKindOfClass:NSString.class] && ![pa[0] integerValue] && !ameVIAIsDigit([pa[0] characterAtIndex:0])) {
        return [a compare:b];
    }
    NSUInteger m = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < m; i++) {
        NSInteger x = i < pa.count ? [pa[i] integerValue] : 0;
        NSInteger y = i < pb.count ? [pb[i] integerValue] : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}

/// 把版本区间化成「代表版本」（区间取下界）。
static NSString *ameVIAVersionRepFromRange(NSString *range) {
    if (range.length == 0) return nil;
    NSString *r = [range stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (r.length == 0) return nil;
    if ([r isEqualToString:@"*"] || [r isEqualToString:@"+"]) return nil;
    // 去掉 Fabric 的尾部 "-"（">=1.21-"）
    while (r.length && [r hasSuffix:@"-"]) r = [r substringToIndex:r.length - 1];
    unichar c0 = [r characterAtIndex:0];
    if (c0 == '[' || c0 == '(') {
        NSString *inner = r;
        NSRange comma = [inner rangeOfString:@","];
        if (comma.location != NSNotFound) inner = [inner substringToIndex:comma.location];
        inner = [inner substringFromIndex:1];
        inner = [inner stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return inner.length ? inner : nil;
    }
    if ([r hasPrefix:@">="]) {
        NSString *rest = [r substringFromIndex:2];
        NSRange sp = [rest rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
        if (sp.location != NSNotFound) rest = [rest substringToIndex:sp.location];
        return ameVIAExtractMCVersion(rest) ?: ([rest length] ? rest : nil);
    }
    if ([r hasPrefix:@"~"]) {
        NSString *rest = [r substringFromIndex:1];
        NSRange sp = [rest rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
        if (sp.location != NSNotFound) rest = [rest substringToIndex:sp.location];
        return ameVIAExtractMCVersion(rest) ?: ([rest length] ? rest : nil);
    }
    if ([r hasPrefix:@">"] || [r hasPrefix:@"<"]) {
        NSString *rest = [r substringFromIndex:1];
        if ([rest hasPrefix:@"="]) rest = [rest substringFromIndex:1];
        NSRange sp = [rest rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
        if (sp.location != NSNotFound) rest = [rest substringToIndex:sp.location];
        return ameVIAExtractMCVersion(rest) ?: ([rest length] ? rest : nil);
    }
    return ameVIAExtractMCVersion(r) ?: r;
}

BOOL ameVIAVersionInRange(NSString *concrete, NSString *range) {
    if (concrete.length == 0) return NO;
    if (range.length == 0) return YES;
    NSString *r = [range stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (r.length == 0 || [r isEqualToString:@"*"] || [r isEqualToString:@"+"]) return YES;

    // 1) Maven 区间 [lo,hi) / (lo,hi] / [lo,]
    unichar c0 = [r characterAtIndex:0];
    if (c0 == '[' || c0 == '(') {
        BOOL loInc = (c0 == '[');
        NSRange close = [r rangeOfString:@"]"];
        NSRange closeP = [r rangeOfString:@")"];
        BOOL hiInc = NO; NSRange closeR = NSMakeRange(NSNotFound, 0);
        if (close.location != NSNotFound && closeP.location != NSNotFound) {
            closeR = close.location < closeP.location ? close : closeP;
            hiInc = (close.location < closeP.location);
        } else if (close.location != NSNotFound) { closeR = close; hiInc = YES; }
        else if (closeP.location != NSNotFound) { closeR = closeP; hiInc = NO; }
        if (closeR.location == NSNotFound) return NO;
        NSString *inner = [r substringWithRange:NSMakeRange(1, closeR.location - 1)];
        NSArray *bounds = [inner componentsSeparatedByString:@","];
        NSString *lo = [bounds.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *hi = bounds.count > 1 ? [bounds[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        while (lo.length && [lo hasSuffix:@"-"]) lo = [lo substringToIndex:lo.length - 1];
        while (hi.length && [hi hasSuffix:@"-"]) hi = [hi substringToIndex:hi.length - 1];
        if (lo.length) { NSInteger c = ameVIACompareVersion(concrete, lo); if (c < 0 || (c == 0 && !loInc)) return NO; }
        if (hi.length) { NSInteger c = ameVIACompareVersion(concrete, hi); if (c > 0 || (c == 0 && !hiInc)) return NO; }
        return YES;
    }
    // 2) 复合比较 ">=1.21 <1.22"
    if ([r containsString:@">="] || [r containsString:@"<="] ||
        [r containsString:@">"]  || [r containsString:@"<"]) {
        BOOL any = NO;
        for (NSString *tok in [r componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
            NSString *t = tok;
            while (t.length && [t hasSuffix:@","]) t = [t substringToIndex:t.length - 1];
            if (t.length == 0) continue;
            NSString *op = @""; NSString *val = t;
            if ([t hasPrefix:@">="]) { op = @">="; val = [t substringFromIndex:2]; }
            else if ([t hasPrefix:@"<="]) { op = @"<="; val = [t substringFromIndex:2]; }
            else if ([t hasPrefix:@">"]) { op = @">"; val = [t substringFromIndex:1]; }
            else if ([t hasPrefix:@"<"]) { op = @"<"; val = [t substringFromIndex:1]; }
            else if ([t hasPrefix:@"~"]) { op = @"~"; val = [t substringFromIndex:1]; }
            while (val.length && [val hasSuffix:@"-"]) val = [val substringToIndex:val.length - 1];
            if (val.length == 0) continue;
            any = YES;
            NSInteger c = ameVIACompareVersion(concrete, val);
            if ([op isEqualToString:@">="] && c < 0) return NO;
            if ([op isEqualToString:@">"]  && c <= 0) return NO;
            if ([op isEqualToString:@"<="] && c > 0) return NO;
            if ([op isEqualToString:@"<"]  && c >= 0) return NO;
            if ([op isEqualToString:@"~"]) {
                NSArray *vp = ameVIAVersionParts(val);
                NSInteger lo = vp.count ? [vp[0] integerValue] : 0;
                NSInteger mi = vp.count > 1 ? [vp[1] integerValue] : -1;
                if (mi >= 0) {
                    NSString *hi = [NSString stringWithFormat:@"%ld.%ld", (long)lo, (long)mi + 1];
                    NSInteger ch = ameVIACompareVersion(concrete, hi);
                    if (c < 0 || ch >= 0) return NO;
                }
            }
        }
        if (any) return YES;
    }
    // 3) "~x.y" 单独出现 = >=x.y <x.(y+1)；其余单值 = 精确匹配（不再前缀放宽）
    if ([r hasPrefix:@"~"]) {
        NSString *val = [r substringFromIndex:1];
        while (val.length && [val hasSuffix:@"-"]) val = [val substringToIndex:val.length - 1];
        NSString *lit = ameVIAExtractMCVersion(val) ?: val;
        NSArray *vp = ameVIAVersionParts(lit);
        if (vp.count >= 2) {
            NSString *hi = [NSString stringWithFormat:@"%ld.%ld",
                            (long)[vp[0] integerValue], (long)[vp[1] integerValue] + 1];
            NSInteger cl = ameVIACompareVersion(concrete, lit);
            NSInteger ch = ameVIACompareVersion(concrete, hi);
            return (cl >= 0 && ch < 0);
        }
        return ameVIACompareVersion(concrete, lit) == 0;
    }
    NSString *lit = ameVIAExtractMCVersion(r) ?: r;
    return [concrete caseInsensitiveCompare:lit] == NSOrderedSame;
}

#pragma mark - pack_format / DataVersion 表

static NSString *ameVIAMCVersionForPackFormat(NSInteger f, NSString **outNote) {
    switch (f) {
        case 1:  *outNote = @"1.6.1–1.8.9";   return @"1.8.9";
        case 2:  *outNote = @"1.9–1.10.2";    return @"1.10.2";
        case 3:  *outNote = @"1.11–1.12.2";   return @"1.12.2";
        case 4:  *outNote = @"1.13–1.14.4";   return @"1.14.4";
        case 5:  *outNote = @"1.15–1.16.1";   return @"1.16.1";
        case 6:  *outNote = @"1.16.2–1.16.5"; return @"1.16.5";
        case 7:  *outNote = @"1.17–1.17.1";   return @"1.17.1";
        case 8:  *outNote = @"1.18–1.18.2";   return @"1.18.2";
        case 9:  *outNote = @"1.19–1.19.2";   return @"1.19.2";
        case 12: *outNote = @"1.19.3";        return @"1.19.3";
        case 13: *outNote = @"1.19.4";        return @"1.19.4";
        case 15: *outNote = @"1.20–1.20.1";   return @"1.20.1";
        case 18: *outNote = @"1.20.2";        return @"1.20.2";
        case 22: *outNote = @"1.20.3–1.20.4"; return @"1.20.4";
        case 32: *outNote = @"1.20.5–1.20.6"; return @"1.20.6";
        case 34: *outNote = @"1.21–1.21.1";   return @"1.21.1";
        case 42: *outNote = @"1.21.2–1.21.3"; return @"1.21.3";
        case 46: *outNote = @"1.21.4";        return @"1.21.4";
        case 55: *outNote = @"1.21.5";        return @"1.21.5";
        case 63: *outNote = @"1.21.6";        return @"1.21.6";
        default: *outNote = nil;              return nil;
    }
}

static NSString *ameVIAMCVersionForDataVersion(NSInteger dv) {
    switch (dv) {
        case 3465: return @"1.20.1";
        case 3463: return @"1.20";
        case 3337: return @"1.19.4";
        case 3120: return @"1.19.2";
        case 3105: return @"1.19";
        case 2865: return @"1.18.2";
        case 2860: return @"1.18.1";
        case 2825: return @"1.18";
        case 2730: return @"1.17.1";
        case 2724: return @"1.17";
        case 2586: return @"1.16.5";
        case 2584: return @"1.16.4";
        case 2567: return @"1.16.2";
        case 2566: return @"1.16.1";
        case 2230: return @"1.15.2";
        case 2202: return @"1.15";
        case 1976: return @"1.14.4";
        case 1901: return @"1.14";
        case 1631: return @"1.13.2";
        case 1519: return @"1.13";
        case 1343: return @"1.12.2";
        default: return nil;
    }
}

#pragma mark - pack.mcmeta

NSInteger ameVIAPackFormatAtPath(NSString *path) {
    NSData *mc = nil;
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) {
        if (isDir) mc = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"pack.mcmeta"]];
        else mc = ameVIAReadZipEntry(path, @"pack.mcmeta");
    }
    if (!mc) return -1;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:mc options:0 error:nil];
    if (![j isKindOfClass:NSDictionary.class]) return -1;
    id pack = j[@"pack"];
    id fmt = [pack isKindOfClass:NSDictionary.class] ? ((NSDictionary *)pack)[@"pack_format"] : nil;
    if ([fmt isKindOfClass:NSNumber.class]) return [(NSNumber *)fmt integerValue];
    return -1;
}

#pragma mark - mods.toml 解析（面向 [[dependencies]] 的定向解析）

static NSString *ameVIATrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
static NSString *ameVIAStripQuotes(NSString *v) {
    NSRange q1 = [v rangeOfString:@"\""];
    if (q1.location == NSNotFound) return ameVIATrim(v);
    NSUInteger start = q1.location + 1;
    if (start > v.length) return @"";
    NSRange rest = NSMakeRange(start, v.length - start);
    NSRange q2 = [v rangeOfString:@"\"" options:0 range:rest];
    if (q2.location == NSNotFound) return ameVIATrim(v);
    return [v substringWithRange:NSMakeRange(start, q2.location - start)];
}

static NSDictionary *ameVIAParseModsToml(NSString *s) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSMutableArray<NSMutableDictionary *> *deps = [NSMutableArray array];
    NSMutableDictionary *curDep = nil;
    NSString *modId = nil;
    BOOL inMods = NO;
    NSArray<NSString *> *lines = [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *raw in lines) {
        NSString *line = ameVIATrim(raw);
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        if ([line hasPrefix:@"[["]) {
            if (curDep) { [deps addObject:curDep]; curDep = nil; }
            NSRange end = [line rangeOfString:@"]]"];
            NSString *inner = end.location != NSNotFound ? [line substringWithRange:NSMakeRange(2, end.location - 2)] : line;
            inMods = [inner isEqualToString:@"mods"];
            if ([inner hasPrefix:@"dependencies"]) curDep = [NSMutableDictionary dictionary];
            continue;
        }
        if ([line hasPrefix:@"["]) {
            if (curDep) { [deps addObject:curDep]; curDep = nil; }
            inMods = NO;
            continue;
        }
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = ameVIATrim([line substringToIndex:eq.location]);
        NSString *v = ameVIATrim([line substringFromIndex:eq.location + 1]);
        v = ameVIAStripQuotes(v);
        if (curDep) {
            curDep[k] = v;
        } else if (inMods && [k isEqualToString:@"modId"] && !modId) {
            modId = v;
        } else if ([k isEqualToString:@"loaderVersion"]) {
            out[@"loaderVersion"] = v;
        } else if ([k isEqualToString:@"modLoader"]) {
            out[@"modLoader"] = v;
        }
    }
    if (curDep) [deps addObject:curDep];
    for (NSDictionary *d in deps) {
        if ([d[@"modId"] isEqualToString:@"minecraft"]) { out[@"mcRange"] = d[@"versionRange"]; break; }
    }
    if (modId) out[@"modId"] = modId;
    return out;
}

// Forge 构建号（loaderVersion 主号）→ MC 版本（弱推断，仅作最后兜底）
static NSString *ameVIAMCVersionForForgeBuild(NSInteger b) {
    if (b >= 36 && b <= 37) return @"1.17.1";
    if (b == 38 || b == 39) return @"1.18.1";
    if (b == 40) return @"1.18.2";
    if (b == 41 || b == 42) return @"1.19.2";
    if (b == 43) return @"1.19.3";
    if (b == 44) return @"1.19.4";
    if (b == 45) return @"1.20";
    if (b == 46 || b == 47) return @"1.20.1";
    if (b == 48) return @"1.20.2";
    if (b == 49) return @"1.20.4";
    if (b == 50) return @"1.20.6";
    if (b == 51) return @"1.21";
    if (b == 52) return @"1.21.4";
    return nil;
}

#pragma mark - ★ [VI-ORIGIN] 来源判定（加载器自带 / 玩家添加 / mod 生成 / 未识别）

// 判定优先级（先命中先算；全部只读磁盘 + 名称，不动任何路径）：
//   ① 加载器基线 ⇒ 加载器自带；
//   ② 名称命中已装 mod 的元数据 id ⇒ mod 生成（需收齐所有 mod 单元后再判，见 ameVIAAnnotateOrigins）；
//   ③ 落在 mods/ saves/ resourcepacks/ shaderpacks/ datapacks/ ⇒ 玩家添加；
//   ④ 其余 ⇒ 未识别（不猜）。

/// 加载器/原版基线【顶层目录】：整体由加载器或原版自生成（内部项一并视为基线）。
static NSArray<NSString *> *ameVIABaselineTopDirs(void) {
    static NSArray<NSString *> *a; static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[ @"logs", @"crash-reports", @".fabric", @".mixin.out" ];   // ★ [VI-ORIGIN]
    });
    return a;
}

/// 加载器/原版基线【根散文件】：原版客户端 / 启动器在游戏根自生成（非玩家内容）。
static NSSet<NSString *> *ameVIABaselineRootFiles(void) {
    static NSSet<NSString *> *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[ @"options.txt", @"optionsof.txt", @"servers.dat",
            @"servers.dat_old", @"realms_persistence.json", @"usercache.json",
            @"usernamecache.json", @"launcher_profiles.json", @"launcher_accounts.json",
            @"banned-ips.json", @"banned-players.json", @"ops.json", @"whitelist.json",
            @"eula.txt", @"debug.log", @"debug-profile.json" ]];   // ★ [VI-ORIGIN]
    });
    return s;
}

/// 玩家内容类别（玩家自己放入/创建）。
static BOOL ameVIAIsPlayerCategory(NSString *cat) {
    return [cat isEqualToString:ameVIACatMod] || [cat isEqualToString:ameVIACatWorld] ||
           [cat isEqualToString:ameVIACatResourcePack] || [cat isEqualToString:ameVIACatShaderPack] ||
           [cat isEqualToString:ameVIACatDataPack];
}

/// 命中加载器基线的理由；未命中返回 nil。rel = 相对源根的路径。
static NSString *ameVIAOriginBaselineReason(NSString *rel) {
    NSArray<NSString *> *cps = [rel pathComponents];
    NSString *top = cps.count ? cps.firstObject : @"";
    if ([ameVIABaselineTopDirs() containsObject:top])
        return [NSString stringWithFormat:@"位于加载器/原版自生成目录 %@/（非玩家内容）", top];
    if ([rel isEqualToString:@"config/fabric"] || [rel hasPrefix:@"config/fabric/"])
        return @"fabric 加载器自身配置目录 config/fabric/";
    if (cps.count == 1 && [ameVIABaselineRootFiles() containsObject:top])
        return [NSString stringWithFormat:@"原版/启动器自生成根文件 %@", top];
    return nil;
}

/// 玩家内容类别 → 理由。
static NSString *ameVIAOriginPlayerReason(NSString *cat) {
    if ([cat isEqualToString:ameVIACatMod])          return @"位于 mods/（玩家放入的 mod）";
    if ([cat isEqualToString:ameVIACatWorld])        return @"位于 saves/（玩家创建/游玩的存档）";
    if ([cat isEqualToString:ameVIACatResourcePack]) return @"位于 resourcepacks/（玩家放入的资源包）";
    if ([cat isEqualToString:ameVIACatShaderPack])   return @"位于 shaderpacks/（玩家放入的光影包）";
    if ([cat isEqualToString:ameVIACatDataPack])     return @"位于 datapacks/（玩家放入的数据包）";
    return @"玩家放入/创建的内容";
}

/// 给一个已分类单元补 origin / originReason。此刻尚不知 mod 列表 ⇒ 非基线/玩家的一律先记「未识别」，
/// 待 ameVIAAnnotateOrigins 用已装 mod id 再升级为「mod 生成」。
static NSDictionary *ameVIAApplyOrigin(NSDictionary *u) {
    NSString *rel = ameVIAStr(u[@"unit"]) ?: @"";
    NSString *cat = ameVIAStr(u[@"category"]) ?: @"";
    NSString *breason = ameVIAOriginBaselineReason(rel);
    NSString *origin, *oreason;
    if (breason.length)                 { origin = ameVIAOriginLoader;  oreason = breason; }
    else if (ameVIAIsPlayerCategory(cat)) { origin = ameVIAOriginPlayer; oreason = ameVIAOriginPlayerReason(cat); }
    else                                { origin = ameVIAOriginUnknown; oreason = @"既非加载器基线、也非玩家内容目录（不猜）"; }
    NSMutableDictionary *m = [u mutableCopy];
    m[@"origin"] = origin;       // ★ [VI-ORIGIN]
    m[@"originReason"] = oreason; // ★ [VI-ORIGIN]
    return m;
}

/// 归一 id / 名称：小写 + 去掉 - _ . 与空白（用于大小写/连字符/下划线无关匹配）。
static NSString *ameVIANormalizeId(NSString *s) {
    if (s.length == 0) return @"";
    NSMutableString *o = [NSMutableString string];
    NSString *low = s.lowercaseString;
    for (NSUInteger i = 0; i < low.length; i++) {
        unichar c = [low characterAtIndex:i];
        if (c == '-' || c == '_' || c == '.' || c == ' ' || c == '\t') continue;
        [o appendFormat:@"%C", c];
    }
    return o;
}

/// 名称是否命中某个已装 mod id：归一全等，或按 - _ . 切词后任一词全等（前缀式，如 jei-client ⇒ jei）。
/// 命中返回该 mod 的原始 id，否则 nil。
static NSString *ameVIAIdMatch(NSString *name, NSDictionary<NSString *, NSString *> *idMap) {
    if (name.length == 0 || idMap.count == 0) return nil;
    NSString *norm = ameVIANormalizeId(name);
    if (norm.length >= 2 && idMap[norm]) return idMap[norm];
    NSArray<NSString *> *tokens = [name componentsSeparatedByCharactersInSet:
                                   [NSCharacterSet characterSetWithCharactersInString:@"-_. "]];
    for (NSString *t in tokens) {
        if (t.length < 2) continue;
        NSString *tn = ameVIANormalizeId(t);
        if (tn.length >= 2 && idMap[tn]) return idMap[tn];
    }
    return nil;
}

NSArray<NSDictionary *> *ameVIAAnnotateOrigins(NSArray<NSDictionary *> *units) {
    if (units.count == 0) return units ?: @[];
    // 1) 收齐【已装 mod 的元数据 id】（来自 mods/*.jar 的 fabric/quilt/forge/neoforge 解析结果）。
    NSMutableDictionary<NSString *, NSString *> *idMap = [NSMutableDictionary dictionary];
    for (NSDictionary *u in units) {
        if (![ameVIAStr(u[@"category"]) isEqualToString:ameVIACatMod]) continue;
        NSString *mid = ameVIAStr(u[@"modId"]);
        if (mid.length < 2) continue;
        NSString *n = ameVIANormalizeId(mid);
        if (n.length >= 2) idMap[n] = mid;
    }
    // 2) 只把「未识别」的项升级为「mod 生成」（基线/玩家已定性，不覆盖）。
    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:units.count];
    for (NSDictionary *u in units) {
        NSString *origin = ameVIAStr(u[@"origin"]);
        if (origin.length && ![origin isEqualToString:ameVIAOriginUnknown]) { [out addObject:u]; continue; }
        NSString *name = [u[@"unit"] lastPathComponent] ?: @"";
        NSString *stem = [name stringByDeletingPathExtension];
        NSString *hit = ameVIAIdMatch(stem, idMap);
        if (hit.length) {
            NSMutableDictionary *m = [u mutableCopy];
            m[@"origin"] = ameVIAOriginMod;       // ★ [VI-ORIGIN]
            m[@"originReason"] = [NSString stringWithFormat:@"名称「%@」命中已装 mod「%@」⇒ 该 mod 运行时生成", stem, hit];
            m[@"originModId"] = hit;
            [out addObject:m];
        } else {
            [out addObject:u];   // 维持未识别
        }
    }
    return out;
}

#pragma mark - 单元分类

static NSDictionary *ameVIAMakeUnit(NSString *srcRoot, NSString *rel, NSString *cat, NSString *ver,
                                    NSString *range, NSString *loader, NSString *reason) {
    NSString *abs = [srcRoot stringByAppendingPathComponent:rel];
    NSDictionary *scan = ameVDMScanPath(abs);
    return @{
        @"unit": rel, @"abs": abs, @"category": cat,
        @"isDir": @([[NSFileManager defaultManager] fileExistsAtPath:abs isDirectory:NULL]),
        @"files": scan[@"files"], @"bytes": scan[@"bytes"],
        @"mcVersion": ver ?: NSNull.null,
        @"mcRange": range ?: NSNull.null,
        @"loader": loader ?: NSNull.null,
        @"reason": reason ?: @"",
    };
}

static NSDictionary *ameVIAModUnit(NSDictionary *u, NSString *modId) {
    if (modId.length == 0) return u;
    NSMutableDictionary *m = [u mutableCopy];
    m[@"modId"] = modId;
    return m;
}

static NSDictionary *ameVIAClassifyJar(NSString *srcRoot, NSString *jarPath, NSString *rel, NSString *cat) {
    NSString *fname = rel.lastPathComponent;
    NSString *fver = ameVIAExtractMCVersion(fname);
    NSString *floader = ameVIAExtractLoader(fname);

    // ---- Fabric / Quilt：fabric.mod.json ----
    NSData *fmj = ameVIAReadZipEntry(jarPath, @"fabric.mod.json");
    if (fmj) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:fmj options:0 error:nil];
        if ([j isKindOfClass:NSDictionary.class]) {
            NSString *mid = ameVIAStr(j[@"id"]);
            NSString *range = nil;
            id dep = j[@"depends"];
            if ([dep isKindOfClass:NSDictionary.class]) {
                id mcd = ((NSDictionary *)dep)[@"minecraft"];
                if ([mcd isKindOfClass:NSString.class]) range = mcd;
                else if ([mcd isKindOfClass:NSArray.class]) range = [(NSArray *)mcd componentsJoinedByString:@" || "];
            }
            NSString *loader = ameVIALoaderFabric;
            NSData *qmj = ameVIAReadZipEntry(jarPath, @"quilt.mod.json");
            if (qmj) loader = ameVIALoaderQuilt;
            else if ([dep isKindOfClass:NSDictionary.class] && ((NSDictionary *)dep)[@"quilt_loader"]) loader = ameVIALoaderQuilt;
            NSString *rep = range ? ameVIAVersionRepFromRange(range) : nil;
            NSString *why = [NSString stringWithFormat:@"fabric.mod.json id=%@ depends.minecraft=%@",
                             mid ?: @"?", range ?: @"(未声明)"];
            if (!rep && fver) { rep = fver; why = [why stringByAppendingString:@"；元数据无版本→文件名兜底"]; }
            return ameVIAModUnit(ameVIAMakeUnit(srcRoot, rel, cat, rep, range, loader, why), mid);
        }
    }
    // ---- Quilt：quilt.mod.json（无 fabric.mod.json）----
    NSData *qmj = ameVIAReadZipEntry(jarPath, @"quilt.mod.json");
    if (qmj) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:qmj options:0 error:nil];
        NSString *range = nil;
        if ([j isKindOfClass:NSDictionary.class]) {
            id ql = j[@"quilt_loader"];
            if ([ql isKindOfClass:NSDictionary.class]) {
                id mcd = ((NSDictionary *)ql)[@"depends"];
                if ([mcd isKindOfClass:NSArray.class]) {
                    for (NSDictionary *d in (NSArray *)mcd)
                        if ([d isKindOfClass:NSDictionary.class] && [d[@"id"] isEqualToString:@"minecraft"]) { range = ameVIAStr(d[@"versions"]); break; }
                }
            }
        }
        NSString *rep = range ? ameVIAVersionRepFromRange(range) : fver;
        return ameVIAMakeUnit(srcRoot, rel, cat, rep, range, ameVIALoaderQuilt,
                              [NSString stringWithFormat:@"quilt.mod.json depends.minecraft=%@", range ?: @"(未声明)"]);
    }
    // ---- Forge / NeoForge：META-INF/mods.toml / neoforge.mods.toml ----
    NSData *toml = ameVIAReadZipEntry(jarPath, @"META-INF/mods.toml");
    BOOL isNeo = NO;
    NSString *tomlName = @"META-INF/mods.toml";
    if (!toml) {
        toml = ameVIAReadZipEntry(jarPath, @"META-INF/neoforge.mods.toml");
        if (toml) { isNeo = YES; tomlName = @"META-INF/neoforge.mods.toml"; }
    }
    if (toml) {
        NSString *s = [[NSString alloc] initWithData:toml encoding:NSUTF8StringEncoding] ?: @"";
        if ([s.lowercaseString containsString:@"neoforge"]) isNeo = YES;
        NSDictionary *p = ameVIAParseModsToml(s);
        NSString *range = ameVIAStr(p[@"mcRange"]);
        NSString *loader = isNeo ? ameVIALoaderNeoForge : ameVIALoaderForge;
        NSString *rep = range ? ameVIAVersionRepFromRange(range) : nil;
        NSMutableString *why = [NSMutableString stringWithFormat:@"%@ modId=%@ minecraft.versionRange=%@",
                                tomlName, ameVIAStr(p[@"modId"]) ?: @"?", range ?: @"(未声明)"];
        if (!rep) {
            // 兜底 1：文件名版本号
            if (fver) { rep = fver; [why appendString:@"；无 minecraft 依赖→文件名兜底"]; }
            else {
                // 兜底 2：Forge 构建号（弱）
                NSString *lv = ameVIAStr(p[@"loaderVersion"]);
                NSInteger b = 0;
                if (lv.length) {
                    NSArray *vp = ameVIAVersionParts(lv);
                    b = vp.count ? [vp[0] integerValue] : 0;
                }
                NSString *byBuild = b ? ameVIAMCVersionForForgeBuild(b) : nil;
                if (byBuild) { rep = byBuild; [why appendFormat:@"；无版本→Forge 构建号 %ld 弱推断", (long)b]; }
            }
        }
        return ameVIAModUnit(ameVIAMakeUnit(srcRoot, rel, cat, rep, range, loader, why), ameVIAStr(p[@"modId"]));
    }
    // ---- 无元数据：只按文件名 ----
    NSString *why = [NSString stringWithFormat:@"无 mod 元数据；按文件名（%@/%@）",
                     fver ?: @"版本未知", floader ?: @"加载器不明"];
    return ameVIAMakeUnit(srcRoot, rel, cat, fver, nil, floader, why);
}

static NSDictionary *ameVIAClassifyUnitInner(NSString *srcRoot, NSString *relPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *abs = [srcRoot stringByAppendingPathComponent:relPath];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:abs isDirectory:&isDir]) return nil;
    NSString *top = [relPath pathComponents].firstObject;
    NSString *cat = ameVIACatRoot;
    if ([top isEqualToString:@"mods"]) cat = ameVIACatMod;
    else if ([top isEqualToString:@"resourcepacks"]) cat = ameVIACatResourcePack;
    else if ([top isEqualToString:@"shaderpacks"]) cat = ameVIACatShaderPack;
    else if ([top isEqualToString:@"datapacks"]) cat = ameVIACatDataPack;
    else if ([top isEqualToString:@"saves"]) cat = ameVIACatWorld;
    else if ([top isEqualToString:@"config"]) cat = ameVIACatConfig;
    else if ([top isEqualToString:@"logs"] || [top isEqualToString:@"crash-reports"]) cat = ameVIACatOther;

    NSString *fname = relPath.lastPathComponent;
    NSString *fver = ameVIAExtractMCVersion(fname);
    NSString *floader = ameVIAExtractLoader(fname);

    if ([cat isEqualToString:ameVIACatMod] && !isDir) {
        if ([fname.lowercaseString hasSuffix:@".jar"] || [fname.lowercaseString hasSuffix:@".zip"]) {
            NSDictionary *u = ameVIAClassifyJar(srcRoot, abs, relPath, cat);
            return u;
        }
        return ameVIAMakeUnit(srcRoot, relPath, cat, nil, nil, nil, @"mods 下非 jar/zip");
    }
    if ([cat isEqualToString:ameVIACatResourcePack] || [cat isEqualToString:ameVIACatDataPack]) {
        NSInteger f = ameVIAPackFormatAtPath(abs);
        NSString *note = nil;
        NSString *ver = f >= 0 ? ameVIAMCVersionForPackFormat(f, &note) : nil;
        NSString *why;
        if (ver) why = [NSString stringWithFormat:@"pack.mcmeta pack_format=%ld ⇒ %@", (long)f, note ?: ver];
        else if (f >= 0) { why = [NSString stringWithFormat:@"pack.mcmeta pack_format=%ld（未收录）", (long)f]; ver = fver; if (fver) why = [why stringByAppendingString:@"；文件名兜底"]; }
        else if (fver) { why = @"无 pack.mcmeta；按文件名"; ver = fver; }
        else why = @"无 pack.mcmeta 且文件名无版本";
        return ameVIAMakeUnit(srcRoot, relPath, cat, ver, nil, nil, why);
    }
    if ([cat isEqualToString:ameVIACatShaderPack]) {
        // 光影包不含 MC 版本字段，只能按文件名
        NSString *why = fver ? @"光影包无版本字段；按文件名" : @"光影包无版本字段，判不出";
        return ameVIAMakeUnit(srcRoot, relPath, cat, fver, nil, nil, why);
    }
    if ([cat isEqualToString:ameVIACatWorld]) {
        NSString *worldDir = isDir ? abs : srcRoot;
        NSString *levelDat = [worldDir stringByAppendingPathComponent:@"level.dat"];
        NSDictionary *ld = ameVIAReadLevelDat(levelDat);
        if (ld) {
            NSString *vn = ameVIAStr(ld[@"versionName"]);
            NSInteger dv = [ld[@"dataVersion"] isKindOfClass:NSNumber.class] ? [ld[@"dataVersion"] integerValue] : NSNotFound;
            NSString *ver = vn;
            NSString *why;
            if (vn) { why = [NSString stringWithFormat:@"level.dat Version.Name=%@", vn]; }
            else {
                NSString *mapped = dv != NSNotFound ? ameVIAMCVersionForDataVersion(dv) : nil;
                ver = mapped;
                why = dv != NSNotFound
                    ? [NSString stringWithFormat:@"level.dat DataVersion=%ld%@", (long)dv,
                       mapped ? [NSString stringWithFormat:@" ⇒ %@", mapped] : @"（未收录，判不出）"]
                    : @"level.dat 无版本字段";
            }
            return ameVIAMakeUnit(srcRoot, relPath, cat, ver, nil, nil, why);
        }
        return ameVIAMakeUnit(srcRoot, relPath, cat, nil, nil, nil, @"存档无 level.dat/读不出");
    }
    if ([cat isEqualToString:ameVIACatConfig]) {
        return ameVIAMakeUnit(srcRoot, relPath, cat, nil, nil, nil, @"config 自身不带版本（可跟随同名 mod）");
    }
    // 根散文件 / logs / crash-reports
    return ameVIAMakeUnit(srcRoot, relPath, cat, fver, nil, floader,
                          cat == ameVIACatRoot ? @"根散文件不带版本信息" : @"该类文件不带版本信息");
}

/// 公开入口：分类 + 补「来源」（★ [VI-ORIGIN]）。来源只加字段，不改 category / 版本 / 加载器判定。
NSDictionary *ameVIAClassifyUnit(NSString *srcRoot, NSString *relPath) {
    NSDictionary *u = ameVIAClassifyUnitInner(srcRoot, relPath);
    return u ? ameVIAApplyOrigin(u) : nil;   // ★ [VI-ORIGIN]
}

#pragma mark - 扫描文件夹

NSDictionary *ameVIAScanFolder(NSString *srcRoot) {
    NSMutableArray<NSDictionary *> *units = [NSMutableArray array];
    NSUInteger scanned = 0;
    if (srcRoot.length == 0) return @{ @"units": units, @"scanned": @0 };
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL rootIsDir = NO;
    if (![fm fileExistsAtPath:srcRoot isDirectory:&rootIsDir] || !rootIsDir)
        return @{ @"units": units, @"scanned": @0 };

    // ★ [VI-ORIGIN] 原版/启动器自生成根文件一并纳入（默认不勾选，仅作「加载器自带」呈现）。
    NSArray<NSString *> *rootFiles = @[@"options.txt", @"optionsof.txt", @"servers.dat",
                                       @"servers.dat_old", @"realms_persistence.json",
                                       @"usercache.json", @"usernamecache.json",
                                       @"launcher_profiles.json", @"launcher_accounts.json",
                                       @"banned-ips.json", @"banned-players.json",
                                       @"ops.json", @"whitelist.json", @"eula.txt", @"debug.log"];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:srcRoot error:nil];

    for (NSString *name in entries) {
        // ★ [VI-ORIGIN] 隐藏目录仅放行加载器基线（.fabric / .mixin.out），其余隐藏项仍跳过。
        BOOL isBaselineHidden = ([name isEqualToString:@".fabric"] || [name isEqualToString:@".mixin.out"]);
        if ([name hasPrefix:@"."] && !isBaselineHidden) continue;
        NSString *abs = [srcRoot stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:abs isDirectory:&isDir]) continue;

        NSArray<NSString *> *cats = @[@"mods", @"resourcepacks", @"shaderpacks", @"datapacks", @"saves", @"config", @"logs", @"crash-reports"];
        if (isDir && isBaselineHidden) {
            // ★ [VI-ORIGIN] 隐藏的加载器基线目录（.fabric / .mixin.out）整体作为一项。
            NSDictionary *u = ameVIAClassifyUnit(srcRoot, name);
            if (u) { [units addObject:u]; scanned++; }
        } else if (isDir && [cats containsObject:name]) {
            // 目录类别：逐子项成为单元
            NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:abs error:nil];
            for (NSString *c in children) {
                if ([c hasPrefix:@"."]) continue;
                NSString *rel = [NSString stringWithFormat:@"%@/%@", name, c];
                NSDictionary *u = ameVIAClassifyUnit(srcRoot, rel);
                if (u) { [units addObject:u]; scanned++; }
            }
        } else if (!isDir && [rootFiles containsObject:name]) {
            NSDictionary *u = ameVIAClassifyUnit(srcRoot, name);
            if (u) { [units addObject:u]; scanned++; }
        }
    }
    NSArray<NSDictionary *> *annotated = ameVIAAnnotateOrigins(units);   // ★ [VI-ORIGIN] 补来源
    return @{ @"units": annotated, @"scanned": @(scanned) };
}

#pragma mark - 扫目标实例

static NSString *ameVIAVersionJsonLoader(NSDictionary *j, NSString *folderName) {
    NSString *byName = ameVIAExtractLoader(folderName);
    if (byName) return byName;
    if ([j isKindOfClass:NSDictionary.class]) {
        NSString *byId = ameVIAExtractLoader(ameVIAStr(j[@"id"]) ?: @"");
        if (byId) return byId;
        NSString *mc = ameVIAStr(j[@"mainClass"]) ?: @"";
        NSString *byMc = ameVIAExtractLoader(mc);
        if (byMc) return byMc;
        id libs = j[@"libraries"];
        if ([libs isKindOfClass:NSArray.class]) {
            for (NSDictionary *l in (NSArray *)libs) {
                if (![l isKindOfClass:NSDictionary.class]) continue;
                NSString *ln = ameVIAStr(l[@"name"]) ?: @"";
                if ([ln hasPrefix:@"net.fabricmc:fabric-loader"]) return ameVIALoaderFabric;
                if ([ln hasPrefix:@"org.quiltmc:quilt-loader"]) return ameVIALoaderQuilt;
                if ([ln hasPrefix:@"net.neoforged:neoforge"]) return ameVIALoaderNeoForge;
                if ([ln hasPrefix:@"cpw.mods:forge"] || [ln hasPrefix:@"net.minecraftforge:forge"]) return ameVIALoaderForge;
            }
        }
    }
    return nil;
}

static NSString *ameVIAVersionJsonMCVersion(NSDictionary *j, NSString *folderName) {
    if ([j isKindOfClass:NSDictionary.class]) {
        NSString *inherits = ameVIAStr(j[@"inheritsFrom"]);
        if (inherits.length) {
            NSString *v = ameVIAExtractMCVersion(inherits);
            if (v) return v;
            return inherits;
        }
        NSString *byId = ameVIAExtractMCVersion(ameVIAStr(j[@"id"]) ?: @"");
        if (byId) return byId;
    }
    return ameVIAExtractMCVersion(folderName);
}

NSArray<NSDictionary *> *ameVIAEnumerateTargets(NSString *instanceRoot) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (instanceRoot.length == 0) return out;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *versions = [instanceRoot stringByAppendingPathComponent:@"versions"];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:versions error:nil];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *dir = [versions stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSString *jsonPath = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]];
        NSDictionary *j = nil;
        NSData *jd = [NSData dataWithContentsOfFile:jsonPath];
        if (jd) j = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
        NSString *loader = ameVIAVersionJsonLoader(j, name) ?: ameVIALoaderVanilla;
        NSString *ver = ameVIAVersionJsonMCVersion(j, name) ?: @"";
        NSString *reason = [NSString stringWithFormat:@"版本目录 %@；%@json%@", name,
                            j ? @"" : @"无 ", [j isKindOfClass:NSDictionary.class] ? @"" : @"(读不出)"];
        [out addObject:@{ @"version": ver, @"loader": loader, @"dir": dir, @"id": name, @"reason": reason }];
    }
    return out;
}

#pragma mark - 分组 + 匹配

static BOOL ameVIALoaderCompatible(NSString *unitLoader, NSString *targetLoader) {
    if (unitLoader.length == 0) return YES;                 // 判不出：任意（但排序降级）
    if (targetLoader.length == 0) return YES;
    return [unitLoader isEqualToString:targetLoader];
}

NSArray<NSDictionary *> *ameVIAGroupUnits(NSArray<NSDictionary *> *units,
                                          NSArray<NSDictionary *> *targets) {
    NSMutableArray<NSDictionary *> *groups = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *index = [NSMutableDictionary dictionary];

    // 0) config「跟随同名 mod 归属」：先建 modId → (ver,range,loader)
    //    仅当同一 modId 只对应唯一 (版本,加载器) 时才用于跟随（避免 26.2/26.3 双版本歧义）。
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *modIds = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *modFirst = [NSMutableDictionary dictionary];
    for (NSDictionary *u in units) {
        if (![u[@"category"] isEqualToString:ameVIACatMod]) continue;
        NSString *mid = ameVIAStr(u[@"modId"]);
        if (mid.length == 0) continue;
        NSString *sig = [NSString stringWithFormat:@"%@|%@", ameVIAStr(u[@"mcVersion"]) ?: @"", ameVIAStr(u[@"loader"]) ?: @""];
        if (!modIds[mid]) { modIds[mid] = [NSMutableSet set]; modFirst[mid] = u; }
        [modIds[mid] addObject:sig];
    }
    NSMutableDictionary<NSString *, NSDictionary *> *modById = [NSMutableDictionary dictionary];
    for (NSString *mid in modIds) if (modIds[mid].count == 1) modById[mid] = modFirst[mid];

    for (NSDictionary *u in units) {
        NSString *ver = ameVIAStr(u[@"mcVersion"]);
        NSString *range = ameVIAStr(u[@"mcRange"]);
        NSString *loader = ameVIAStr(u[@"loader"]);
        NSString *cat = u[@"category"];
        NSString *reason = ameVIAStr(u[@"reason"]) ?: @"";
        NSString *origin = ameVIAStr(u[@"origin"]) ?: ameVIAOriginUnknown;       // ★ [VI-ORIGIN]
        NSString *originReason = ameVIAStr(u[@"originReason"]) ?: @"";           // ★ [VI-ORIGIN]

        // config 跟随同名 mod（唯一命中才做）
        if ([cat isEqualToString:ameVIACatConfig] && !ver && !loader) {
            NSString *stem = [u[@"unit"] lastPathComponent];
            NSString *base = [stem stringByDeletingPathExtension];
            NSString *head = [base componentsSeparatedByString:@"-"].firstObject;
            NSDictionary *matchMod = modById[base] ?: modById[head];
            if (matchMod) {
                ver = ameVIAStr(matchMod[@"mcVersion"]);
                range = ameVIAStr(matchMod[@"mcRange"]);
                loader = ameVIAStr(matchMod[@"loader"]);
                reason = [NSString stringWithFormat:@"跟随同名 mod「%@」的归属", base];
            }
        }

        // ★ [VI-ORIGIN] 组键含来源 ⇒ 同版本/加载器/类型但来源不同的项分属不同组（便于来源筛选）。
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@", ver ?: @"", loader ?: @"", cat ?: @"", origin];
        NSMutableDictionary *g = index[key];
        if (!g) {
            g = [@{
                @"mcVersion": ver ?: NSNull.null,
                @"mcRange": range ?: NSNull.null,
                @"loader": loader ?: NSNull.null,
                @"category": cat,
                @"origin": origin,                       // ★ [VI-ORIGIN]
                @"originReason": originReason,           // ★ [VI-ORIGIN]
                @"units": [NSMutableArray array],
                @"files": @0, @"bytes": @0,
                @"reason": reason,
                @"target": NSNull.null, @"targetDir": NSNull.null, @"match": @"none",
            } mutableCopy];
            index[key] = g;
            [groups addObject:g];
        }
        [(NSMutableArray *)g[@"units"] addObject:u];
        g[@"files"] = @([g[@"files"] unsignedIntegerValue] + [u[@"files"] unsignedIntegerValue]);
        g[@"bytes"] = @([g[@"bytes"] unsignedLongLongValue] + [u[@"bytes"] unsignedLongLongValue]);
        if ([(NSString *)g[@"reason"] length] == 0) g[@"reason"] = reason;
    }

    // 匹配目标实例
    for (NSMutableDictionary *g in groups) {
        NSString *ver = ameVIAStr(g[@"mcVersion"]);
        NSString *range = ameVIAStr(g[@"mcRange"]) ?: ver;
        NSString *loader = ameVIAStr(g[@"loader"]);
        if (ver.length == 0) { g[@"match"] = @"unrecognized"; continue; }
        NSDictionary *best = nil; int bestRank = 0; int ties = 0;
        for (NSDictionary *t in targets) {
            if (!ameVIALoaderCompatible(loader, ameVIAStr(t[@"loader"]) ?: @"")) continue;
            if (!ameVIAVersionInRange(ameVIAStr(t[@"version"]), range)) continue;
            int rank = [ameVIAStr(t[@"version"]) isEqualToString:ver] ? 2 : 1;
            if (loader.length == 0) rank = MIN(rank, 1);
            if (rank > bestRank) { bestRank = rank; best = t; ties = 1; }
            else if (rank == bestRank) {
                ties++;
                // 单元加载器判不出（资源包/存档等与加载器无关）：同版本并列时优先 vanilla 目标
                if (best && loader.length == 0 &&
                    [ameVIAStr(t[@"loader"]) isEqualToString:ameVIALoaderVanilla] &&
                    ![ameVIAStr(best[@"loader"]) isEqualToString:ameVIALoaderVanilla]) {
                    best = t;
                }
            }
        }
        if (best) {
            g[@"target"] = best;
            g[@"targetDir"] = best[@"dir"];
            g[@"match"] = bestRank == 2 ? @"exact" : @"range";
            if (ties > 1) {
                g[@"reason"] = [NSString stringWithFormat:@"%@（有 %d 个同版本目标，取第一个）",
                                ameVIAStr(g[@"reason"]) ?: @"", ties];
            }
        } else {
            g[@"match"] = @"none";
        }
    }

    // 排序：已匹配（版本降序）→ 未匹配 → 未识别
    [groups sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        int ra = [a[@"match"] isEqualToString:@"unrecognized"] ? 2 : ([a[@"match"] isEqualToString:@"none"] ? 1 : 0);
        int rb = [b[@"match"] isEqualToString:@"unrecognized"] ? 2 : ([b[@"match"] isEqualToString:@"none"] ? 1 : 0);
        if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        NSString *va = ameVIAStr(a[@"mcVersion"]) ?: @"";
        NSString *vb = ameVIAStr(b[@"mcVersion"]) ?: @"";
        NSInteger c = ameVIACompareVersion(vb, va);
        if (c != 0) return c < 0 ? NSOrderedAscending : NSOrderedDescending;
        return [NSStringFromClass(a.class) compare:NSStringFromClass(b.class)];
    }];
    return groups;
}

#pragma mark - 执行（复用既有引擎）

NSDictionary *ameVIAExecute(NSString *srcRoot, NSArray<NSDictionary *> *units,
                            NSDictionary *options) {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableArray *errors = [NSMutableArray array];
    NSUInteger copied = 0, identical = 0, conflicts = 0, renamed = 0;
    BOOL removed = NO;
    for (NSDictionary *u in units) {
        NSString *rel = ameVIAStr(u[@"unit"]);
        NSString *dstRoot = ameVIAStr(u[@"dstRoot"]);
        if (rel.length == 0 || dstRoot.length == 0) continue;
        NSDictionary *r = ameVDMExecuteItem(srcRoot, dstRoot, rel, options);   // ★ 既有引擎
        [items addObject:r];
        copied    += [r[@"copied"] unsignedIntegerValue];
        identical += [r[@"identical"] unsignedIntegerValue];
        conflicts += [r[@"conflict"] unsignedIntegerValue];
        renamed   += [r[@"renamed"] unsignedIntegerValue];
        if ([r[@"removed"] boolValue]) removed = YES;
        for (NSString *e in r[@"errors"]) [errors addObject:[NSString stringWithFormat:@"%@: %@", rel, e]];
    }
    NSLog(@"★ [VI-MIGRATE-AUTO] execute src=%@ units=%lu copied=%lu identical=%lu conflicts=%lu renamed=%lu",
          srcRoot, (unsigned long)units.count, (unsigned long)copied,
          (unsigned long)identical, (unsigned long)conflicts, (unsigned long)renamed);
    return @{ @"ok": @(errors.count == 0), @"copied": @(copied), @"identical": @(identical),
              @"conflicts": @(conflicts), @"renamed": @(renamed), @"removed": @(removed),
              @"errors": errors, @"items": items };
}
