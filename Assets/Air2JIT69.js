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
// ★A2PROBE★ 已布点的地址（BigInt；null = 该槽没有点）+ 本次武装已打印的命中次数
let a2Probe = { a: null, b: null, hits: 0 };
let pid = get_pid();
let attachResponse = send_command(`vAttach;${pid.toString(16)}`);

log(`pid = ${pid}`);
log(`attach_response = ${attachResponse}`);
    
let totalBreakpoints = 0;
while (!detached) {
    totalBreakpoints++;
    log(`Handling signal ${totalBreakpoints}`);
    
    let brkResponse = send_command(`c`);
    log_verbose(`brkResponse = ${brkResponse}`);
    
    // extract tid, pc, x16
    let tmpMatch = /T[0-9a-f]+thread:(?<tid>[0-9a-f]+);/.exec(brkResponse);
    tid = tmpMatch ? tmpMatch.groups['tid'] : null;
    tmpMatch = /20:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    pc = tmpMatch ? tmpMatch.groups['reg'] : null;
    tmpMatch = /10:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    x16 = tmpMatch ? tmpMatch.groups['reg'] : null;
    if (!tid || !pc || !x16) {
        log(`Failed to extract registers: tid=${tid}, pc=${pc}, x16=${x16}`);
        continue;
    }
    pc = littleEndianHexStringToNumber(pc);
    x16 = littleEndianHexStringToNumber(x16);

    // ★A2PROBE★ 命中我们布的两个 GL 地址 ⇒ 打印寄存器、摘点、继续。
    //   ★必须在下面「读 pc 指令 / 区分 brk」之前判★：Z0 停下来时 pc 上是调试器塞的 brk #0，
    //   走后面的分支只会落进「这条 brk 没人认领 ⇒ continue」⇒ 同一地址反复停（死循环）。
    if (a2ProbeHandleStop()) {
        continue;
    }

    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    
    // check if this is a brk
    if ((instrU32 & 0xFFE0001F)>>>0 != 0xD4200000) {
        log(`Skipping: instruction was not a brk (was 0x${instrU32.toString(16)})`);
        let signum = /^T(?<sig>[a-z0-9;]{2})/.exec(brkResponse);
        signum = signum ? signum.groups['sig'] : null;
        if (!signum) {
            log(`Failed to extract signal number: ${signum}`);
            continue;
        }
        // ★2026-10-31：致命信号不再放行★
        //   真机现象：进程真崩（SIGSEGV=0x0b / SIGBUS=0x0a）时，脚本原本一律 vCont 放行，
        //   于是同一处崩溃被反复「继续 → 再崩 → 再继续」，StikDebug 控制台无限刷信号。
        //   这里对致命信号**停住不放行**，让人能直接看到现场（进程保持停止）。
        const fatalSigs = ['0b', '0a', '04', '06', '05'];  // SEGV / BUS / ILL / ABRT / TRAP
        if (fatalSigs.indexOf(String(signum).toLowerCase()) >= 0) {
            log(`[A2PROBE] FATAL sig=0x${signum} pc=0x${pc.toString(16)} ⇒ 停止放行（保留现场，不再 continue）`);
            detached = true;   // 跳出主循环，进程保持 stopped
            break;
        }
        log(`Continuing with signal 0x${signum}`);
        send_command(`vCont;S${signum}:${tid}`);
        continue;
    }
    
    let brkImmediate = extractBrkImmediate(instrU32);
    log(`BRK immediate: 0x${brkImmediate.toString(16)} (${brkImmediate})`);
    if (legacyCommands[brkImmediate] != undefined) {
        // when we find a valid brk immediate command, parse x0 and x1
        tmpMatch = /00:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
        x0 = tmpMatch ? tmpMatch.groups['reg'] : null;
        tmpMatch = /01:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
        x1 = tmpMatch ? tmpMatch.groups['reg'] : null;
        if (!x0 || !x1) {
            log(`Failed to extract registers: x0=${x0}, x1=${x1}`);
            continue;
        }
        x0 = littleEndianHexStringToNumber(x0);
        x1 = littleEndianHexStringToNumber(x1);
        
        // jump over brk
        let pcPlus4 = numberToLittleEndianHexString(pc + 4n);
        let pcPlus4Response = send_command(`P20=${pcPlus4};thread:${tid};`);
        log(`pcPlus4Response = ${pcPlus4Response}`);
        
        // dispatch brk-immediate command
        const command = legacyCommands[brkImmediate];
        command(brkResponse);
    } else {
        log(`Skipping breakpoint: brk immediate 0x${brkImmediate.toString(16)} was not handled by this script. You could add it by evaluating legacyCommands[0x${brkImmediate.toString(16)}] = yourFunction;`);
        // ★2026-10-31：未知 brk 不再一律放行★
        //   真机：`brk #0xb001`（libsystem 在 pthread_exit 里检测到 pthread 结构损坏时发的）
        //   原本走 continue ⇒ 立刻再撞同一条 ⇒ 控制台无限刷「0xb001 not handled」。
        //   这里把 0xb001（以及任何 0xb0xx 家族）视为致命，停住不放行，保留现场。
        if (brkImmediate >= 0xb000 && brkImmediate <= 0xb0ff) {
            log(`[A2PROBE] FATAL brk=0x${brkImmediate.toString(16)} pc=0x${pc.toString(16)} ⇒ 停止放行（系统库致命断点，不再 continue）`);
            detached = true;
            break;
        }
        continue;
    }
}

function JIT26Detach() {
    // ★[A2PROBE] 探针模式禁用 detach★
    //   真机实证（2026-10-31）：Z0 断点是调试器侧状态，StikDebug 一 detach 就被撤掉并还原原指令
    //   ⇒ 黑屏期间永远不会有 [A2PROBE] HIT。所以只要探针已 armed，就把 detach 忽略掉，让它一直附着。
    //   未 arm（普通用户路径）行为不变：照常 D 并跳出主循环。
    if (typeof a2Probe !== 'undefined' && a2Probe && (a2Probe.a || a2Probe.b)) {
        log(`[A2PROBE] detach ignored (probe armed A=0x${(a2Probe.a||0).toString(16)} B=0x${(a2Probe.b||0).toString(16)})`);
        return;
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

// brk 0x69
function JIT26HandleBrk0x69(brkResponse) {
    // in the old script we chose 0x69, so now we check here and return error
    // if you wish to keep using this, you can set your own handler like `legacyCommands[0x69] = yourHandler;` using BreakSendJITScript
    log(`Error: It seems you are using legacy breakpoint 0x69. Please set your legacy handler using \`legacyCommands[0x69] = yourHandler;\` or migrate to universal jitcalls to use this script. The function will now return 0xE0000069.`);
    let putX0Response = send_command(`P0=E0000069;thread:${tid};`);
    log(`putX0Response = ${putX0Response}`);
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
        
        if (!requestRXResponse || requestRXResponse.length === 0) {
            log(`Failed to allocate RX memory`);
            return;
        }
        
        jitPageAddress = BigInt(`0x${requestRXResponse}`);
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
    return parseInt(hexStr.match(/../g).reverse().join(''), 16);
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
