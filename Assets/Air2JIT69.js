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
//     [改-3] 主循环的「非 brk 停止 ⇒ 放行信号」：base 用 `vCont;S<sig>:<tid>` 是【单步】不是继续
//            （debugserver RNBRemote.cpp L4072-L4083：case 'S' ⇒ eStateStepping；
//              L4059-L4069：case 'C' ⇒ eStateRunning）。⇒ 回真机上表现为每停一次只前进【一条指令】，
//            于是满屏 `Skipping: instruction was not a brk`（pc 落在函数序言 `stp x29,x30,[sp,#-16]!`
//             / `ret` 这类任意指令上），永远走不到下一个 brk，App 也永远拿不到 0x69 的映射区。
//             改为 `C<sig>`（带信号继续，全线程恢复），详见 ameJITResumePacket()。
//     [改-4] 停止回复解析独立成纯函数 ameJITParseStopReply()，并把「拿不到停止回复」变成
//            【有界、有原文】的失败：base 在 tid/pc/x16 全 null 时 `continue` 空转，最后被宿主
//            以 `Script failed:` 收尾（真机日志：Handling signal 5 → Failed to extract registers）。 
//
// 命中传统 0x69 时打印 `[AIR2-JIT69] ...` 行，便于真机判据（见 D:\CTF\_JIT_SCRIPT.md）。
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

// universal cmd 4 = JIT26PrepareRegionForPatching(addr, len)
//   App 侧 mmap 一段 RW 后发它，脚本把页「读 + 原样写回」—— 这是让页拿到
//   TXM 可执行祝福的唯一手段（官方 Extension 就是这么做的）。
//   ★内部分块★：一次 m 读 1MB 会拼出 2MB 的十六进制文本，包太大 ⇒ 每 64KB 一块。
commands[4] = function (brkResponse) {
    let addr = x0;
    let len  = x1;
    const CH = 0x10000n;          // 64 KiB
    let off = 0n;
    let ok = 0;
    let fail = 0;
    while (off < len) {
        let n = (len - off) < CH ? (len - off) : CH;
        let a = (addr + off).toString(16);
        let s = n.toString(16);
        let bytes = send_command(`m${a},${s}`);
        if (bytes && /^[0-9a-fA-F]+$/.test(String(bytes))) {
            send_command(`M${a},${s}:${bytes}`);
            ok++;
        } else {
            fail++;
        }
        off += n;
    }
    log(`[AIR2-JIT69] cmd4 prepare addr=0x${addr.toString(16)} len=0x${len.toString(16)} ok=${ok} fail=${fail}`);
};
// ★自研 JIT 宿主区（brk #0x6942）★
//   App 侧 mmap 一段 RW 内存后发这个 brk，把地址/长度交给调试器整段祝福成可执行；
//   之后的 0x69（BreakGetJITMapping）直接交付这块，绕开 `_M<size>` 只回 16384 字节的限制。
const AME_JIT_FORCE_ZERO = false;  // ★2026-10-18★ 改回 false：App 现在逐页向调试器要 rx 页(_M4000,rx)，需要脚本真去分配
let ameJITBigRegion = 0n;
let ameJITBigSize   = 0n;
function ameJITHandleRegisterRegion(brkResponse) {
    ameJITBigRegion = x0;
    ameJITBigSize   = x1;
    let r = -1;
    try { r = prepare_memory_region(ameJITBigRegion, ameJITBigSize); } catch (e) { log(`prepare 异常: ${e}`); }
    // ★关键★ prepare 只让页“可写/可补丁”，实测整段做完 cur=0x3(rw)、还不是 r-x。
    //   官方 UniversalJIT26Extension 的 commands[4] 用「m 读 + M 写回」来让页真正拿到可执行祝福。
    //   64MB 整包一次不现实 ⇒ 逐页(16KB)做一次 1 字节读+写回；只祝福前 16MB（= code cache 大小）。
    const PAGE = 0x4000n;
    const CAP  = 0x1000000n;                     // 16 MiB
    let limit = ameJITBigSize < CAP ? ameJITBigSize : CAP;
    let blessed = 0;
    for (let off = 0n; off < limit; off += PAGE) {
        let a = ameJITBigRegion + off;
        let hex = send_command(`m${a.toString(16)},1`);
        if (hex && /^[0-9a-fA-F]{1,4}$/.test(hex)) {
            send_command(`M${a.toString(16)},1:${hex}`);
            blessed++;
        }
    }
    log(`[AIR2-JIT69] 注册自研宿主区 addr=0x${ameJITBigRegion.toString(16)} size=0x${ameJITBigSize.toString(16)} prepare=${r} blessed=${blessed} pages`);
    ameJITReplyX0(0n);
}

const legacyCommands = {
    [0x68]: JIT26NewBreakpoints,
    [0x69]: JIT26HandleBrk0x69,
    [0x6942]: ameJITHandleRegisterRegion,
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
const AME_JIT_SIGTRAP        = 0x05;                   // ★[改-3]★ brk 走的就是 SIGTRAP（5）
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
        log(`[AIR2-JIT69] _M${bytes.toString(16)},${p} -> '${resp}'`);
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
let ameJITBadReplies = 0;               // ★[改-4]★ 连续「不是停止回复」的计数（有界失败，不许空转）
let ameJITTrapPc      = null;           // ★[改-3]★ 上一次被吞掉的 SIGTRAP 所在 pc（防同一地址死循环）
const AME_JIT_BAD_REPLY_LIMIT = 8;
while (!detached) {
    totalBreakpoints++;
    log(`Handling signal ${totalBreakpoints}`);
    
    let brkResponse = send_command(`c`);
    log_verbose(`brkResponse = ${brkResponse}`);
    
    // ★[改-4]★ 停止回复分类：T=停住 / W,X=进程已退出 / E=包错误 / 其它=空或垃圾
    const stop = ameJITParseStopReply(brkResponse);
    const signo = stop.signo;
    if (stop.kind !== 'stop' || !stop.tid || !stop.pcHex || !stop.x16Hex) {
        ameJITBadReplies++;
        log(`Failed to extract registers: tid=${stop.tid}, pc=${stop.pcHex}, x16=${stop.x16Hex}`
            + ` (kind=${stop.kind}, signo=${signo}, ${ameJITBadReplies}/${AME_JIT_BAD_REPLY_LIMIT},`
            + ` raw='${ameJITClip(stop.raw, 160)}')`);
        if (stop.kind === 'exited' || stop.kind === 'error'
            || ameJITBadReplies >= AME_JIT_BAD_REPLY_LIMIT) {
            // 进程已被杀 / 调试会话报错 / 连续拿不到停止回复 ⇒ 如实收尾（base 在这里无限空转，
            // 最终被宿主按 `Script failed:` 结束，看不到任何原因）。
            log(`[AIR2-JIT69] 停止服务：进程已退出或调试会话失效`
                + `（kind=${stop.kind}, 连续无效回复=${ameJITBadReplies}）`);
            break;
        }
        continue;
    }
    ameJITBadReplies = 0;
    tid = stop.tid;
    pc  = littleEndianHexStringToNumber(stop.pcHex);
    x16 = littleEndianHexStringToNumber(stop.x16Hex);
    log_verbose(`stop: signo=0x${signo === null ? '??' : signo.toString(16)} tid=${tid} pc=0x${pc.toString(16)} x16=0x${x16.toString(16)}`);
    
    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    log(`instruction at pc: ${instructionResponse}`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    
    // check if this is a brk
    if (!ameJITIsBrk(instrU32)) {
        log(`Skipping: instruction was not a brk (was 0x${instrU32.toString(16)})`);
        if (signo === AME_JIT_SIGTRAP) {
            // SIGTRAP 是调试器自己的（brk 已在上一行判掉）⇒ 吞掉后继续；
            // 若同一个 pc 连续第二次报 SIGTRAP，说明这条指令自身必停（例如读不出指令字的 brk），
            // 越过它再继续，避免在同一地址无休止重停。
            if (ameJITTrapPc !== null && ameJITTrapPc === pc) {
                log(`[AIR2-JIT69] 同一 pc 连续 SIGTRAP ⇒ 跳过该指令 (pc=0x${pc.toString(16)})`);
                ameJITSkipInstruction();
            }
            ameJITTrapPc = pc;
            continue;
        }
        ameJITTrapPc = null;
        // ★[改-3]★ base 这里发的是 `vCont;S<sig>:<tid>` —— S 是【单步】(RNBRemote.cpp L4072-4083)，
        // 每停一次只前进一条指令，所以永远到不了下一个 brk。换成 `C<sig>`（带信号继续，全线程恢复）。
        const resumePacket = ameJITResumePacket(signo);
        log(`Continuing with signal 0x${signo === null ? '??' : signo.toString(16)} (packet '${resumePacket}')`);
        send_command(resumePacket);
        continue;
    }
    ameJITTrapPc = null;
    
    let brkImmediate = extractBrkImmediate(instrU32);
    log(`BRK immediate: 0x${brkImmediate.toString(16)} (${brkImmediate})`);
    if (legacyCommands[brkImmediate] != undefined) {
        // when we find a valid brk immediate command, parse x0 and x1
        x0 = stop.x0Hex;
        x1 = stop.x1Hex;
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
        // ★[改-3]★ 必须越过这条 brk：不跳过的话 pc 一直停在这条 brk 上，循环会无休止重停同一条指令。
        ameJITSkipInstruction();
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
        log(`[AIR2-JIT69] re-entrant brk #0x69 -> skipped`);
        return;
    }
    ameJITInBrk69 = true;
    try {
        ameJITBrk69Hits++;
        if (ameJITBrk69Hits <= 3) {                            // 只记前几次，避免刷屏
            log(`[AIR2-JIT69] hit #${ameJITBrk69Hits}: brk #0x69 BreakGetJITMapping(size=0x${x0.toString(16)}) @pc=0x${pc.toString(16)}`);
        }
        x1 = x0;                                               // 官方语义：size 挪到 x1
        x0 = 0;                                                // 官方语义：x0=0 ⇒ 由 host 分配
        // ★A 方案开关(2026-10-18)★ AME_JIT_FORCE_ZERO=true ⇒ 对 0x69 一律回 0，
        //   逼 libjvm 走它自己的备胎：mmap(PROT_READ|PROT_EXEC)。
        //   目的：一次性判定「本进程到底能不能 mmap 可执行内存」。
        if (AME_JIT_FORCE_ZERO) {
            log(`[AIR2-JIT69] FORCE_ZERO: 0x69 回 0（size=0x${x1.toString(16)}）⇒ 让 VM 自己 mmap RX`);
            ameJITReplyX0(0n);
        } else if (ameJITBigRegion != 0n && x1 <= ameJITBigSize) {
            // ★优先交付自研宿主区★：它已经整段 prepare 过，尺寸由我们保证
            log(`[AIR2-JIT69] 交付自研宿主区 0x${ameJITBigRegion.toString(16)} 给 size=0x${x1.toString(16)} 的请求`);
            ameJITReplyX0(ameJITBigRegion);
        } else {
            JIT26PrepareRegion(brkResponse);                   // 官方路径：分配 + prepare + 回填 x0
        }
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

    // ★一次分配，不重复★
    //   旧实现会先 `_M<size>,rx` 再 `_M<size>,rwx`（两次分配 ⇒ 双倍命令 + 双倍内存）。
    //   大区(>1MiB)直接 `_M<size>,rwx` 一条；小区才走「分配 + 逐页 prepare」官方路径。
    //   逐页 prepare 的代价：64MiB ⇒ 4096 条命令（真机 6000+ 请求的根源）。
    // ★恢复官方交付路径（2026-10-17 对照结论）★
    //   老 Air 的 UniversalJIT26 就是这条：`_M<size>,rx` + prepare_memory_region(addr,size)。
    //   它对 64MB 会发约 4096 条命令（StikDebug 里几千条请求），但★真的把请求尺寸交出来★；
    //   而我们前一轮的“单条 _M<size>,rwx 捷径”只换回 16384 字节 ⇒ JVM 拿不到要的尺寸 ⇒ 卡死。
    //   ⇒ 先求“能启动”，噪声交给 L2'（自写宿主）解决。
    // ★`_M` 的回复必须判别★（L2' 核验报告 §2）
    //   debugserver 的 HandlePacket_AllocateMemory 在 mach_vm_protect 失败时回 `E53`；
    //   老实现直接 BigInt("0x"+resp) ⇒ 把 "E53" 当成地址 0xE53=3667 写回 P0，
    //   之后 JVM 在 3667 取指 ⇒ SIGBUS 风暴。
    const ameIsHexAddress = (s) => typeof s === 'string' && /^[0-9a-fA-F]+$/.test(s) && s.length >= 6;
    let jitPageAddress = x0;
    let usedFallbackPerms = '';
    if (x0 == 0n) {
        let allocResp = send_command(`_M${x1.toString(16)},rx`);
        if (!ameIsHexAddress(allocResp)) {
            // 回退：先 `rw`（不带 X）再逐页祝福，这是最接近官方 UniversalJIT26 的路径
            log(`[AIR2-JIT69] _M(rx) 失败回复='${allocResp}' ⇒ 回退 _M(rw) + 逐页 prepare`);
            allocResp = send_command(`_M${x1.toString(16)},rw`);
            usedFallbackPerms = 'rw';
            if (!ameIsHexAddress(allocResp)) {
                log(`[AIR2-JIT69] 分配彻底失败(size=0x${x1.toString(16)}) 回复='${allocResp}'`);
                return;
            }
        }
        jitPageAddress = BigInt(`0x${allocResp}`);
        log(`[AIR2-JIT69] 分配 ok: addr=0x${jitPageAddress.toString(16)} size=0x${x1.toString(16)} perms=${usedFallbackPerms || 'rx'}（随后逐页 prepare，请求数≈size/16KB）`);
    }
    let prepareJITPageResponse = prepare_memory_region(jitPageAddress, x1);
    log(`prepareJITPageResponse = ${prepareJITPageResponse}`);


    let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
    log(`putX0Response = ${putX0Response}`);
}

// utilities
// ---------------------------------------------------------------------------
// ★[改-3]/[改-4] 停止回复与续跑（纯函数；tests/JIT/jit_script_tests.js 逐例覆盖）
// ---------------------------------------------------------------------------
// debugserver 的停止回复（arm64）形如：
//   T05thread:1e03;00:<x0>;01:<x1>;…;10:<x16>;…;20:<pc>;21:<cpsr>;
// 每个寄存器 16 个 hex 字符、目标字节序（小端）；20 = pc，10 = x16，00/01 = x0/x1。
// 进程退出时回 W<status> / X<signal>，包出错回 E<nn> —— 这两种【没有】T/thread/寄存器字段，
// base 的解析必然得到 tid=null,pc=null,x16=null（真机日志里那一行），然后原样 continue 空转。
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

// BRK #imm 的编码 = 0xD4200000 | (imm << 5)，判定 mask 0xFFE0001F
function ameJITIsBrk(u32) {
    if (typeof u32 !== 'number' || !isFinite(u32)) return false;
    return ((u32 & 0xFFE0001F) >>> 0) === 0xD4200000;
}

// ★[改-3]★ 续跑包：`C<sig>` = 带信号继续（RNBRemote.cpp L4059-L4069：case 'C' ⇒ eStateRunning，
// 且 SetDefaultThreadActionIfNeeded(eStateRunning) ⇒ 其余线程一起恢复）。
// 绝不能写成 `vCont;S<sig>:<tid>`：S ⇒ eStateStepping（L4072-L4083），只前进一条指令。
// 也绝不能写成 `C<sig>;thread:<tid>`：HandlePacket_C 会把信号之后的 ';' 当成【PC 地址】解析。
function ameJITResumePacket(signo) {
    if (typeof signo !== 'number' || !(signo >= 0 && signo <= 0xff)) return 'c';
    return `C${signo.toString(16).padStart(2, '0')}`;
}

// 越过当前指令（pc += 4），用于「这条 brk 没人认领」与「同一 pc 反复 SIGTRAP」
function ameJITSkipInstruction() {
    const pcPlus4Response = send_command(`P20=${numberToLittleEndianHexString(pc + 4n)};thread:${tid};`);
    log_verbose(`pcPlus4Response = ${pcPlus4Response}`);
}

function ameJITClip(s, n) {
    s = (s === undefined || s === null) ? '' : String(s);
    return s.length <= n ? s : `${s.slice(0, n)}…`;
}

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
    // 整个脚本被宿主以 `Script failed:` 收尾。这里改成返回 NaN（调用方按「指令未知」处理）。
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
