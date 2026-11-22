import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/ting_theme.dart';
import '../services/app_log.dart';
import '../services/log_reporter.dart';
import '../widgets/common.dart';

/// 错误色。主题里没有红色（适老化界面刻意少用），只在日志页用来标错。
const _errColor = Color(0xFFB3261E);

/// 设备日志页（测试版可见）。
///
/// 两个视角：
/// - **本机**：老人刚才点了什么、有没有报错，实时看
/// - **服务器**：多台设备回传上来的，按设备分开看，能导出成文本喂给 AI 分析
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

enum _Tab { local, remote }

class _LogPageState extends State<LogPage> {
  _Tab _tab = _Tab.local;
  bool _onlyError = false;

  List<LogEntry> _local = const [];
  bool _loadingLocal = true;

  // 服务器视角
  bool _loadingRemote = false;
  String? _remoteError;
  List<RemoteDevice> _devices = const [];
  RemoteDevice? _selected;
  List<LogEntry> _remoteEntries = const [];
  bool _loadingTail = false;

  String? _banner;

  @override
  void initState() {
    super.initState();
    AppLog.instance.addListener(_onLogChanged);
    _loadLocal();
  }

  @override
  void dispose() {
    AppLog.instance.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onLogChanged() {
    if (!mounted) return;
    // 只更新内存里的，不重读文件（正在播放时每秒都有写入）
    setState(() => _local = AppLog.instance.mem.reversed.toList());
  }

  Future<void> _loadLocal() async {
    final list = await AppLog.instance.readDays(1);
    if (!mounted) return;
    setState(() {
      _local = list; // readDays 已经新的在前
      _loadingLocal = false;
    });
  }

  Future<void> _refresh() async {
    if (_tab == _Tab.local) {
      await _loadLocal();
    } else if (_selected != null) {
      await _loadTail(_selected!);
    } else {
      await _loadDevices();
    }
  }

  Future<void> _loadDevices() async {
    setState(() {
      _loadingRemote = true;
      _remoteError = null;
    });
    try {
      final list = await LogReporter.instance.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = list;
        _loadingRemote = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRemote = false;
        _remoteError = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _loadTail(RemoteDevice d) async {
    setState(() {
      _selected = d;
      _loadingTail = true;
      _remoteError = null;
    });
    try {
      final list = await LogReporter.instance.fetchTail(d.deviceId, limit: 300);
      if (!mounted) return;
      setState(() {
        _remoteEntries = list;
        _loadingTail = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingTail = false;
        _remoteError = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _reportNow() async {
    setState(() => _banner = '正在上报…');
    final ok = await LogReporter.instance.reportNow();
    if (!mounted) return;
    setState(() {
      _banner = ok
          ? '已上报（本次 ${LogReporter.instance.lastCount} 条）'
          : '上报失败：${LogReporter.instance.lastError ?? '网络不通'}';
    });
    await _loadLocal();
  }

  Future<void> _copyAll() async {
    final text = _tab == _Tab.local
        ? await AppLog.instance.exportText(days: 3)
        : await _remoteAsText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showTip(context, '已复制，可以发给家人或贴给 AI');
  }

  Future<String> _remoteAsText() async {
    final b = StringBuffer()
      ..writeln('# 听评书 设备日志（服务器）');
    for (final e in _remoteEntries.reversed) {
      b.writeln(e.describe());
    }
    return b.toString();
  }

  Future<void> _renameDevice() async {
    final ctl = TextEditingController(text: AppLog.instance.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('给这台手机起个名字', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: const TextStyle(fontSize: 20),
          decoration: const InputDecoration(hintText: '例如：爷爷的手机'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('保存', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await AppLog.instance.setDeviceName(name);
    if (!mounted) return;
    setState(() {});
    await _reportNow();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TingBar(
              title: '设备日志',
              actions: [
                IconButton(
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh_rounded, size: 28, color: TingColors.ink),
                  onPressed: _refresh,
                ),
              ],
            ),
            _tabBar(),
            if (_banner != null) _bannerBar(),
            Expanded(child: _tab == _Tab.local ? _localView() : _remoteView()),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _tabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 10),
      child: Row(
        children: [
          Expanded(
            child: _tabButton(
              '本机',
              _tab == _Tab.local,
              () => setState(() => _tab = _Tab.local),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _tabButton(
              '服务器',
              _tab == _Tab.remote,
              () {
                setState(() => _tab = _Tab.remote);
                if (_devices.isEmpty) _loadDevices();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? TingColors.primary : TingColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? TingColors.primary : TingColors.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: active ? Colors.white : TingColors.ink,
          ),
        ),
      ),
    );
  }

  Widget _bannerBar() {
    final isErr = _banner!.contains('失败');
    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isErr ? TingColors.warnSoft : TingColors.primarySoft,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _banner!,
          style: TextStyle(fontSize: 16, color: isErr ? TingColors.warn : TingColors.primary),
        ),
      ),
    );
  }

  // ---------------- 本机 ----------------

  Widget _localView() {
    if (_loadingLocal) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    final list = _onlyError
        ? _local.where((e) => e.level == LogLevel.error).toList()
        : _local;
    final errCount = _local.where((e) => e.level == LogLevel.error).length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '今天 ${_local.length} 条 · 错误 $errCount 条',
                  style: const TextStyle(fontSize: 16, color: TingColors.muted),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _onlyError = !_onlyError),
                child: Text(
                  _onlyError ? '看全部' : '只看错误',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text(
                    '还没有日志',
                    style: TextStyle(fontSize: 19, color: TingColors.muted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 16),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _entryTile(list[i]),
                ),
        ),
      ],
    );
  }

  Widget _entryTile(LogEntry e) {
    final color = switch (e.level) {
      LogLevel.error => _errColor,
      LogLevel.warn => TingColors.warn,
      LogLevel.info => TingColors.muted,
    };
    final hh = e.at.hour.toString().padLeft(2, '0');
    final mm = e.at.minute.toString().padLeft(2, '0');
    final ss = e.at.second.toString().padLeft(2, '0');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: TingColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: color, width: 4),
          top: const BorderSide(color: TingColors.line),
          right: const BorderSide(color: TingColors.line),
          bottom: const BorderSide(color: TingColors.line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$hh:$mm:$ss',
                style: const TextStyle(fontSize: 15, color: TingColors.muted),
              ),
              const SizedBox(width: 10),
              Text(
                e.level.label,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color),
              ),
              const Spacer(),
              Text(
                e.kind,
                style: const TextStyle(fontSize: 13, color: TingColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            e.message,
            style: const TextStyle(fontSize: 17, height: 1.4, color: TingColors.ink),
          ),
          if (e.data != null && e.data!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              e.data!.entries.map((x) => '${x.key}=${x.value}').join('  '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, height: 1.4, color: TingColors.muted),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------- 服务器 ----------------

  Widget _remoteView() {
    if (_loadingRemote) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    if (_remoteError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 56, color: TingColors.muted),
              const SizedBox(height: 14),
              Text(
                _remoteError!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, height: 1.5, color: TingColors.ink),
              ),
              const SizedBox(height: 18),
              OutlinedButton(onPressed: _loadDevices, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    // 已经选了某台设备：看它的日志
    if (_selected != null) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() {
                    _selected = null;
                    _remoteEntries = const [];
                  }),
                  icon: const Icon(Icons.arrow_back_rounded, size: 22),
                  label: const Text('设备列表', style: TextStyle(fontSize: 17)),
                ),
                const Spacer(),
                Text(
                  '${_remoteEntries.length} 条',
                  style: const TextStyle(fontSize: 16, color: TingColors.muted),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loadingTail
                ? const Center(child: CircularProgressIndicator(strokeWidth: 3))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 16),
                    itemCount: _remoteEntries.length,
                    itemBuilder: (_, i) => _entryTile(_remoteEntries[i]),
                  ),
          ),
        ],
      );
    }

    if (_devices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '服务器上还没有设备回传过。\n手机联网后重新打开 App 就会自动上报。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, height: 1.6, color: TingColors.muted),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 16),
      itemCount: _devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final d = _devices[i];
        final mine = d.deviceId == AppLog.instance.deviceId;
        return InkWell(
          borderRadius: BorderRadius.circular(T.radius),
          onTap: () => _loadTail(d),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: TingColors.surface,
              borderRadius: BorderRadius.circular(T.radius),
              border: Border.all(
                color: mine ? TingColors.primary : TingColors.line,
                width: mine ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  mine ? Icons.phone_iphone_rounded : Icons.devices_other_rounded,
                  size: 32,
                  color: mine ? TingColors.primary : TingColors.muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.deviceName.isNotEmpty ? d.deviceName : d.model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: TingColors.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${d.versionName} · ${d.count} 条 · ${_ago(d.lastAt)}',
                        style: const TextStyle(fontSize: 15, color: TingColors.muted),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 28, color: TingColors.muted),
              ],
            ),
          ),
        );
      },
    );
  }

  String _ago(DateTime? t) {
    if (t == null) return '无时间';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  // ---------------- 底部 ----------------

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 14),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyAll,
                  icon: const Icon(Icons.copy_rounded, size: 24),
                  label: const Text('复制全部'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(60)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _reportNow,
                  icon: const Icon(Icons.cloud_upload_rounded, size: 24),
                  label: const Text('上报'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(60)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _renameDevice,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '这台叫「${AppLog.instance.deviceName}」· 设备号 ${AppLog.instance.deviceId} · 点这里改名',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: TingColors.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
