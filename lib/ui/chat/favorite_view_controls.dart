import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

const favoriteFilterLabels = {
  'all': '全部类型',
  'text': '文字',
  'image': '图片',
  'video': '视频',
  'file': '文件',
};
const favoriteSortLabels = {
  'newest': '时间：从新到旧',
  'oldest': '时间：从旧到新',
  'type': '按类型',
  'titleAsc': '首字：升序',
  'titleDesc': '首字：降序',
};

class FavoriteViewControls extends StatelessWidget {
  const FavoriteViewControls({
    super.key,
    required this.preferences,
    required this.onChanged,
    required this.onLayout,
    this.enabled = true,
    this.showMenus = true,
  });

  final FavoritePreferences preferences;
  final ValueChanged<FavoritePreferences> onChanged;
  final ValueChanged<String> onLayout;
  final bool enabled;
  final bool showMenus;

  @override
  Widget build(BuildContext context) {
    final filtered = preferences.filter != 'all' || preferences.onlyPinned;
    return Wrap(
      spacing: 2,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showMenus)
          PopupMenuButton<String>(
            key: const ValueKey('favorites-filter-menu'),
            tooltip: tr(context, '收藏筛选'),
            enabled: enabled,
            icon: Badge(
              isLabelVisible: filtered,
              child: const Icon(Icons.filter_alt_outlined, size: 21),
            ),
            onSelected: (value) => onChanged(
              value == 'pinned'
                  ? preferences.copyWith(onlyPinned: !preferences.onlyPinned)
                  : preferences.copyWith(filter: value),
            ),
            itemBuilder: (context) => [
              for (final item in favoriteFilterLabels.entries)
                CheckedPopupMenuItem(
                  key: ValueKey('favorites-filter-${item.key}'),
                  value: item.key,
                  checked: preferences.filter == item.key,
                  child: Text(tr(context, item.value)),
                ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                key: const ValueKey('favorites-filter-pinned'),
                value: 'pinned',
                checked: preferences.onlyPinned,
                child: Text(tr(context, '仅置顶')),
              ),
            ],
          ),
        if (showMenus)
          PopupMenuButton<String>(
            key: const ValueKey('favorites-sort-menu'),
            tooltip:
                '${tr(context, '收藏排序')} · ${tr(context, favoriteSortLabels[preferences.sort]!)}',
            enabled: enabled,
            icon: const Icon(Icons.sort_rounded, size: 21),
            onSelected: (value) => onChanged(preferences.copyWith(sort: value)),
            itemBuilder: (context) => [
              for (final item in favoriteSortLabels.entries)
                CheckedPopupMenuItem(
                  key: ValueKey('favorites-sort-${item.key}'),
                  value: item.key,
                  checked: preferences.sort == item.key,
                  child: Text(tr(context, item.value)),
                ),
            ],
          ),
        const SizedBox(width: 4),
        SegmentedButton<String>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          segments: [
            ButtonSegment(
              value: 'masonry',
              tooltip: tr(context, '瀑布流视图'),
              icon: const Icon(
                Icons.dashboard_outlined,
                key: ValueKey('favorites-view-masonry'),
                size: 19,
              ),
              enabled: enabled,
            ),
            ButtonSegment(
              value: 'list',
              tooltip: tr(context, '列表视图'),
              icon: const Icon(
                Icons.view_list_outlined,
                key: ValueKey('favorites-view-list'),
                size: 21,
              ),
              enabled: enabled,
            ),
          ],
          selected: {preferences.layout},
          onSelectionChanged: enabled
              ? (value) => onLayout(value.single)
              : null,
        ),
        if (showMenus && filtered)
          TextButton.icon(
            key: const ValueKey('favorites-clear-filters'),
            onPressed: enabled
                ? () => onChanged(
                    preferences.copyWith(filter: 'all', onlyPinned: false),
                  )
                : null,
            icon: const Icon(Icons.close_rounded, size: 15),
            label: Text(
              [
                if (preferences.filter != 'all')
                  tr(context, favoriteFilterLabels[preferences.filter]!),
                if (preferences.onlyPinned) tr(context, '仅置顶'),
              ].join(' · '),
            ),
          ),
      ],
    );
  }
}
