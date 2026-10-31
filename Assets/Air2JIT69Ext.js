// Air2 JIT69 扩展脚本（由 App 通过 brk #0xf00d x16=2 下发给 StikDebug 执行）
// ★加固（2026-10-31）★：整段包 try/catch。
//   真机证据：本文件 eval 失败时 runScriptAndCapture 抛错，legacyCommands[0x69] 没装上
//   ⇒ JIT 区拿不到（[A2JIT] region=0x0 size=0）⇒ 后续全部白测。
//   加固后：单个处理器装不上只打一行错误，不再影响其它命令注册。
(function () {
    try {
        if (typeof legacyCommands === 'undefined' || typeof commands === 'undefined') {
            log('[A2EXT] 跳过：legacyCommands/commands 未定义（说明 base 脚本不是我们的版本）');
            return;
        }

        logLevel = LOG_INFO;
        let detachAfterFirstBr = false;

        // brk 0x69: to work without introducing breaking change
        legacyCommands[0x69] = function (brkResponse) {
            x1 = x0;
            x0 = 0;
            JIT26PrepareRegion(brkResponse);
            if (detachAfterFirstBr) {
                JIT26Detach();
            }
        };

        // JIT26SetDetachAfterFirstBr(BOOL)
        commands[3] = function (brkResponse) {
            detachAfterFirstBr = x0 != 0;
            log(`JIT26SetDetachAfterFirstBr(${detachAfterFirstBr}) called`);
        };

        // JIT26PrepareRegionForPatching(void *addr, size_t len)
        commands[4] = function (brkResponse) {
            let x0str = x0.toString(16);
            let x1str = x1.toString(16);
            let bytes = send_command(`m${x0str},${x1str}`);
            send_command(`M${x0str},${x1str}:${bytes}`);
        };

        log('[A2EXT] 扩展已装载：legacyCommands[0x69] + commands[3][4]');
    } catch (e) {
        log('[A2EXT] 装载失败：' + (e && e.name ? e.name : 'Error') + ': ' + (e && e.message ? e.message : e));
        log(e && e.stack ? e.stack : '');
    }
})();
