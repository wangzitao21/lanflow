import 'package:flutter/material.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/motion.dart';
import 'package:lanflow/ui/shared/profile_avatar.dart';
import 'package:lanflow/ui/shared/app_strings.dart';

enum MobileSection {
  conversations('会话', Icons.chat_bubble_outline_rounded),
  devices('我的设备', Icons.devices_outlined),
  transfers('传输任务', Icons.sync_alt_rounded),
  favorites('收藏', Icons.star_border_rounded),
  trash('回收站', Icons.delete_outline_rounded);

  const MobileSection(this.title, this.icon);
  final String title;
  final IconData icon;
}

const homeSections = [
  MobileSection.conversations,
  MobileSection.favorites,
  MobileSection.trash,
];

class MobileHome extends StatelessWidget {
  const MobileHome({
    super.key,
    required this.inbox,
    required this.section,
    required this.onSection,
    required this.onProfile,
    required this.onSettings,
    required this.notice,
    required this.child,
    this.keyboardVisible = false,
  });

  final InboxController inbox;
  final MobileSection section;
  final ValueChanged<MobileSection> onSection;
  final VoidCallback onProfile, onSettings;
  final Widget notice, child;
  final bool keyboardVisible;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: tr(context, '修改头像与名称'),
                onPressed: onProfile,
                icon: ProfileAvatar(inbox: inbox, local: true, size: 32),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr(context, section.title),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: tr(context, '设置'),
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        const Divider(),
        notice,
        Expanded(
          child: PageReveal(identity: section, child: child),
        ),
        if (!keyboardVisible) ...[
          const Divider(),
          ValueListenableBuilder<int>(
            valueListenable: inbox.activity,
            builder: (context, _, _) {
              final count = inbox.transferTasks
                  .where((task) => task.state != 'cancelled')
                  .length;
              return NavigationBar(
                key: const ValueKey('mobile-navigation'),
                selectedIndex: homeSections
                    .indexOf(section)
                    .clamp(0, homeSections.length - 1),
                onDestinationSelected: (index) =>
                    onSection(homeSections[index]),
                animationDuration: AppMotion.duration(context),
                height: 72,
                elevation: 0,
                backgroundColor: palette.surface,
                surfaceTintColor: Colors.transparent,
                indicatorColor: palette.selected,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: [
                  for (final destination in homeSections)
                    NavigationDestination(
                      key: ValueKey('mobile-nav-${destination.name}'),
                      label: tr(context, destination.title),
                      tooltip: tr(context, destination.title),
                      icon: Badge(
                        isLabelVisible:
                            destination == MobileSection.transfers && count > 0,
                        label: Text('$count'),
                        backgroundColor: palette.selected,
                        textColor: palette.text,
                        child: Icon(destination.icon),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}
