/// 业务方注入的 URL 刷新回调：给定 taskId，返回该任务的新直链。
typedef RefreshUrlCallback = Future<String> Function(String taskId);

/// 未注入刷新回调时调用 [UrlRefresher.refresh] 抛出。
class NoRefreshCallbackException implements Exception {
  @override
  String toString() =>
      'UrlRefresher: no refresh callback registered (call setRefreshUrl first)';
}

/// 刷新在次数上限内仍失败时抛出。
class UrlRefreshFailedException implements Exception {
  final String taskId;
  final int attempts;
  final Object? lastError;

  UrlRefreshFailedException(this.taskId, this.attempts, this.lastError);

  @override
  String toString() =>
      'UrlRefreshFailedException: refresh failed for "$taskId" after '
      '$attempts attempt(s), last error: $lastError';
}

/// 包裹业务刷新回调，强制「同一 taskId 单飞去重 + 退避重试 + 次数上限」。
///
/// 稳定性核心：CDN 直链每 ~30min 过期成 404，多个并发请求会同时命中过期；
/// 单飞保证一次 404 风暴只触发一次业务回调，防止刷新风暴。
class UrlRefresher {
  RefreshUrlCallback? _callback;
  final int maxRetries;
  final Duration backoff;

  /// 每个 taskId 正在进行中的刷新 Future，完成（成功或失败）后立即清除。
  final Map<String, Future<String>> _inFlight = <String, Future<String>>{};

  UrlRefresher({
    RefreshUrlCallback? callback,
    this.maxRetries = 3,
    this.backoff = const Duration(milliseconds: 500),
  }) : _callback = callback;

  /// 由 DownloadManager 在 setRefreshUrl 时注入/替换。
  set callback(RefreshUrlCallback? cb) => _callback = cb;

  bool get hasCallback => _callback != null;

  /// 刷新指定任务的 URL。
  ///
  /// - 单飞：若该 taskId 已有刷新在途，返回同一个 Future，不再触发回调。
  /// - 重试：回调抛错或返回空白串时退避重试，总尝试次数 = [maxRetries] + 1。
  /// - 全部失败抛 [UrlRefreshFailedException]；未注入回调抛 [NoRefreshCallbackException]。
  Future<String> refresh(String taskId) {
    final existing = _inFlight[taskId];
    if (existing != null) return existing;

    final cb = _callback;
    if (cb == null) {
      return Future<String>.error(NoRefreshCallbackException());
    }

    final future = _run(taskId, cb);
    _inFlight[taskId] = future;
    // 完成后清除在途条目；whenComplete 派生的 future 用 ignore 避免未处理错误。
    future.whenComplete(() {
      // 仅当仍是本次 Future 时才移除，避免误删后续替换进来的条目。
      if (identical(_inFlight[taskId], future)) {
        _inFlight.remove(taskId);
      }
    }).ignore();
    return future;
  }

  Future<String> _run(String taskId, RefreshUrlCallback cb) async {
    final totalAttempts = maxRetries + 1;
    Object? lastError;
    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(backoff);
      try {
        final url = (await cb(taskId)).trim();
        if (url.isEmpty) {
          lastError = StateError('refresh callback returned empty url');
          continue;
        }
        return url;
      } catch (e) {
        lastError = e;
      }
    }
    throw UrlRefreshFailedException(taskId, totalAttempts, lastError);
  }
}
