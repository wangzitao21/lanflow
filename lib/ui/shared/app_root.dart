import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'chat_theme.dart';
import 'motion.dart';

class AppRoot extends StatelessWidget {
  const AppRoot({
    super.key,
    required this.home,
    this.themeMode = ThemeMode.system,
    this.language = 'zh',
    this.platform,
    this.builder,
  });
  final Widget home;
  final ThemeMode themeMode;
  final String language;
  final TargetPlatform? platform;
  final TransitionBuilder? builder;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LanFlow',
    debugShowCheckedModeBanner: false,
    locale: language == 'en' ? const Locale('en') : const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: chatTheme(Brightness.light, platform: platform),
    darkTheme: chatTheme(Brightness.dark, platform: platform),
    themeMode: themeMode,
    themeAnimationDuration:
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 180),
    themeAnimationCurve: AppMotion.curve,
    builder: builder,
    home: home,
  );
}
