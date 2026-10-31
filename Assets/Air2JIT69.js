// ============================================================================
// Air2JIT69.js  ——  Air2 启动链专属 JIT 脚本（StikDebug「Assign Script」下发）
// ----------------------------------------------------------------------------
// 职责：接管【传统 legacy `brk #0x69`】= BreakGetJITMapping(size)，在目标进程里
//       【真的分配一块可执行区】并把地址回填 x0；同时服务 universal `brk #0xf00d`
//       命令集（detach / prepare region / 下发脚本）与 ★A2PROBE★ GL 探针。
//
// 单测（改本文件必须先跑；测试是这里的行为契约，不是参考）：
//   node tests/JIT/jit_script_tests.js   停止回复解析 / 续跑包 / brk 交付 / 有界收尾
//   node tests/JIT/jit_probe_tests.js    cmd 99 探针（Z0/z0/g）
//
// 血统：协议逻辑派生自 UniversalJIT26.js（last updated 2025-10-10）+ 其 Extension
//   的 0x69 语义；改动均以 ★[改-*]★ 标出：
//   [改-1] 0x69 真交付：不回 legacy 哨兵 0xE0000069，按官方 Extension 的三行语义
//          （x1 = x0(size) ⇒ x0 = 0 ⇒ JIT26PrepareRegion）分配 + 落实页 + 回填 x0。
//   [改-2] 停止回复解析独立成纯函数 ameJITParseStopReply()：T=停住 / W,X=退出 /
//          E=包错 / 空串=没拿到。真机日志那行 "tid=null, pc=null, x16=null" 不是
//          正则问题：W/X/E 回复里压根没有这些字段，而 base 在该分支里 continue 空转。
//   [改-3] 续跑包：base 发 `vCont;S<sig>:<tid>` —— 'S' 在 debugserver 里是【单步】
//          （RNBRemote.cpp L4072-L4083：case 'S' ⇒ eStateStepping），每停一次只前进
//          一条指令 ⇒ 满屏 "Skipping: instruction was not a brk"，永远到不了下一个
//          brk。改发 ameJITResumePacket() = `C<sig>`（L4059-L4069：case 'C' ⇒
//          eStateRunning，且其余线程一起恢复）。不能带 `;thread:` —— ';' 之后会被
//          HandlePacket_C 当成 PC 地址解析。
//   [改-4] 不许空转：连续 8 次拿不到停止回复 ⇒ 打日志 + 收尾；读到 W/X/E 立即收尾。
//   [改-5] 停点日志去重（a2StopLogOnce）：同一 (信号|brk, pc) 只打一次，其余静默放行。
// ============================================================================


// Universal JIT Script, last updated 2025-10-10
/*
 // JIT "syscalls"
 __attribute__((noinline,optnone,naked))
 void JIT26Detach(void) {
     asm("mov x16, #0 \n"
         "brk #0xf00d \n"
         "ret");
 }
 __attribute__((noinline,optnone,naked))
 void* JIT26PrepareRegion(void *addr, size_t len) {
     asm("mov x16, #1 \n"
         "brk #0xf00d \n"
         "ret");
 }

 __attribute__((noinline,optnone,naked))
void BreakSendJITScript(char* script, size_t len) {
    asm("mov x16, #2 \n"
        "brk #0xf00d \n"
        "ret");
}
 */
const CMD_DETACH = 0;
const CMD_PREPARE_REGION = 1;
const CMD_NEW_BREAKPOINTS = 2;
// ★A2PROBE★ cmd 99 = GL 断点探针武装（App 侧 a2_jit_probe_arm 发出）。
//   入参：x0 = 地址 A（KW 的 glLoadIdentity）、x1 = 地址 B（ANGLE 的 glLoadIdentity）；
//   两者都是 ASLR 后的实际地址（小端整数），0 = App 没取到该符号。
//   行为：对每个非 0 地址发一发 `Z0,<hex>,4`；之后主循环里 pc 命中就打印一行寄存器并摘点。
const CMD_PROBE_GL = 99;
// ★A2PROBE★ 单次武装最多打印几次命中（超了只摘点不打印，防同一地址刷屏）
const A2PROBE_HIT_LIMIT = 3;
// ★[改-3]★ SIGTRAP 归调试器所有（brk 走的就是它），不往 App 转发。
const A2_SIGTRAP = 0x05;
// ★[改-4]★ 连续「不是停止回复」的上限：到顶就收尾，不许在 while 里空转。
const A2_BAD_REPLY_LIMIT = 8;
const commands = {
    [CMD_DETACH]: JIT26Detach,
    [CMD_PREPARE_REGION]: JIT26PrepareRegion,
    [CMD_NEW_BREAKPOINTS]: JIT26NewBreakpoints,
    [CMD_PROBE_GL]: JIT26ProbeArmGL
};
const legacyCommands = {
    [0x68]: JIT26NewBreakpoints,
    [0x69]: JIT26HandleBrk0x69,
    [0xf00d]: JIT26HandleBrk0xf00d
};

// Log levels
//const LOG_NONE = 0;
const LOG_INFO = 1;
const LOG_VERBOSE = 2;
let logLevel = LOG_VERBOSE;
function log_verbose(msg) {
    if (logLevel >= LOG_VERBOSE) {
        log(msg);
    }
}

// To avoid having to re-parse these in each function, we save some registers here
let tid, x0, x1, x16, pc;
let detached = false;
// ★[改-1]★ 命中计数与重入闸（真机判据：日志里数 `[AIR2-JIT69] hit #N`）
let a2Brk69Hits = 0;
let a2InBrk69 = false;
// ★[改-5]★ 停点日志去重
//   真机上同一处停止会被反复停/继续，一次启动能刷几万条。这里按 (信号|brk, pc) 去重：
//   **同一个位置只打一次**，其余静默，但照样放行 ⇒ 不刷屏、游戏仍能跑。
const a2StopSeen = new Set();
const A2_STOP_LOG_MAX = 20;   // 全局上限，超了就完全静默，避免新位置也能刷
let a2StopLogCount = 0;
function a2StopLogOnce(key, msg) {
    if (a2StopSeen.has(key)) return false;
    a2StopSeen.add(key);
    if (a2StopLogCount >= A2_STOP_LOG_MAX) return false;
    a2StopLogCount++;
    log(msg);
    return true;
}
// ★A2PROBE★ 已布点的地址（BigInt；null = 该槽没有点）+ 本次武装已打印的命中次数
let a2Probe = { a: null, b: null, hits: 0 };
let pid = get_pid();
let attachResponse = send_command(`vAttach;${pid.toString(16)}`);

log(`pid = ${pid}`);
log(`attach_response = ${attachResponse}`);

let totalBreakpoints = 0;
let a2BadReplies = 0;                 // ★[改-4]★ 连续「不是停止回复」的计数
let a2TrapPc = null;                  // ★[改-3]★ 上一次被吞掉的 SIGTRAP 所在 pc（防同址死循环）
while (!detached) {
    totalBreakpoints++;
    log(`Handling signal ${totalBreakpoints}`);
    
    let brkResponse = send_command(`c`);
    log_verbose(`brkResponse = ${brkResponse}`);

    // ★[改-2]★ 停止回复分类：T=停住 / W,X=进程已退出 / E=包错误 / 空=没拿到 / 其它=垃圾
    const stop = ameJITParseStopReply(brkResponse);
    const signo = stop.signo;
    if (stop.kind !== 'stop' || !stop.tid || !stop.pcHex || !stop.x16Hex) {
        a2BadReplies++;
        log(`Failed to extract registers: tid=${stop.tid}, pc=${stop.pcHex}, x16=${stop.x16Hex}`
            + ` (kind=${stop.kind}, signo=${signo}, ${a2BadReplies}/${A2_BAD_REPLY_LIMIT},`
            + ` raw='${ameJITClip(stop.raw, 160)}')`);
        if (stop.kind === 'exited' || stop.kind === 'error'
            || a2BadReplies >= A2_BAD_REPLY_LIMIT) {
            // 进程被杀 / 调试会话报错 / 连续拿不到停止回复 ⇒ 如实收尾。
            // （base 在这里无限 continue，最后被宿主按 `Script failed:` 收尾，看不到原因。）
            log(`[AIR2-JIT69] 停止服务：进程已退出或调试会话失效`
                + `（kind=${stop.kind}, 连续无效回复=${a2BadReplies}）`);
            break;
        }
        continue;
    }
    a2BadReplies = 0;
    tid = stop.tid;
    pc  = littleEndianHexStringToNumber(stop.pcHex);
    x16 = littleEndianHexStringToNumber(stop.x16Hex);
    log_verbose(`stop: signo=0x${signo === null ? '??' : signo.toString(16)}`
        + ` tid=${tid} pc=0x${pc.toString(16)} x16=0x${x16.toString(16)}`);

    // ★A2PROBE★ 命中我们布的两个 GL 地址 ⇒ 打印寄存器、摘点、继续。
    //   ★必须在下面「读 pc 指令 / 区分 brk」之前判★：Z0 停下来时 pc 上是调试器塞的 brk #0，
    //   走后面的分支只会落进「这条 brk 没人认领 ⇒ 跳过」，把探针的停点悄悄吃掉。
    if (a2ProbeHandleStop()) {
        a2TrapPc = null;
        continue;
    }

    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);

    // check if this is a brk
    if (!ameJITIsBrk(instrU32)) {
        // 同一 (信号, pc) 只打一次；指令字读不出来时如实打 0xNaN（不抛 TypeError）。
        a2StopLogOnce('skip:' + signo + ':' + pc.toString(16),
                      `Skipping: instruction was not a brk (was 0x${instrU32.toString(16)})`);
        if (signo === A2_SIGTRAP) {
            // SIGTRAP 是调试器自己的（brk 已在上一行判掉）⇒ 吞掉后继续，不转发给 App。
            // 同一个 pc 连续第二次报 SIGTRAP ⇒ 这条指令自身必停（例如读不出指令字的 brk），
            // 越过它再继续，否则会在同一地址无休止重停。
            if (a2TrapPc !== null && a2TrapPc === pc) {
                log(`[AIR2-JIT69] 同一 pc 连续 SIGTRAP ⇒ 跳过该指令 (pc=0x${pc.toString(16)})`);
                ameJITSkipInstruction();
            }
            a2TrapPc = pc;
            continue;
        }
        a2TrapPc = null;
        // ★[改-3]★ 放行信号必须发 `C<sig>`（带信号继续，全线程恢复）。
        // 绝不能用 vCont 形式（'S' 是单步；带 thread 的 'C' 会被当 PC 地址）。
        const resumePacket = ameJITResumePacket(signo);
        log_verbose(`Continuing with signal 0x${signo === null ? '??' : signo.toString(16)}`
            + ` (packet '${resumePacket}')`);
        send_command(resumePacket);
        continue;
    }
    a2TrapPc = null;

    let brkImmediate = extractBrkImmediate(instrU32);
    log(`BRK immediate: 0x${brkImmediate.toString(16)} (${brkImmediate})`);
    if (legacyCommands[brkImmediate] != undefined) {
        // when we find a valid brk immediate command, parse x0 and x1
        const x0Hex = stop.x0Hex;
        const x1Hex = stop.x1Hex;
        if (!x0Hex || !x1Hex) {
            log(`Failed to extract registers: x0=${x0Hex}, x1=${x1Hex}`);
            continue;
        }
        x0 = littleEndianHexStringToNumber(x0Hex);
        x1 = littleEndianHexStringToNumber(x1Hex);

        // jump over brk
        let pcPlus4Response = ameJITSkipInstruction();
        log(`pcPlus4Response = ${pcPlus4Response}`);

        // dispatch brk-immediate command
        const command = legacyCommands[brkImmediate];
        command(brkResponse);
    } else {
        // ★必须越过这条 brk★：不跳过的话 pc 一直停在这条 brk 上，循环会无休止重停同一条指令。
        a2StopLogOnce('brk:' + brkImmediate.toString(16) + ':' + pc.toString(16),
                      `Skipping breakpoint: brk immediate 0x${brkImmediate.toString(16)}`
                      + ` was not handled by this script (pc=0x${pc.toString(16)});`
                      + ` 可加 legacyCommands[0x${brkImmediate.toString(16)}] = yourFunction; 认领它`);
        ameJITSkipInstruction();
        continue;
    }
}

function JIT26Detach() {
    // ★A2PROBE★ 探针在岗时 detach 会把 Z0 点一起撤掉 ⇒ 探针就此结束。如实说一句，
    //   但仍然要 D：App 已经不再需要调试器，留在这里只会挡住它（曾因此整个脚本挂住）。
    if (a2Probe && (a2Probe.a !== null || a2Probe.b !== null)) {
        const h = (v) => (v === null ? '0x0' : `0x${v.toString(16)}`);
        log(`[A2PROBE] detach 时探针仍在岗 (A=${h(a2Probe.a)} B=${h(a2Probe.b)}，`
            + `hits=${a2Probe.hits}) ⇒ Z0 点随 detach 撤销，探针到此结束`);
    }
    let detachResponse = send_command(`D`);
    log_verbose(`detachResponse = ${detachResponse}`);
    detached = true;
}

// brk 0x68
function JIT26NewBreakpoints(brkResponse) {
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    
    let memResponse = send_command(`m${x0.toString(16)},${x1}`);

    let scriptText = hexToAscii(memResponse);
    log_verbose(`Script text: ${scriptText}`);

    const res = runScriptAndCapture(scriptText);
    if (res.ok) {
        log('Script succeeded:', res.value);
    } else {
        // ★明确打出错误名与消息（以前只打 name/message 两个参数，真机上显示不出内容）★
        log('[A2SCRIPT] failed: ' + (res.name || 'Error') + ': ' + (res.message || '(no message)'));
        log(res.stack);
    }
}

// brk 0x69  ★[改-1]★ —— 真服务 legacy BreakGetJITMapping(size)
//
// 语义照官方 UniversalJIT26Extension.js 的三行实现，不自造分配：
//   x1 = x0(size)；x0 = 0；JIT26PrepareRegion() ⇒ host 走官方路径（_M<size>,rx 分配 +
//   逐页 prepare_memory_region）并回填 x0 = 可执行区首地址。
// 不再回 legacy 哨兵 0xE0000069（那是 base 让调用方去下发 Extension 的占位值，本脚本
// 自带 Extension 语义，回哨兵只会让 App 判「JIT 没开」）。
function JIT26HandleBrk0x69(brkResponse) {
    if (a2InBrk69) {                                       // ★防重入★：同一时刻只允许一层
        log(`[AIR2-JIT69] re-entrant brk #0x69 -> skipped`);
        return;
    }
    a2InBrk69 = true;
    try {
        a2Brk69Hits++;
        if (a2Brk69Hits <= 3) {                            // 只记前几次，避免刷屏
            log(`[AIR2-JIT69] hit #${a2Brk69Hits}: brk #0x69 BreakGetJITMapping`
                + `(size=0x${x0.toString(16)}) @pc=0x${pc.toString(16)}`);
        }
        x1 = x0;                                           // 官方语义：size 挪到 x1
        x0 = 0n;                                           // 官方语义：x0=0 ⇒ 由 host 分配
        JIT26PrepareRegion(brkResponse);                   // 官方路径：分配 + 落实 + 回填 x0
    } finally {
        a2InBrk69 = false;
    }
}

// brk 0xf00d
function JIT26HandleBrk0xf00d(brkResponse) {
    // dispatch command via x16
    const command = commands[x16];
    if (command === undefined) {
        log(`Unknown command ${x16.toString(16)}`);
        return;
    }
    log(`Invoking command ${x16.toString(16)}`);
    command(brkResponse);
}

function JIT26PrepareRegion(brkResponse) {
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    
    if (x0 == 0n && x1 == 0n) {
        return;
    }

    let jitPageAddress = x0;
    if (x0 == 0n) {
        let requestRXResponse = send_command(`_M${x1.toString(16)},rx`);
        log_verbose(`requestRXResponse = ${requestRXResponse}`);
        // ★_M 的回复必须是地址★：E53 这类错误包曾被当成地址 0xE53 回填进 x0，
        //   于是 App 往 0xE53 写指令 ⇒ SIGBUS 风暴。不是 ≥8 位 hex 就如实判失败。
        const rxText = (requestRXResponse === undefined || requestRXResponse === null)
            ? '' : String(requestRXResponse).trim();
        if (!/^[0-9a-fA-F]+$/.test(rxText) || rxText.length < 8) {
            log(`Failed to allocate RX memory (response '${rxText}' 不是地址，不回填 x0)`);
            return;
        }
        jitPageAddress = BigInt(`0x${rxText}`);
        log(`Allocated JIT page at address: 0x${jitPageAddress.toString(16)}`);
    }

    let prepareJITPageResponse = prepare_memory_region(jitPageAddress, x1);
    log(`prepareJITPageResponse = ${prepareJITPageResponse}`);

    let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
    log(`putX0Response = ${putX0Response}`);
}

// ★A2PROBE★ 命令 99：对 A、B 各发一发 Z0（软件断点，4 字节，arm64 定长指令），
//   并把这两个地址记进 a2Probe 供主循环比 pc。地址为 0 ⇒ 跳过该槽（App 没取到符号）。
function JIT26ProbeArmGL(brkResponse) {
    const hasA = (x0 != 0n);
    const hasB = (x1 != 0n);
    const aHex = hasA ? x0.toString(16) : '0';
    const bHex = hasB ? x1.toString(16) : '0';
    a2Probe = { a: hasA ? x0 : null, b: hasB ? x1 : null, hits: 0 };
    if (!hasA && !hasB) {
        log(`[A2PROBE] armed A=0x0 B=0x0 ⇒ 两个地址都是 0，不下断（App 没取到 glLoadIdentity）`);
        return;
    }
    if (hasA) {
        log(`[A2PROBE] Z0 A=0x${aHex} => <${send_command(`Z0,${aHex},4`)}>`);
    }
    if (hasB) {
        log(`[A2PROBE] Z0 B=0x${bHex} => <${send_command(`Z0,${bHex},4`)}>`);
    }
    log(`[A2PROBE] armed A=0x${aHex} B=0x${bHex}`);
}

// ★A2PROBE★ 主循环里的命中判定：pc 落在布点地址上 ⇒ 摘点 + 打印寄存器，返回 true（调用方 continue）。
//   ★先摘点（z0）再继续★：Z0 停在同一地址时若把点留着，下一个 c 立刻又停在同一 pc ⇒ 死循环。
//   ★不重新下断★：一个地址只报一次；超过 A2PROBE_HIT_LIMIT 次后只摘点、不打印。
function a2ProbeHandleStop() {
    if (pc === null) {
        return false;
    }
    const isA = (a2Probe.a !== null && pc === a2Probe.a);
    const isB = (a2Probe.b !== null && pc === a2Probe.b);
    if (!isA && !isB) {
        return false;
    }
    const slot = isA ? 'A' : 'B';
    const addrHex = pc.toString(16);
    const disarmResponse = send_command(`z0,${addrHex},4`);
    log_verbose(`[A2PROBE] disarm ${slot}=0x${addrHex} z0=<${disarmResponse}>`);
    if (a2Probe.hits >= A2PROBE_HIT_LIMIT) {
        log(`[A2PROBE] HIT ${slot}=0x${addrHex} 已报满 ${A2PROBE_HIT_LIMIT} 次 ⇒ 只摘点不打印`);
        return true;
    }
    a2Probe.hits++;
    const regs = a2ProbeParseRegisters(send_command(`g`));
    const h = (v) => (v === null ? '?' : v.toString(16));
    log(`[A2PROBE] HIT pc=0x${h(regs.pc)} lr=0x${h(regs.lr)} x0=0x${h(regs.x0)} x1=0x${h(regs.x1)} x2=0x${h(regs.x2)} x3=0x${h(regs.x3)}`);
    return true;
}

// ★A2PROBE★ 解析 `g` 寄存器包：ARM64 顺序 x0..x28, fp(x29), lr(x30), sp, pc, cpsr；
//   每个 8 字节、目标字节序（小端）⇒ 偏移(字节)：x0 = 0、lr = 30*8、pc = 32*8（hex 字符 = ×2）。
//   包短了 / 字段不是 16 位 hex ⇒ 该字段如实给 null（不猜 0）。
function a2ProbeParseRegisters(gResponse) {
    const out = { x0: null, x1: null, x2: null, x3: null, lr: null, pc: null };
    if (typeof gResponse !== 'string') {
        return out;
    }
    const readReg = (index) => {
        const start = index * 16;
        if (start + 16 > gResponse.length) {
            return null;
        }
        const chunk = gResponse.substr(start, 16);
        return /^[0-9a-fA-F]{16}$/.test(chunk) ? littleEndianHexStringToNumber(chunk) : null;
    };
    out.x0 = readReg(0);
    out.x1 = readReg(1);
    out.x2 = readReg(2);
    out.x3 = readReg(3);
    out.lr = readReg(30);
    out.pc = readReg(32);
    return out;
}

// ---------------------------------------------------------------------------
// ★[改-2]/[改-3] 停止回复与续跑（纯函数；tests/JIT/jit_script_tests.js 逐例覆盖）
// ---------------------------------------------------------------------------
// debugserver 的停止回复（arm64）形如：
//   T05thread:1e03;00:<x0>;01:<x1>;…;10:<x16>;…;20:<pc>;21:<cpsr>;
// 每个寄存器 16 个 hex 字符、目标字节序（小端）；20 = pc，10 = x16，00/01 = x0/x1。
// 进程退出时回 W<status> / X<signal>，包出错回 E<nn> —— 这几种【没有】T/thread/寄存器
// 字段，base 的解析必然得到 tid=null,pc=null,x16=null（真机那行）然后原样 continue 空转。
// 取寄存器只认「(串首或';') + 两位寄存器号 + ':' + 恰好 16 hex」：否则 16 位值里出现的
// "20:" 之类会被误当成寄存器号。
function ameJITPickReg(s, regNo) {
    const m = new RegExp('(?:^|;)' + regNo + ':([0-9a-fA-F]{16})').exec(s);
    return m ? m[1] : null;
}

function ameJITParseStopReply(reply) {
    const out = {
        kind: 'empty', signo: null, tid: null,
        x0Hex: null, x1Hex: null, x16Hex: null, pcHex: null, raw: ''
    };
    if (reply === undefined || reply === null) return out;
    const s = String(reply).trim();
    out.raw = s;
    if (s.length === 0) return out;
    const head = s.charAt(0).toUpperCase();
    if (head === 'T') {
        out.kind = 'stop';
        const sig = /^T([0-9a-fA-F]{2})/.exec(s);
        out.signo = sig ? parseInt(sig[1], 16) : null;
        const th = /thread:([0-9a-fA-F]+)/.exec(s);
        out.tid = th ? th[1] : null;
        out.x0Hex  = ameJITPickReg(s, '00');
        out.x1Hex  = ameJITPickReg(s, '01');
        out.x16Hex = ameJITPickReg(s, '10');
        out.pcHex  = ameJITPickReg(s, '20');
        return out;
    }
    if (head === 'W' || head === 'X') { out.kind = 'exited'; return out; }
    if (head === 'E') { out.kind = 'error'; return out; }
    out.kind = 'unknown';
    return out;
}

// BRK #imm 的编码 = 0xD4200000 | (imm << 5)，判定 mask 0xFFE0001F。
// 读内存失败时指令字是 NaN ⇒ 必须返回 false 且不抛（typeof 检查先兜住 undefined）。
function ameJITIsBrk(u32) {
    if (typeof u32 !== 'number' || !isFinite(u32)) return false;
    return ((u32 & 0xFFE0001F) >>> 0) === 0xD4200000;
}

// ★[改-3]★ 续跑包：`C<sig>` = 带信号继续（RNBRemote.cpp L4059-L4069：case 'C' ⇒
// eStateRunning，且 SetDefaultThreadActionIfNeeded(eStateRunning) ⇒ 其余线程一起恢复）。
// 单步形式（'S' 那条）会让进程每停一次只前进一条指令，已由 K1/K2 单测禁掉。
// 也不能带 `;thread:<tid>`：HandlePacket_C 会把信号之后的 ';' 当成【PC 地址】解析。
// 信号号未知/越界 ⇒ 退化为不带信号的 `c`（继续，但别再乱转发信号）。
function ameJITResumePacket(signo) {
    if (typeof signo !== 'number' || !(signo >= 0 && signo <= 0xff)) return 'c';
    return `C${signo.toString(16).padStart(2, '0')}`;
}

// 越过当前指令（pc += 4）：用于「这条 brk 没人认领」与「同一 pc 反复 SIGTRAP」。
// 返回宿主的回包，调用方可按需记录。
function ameJITSkipInstruction() {
    return send_command(`P20=${numberToLittleEndianHexString(pc + 4n)};thread:${tid};`);
}

function ameJITClip(s, n) {
    s = (s === undefined || s === null) ? '' : String(s);
    return s.length <= n ? s : `${s.slice(0, n)}…`;
}

// utilities
function littleEndianHexStringToNumber(hexStr) {
    const bytes = [];
    for (let i = 0; i < hexStr.length; i += 2) {
        bytes.push(parseInt(hexStr.substr(i, 2), 16));
    }
    let num = 0n;
    for (let i = 4; i >= 0; i--) {
        num = (num << 8n) | BigInt(bytes[i]);
    }
    return num;
}

function numberToLittleEndianHexString(num) {
    const bytes = [];
    for (let i = 0; i < 5; i++) {
        bytes.push(Number(num & 0xFFn));
        num >>= 8n;
    }
    while (bytes.length < 8) {
        bytes.push(0);
    }
    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
}

function littleEndianHexToU32(hexStr) {
    // ★[改-4]★ 读内存失败时宿主回的是 "E01"/空串 —— base 直接 .match() 会抛 TypeError，
    // 整个脚本被宿主以 `Script failed:` 收尾。这里改成返回 NaN（调用方按「指令未知」处理，
    // 日志里如实出现 0xNaN）。
    const s = (hexStr === undefined || hexStr === null) ? '' : String(hexStr).trim();
    const m = /^[0-9a-fA-F]{8}/.exec(s);
    if (!m) return NaN;
    return parseInt(m[0].match(/../g).reverse().join(''), 16);
}

function extractBrkImmediate(u32) {
    return (u32 >> 5) & 0xFFFF;
}

function hexToAscii(hexStr) {
    let str = '';
    for (let i = 0; i < hexStr.length; i += 2) {
        const byte = parseInt(hexStr.substr(i, 2), 16);
        if (byte === 0) break;
        str += String.fromCharCode(byte);
    }
    return str;
}

function runScriptAndCapture(scriptText) {
    try {
        const value = eval(scriptText);
        return { ok: true, value };
    } catch (err) {
        return {
            ok: false,
            name: err && err.name,
            message: err && err.message,
            stack: err && err.stack
        };
    }
}

// For making your own script / adding your own breakpoints. you can send this string to BreakSendJITScript and it'll add it for any subsequent breakpoints
// x0, x1, x16, pc and tid are global variables. If you need more registers, parse them like:
// tmpMatch = /02:(?<reg>[0-9a-f]{16});/.exec(brkResponse); // x2
// let x2 = tmpMatch ? tmpMatch.groups['reg'] : null;
// if (!x2) {
//     log(`Failed to extract registers: x2=${x2}`);
//     return;
// }
// x2 = littleEndianHexStringToNumber(x2);
//
/*
commands[3] = wowBreakPoint;

function wowBreakPoint(brekpoint) {
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    
    if (x0 == 0n && x1 == 0n) {
        return;
    }

    let jitPageAddress = x0;
    let prepareJITPageResponse = prepare_memory_region(jitPageAddress, x1);
    log(`prepareJITPageResponse = ${prepareJITPageResponse}`);

    let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
    log(`putX0Response = ${putX0Response}`);
}
*/
