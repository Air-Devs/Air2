// ============================================================================
// AmethystJIT69.js  ——  自研启动链（runtime_native）专属 JIT 脚本
// ----------------------------------------------------------------------------
// 职责：接管【传统 legacy `brk #0x69`】= BreakGetJITMapping(size)，在目标进程里
//       【真的分配一块可写可执行(W+X)内存】并回填给 App —— 不再像 base 脚本那样回哨兵。
//
// 血统（provenance）：本节以下 = UniversalJIT26.js（App 包内 Natives/resources/，
//   last updated 2025-10-10）【逐字照搬】，仅做三处改动（均在下方以 ★[改-*]★ 标出）：
//     [改-1] JIT26HandleBrk0x69 函数体：把 base 的“回 legacy 哨兵 0xE0000069”分支
//            替换为【真分配 + 落实页 + 回填地址】。
//     [改-2] JIT26NewBreakpoints 尾部追加一行：把 legacyCommands[0x69] 重新指回本脚本的
//            真交付器（防止 App 下发 UniversalJIT26Extension.js 时把 0x69 又换成 rx 版）。
//     [增]   文件前部插入配置常量 + 分配助手 + （照搬 UniversalJIT26Extension.js 的）
//            commands[3]/[4] 两条 universal 命令注册，使本脚本可单独替代 base+Extension。
//
// 命中传统 0x69 时打印 `[AMETHYST-JIT69] ...` 行，便于真机判据（见 D:\CTF\_JIT_SCRIPT.md）。
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
const commands = {
    [CMD_DETACH]: JIT26Detach,
    [CMD_PREPARE_REGION]: JIT26PrepareRegion,
    [CMD_NEW_BREAKPOINTS]: JIT26NewBreakpoints
};
const legacyCommands = {
    [0x68]: JIT26NewBreakpoints,
    [0x69]: JIT26HandleBrk0x69,
    [0xf00d]: JIT26HandleBrk0xf00d
};

// ----------------------------------------------------------------------------
// ★[增] 自研启动链配置：传统 0x69 真交付器
// ----------------------------------------------------------------------------
// App 契约：x0 = 请求字节数（BreakGetJITMapping(size)）；返回 x0 = 可写可执行区首地址。
// 见 D:\CTF\_JIT_SCRIPT.md §2/§4。JVM 侧 -XX:+MirrorMappedCodeCache 走同一条 0x69。
const AME_JIT_PAGE           = 16384n;                 // arm64e getpagesize()（App 探测即请求 1 页）
const AME_JIT_REGION_MIN     = AME_JIT_PAGE;           // 最小 1 页
const AME_JIT_REGION_MAX     = 268435456n;             // 上限 256 MiB（可调；JVM 默认请求 64 MiB=0x4000000）
const AME_JIT_ERR_BAD_SIZE   = 0xE0000001n;            // 请求尺寸非法/超上限
const AME_JIT_ERR_ALLOC_FAIL = 0xE0000002n;            // _M（rwx 与 rx 都）分配失败
const AME_JIT_ERR_BLESS_FAIL = 0xE0000003n;            // prepare_memory_region 落实页失败
let   ameJITBrk69Hits        = 0;                      // 命中计数（真机判据）
let   ameJITInBrk69          = false;                  // ★防重入★：0x69 handler 一次只允许一层

// ★[照搬自 UniversalJIT26Extension.js] universal 命令 3/4：
//   commands[3] = JIT26SetDetachAfterFirstBr(BOOL)（默认 false：本链【不】自动脱离，
//                 脱离后新 RX 区无法再被落实，JVM code cache 增长会失败）
//   commands[4] = JIT26PrepareRegionForPatching(void *addr, size_t len)（读+原样写回，触碰页）
let detachAfterFirstBr = false;
commands[3] = function(brkResponse) {
    detachAfterFirstBr = x0 != 0;
    log(`JIT26SetDetachAfterFirstBr(${detachAfterFirstBr}) called`);
};
commands[4] = function(brkResponse) {
    let x0str = x0.toString(16);
    let x1str = x1.toString(16);
    let bytes = send_command(`m${x0str},${x1str}`);
    send_command(`M${x0str},${x1str}:${bytes}`);
};

// ----------------------------------------------------------------------------
// ★[增] 真交付器：分配 + 回填
// ----------------------------------------------------------------------------
// 手法【照搬】base 的 JIT26PrepareRegion：`_M<size>,<perms>`（debugserver 在目标进程分配）
//   + prepare_memory_region(addr,size)（StikDebug 逐 16KB 页写 1 字节 0x69 “落实/祝福”该页）。
// 与 base 的唯一区别：权限用 **rwx**（而非 base 的 rx）。
//   原因：App 侧自证 ameJITProveRegionRWX 会先 mprotect(RW)、写指令、再 mprotect(RX)、真执行；
//   只有该区 max_protection 同时含 W 与 X，这一步才可能全过。若 rwx 被拒，退 base 同款 rx。
function ameJITParseAllocAddr(resp) {
    if (!resp) return 0n;
    const s = String(resp).trim();
    if (!/^[0-9a-fA-F]+$/.test(s)) return 0n;   // 含非 hex 字符（如 "OK"）⇒ 失败
    if (s.length < 8) return 0n;                // debugserver 错误码 "EXX" = 3 字符 ⇒ 失败；真地址 ≥8 hex
    const a = BigInt(`0x${s}`);
    return (a > 0x1000n) ? a : 0n;
}

function ameJITAllocMapping(bytes) {
    const perms = ["rwx", "rx"];               // 先 rwx，退 rx（base 同款）
    for (let i = 0; i < perms.length; i++) {
        const p = perms[i];
        const resp = send_command(`_M${bytes.toString(16)},${p}`);
        log(`[AMETHYST-JIT69] _M${bytes.toString(16)},${p} -> '${resp}'`);
        const addr = ameJITParseAllocAddr(resp);
        if (addr !== 0n) return addr;
    }
    return 0n;
}

function ameJITReplyX0(val) {
    let resp = send_command(`P0=${numberToLittleEndianHexString(val)};thread:${tid};`);
    log_verbose(`putX0Response = ${resp}`);
}


// Log levels
//const LOG_NONE = 0;
const LOG_INFO = 1;
const LOG_VERBOSE = 2;
let logLevel = LOG_INFO;
function log_verbose(msg) {
    if (logLevel >= LOG_VERBOSE) {
        log(msg);
    }
}

// To avoid having to re-parse these in each function, we save some registers here
let tid, x0, x1, x16, pc;
let detached = false;
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
        continue;
    }
}

function JIT26Detach() {
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
        log('Script failed:', res.name, res.message);
        log(res.stack);
    }

    // ★[自纠]★ 不再强行覆盖 legacyCommands[0x69]：App 下发的官方 UniversalJIT26Extension.js 自身
    //   就是正确实现（x1=x0; x0=0; JIT26PrepareRegion ⇒ 同语义），强行顶掉它只会在 App 与脚本之间
    //   来回拉扯（曾造成命令洪水 + 假死/黑屏）。此处保持安静，让它自然生效。
}

// brk 0x69  ★[改-1]★ —— 真服务 legacy BreakGetJITMapping（base 此处回哨兵 0xE0000069，本脚本不再回）
//
// ★[自纠]★ 语义回归官方 UniversalJIT26Extension.js 的 3 行实现，不再自造分配：
//   x1 = x0(size)；x0 = 0；JIT26PrepareRegion(brkResponse) ⇒ 由 host 走官方路径分配+落实并回填 x0。
//   旧版自造的 `_M<size>,rwx` + 逐 16KB 页 prepare_memory_region 会在【每次命中】都新分配一块内存、
//   并打出成千条调试命令（64MiB ⇒ 4096 条）⇒ 地址每次都变 + 命令洪水 ⇒ App 反复重试 ⇒ 假死/黑屏。
function JIT26HandleBrk0x69(brkResponse) {
    if (ameJITInBrk69) {                                       // ★防重入★：同一时刻只允许一层
        log(`[AMETHYST-JIT69] re-entrant brk #0x69 -> skipped`);
        return;
    }
    ameJITInBrk69 = true;
    try {
        ameJITBrk69Hits++;
        if (ameJITBrk69Hits <= 3) {                            // 只记前几次，避免刷屏
            log(`[AMETHYST-JIT69] hit #${ameJITBrk69Hits}: brk #0x69 BreakGetJITMapping(size=0x${x0.toString(16)}) @pc=0x${pc.toString(16)}`);
        }
        x1 = x0;                                               // 官方语义：size 挪到 x1
        x0 = 0;                                                // 官方语义：x0=0 ⇒ 由 host 分配
        JIT26PrepareRegion(brkResponse);                       // 官方路径：分配 + prepare + 回填 x0
        if (detachAfterFirstBr) {
            JIT26Detach();
        }
    } finally {
        ameJITInBrk69 = false;
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
