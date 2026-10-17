#!/usr/bin/env node
// ============================================================================
// tests/JIT/jit_script_tests.js —— Air2JIT69.js 的纯逻辑 + 协议行为单测
// ----------------------------------------------------------------------------
// 被测对象是【仓里真实的】Assets/Air2JIT69.js（不是镜像实现）：
//   * 用 node:vm 把它跑在一个沙箱里，宿主侧的 send_command / get_pid / log /
//     prepare_memory_region 全部由本文件假装成一台 debugserver；
//   * 单测直接断言【脚本发出去的 GDB-RSP 包】与【它自己打出来的日志】。
//
// 为什么要这么测（真机回归的两条判据，都是本文件盯住的）：
//   ① 非 brk 停止放行信号时必须发 `C<sig>`（带信号继续）。
//      发 `vCont;S<sig>:<tid>` 是【单步】（debugserver RNBRemote.cpp L4072-L4083
//      case 'S' ⇒ eStateStepping）⇒ 每停一次只前进一条指令 ⇒ 满屏
//      `Skipping: instruction was not a brk`，永远到不了下一个 brk。
//   ② 停止回复不是 T 包（进程退出 W/X、包错误 E、空串）时不得空转：
//      必须如实记下原文并且有界收尾。
//
// 运行：node tests/JIT/jit_script_tests.js
// 退出码：0 = 全通过；1 = 有 FAIL。
// ============================================================================

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SCRIPT_PATH = path.join(__dirname, '..', '..', 'Assets', 'Air2JIT69.js');
const SRC = fs.readFileSync(SCRIPT_PATH, 'utf8');

let pass = 0;
let fail = 0;
function ok(cond, name, detail) {
    if (cond) {
        pass++;
        console.log('PASS ' + name);
    } else {
        fail++;
        console.log('FAIL ' + name + (detail === undefined ? '' : '  << ' + detail));
    }
}
function eq(actual, expected, name) {
    ok(actual === expected, name, 'actual=' + JSON.stringify(actual) + ' expected=' + JSON.stringify(expected));
}

// ---------------------------------------------------------------- 工具
/** 64 位值 → 停止回复里的 16 个 hex（小端，与 debugserver 一致）。 */
function leHex(n) {
    let v = BigInt(n);
    const bytes = [];
    for (let i = 0; i < 8; i++) {
        bytes.push(Number(v & 0xffn));
        v >>= 8n;
    }
    return bytes.map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
}
/** brk #imm 的 32 位机器码。 */
function brkU32(imm) {
    return (0xd4200000 | ((imm & 0xffff) << 5)) >>> 0;
}
/** brk #imm 的机器码（小端 hex 字符串，`m` 包回的就是这个顺序）。 */
function brkHex(imm) {
    const u32 = brkU32(imm);
    return [u32 & 0xff, (u32 >>> 8) & 0xff, (u32 >>> 16) & 0xff, (u32 >>> 24) & 0xff]
        .map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
}
/** 组装一条停止回复。regs: {x0,x1,x16,pc}（BigInt 或 number）。 */
function stopReply(signo, regs) {
    const r = regs || {};
    return 'T' + signo.toString(16).padStart(2, '0') + 'thread:1e03;'
        + '00:' + leHex(r.x0 === undefined ? 0n : r.x0) + ';'
        + '01:' + leHex(r.x1 === undefined ? 0n : r.x1) + ';'
        + '10:' + leHex(r.x16 === undefined ? 0n : r.x16) + ';'
        + '20:' + leHex(r.pc === undefined ? 0x100000000n : r.pc) + ';'
        + '21:00000000;';
}

/**
 * 把真实脚本跑起来。
 *   respond(packet, ctx) → 回包字符串（undefined ⇒ 'OK'）
 * 返回 {ctx, sent, logs, preps, error}
 */
function run(respond, options) {
    const opts = options || {};
    const sent = [];
    const logs = [];
    const preps = [];
    const state = { lastStop: null, mem: opts.mem || {} };
    const sandbox = {
        send_command: function (packet) {
            sent.push(packet);
            const r = respond(packet, state);
            return r === undefined ? 'OK' : r;
        },
        get_pid: function () { return 0x1234; },
        log: function () {
            logs.push(Array.prototype.slice.call(arguments).map(String).join(' '));
        },
        prepare_memory_region: function (addr, len) {
            preps.push([addr, len]);
            return 'OK';
        }
    };
    vm.createContext(sandbox);
    let error = null;
    try {
        vm.runInContext(SRC, sandbox, { filename: 'Air2JIT69.js' });
    } catch (e) {
        error = e;
    }
    return { ctx: sandbox, sent: sent, logs: logs, preps: preps, error: error, state: state };
}

/** 场景驱动：stops 依次作为每次 `c` 的停止回复；mem 是 pc→指令字的表。 */
function driver(stops, mem, extra) {
    let i = 0;
    return function (packet, state) {
        if (extra) {
            const r = extra(packet, state);
            if (r !== undefined) return r;
        }
        if (packet.indexOf('vAttach') === 0) return 'T11thread:1e03;';
        if (packet === 'c') {
            const s = stops[Math.min(i, stops.length - 1)];
            i++;
            return s;
        }
        const m = /^m([0-9a-f]+),4$/.exec(packet);
        if (m) {
            if (mem === null) return 'E01';
            const addr = parseInt(m[1], 16);
            return (addr in mem) ? mem[addr] : 'ffffffff';
        }
        return 'OK';
    };
}

/** 只跑一轮就收尾，用来取沙箱里的纯函数。 */
function pureCtx() {
    return run(driver(['X09'])).ctx;
}

// ============================================================================
console.log('== A. ameJITParseStopReply（停止回复解析）');
{
    const c = pureCtx();
    const P = c.ameJITParseStopReply;

    const full = P(stopReply(0x0a, { x0: 0x1000n, x1: 0n, x16: 0n, pc: 0x100003f00n }));
    eq(full.kind, 'stop', 'A1 完整 T 包 ⇒ kind=stop');
    eq(full.signo, 10, 'A2 信号号取自 T 后两位（0x0a=SIGBUS）');
    eq(full.tid, '1e03', 'A3 tid 取自 thread: 字段');
    eq(full.pcHex, leHex(0x100003f00n), 'A4 pc 取自 20: 寄存器');
    eq(full.x16Hex, leHex(0n), 'A5 x16 取自 10: 寄存器');
    eq(full.x0Hex, leHex(0x1000n), 'A6 x0 取自 00: 寄存器');
    eq(full.x1Hex, leHex(0n), 'A7 x1 取自 01: 寄存器');

    const trap = P(stopReply(5, { pc: 0x100004000n }));
    eq(trap.signo, 5, 'A8 SIGTRAP 信号号 = 5');

    // 老正则 /T[0-9a-f]+thread:/ 要求 thread: 紧跟 T 后；这里留一条更宽松的格式做回归
    const noSemi = P('T05thread:1e03;00:' + leHex(7n) + ';20:' + leHex(0x2000n) + ';');
    eq(noSemi.kind, 'stop', 'A9 缺后面若干寄存器但仍可解析');
    eq(noSemi.x0Hex, leHex(7n), 'A10 寄存器 00 直接跟在 thread 后也取得对');
    eq(noSemi.x1Hex, null, 'A11 缺 01 时如实为 null（不猜 0）');
    eq(noSemi.x16Hex, null, 'A12 缺 10 时如实为 null');

    eq(P('W09').kind, 'exited', 'A13 W09（进程退出）⇒ kind=exited');
    eq(P('X0b').kind, 'exited', 'A14 X0b（被信号杀死）⇒ kind=exited');
    eq(P('X0b').signo, null, 'A15 退出包不提供信号号（不装成停止）');
    eq(P('E23').kind, 'error', 'A16 E23（无效进程）⇒ kind=error');
    eq(P('E01').tid, null, 'A17 错误包没有 tid');
    eq(P('').kind, 'empty', 'A18 空串 ⇒ kind=empty');
    eq(P('   ').kind, 'empty', 'A19 全空白 ⇒ kind=empty');
    eq(P(null).kind, 'empty', 'A20 null ⇒ kind=empty（不抛）');
    eq(P(undefined).kind, 'empty', 'A21 undefined ⇒ kind=empty（不抛）');
    eq(P('OK').kind, 'unknown', 'A22 杂包 OK ⇒ kind=unknown');
    eq(P('T05thread:1e03;').pcHex, null, 'A23 只有 thread 没有寄存器 ⇒ pc 为 null');
    eq(P('T05thread:1e03;').kind, 'stop', 'A24 只有 thread 也仍判为 stop（由调用方判缺字段）');
    const upper = P('T05thread:1E03;00:' + '00'.repeat(8).toUpperCase() + ';20:' + leHex(0xabc0n) + ';');
    eq(upper.tid, '1E03', 'A25 大写 hex 的 tid 也认');
    eq(upper.pcHex, leHex(0xabc0n), 'A26 大写 hex 的寄存器值也认');
    const shadow = P('T0a' + 'thread:1e03;00:1122334455667788;20:99aabbccddeeff00;');
    eq(shadow.x0Hex, '1122334455667788', 'A27 不把 16 位值里的"20:"误当寄存器号'); 
}

console.log('== B. ameJITIsBrk / extractBrkImmediate');
{
    const c = pureCtx();
    const B = c.ameJITIsBrk;
    ok(B(0xd4200000), 'B1 brk #0 是 brk');
    ok(B(brkU32(0x69)), 'B2 brk #0x69 是 brk');
    ok(B(brkU32(0xf00d)), 'B3 brk #0xf00d 是 brk');
    ok(!B(0xa9bf7bfd), 'B4 stp x29,x30,[sp,#-16]! 不是 brk（真机日志里的 0xa9bf7bfd）');
    ok(!B(0xd65f03c0), 'B5 ret 不是 brk（真机日志里的 0xd65f03c0）');
    ok(!B(0xd503201f), 'B6 nop 不是 brk');
    ok(!B(NaN), 'B7 NaN（读内存失败）不是 brk，且不抛');
    ok(!B(undefined), 'B8 undefined 不是 brk，且不抛');
    eq(c.extractBrkImmediate(brkU32(0x69)), 0x69, 'B9 brk #0x69 ⇒ 立即数 0x69');
    eq(c.extractBrkImmediate(brkU32(0xf00d)), 0xf00d, 'B10 brk #0xf00d ⇒ 立即数 0xf00d');
    eq(c.extractBrkImmediate(brkU32(0x68)), 0x68, 'B11 brk #0x68 ⇒ 立即数 0x68');
}

console.log('== C. ameJITResumePacket（续跑包）');
{
    const c = pureCtx();
    const R = c.ameJITResumePacket;
    eq(R(0x0a), 'C0a', 'C1 SIGBUS ⇒ C0a（带信号继续）');
    eq(R(0x0b), 'C0b', 'C2 SIGSEGV ⇒ C0b');
    eq(R(5), 'C05', 'C3 SIGTRAP ⇒ C05（补零两位）');
    eq(R(0x11), 'C11', 'C4 SIGSTOP ⇒ C11');
    ok(R(0x0a).indexOf('vCont') === -1, 'C5 续跑包不得是 vCont（S 会被当成单步）');
    ok(R(0x0a).indexOf(';') === -1, 'C6 续跑包不得带 ;thread:<tid>（会被当成 PC 地址）');
    ok(/^C[0-9a-f]{2}$/.test(R(0x0a)), 'C7 续跑包形状 = C + 两位 hex');
    eq(R(null), 'c', 'C8 信号号未知 ⇒ 退化为 plain c');
    eq(R(undefined), 'c', 'C9 信号号缺失 ⇒ 退化为 plain c');
    eq(R(0x100), 'c', 'C10 越界信号号 ⇒ 退化为 plain c');
}

console.log('== D. 端到端：SIGBUS 非 brk 停止必须"继续"而不是"单步"');
{
    // 真机日志的三条停止：pc 落在 stp 序言 / ret 上，指令字都不是 brk
    const mem = {
        0x100003f00: 'fd7bbfa9',   // stp x29,x30,[sp,#-16]!
        0x100004200: 'c0035fd6'    // ret
    };
    const stops = [
        stopReply(0x0a, { pc: 0x100003f00n }),
        stopReply(0x0a, { pc: 0x100004200n }),
        'X09'
    ];
    const r = run(driver(stops, mem));
    eq(r.error, null, 'D1 整个脚本无异常结束');
    const vcont = r.sent.filter(function (p) { return p.indexOf('vCont') === 0; });
    eq(vcont.length, 0, 'D2 一个 vCont 包都不许发（S=单步、C 带 tid 会被当 PC 地址）');
    const cs = r.sent.filter(function (p) { return /^C[0-9a-f]{2}$/.test(p); });
    eq(cs.length, 2, 'D3 两次非 brk 停止各发一条 C<sig>');
    eq(cs[0], 'C0a', 'D4 第一条放行包 = C0a');
    eq(cs[1], 'C0a', 'D5 第二条放行包 = C0a');
    ok(r.logs.some(function (l) { return l.indexOf('not a brk (was 0xa9bf7bfd)') >= 0; }),
        'D6 如实记录 0xa9bf7bfd 不是 brk');
    ok(r.logs.some(function (l) { return l.indexOf('not a brk (was 0xd65f03c0)') >= 0; }),
        'D7 如实记录 0xd65f03c0 不是 brk');
    ok(r.logs.some(function (l) { return l.indexOf('停止服务') >= 0; }),
        'D8 进程退出（X09）时有明确收尾日志');
    eq(r.sent[r.sent.length - 1], 'c', 'D9 退出前最后一个包是 c');
}

console.log('== E. 端到端：brk #0x69 真交付');
{
    const pc = 0x100005000n;
    const mem = {};
    mem[Number(pc)] = brkHex(0x69);
    const stops = [
        stopReply(5, { x0: 0x1000n, x1: 0n, x16: 0n, pc: pc }),
        'X09'
    ];
    const r = run(driver(stops, mem, function (packet) {
        // _M 回的是【大端文本 hex】地址（debugserver 直接打印 %llx），不是小端字节串
        if (packet.indexOf('_M') === 0) return (0x100004000n).toString(16);
        return undefined;
    }));
    eq(r.error, null, 'E1 无异常');
    ok(r.sent.some(function (p) { return p === 'P20=' + leHex(pc + 4n) + ';thread:1e03;'; }),
        'E2 越过 brk：P20 = pc+4（本线程）');
    const alloc = r.sent.filter(function (p) { return p.indexOf('_M') === 0; });
    eq(alloc.length, 1, 'E3 只分配一次（不许命令洪水）');
    eq(alloc[0], '_M1000,rx', 'E4 按官方语义 _M<size>,rx 分配');
    eq(r.preps.length, 1, 'E5 prepare_memory_region 只调一次');
    eq(String(r.preps[0][0]), String(0x100004000n), 'E6 落实的是分配回来的地址');
    eq(String(r.preps[0][1]), String(0x1000n), 'E7 落实长度 = 请求尺寸');
    ok(r.sent.some(function (p) { return p === 'P0=' + leHex(0x100004000n) + ';thread:1e03;'; }),
        'E8 回填 x0 = 分配到的区域地址');
    ok(r.logs.some(function (l) { return l.indexOf('[AIR2-JIT69] hit #1') >= 0; }),
        'E9 打出 0x69 命中判据行');
}

console.log('== F. 端到端：没人认领的 brk 必须越过（否则同一 pc 死循环）');
{
    const pc = 0x100006000n;
    const mem = {};
    mem[Number(pc)] = brkHex(0x1234);
    const stops = [
        stopReply(5, { x0: 1n, x1: 2n, x16: 0n, pc: pc }),
        'X09'
    ];
    const r = run(driver(stops, mem));
    eq(r.error, null, 'F1 无异常');
    ok(r.logs.some(function (l) { return l.indexOf('was not handled by this script') >= 0; }),
        'F2 如实说这条 brk 没人认领');
    ok(r.sent.some(function (p) { return p === 'P20=' + leHex(pc + 4n) + ';thread:1e03;'; }),
        'F3 越过这条 brk（P20 = pc+4）');
    eq(r.sent.filter(function (p) { return p === 'c'; }).length, 2, 'F4 之后仍继续跑（第二次 c）');
}

console.log('== G. 端到端：SIGTRAP 落在非 brk 指令上');
{
    const pc = 0x100007000n;
    const mem = {};
    mem[Number(pc)] = '1f2003d5';    // nop
    const r1 = run(driver([stopReply(5, { pc: pc }), 'X09'], mem));
    eq(r1.error, null, 'G1 无异常');
    eq(r1.sent.filter(function (p) { return /^P20=/.test(p); }).length, 0,
        'G2 第一次 SIGTRAP（非 brk）只是吞掉，不动 pc');
    eq(r1.sent.filter(function (p) { return /^C[0-9a-f]{2}$/.test(p); }).length, 0,
        'G3 SIGTRAP 不转发给 App（它归调试器所有）');

    // 同一个 pc 连停两次 ⇒ 必须跳过该指令，否则无限重停
    const r2 = run(driver([stopReply(5, { pc: pc }), stopReply(5, { pc: pc }), 'X09'], mem));
    ok(r2.sent.some(function (p) { return p === 'P20=' + leHex(pc + 4n) + ';thread:1e03;'; }),
        'G4 同一 pc 连续 SIGTRAP ⇒ 越过该指令');
    eq(r2.error, null, 'G5 无异常');
}

console.log('== H. 端到端："Failed to extract registers" 必须有界、带原文');
{
    // H1/H2：先空串，再正常停止 —— 空回复不能让脚本死，也不能吞掉后续停止
    const pc = 0x100008000n;
    const mem = {};
    mem[Number(pc)] = brkHex(0x69);
    const r1 = run(driver(['', stopReply(5, { x0: 0x1000n, x1: 0n, x16: 0n, pc: pc }), 'X09'], mem,
        function (packet) {
            if (packet.indexOf('_M') === 0) return leHex(0x100004000n);
            return undefined;
        }));
    eq(r1.error, null, 'H1 空回复不抛异常');
    ok(r1.logs.some(function (l) {
        return l.indexOf('Failed to extract registers: tid=null, pc=null, x16=null') >= 0
            && l.indexOf('kind=empty') >= 0;
    }), 'H2 空回复的日志保留真机那行原样 + 补上 kind/raw');
    eq(r1.preps.length, 1, 'H3 空回复之后仍把后面的 brk #0x69 服务了');

    // H4：进程退出包 ⇒ 立即收尾，不再空转
    const r2 = run(driver(['W09']));
    eq(r2.error, null, 'H4 W09 不抛异常');
    eq(r2.sent.filter(function (p) { return p === 'c'; }).length, 1, 'H5 W09 之后不再发 c（不空转）');

    // H6：包错误 ⇒ 立即收尾
    const r3 = run(driver(['E23']));
    eq(r3.error, null, 'H6 E23 不抛异常');
    eq(r3.sent.filter(function (p) { return p === 'c'; }).length, 1, 'H7 E23 之后不再发 c');

    // H8：永远拿不到停止回复 ⇒ 8 次后收尾（有界，不死循环）
    const r4 = run(function (packet) {
        if (packet.indexOf('vAttach') === 0) return 'T11thread:1e03;';
        if (packet === 'c') return '';
        return 'OK';
    });
    eq(r4.error, null, 'H8 连续空回复不抛异常');
    eq(r4.sent.filter(function (p) { return p === 'c'; }).length, 8, 'H9 连续空回复在 8 次后收尾');
    ok(r4.logs.some(function (l) { return l.indexOf('停止服务') >= 0; }),
        'H10 有界收尾时有明确日志');

    // H11：T 包缺 pc ⇒ 同样有界
    const r5 = run(function (packet) {
        if (packet.indexOf('vAttach') === 0) return 'T11thread:1e03;';
        if (packet === 'c') return 'T05thread:1e03;00:' + leHex(0n) + ';';
        return 'OK';
    });
    eq(r5.error, null, 'H11 T 包缺 pc 不抛异常');
    eq(r5.sent.filter(function (p) { return p === 'c'; }).length, 8, 'H12 T 包缺 pc 也走有界收尾');
}

console.log('== I. 端到端：读内存失败（m 包回 E01）');
{
    const pc = 0x100009000n;
    const r = run(driver([stopReply(5, { pc: pc }), 'X09'], null));
    eq(r.error, null, 'I1 m 包失败不再抛 TypeError（base 会炸成 Script failed）');
    ok(r.logs.some(function (l) { return l.indexOf('was 0xNaN') >= 0; }),
        'I2 指令未知时如实打 NaN');
}

console.log('== J. 端到端：detach 命令仍可用');
{
    const pc = 0x10000a000n;
    const mem = {};
    mem[Number(pc)] = brkHex(0xf00d);
    const r = run(driver([stopReply(5, { x0: 0n, x1: 0n, x16: 0n, pc: pc })], mem));
    eq(r.error, null, 'J1 brk #0xf00d cmd=0 ⇒ detach 路径无异常');
    eq(r.sent[r.sent.length - 1], 'D', 'J2 detach 发的是 D');
}

console.log('== K. 源码级不变量（防止有人把这几个坑改回去）');
{
    // 注释里允许写「别再用 vCont;S」这类警示；只检查【代码行】。
    const code = SRC.split('\n').filter(function (line) {
        const t = line.trim();
        return t !== '' && t.indexOf('//') !== 0 && t.indexOf('*') !== 0 && t.indexOf('/*') !== 0;
    }).join('\n');
    ok(code.indexOf('vCont;S') === -1, 'K1 代码里不许再出现 vCont;S（单步）');
    ok(code.indexOf('vCont') === -1, 'K2 代码里不许再出现 vCont（本项目只需要 C<sig> / c）');
    ok(SRC.indexOf('ameJITResumePacket') >= 0, 'K3 续跑走 ameJITResumePacket()');
    ok(SRC.indexOf('ameJITParseStopReply') >= 0, 'K4 停止回复走 ameJITParseStopReply()');
    ok(SRC.indexOf('brk #0x69') >= 0, 'K5 0x69 契约注释仍在');
    ok(SRC.indexOf('prepare_memory_region') >= 0, 'K6 仍然用宿主的 prepare_memory_region 落实页');
    // 小区(<=1MiB)仍走 _M<size>,rx + 逐页 prepare；大区改单条 _M<size>,rwx
    // （64MiB 逐页 prepare = 4096 条调试命令 = 真机 6000~10000 请求的根源）
    ok(SRC.indexOf("const perms = (x1 > AME_BIG_REGION) ? 'rwx' : 'rx';") >= 0,
       'K7 小区域用 rx、大区域用 rwx（一次分配，不再逐页 prepare）');
    ok(SRC.indexOf('const AME_BIG_REGION = 1048576n;') >= 0, 'K7b 大区阈值 1MiB 存在');
}

console.log('');
const total = pass + fail;
console.log('TOTAL pass=' + pass + ' fail=' + fail + ' (total=' + total + ')');
if (fail === 0) {
    console.log('[runner] 全部通过 ✓');
} else {
    console.log('[runner] 有失败 ✗');
}
process.exit(fail === 0 ? 0 : 1);
