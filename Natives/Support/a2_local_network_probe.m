//
//  a2_local_network_probe.m
//  Air2 —— [PAIRWIRE-NETPROBE] 实现（见头文件说明）
//

#import "a2_local_network_probe.h"

#import <Network/Network.h>

static NSString *const kA2LNProbeServiceType = @"_a2lnprobe._tcp";
static NSString *const kA2LNProbeServiceName = @"Air2LocalNetProbe";

BOOL A2LocalNetworkProbeRun(NSTimeInterval timeout, NSString *_Nullable *_Nullable reason) {
    if (timeout <= 0) { timeout = 5.0; }

    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                             NW_PARAMETERS_DEFAULT_CONFIGURATION);
    if (params == NULL) {
        if (reason) { *reason = @"无法创建探针参数"; }
        return NO;
    }
    nw_parameters_set_include_peer_to_peer(params, true);

    nw_listener_t listener = nw_listener_create(params);
    if (listener == NULL) {
        if (reason) { *reason = @"无法创建探针 listener"; }
        return NO;
    }
    nw_advertise_descriptor_t ad = nw_advertise_descriptor_create_bonjour_service(
        kA2LNProbeServiceName.UTF8String, kA2LNProbeServiceType.UTF8String, NULL);
    if (ad != NULL) {
        nw_listener_set_advertise_descriptor(listener, ad);
    }

    nw_browser_t browser = nw_browser_create(
        nw_browse_descriptor_create_bonjour_service(kA2LNProbeServiceType.UTF8String, NULL), params);
    if (browser == NULL) {
        nw_listener_cancel(listener);
        if (reason) { *reason = @"无法创建探针 browser"; }
        return NO;
    }

    dispatch_queue_t q = dispatch_queue_create("a2.localnetprobe", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL authorized = NO;
    __block BOOL listenerFailed = NO;
    __block NSString *failDetail = nil;

    nw_listener_set_queue(listener, q);
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t e) {
        if (state == nw_listener_state_failed) {
            listenerFailed = YES;
            int code = e ? (int)nw_error_get_error_code(e) : 0;
            int dom = e ? (int)nw_error_get_error_domain(e) : 0;
            failDetail = [NSString stringWithFormat:@"listener 失败（domain=%d, err=%d）", dom, code];
            dispatch_semaphore_signal(sem);
        }
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t c) {
        nw_connection_cancel(c);
    });

    nw_browser_set_queue(browser, q);
    nw_browser_set_state_changed_handler(browser, ^(nw_browser_state_t state, nw_error_t e) {
        if (state == nw_browser_state_failed) {
            listenerFailed = YES;
            int code = e ? (int)nw_error_get_error_code(e) : 0;
            failDetail = [NSString stringWithFormat:@"browser 失败（err=%d）", code];
            dispatch_semaphore_signal(sem);
        }
    });
    nw_browser_set_browse_results_changed_handler(browser,
                                                 ^(nw_browse_result_t oldR, nw_browse_result_t newR, bool complete) {
        (void)oldR; (void)newR; (void)complete;
        // 浏览到【任何】结果即视为「本地网络可用」—— 目标只是判权限，不是判具体服务。
        authorized = YES;
        dispatch_semaphore_signal(sem);
    });

    nw_listener_start(listener);
    nw_browser_start(browser);

    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    dispatch_semaphore_wait(sem, dl);

    nw_browser_cancel(browser);
    nw_listener_cancel(listener);

    if (authorized) {
        return YES;
    }
    if (reason) {
        *reason = failDetail.length > 0 ? failDetail
                                        : @"超时内没浏览到探针服务（多半是本地网络权限未授予）";
    }
    return NO;
}

NSString *A2LocalNetworkProbeCriterionLine(NSString *verdict, NSString *_Nullable reason) {
    return [NSString stringWithFormat:@"[A2-PAIRPIN] netprobe=%@ reason=%@",
            verdict ?: @"unknown", reason.length > 0 ? reason : @"-"];
}
