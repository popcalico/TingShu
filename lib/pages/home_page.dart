import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/ting_theme.dart';
import '../models/ting.dart';
import '../player/ting_player.dart';
import '../services/backup_service.dart';
import '../services/library.dart';
import '../services/notify_permission.dart';
import '../services/update_service.dart';
import '../widgets/common.dart';
import '../widgets/recommend_flow.dart';
import '../widgets/update_prompt.dart';
import 'add_page.dart';
import 'book_page.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'shelf_page.dart';

/// 首页：一个「继续收听」大卡片 + 书架，没有底部栏。
///
/// 设计原则——老人打开就该能听，不需要搜索、不需要选分类、不需要理解"播放列表"。
///
/// 为什么去掉底部栏：底边是握持时手指最容易蹭到的地方，两个常驻按钮
/// 等于给老人埋了两个误触陷阱（尤其"全部书架"和下面已经显示的书架重复）。
/// 设置这类低频入口全部收进右上角菜单，既不占地也不容易被碰到。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    // 首帧之后再查更新，避免和启动动画抢
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkNotify();
      _autoCheckUpdate();
      _maybeOfferRestore();
    });
  }

  /// 书架是空的、但公共目录里有备份 → 问一句要不要恢复。
  ///
  /// 这是给"更新完发现书架空了"准备的兜底：数据读坏了/被覆盖了，
  /// 至少还能从备份里把书和进度捞回来，而不用家属重新一本本加。
  static bool _offeredRestore = false;

  Future<void> _maybeOfferRestore() async {
    if (_offeredRestore) return;
    if (Library.instance.shelf.isNotEmpty) return;
    if (Library.instance.restoreDeclined) return;
    final b = await BackupService.instance.peek();
    if (b == null || b.books == 0) return;
    _offeredRestore = true;
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '书架是空的，要恢复吗？',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '找到一份备份，里面有 ${b.books} 部书，还有听到哪儿了。\n\n'
          '要恢复到书架上吗？',
          style: const TextStyle(fontSize: 18, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () {
              // 记下来，以后别再问
              Library.instance.declineRestore();
              Navigator.pop(ctx, false);
            },
            child: const Text('不用了'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '恢复',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final ok = await BackupService.instance.restoreNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已恢复 ${b.books} 部书' : '恢复失败，备份可能损坏')),
    );
    if (ok) setState(() {});
  }

  /// 通知权限没开时首页顶部会挂一条提示——否则锁屏后没有任何播放控件，
  /// 老人会以为软件坏了。
  bool _notifyOk = true;

  Future<void> _checkNotify() async {
    final ok = await NotifyPermission.has();
    if (!mounted) return;
    setState(() => _notifyOk = ok);
  }

  Future<void> _askNotify() async {
    await NotifyPermission.request();
    await _checkNotify();
    // 拒过一次之后系统不再弹框，只能带去设置页手动开
    if (!_notifyOk) await NotifyPermission.openSettings();
    await _checkNotify();
  }

  /// 只在没授权时出现，开了就永久消失，不占老人视线。
  Widget _notifyBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 10),
      child: Material(
        color: TingColors.warn.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _askNotify,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.notifications_off_rounded, size: 28, color: TingColors.warn),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '通知没打开，锁屏后不能暂停',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.35),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '去打开',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: TingColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 启动时静默查一次更新。没联网、没配地址、服务器挂了都直接跳过，绝不打扰。
  Future<void> _autoCheckUpdate() async {
    final svc = UpdateService.instance;
    final info = await svc.autoCheckOnStart();
    if (info == null || !mounted) return;

    // 一步到位的更新弹窗：点「立即更新」后全程自动，不再跳页面、不再点第二次
    await UpdatePrompt.show(context, info);
  }

  @override
  Widget build(BuildContext context) {
    final lib = Library.instance;
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([lib, TingPlayer.instance]),
          builder: (context, _) {
            final current = lib.current;
            final shelf = lib.shelf;
            return Column(
              children: [
                _Header(),
                if (!_notifyOk) _notifyBanner(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 12),
                    children: [
                      _ContinueCard(item: current),
                      const SizedBox(height: 26),
                      if (shelf.isNotEmpty) ...[
                        Row(
                          children: [
                            const Text(
                              '我的书架',
                              style: TextStyle(
                                fontSize: T.fontTitle,
                                fontWeight: FontWeight.w700,
                                color: TingColors.ink,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '共 ${shelf.length} 部',
                              style: const TextStyle(fontSize: T.fontSmall, color: TingColors.muted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _ShelfGrid(items: shelf.take(6).toList()),
                      ],
                    ],
                  ),
                ),
                const _MiniBar(),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 12, T.pagePad - 6, 6),
      child: Row(
        children: [
          const Text(
            '听评书',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: TingColors.ink,
              letterSpacing: 2,
            ),
          ),
          const Spacer(),
          // 搜索放在三横线左边：一只手够得到，又不至于被当成主按钮
          IconButton(
            tooltip: '搜索',
            iconSize: 30,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.search_rounded, color: TingColors.muted),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
          _HomeMenu(),
        ],
      ),
    );
  }
}

/// 右上角的三横线菜单：设置、添加评书、全部书架都在这里。
///
/// 刻意做小、放在角落：这是家属用的低频入口，老人平时不会点。
/// 反过来把它做成大按钮放在底边，反而会成为误触重灾区。
class _HomeMenu extends StatelessWidget {
  const _HomeMenu();

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '菜单',
      iconSize: 28,
      padding: EdgeInsets.zero,
      splashRadius: 24,
      icon: const Icon(Icons.menu_rounded, color: TingColors.muted),
      offset: const Offset(0, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      itemBuilder: (ctx) => [
        _item(1, Icons.add_circle_outline_rounded, '添加评书'),
        _item(2, Icons.menu_book_rounded, '全部书架'),
        _item(3, Icons.settings_outlined, '设置'),
      ],
      onSelected: (v) {
        switch (v) {
          case 1:
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddPage()));
          case 2:
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShelfPage()));
          case 3:
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
        }
      },
    );
  }

  PopupMenuItem<int> _item(int value, IconData icon, String label) {
    return PopupMenuItem<int>(
      value: value,
      height: 60,
      child: Row(
        children: [
          Icon(icon, size: 24, color: TingColors.primary),
          const SizedBox(width: 14),
          Text(
            label,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 继续收听：全页最大的目标，闭着眼也能点中。
class _ContinueCard extends StatelessWidget {
  final ShelfItem? item;

  const _ContinueCard({this.item});

  @override
  Widget build(BuildContext context) {
    final it = item;
    final player = TingPlayer.instance;

    // 一本听完：不要再给"继续收听"（点进去只会重听最后一回），
    // 直接问他要不要换一本——这是老人最需要的一步。
    if (player.state == TingState.finished && player.book != null) {
      return _PickCard(finished: player.book);
    }

    if (it == null) return const _PickCard();

    final chapter = it.chapter;

    // 这本书如果正在播放器里，就以播放器的实时位置为准。
    // 否则会出现"明明还在放，卡片却写着从头开始听"的错觉。
    final live = player.book?.id == it.book.id &&
        player.book?.source == it.book.source &&
        player.state != TingState.idle;
    final resumeMs = live ? player.position.inMilliseconds : it.positionMs;

    final progressText = live
        ? (player.isPlaying ? '正在播放 ${fmtDuration(player.position)}' : '已暂停 ${fmtDuration(player.position)}')
        : (resumeMs > 0 ? '上次听到 ${fmtDuration(Duration(milliseconds: resumeMs))}' : '从头开始听');

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: TingColors.primarySoft,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TingColors.primary.withValues(alpha: 0.25), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.play_circle_fill_rounded, size: 24, color: TingColors.primary),
              const SizedBox(width: 6),
              Text(
                (live || resumeMs > 0) ? '正在听' : '上次听的书',
                style: const TextStyle(fontSize: T.fontSmall, color: TingColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            it.book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 30,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: Color(0xFF04243F),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            chapter == null ? it.book.subtitle : chapter.numbered,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: T.fontBody, color: TingColors.primary),
          ),
          const SizedBox(height: 4),
          Text(
            progressText,
            style: const TextStyle(fontSize: T.fontSmall, color: TingColors.muted),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                final player = TingPlayer.instance;
                // 故意不 await：这一回第一次听要先下载，几十秒里 await 会让按钮
                // "点了没反应"，用户就会连点，下载完一起恢复 → 堆出一串播放页。
                // 直接进播放页，由播放页自己显示"正在准备这一回 45%"。
                unawaited(player.open(it.book, it.chapterIndex, positionMs: resumeMs));
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PlayerPage()),
                );
              },
              child: const Text('继续收听', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 主卡片在没有书 / 一本听完时显示：一句说明 + 「推荐一本」+「手动挑选」。
///
/// 用户的原话：首次进入时是"让家人帮我选书"，一本书放完了也该给同样的选择。
/// 所以两种场景共用同一张卡片，只是标题和说明不同。
class _PickCard extends StatelessWidget {
  /// 刚听完的那本；null 表示还没开始听
  final TingBook? finished;

  const _PickCard({this.finished});

  @override
  Widget build(BuildContext context) {
    final done = finished;
    final isDone = done != null;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: isDone ? TingColors.doneSoft : TingColors.warnSoft,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isDone ? '这本听完了' : '想听点什么？',
            style: TextStyle(
              fontSize: T.fontTitle,
              fontWeight: FontWeight.w700,
              color: isDone ? TingColors.done : TingColors.warn,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isDone
                ? '《${done.title}》已经听完了。换一本接着听？'
                : '点下面的「推荐一本」，我帮你找一部没听过的，从头开始放。',
            style: const TextStyle(fontSize: T.fontBody, color: TingColors.ink, height: 1.55),
          ),
          const SizedBox(height: 18),
          const PickBookButtons(),
        ],
      ),
    );
  }
}

class _ShelfGrid extends StatelessWidget {
  final List<ShelfItem> items;

  const _ShelfGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // 最后多一格放"推荐一本"：书架翻到底就有下一步，不用再回顶部找
      itemCount: items.length + 1,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        mainAxisExtent: 108,
      ),
      itemBuilder: (context, i) {
        if (i == items.length) return const _RecommendTile();
        final it = items[i];
        return InkWell(
          borderRadius: BorderRadius.circular(T.radius),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => BookPage(book: it.book)),
          ),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TingColors.surface,
              borderRadius: BorderRadius.circular(T.radius),
              border: Border.all(color: TingColors.line),
            ),
            child: Row(
              children: [
                CoverBox(book: it.book, size: 62),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        it.book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 19,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: TingColors.ink,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        it.book.count > 0 ? '${it.book.count} 回' : it.book.author,
                        style: const TextStyle(fontSize: T.fontSmall, color: TingColors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 书架末尾的"推荐一本"格子。
///
/// 用户要求把推荐放在书架最后一个位置：老人看完自己的书，手指自然滑到底，
/// 就在那儿给他一个"再来一本"，不用退回去找按钮。
class _RecommendTile extends StatelessWidget {
  const _RecommendTile();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(T.radius),
      onTap: () => startRecommend(context),
      child: Container(
        decoration: BoxDecoration(
          color: TingColors.primarySoft,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: TingColors.primary.withValues(alpha: 0.4), width: 1.5),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome_rounded, size: 30, color: TingColors.primary),
            SizedBox(height: 6),
            Text(
              '推荐一本',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: TingColors.primary,
              ),
            ),
            Text(
              '没听过的',
              style: TextStyle(fontSize: 14, color: TingColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 正在播放时贴一条，点一下回到播放页——老人从别的页面回来常找不到"刚才那个"
class _MiniBar extends StatelessWidget {
  const _MiniBar();

  @override
  Widget build(BuildContext context) {
    final p = TingPlayer.instance;
    final b = p.book;
    if (b == null || p.state == TingState.idle) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(T.pagePad, 0, T.pagePad, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(T.radius),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PlayerPage()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: TingColors.surface,
            borderRadius: BorderRadius.circular(T.radius),
            border: Border.all(color: TingColors.primary.withValues(alpha: 0.35), width: 1.5),
          ),
          child: Row(
            children: [
              Icon(
                p.isPlaying ? Icons.graphic_eq_rounded : Icons.pause_circle_outline_rounded,
                color: TingColors.primary,
                size: 30,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: TingColors.ink,
                      ),
                    ),
                    Text(
                      p.chapter?.numbered ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, color: TingColors.muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                iconSize: 40,
                onPressed: () => p.toggle(),
                icon: Icon(
                  p.isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                  color: TingColors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


