import 'package:flutter/material.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/ui/shared/app_strings.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/profile_avatar.dart';
import 'mobile_home.dart';

class DesktopNavigation extends StatelessWidget {
  const DesktopNavigation({
    super.key,
    required this.inbox,
    required this.section,
    required this.onSection,
    required this.onProfile,
    required this.onSettings,
  });
  final InboxController inbox;
  final MobileSection section;
  final ValueChanged<MobileSection> onSection;
  final VoidCallback onProfile, onSettings;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final style = IconButton.styleFrom(
      fixedSize: const Size.square(44),
      minimumSize: const Size.square(44),
      maximumSize: const Size.square(44),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: AppCorners.border),
    );
    return Material(
      key: const ValueKey('desktop-navigation-rail'),
      color: palette.rail,
      child: SizedBox(
        width: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              IconButton(
                tooltip: tr(context, '修改头像与名称'),
                style: style,
                onPressed: onProfile,
                icon: ProfileAvatar(inbox: inbox, local: true, size: 36),
              ),
              const SizedBox(height: 24),
              for (final destination in const [
                MobileSection.conversations,
                MobileSection.favorites,
                MobileSection.trash,
              ]) ...[
                ValueListenableBuilder<int>(
                  valueListenable: inbox.activity,
                  builder: (context, _, _) {
                    final count = destination == MobileSection.transfers
                        ? inbox.transferTasks
                              .where((task) => task.state != 'cancelled')
                              .length
                        : 0;
                    return Semantics(
                      selected: section == destination,
                      child: IconButton(
                        key: ValueKey('desktop-nav-${destination.name}'),
                        tooltip: tr(context, destination.title),
                        style: style.copyWith(
                          foregroundColor: WidgetStatePropertyAll(
                            section == destination ? brandGreen : palette.muted,
                          ),
                          backgroundColor: WidgetStatePropertyAll(
                            section == destination
                                ? palette.selected
                                : Colors.transparent,
                          ),
                        ),
                        onPressed: () => onSection(destination),
                        icon: Badge(
                          isLabelVisible: count > 0,
                          label: Text(count > 99 ? '99+' : '$count'),
                          backgroundColor: palette.selected,
                          textColor: palette.text,
                          child: Icon(destination.icon, size: 24),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
              ],
              const Spacer(),
              IconButton(
                tooltip: tr(context, '设置'),
                style: style,
                onPressed: onSettings,
                icon: Icon(
                  Icons.settings_outlined,
                  size: 24,
                  color: palette.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
