import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinquest/core/theme/app_theme.dart';
import 'package:kinquest/features/competitions/screens/daily_challenge_screen.dart';
import 'package:kinquest/features/competitions/screens/monthly_cup_screen.dart';
import 'package:kinquest/features/competitions/screens/weekly_championship_screen.dart';
import 'package:kinquest/l10n/app_localizations.dart';

void main() {
  for (final languageCode in ['en', 'ar']) {
    final isArabic = languageCode == 'ar';

    testWidgets(
      '$languageCode Daily prizes show 10 and 4 Tokens on a narrow screen',
      (tester) async {
        await _expectCompetitionPrizes(
          tester,
          languageCode: languageCode,
          screen: const DailyChallengeScreen(developerPreview: true),
          prizes: isArabic
              ? ['الفائز: +10 رمزًا', 'الوصيف: +4 رمزًا']
              : ['Winner: +10 Tokens', 'Runner-up: +4 Tokens'],
        );
      },
    );

    testWidgets(
      '$languageCode Weekly prizes show 50, 20 and 10 Tokens on a narrow screen',
      (tester) async {
        await _expectCompetitionPrizes(
          tester,
          languageCode: languageCode,
          screen: const WeeklyChampionshipScreen(developerPreview: true),
          prizes: isArabic
              ? [
                  'البطل: +50 رمزًا',
                  'الوصيف: +20 رمزًا',
                  'المركز الثالث: +10 رمزًا',
                ]
              : [
                  'Champion: +50 Tokens',
                  'Runner-up: +20 Tokens',
                  'Third place: +10 Tokens',
                ],
        );

        final strings = AppLocalizations.of(
          tester.element(find.byType(WeeklyChampionshipScreen)),
        )!;
        // Round scores still determine the championship standings; only the
        // spendable placement rewards changed from RP to Tokens.
        expect(
          find.text(strings.championshipScoringDescription),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$languageCode Monthly prizes show 100, 50 and 20 Tokens on a narrow screen',
      (tester) async {
        await _expectCompetitionPrizes(
          tester,
          languageCode: languageCode,
          screen: const MonthlyCupScreen(developerPreview: true),
          prizes: isArabic
              ? [
                  'البطل: +100 رمزًا + كأس',
                  'الوصيف: +50 رمزًا',
                  'المتأهلون لنصف النهائي: +20 رمزًا لكل متأهل',
                ]
              : [
                  'Champion: +100 Tokens + Trophy',
                  'Runner-up: +50 Tokens',
                  'Semifinalists: +20 Tokens each',
                ],
        );
      },
    );
  }
}

Future<void> _expectCompetitionPrizes(
  WidgetTester tester, {
  required String languageCode,
  required Widget screen,
  required List<String> prizes,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      locale: Locale(languageCode),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: screen,
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);

  final obsoleteRankingPrize = find.textContaining(
    RegExp(
      r'Ranking Points|\bRP\b|نقاط الترتيب|نقطة ترتيب|نقاط ترتيب',
      caseSensitive: false,
    ),
    findRichText: true,
  );
  expect(obsoleteRankingPrize, findsNothing);

  for (final prize in prizes) {
    final prizeText = find.text(prize);
    await tester.scrollUntilVisible(
      prizeText,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(prizeText, findsOneWidget);
    expect(
      Directionality.of(tester.element(prizeText)),
      languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
    );
    expect(obsoleteRankingPrize, findsNothing);
    expect(tester.takeException(), isNull);
  }
}
