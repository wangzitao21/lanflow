import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/platform/platform_bridge.dart';
import 'package:lanflow/ui/chat/home_page.dart';
import 'package:lanflow/ui/chat/mobile_home.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/app_root.dart';

class LanFlowApp extends StatefulWidget {
  const LanFlowApp({
    super.key,
    required this.controller,
    required this.inbox,
    this.platform,
    this.builder,
    this.interactionsBlocked = false,
    this.initialSection = MobileSection.conversations,
  });
  final LanController controller;
  final InboxController inbox;
  final TargetPlatform? platform;
  final TransitionBuilder? builder;
  final bool interactionsBlocked;
  final MobileSection initialSection;
  @override
  State<LanFlowApp> createState() => _LanFlowAppState();
}

class _LanFlowAppState extends State<LanFlowApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.inbox.appearance.addListener(_appearanceChanged);
    widget.inbox.language.addListener(_languageChanged);
    _updateSystemTheme();
    _updateSystemLanguage();
  }

  void _updateSystemTheme() {
    final preference = widget.inbox.appearance.value;
    final dark =
        preference == 'dark' ||
        (preference == 'system' &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: ChatPalette(dark).canvas,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
    unawaited(PlatformBridge.setDarkMode(dark).catchError((Object _) {}));
  }

  void _appearanceChanged() {
    _updateSystemTheme();
    setState(() {});
  }

  void _updateSystemLanguage() => unawaited(
    PlatformBridge.setLanguage(
      widget.inbox.language.value,
    ).catchError((Object _) {}),
  );

  void _languageChanged() {
    _updateSystemLanguage();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant LanFlowApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inbox == widget.inbox) return;
    oldWidget.inbox.appearance.removeListener(_appearanceChanged);
    oldWidget.inbox.language.removeListener(_languageChanged);
    widget.inbox.appearance.addListener(_appearanceChanged);
    widget.inbox.language.addListener(_languageChanged);
    _updateSystemTheme();
    _updateSystemLanguage();
  }

  @override
  void didChangePlatformBrightness() {
    if (widget.inbox.appearance.value == 'system') _appearanceChanged();
  }

  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.inbox.appearance.removeListener(_appearanceChanged);
    widget.inbox.language.removeListener(_languageChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppRoot(
    language: widget.inbox.language.value,
    platform: widget.platform,
    builder: widget.builder,
    themeMode: switch (widget.inbox.appearance.value) {
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.light,
    },
    home: HomePage(
      controller: widget.controller,
      inbox: widget.inbox,
      interactionsBlocked: widget.interactionsBlocked,
      initialSection: widget.initialSection,
    ),
  );
}
