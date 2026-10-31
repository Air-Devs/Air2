#!/usr/bin/env node
// ============================================================================
// tests/JIT/jit_probe_tests.js —— ★A2PROBE★ GL 断点探针（cmd 99）的协议行为单测
// ----------------------------------------------------------------------------
// 被测对象是【仓里真实的】Assets/Air2JIT69.js。做法与 jit_script_tests.js 同源：
// 用 node:vm 把它跑在沙箱里，send_command / get_pid / log / prepare_memory_region
// 全部由本文件假装成一台 debugserver，直接断言【脚本发出去的 GDB-RSP 包】与
// 【它自己打出来的日志】。
//
// 为什么单独一个文件：jit_script_tests.js 的驱动在 baseline 上就不终止（它期望的
// ameJITParseStopReply 那版脚本已被 db44cc8 回退），本文件用**有限停止序列**驱动，
// 只盯 cmd 99 这一条新命令，能立刻给出「探针到底发了什么包」的判据。
//
// 覆盖的判据：
//   ① cmd 99 ⇒ 对 A、B 各发一发 `Z0,<hex>,4`，并打 `[A2PROBE] armed A=0x… B=0x…`；
//   ② 地址为 0 的槽不下断（App 没取到该符号）；
//   ③ pc 落到 A/B ⇒ 发 `z0,<hex>,4` 摘点 + `g` 取寄存器，打一行 HIT（pc/lr/x0..x3）；
//   ④ ★同一地址不重复下断★：摘点后不再出现第二发 Z0，也不会有第二次同址命中；
//   ⑤ 命中打印有上限（A2PROBE_HIT_LIMIT = 3），超了只摘点不打印；
//   ⑥ `g` 包解析按 ARM64 偏移（x0=0、lr=30*8、pc=32*8），短包如实给 null。
//
// 运行：node tests/JIT/jit_probe_tests.js
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
    ok(actual === expected, name, 'actual=' + dump(actual) + ' expected=' + dump(expected));
}
/** 断言失败时能安全打印 BigInt（JSON.stringify 遇 BigInt 会抛）。 */
function dump(v) {
    if (typeof v === 'bigint') return v.toString() + 'n';
    try {
        return JSON.stringify(v);
    } catch (e) {
        return String(v);
    }
}

// ---------------------------------------------------------------- 工具
/** 64 位值 → 16 个 hex（小端，与 debugserver 的寄存器编码一致）。 */
function leHex(n) {
    let v = BigInt(n);
    const bytes = [];
    for (let i = 0; i < 8; i++) {
        bytes.push(Number(v & 0xffn));
        v >>= 8n;
    }
    return bytes.map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
}
function brkU32(imm) {
    return (0xd4200000 | ((imm & 0xffff) << 5)) >>> 0;
}
/** brk #imm 的机器码（小端 hex，`m` 包回的就是这个顺序）。 */
function brkHex(imm) {
    const u32 = brkU32(imm);
    return [u32 & 0xff, (u32 >>> 8) & 0xff, (u32 >>> 16) & 0xff, (u32 >>> 24) & 0xff]
        .map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
}
/** 一条停止回复。regs: {x0,x1,x16,pc}。 */
function stopReply(signo, regs) {
    const r = regs || {};
    return 'T' + signo.toString(16).padStart(2, '0') + 'thread:1e03;'
        + '00:' + leHex(r.x0 === undefined ? 0n : r.x0) + ';'
        + '01:' + leHex(r.x1 === undefined ? 0n : r.x1) + ';'
        + '10:' + leHex(r.x16 === undefined ? 0n : r.x16) + ';'
        + '20:' + leHex(r.pc === undefined ? 0x100000000n : r.pc) + ';';
}
/**
 * 一条 `g` 寄存器包：x0..x28 / fp / lr / sp / pc / cpsr 共 34 个 8 字节小端值。
 * regs: { x0..x3, lr, pc }（都用 BigInt 或 number）。
 */
function gPacket(regs) {
    const r = regs || {};
    const table = [];
    for (let i = 0; i < 34; i++) table.push(0n);
    for (let i = 0; i <= 3; i++) {
        if (r['x' + i] !== undefined) table[i] = BigInt(r['x' + i]);
    }
    if (r.lr !== undefined) table[30] = BigInt(r.lr);
    if (r.pc !== undefined) table[32] = BigInt(r.pc);
    return table.map(function (v) { return leHex(v); }).join('');
}

/**
 * 把真实脚本跑起来。stops 依次作为每次 `c` 的停止回复（用完就重复最后一条）。
 * mem: pc(number) → 指令字 hex；gReply: `g` 包的回复（必须在跑之前给，脚本在跑的过程中就会问）。
 * 返回 {ctx, sent, logs, error}
 */
function run(stops, mem, gReply) {
    const sent = [];
    const logs = [];
    let cursor = 0;
    const sandbox = {
        send_command: function (packet) {
            sent.push(packet);
            if (packet.indexOf('vAttach') === 0) return 'T11thread:1e03;';
            if (packet === 'c') {
                const s = stops[Math.min(cursor, stops.length - 1)];
                cursor++;
                return s;
            }
            if (packet === 'g') {
                return (gReply === undefined || gReply === null) ? '' : gReply;
            }
            const m = /^m([0-9a-f]+),4$/.exec(packet);
            if (m) {
                const addr = parseInt(m[1], 16);
                return (addr in mem) ? mem[addr] : 'ffffffff';
            }
            return 'OK';
        },
        get_pid: function () { return 0x1234; },
        log: function () {
            logs.push(Array.prototype.slice.call(arguments).map(String).join(' '));
        },
        prepare_memory_region: function () { return 'OK'; }
    };
    vm.createContext(sandbox);
    let error = null;
    try {
        vm.runInContext(SRC, sandbox, { filename: 'Air2JIT69.js' });
    } catch (e) {
        error = e;
    }
    return { ctx: sandbox, sent: sent, logs: logs, error: error };
}

// 布局：A/B 是「GL 入口」地址；ARM_PC 是 App 发 cmd 99 时那发 brk #0xf00d 的地址。
const A = 0x1028a4b80n;
const B = 0x1019c3d40n;
const ARM_PC = 0x1000ff000n;
const DETACH_PC = 0x1000ff800n;

/** 一段完整的脚本生命周期：武装 → 命中 A → 命中 B → detach。 */
function fullRun(extraStops) {
    const mem = {};
    mem[Number(ARM_PC)] = brkHex(0xf00d);
    mem[Number(DETACH_PC)] = brkHex(0xf00d);
    const stops = [
        stopReply(5, { x0: A, x1: B, x16: 99n, pc: ARM_PC }),
    ].concat(extraStops || [
        stopReply(5, { pc: A }),
        stopReply(5, { pc: B }),
        stopReply(5, { x0: 0n, x1: 0n, x16: 0n, pc: DETACH_PC })
    ]);
    const g = gPacket({ x0: 0x11n, x1: 0x22n, x2: 0x33n, x3: 0x44n,
                        lr: 0x1000abcd0n, pc: A });
    return run(stops, mem, g);
}

console.log('== P1. 命令 99：对 A、B 各发一发 Z0 + 一行 armed 判据');
{
    const r = fullRun();
    eq(r.error, null, 'P1.1 整个脚本无异常结束');
    eq(r.sent.filter(function (p) { return p === 'Z0,' + A.toString(16) + ',4'; }).length, 1,
        'P1.2 A 上真发了一发 Z0（4 字节）');
    eq(r.sent.filter(function (p) { return p === 'Z0,' + B.toString(16) + ',4'; }).length, 1,
        'P1.3 B 上真发了一发 Z0（4 字节）');
    ok(r.logs.some(function (l) {
        return l.indexOf('[A2PROBE] armed A=0x' + A.toString(16) + ' B=0x' + B.toString(16)) >= 0;
    }), 'P1.4 打 `[A2PROBE] armed A=0x… B=0x…`（地址是 ASLR 后的实际值）');
    eq(r.sent.filter(function (p) { return p === 'D'; }).length, 1, 'P1.5 收尾走 detach（D）');
}

console.log('== P2. 命中 A：摘点 + 取寄存器 + 打 HIT（pc/lr/x0..x3）');
{
    const r = fullRun();
    eq(r.sent.filter(function (p) { return p === 'z0,' + A.toString(16) + ',4'; }).length, 1,
        'P2.1 命中后摘点（z0，同一地址）');
    eq(r.sent.filter(function (p) { return p === 'g'; }).length, 2,
        'P2.2 两次命中各发一发 `g` 取寄存器（A 一次、B 一次）');
    ok(r.logs.some(function (l) {
        return l.indexOf('[A2PROBE] HIT pc=0x' + A.toString(16)) >= 0
            && l.indexOf('lr=0x1000abcd0') >= 0
            && l.indexOf('x0=0x11') >= 0
            && l.indexOf('x1=0x22') >= 0
            && l.indexOf('x2=0x33') >= 0
            && l.indexOf('x3=0x44') >= 0;
    }), 'P2.3 HIT 行里 pc/lr/x0/x1/x2/x3 都按 ARM64 偏移解出来了');
    // ★不重复下断★：整轮 Z0 只出现在武装那一次（A 一发、B 一发）
    eq(r.sent.filter(function (p) { return p.indexOf('Z0,') === 0; }).length, 2,
        'P2.4 摘点后不再重新下断（Z0 总共只有 2 发）');
    // 命中停止不是 brk ⇒ 不该去读 pc 上的指令（m 包只应出现在武装那一次）
    eq(r.sent.filter(function (p) { return /^m[0-9a-f]+,4$/.test(p); }).length, 2,
        'P2.5 命中分支不再走「读 pc 指令判 brk」（m 包只来自两次 brk #0xf00d）');
}

console.log('== P3. 命中 B：同一套动作，且 A 不再命中');
{
    const r = fullRun();
    eq(r.sent.filter(function (p) { return p === 'z0,' + B.toString(16) + ',4'; }).length, 1,
        'P3.1 命中 B 后摘 B 的点');
    eq(r.logs.filter(function (l) { return l.indexOf('[A2PROBE] HIT pc=0x') >= 0; }).length, 2,
        'P3.2 一轮里恰好两行 HIT（A 一次、B 一次）');
    eq(r.sent.filter(function (p) { return p === 'c'; }).length, 4,
        'P3.3 有限停止序列下恰好 4 次 c（武装 / A / B / detach），没有空转');
}

console.log('== P4. 地址为 0 的槽不下断（App 没取到该符号）');
{
    const mem = {};
    mem[Number(ARM_PC)] = brkHex(0xf00d);
    mem[Number(DETACH_PC)] = brkHex(0xf00d);
    const r = run([
        stopReply(5, { x0: 0n, x1: B, x16: 99n, pc: ARM_PC }),
        stopReply(5, { x0: 0n, x1: 0n, x16: 0n, pc: DETACH_PC })
    ], mem);
    eq(r.error, null, 'P4.1 无异常');
    eq(r.sent.filter(function (p) { return p.indexOf('Z0,') === 0; }).length, 1,
        'P4.2 A=0 ⇒ 只给 B 下断（不发 Z0,0,4）');
    ok(r.sent.some(function (p) { return p === 'Z0,' + B.toString(16) + ',4'; }),
        'P4.3 B 的 Z0 照发');
    ok(r.logs.some(function (l) {
        return l.indexOf('[A2PROBE] armed A=0x0 B=0x' + B.toString(16)) >= 0;
    }), 'P4.4 armed 行如实写 A=0x0（不假装取到了）');

    const r2 = run([
        stopReply(5, { x0: 0n, x1: 0n, x16: 99n, pc: ARM_PC }),
        stopReply(5, { x0: 0n, x1: 0n, x16: 0n, pc: DETACH_PC })
    ], mem);
    eq(r2.sent.filter(function (p) { return p.indexOf('Z0,') === 0; }).length, 0,
        'P4.5 A=B=0 ⇒ 一发 Z0 都不发');
    ok(r2.logs.some(function (l) { return l.indexOf('两个地址都是 0') >= 0; }),
        'P4.6 如实说明没下断的原因');
}

console.log('== P5. 命中打印上限（A2PROBE_HIT_LIMIT = 3）');
{
    // 反复在同一地址停 5 次：脚本应摘点 5 次、只打印 3 行 HIT
    const mem = {};
    mem[Number(ARM_PC)] = brkHex(0xf00d);
    mem[Number(DETACH_PC)] = brkHex(0xf00d);
    const stops = [stopReply(5, { x0: A, x1: B, x16: 99n, pc: ARM_PC })];
    for (let i = 0; i < 5; i++) stops.push(stopReply(5, { pc: A }));
    stops.push(stopReply(5, { x0: 0n, x1: 0n, x16: 0n, pc: DETACH_PC }));
    const r = run(stops, mem, gPacket({ pc: A, lr: 0x1n }));
    eq(r.error, null, 'P5.1 无异常');
    eq(r.logs.filter(function (l) { return l.indexOf('[A2PROBE] HIT pc=0x') >= 0; }).length, 3,
        'P5.2 只打印 3 行 HIT（到上限收手）');
    eq(r.sent.filter(function (p) { return p === 'z0,' + A.toString(16) + ',4'; }).length, 5,
        'P5.3 但 5 次都摘了点（否则同一地址会反复停 = 死循环）');
    ok(r.logs.some(function (l) { return l.indexOf('只摘点不打印') >= 0; }),
        'P5.4 超上限时如实打一行「只摘点不打印」');
}

console.log('== P6. `g` 包解析（ARM64 偏移 / 短包如实为 null）');
{
    const mem6 = {};
    mem6[Number(DETACH_PC)] = brkHex(0xf00d);
    const c = run([stopReply(5, { x0: 0n, x1: 0n, x16: 0n, pc: DETACH_PC })], mem6).ctx;
    const P = c.a2ProbeParseRegisters;

    const full = P(gPacket({ x0: 0x1234n, x1: 0x5678n, x2: 0x9abcn, x3: 0xdef0n,
                             lr: 0x100030000n, pc: 0x1028a4b80n }));
    eq(full.x0, 0x1234n, 'P6.1 x0 在偏移 0');
    eq(full.x1, 0x5678n, 'P6.2 x1 在偏移 1*8');
    eq(full.x2, 0x9abcn, 'P6.3 x2 在偏移 2*8');
    eq(full.x3, 0xdef0n, 'P6.4 x3 在偏移 3*8');
    eq(full.lr, 0x100030000n, 'P6.5 lr(x30) 在偏移 30*8');
    eq(full.pc, 0x1028a4b80n, 'P6.6 pc 在偏移 32*8');

    const short = P(leHex(0x1234n));
    eq(short.x0, 0x1234n, 'P6.7 短包仍能读到 x0');
    eq(short.lr, null, 'P6.8 短包缺 lr ⇒ null（不猜 0）');
    eq(short.pc, null, 'P6.9 短包缺 pc ⇒ null（不猜 0）');
    eq(P('').pc, null, 'P6.10 空包 ⇒ null');
    eq(P(null).x0, null, 'P6.11 null 入参 ⇒ null（不抛）');
    eq(P('zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz').x0, null, 'P6.12 非 hex 字段 ⇒ null');
}

console.log('== P7. 没武装时，普通停止仍走原路径（不误判为命中）');
{
    const mem = {};
    mem[Number(DETACH_PC)] = brkHex(0xf00d);
    const r = run([stopReply(5, { pc: A }), stopReply(5, { x0: 0n, x1: 0n, x16: 0n, pc: DETACH_PC })], mem);
    eq(r.error, null, 'P7.1 无异常');
    eq(r.logs.filter(function (l) { return l.indexOf('[A2PROBE] HIT') >= 0; }).length, 0,
        'P7.2 没发过 cmd 99 ⇒ 不发 HIT 行');
    eq(r.sent.filter(function (p) { return p === 'g' || p.indexOf('z0,') === 0; }).length, 0,
        'P7.3 没发过 cmd 99 ⇒ 不发 g / z0');
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
