import 'package:flutter_test/flutter_test.dart';
import 'package:kinquest/features/competitions/config/competition_rewards.dart';
import 'package:kinquest/features/competitions/services/championship_scoring_service.dart';
import 'package:kinquest/l10n/app_localizations.dart';
import 'package:kinquest/l10n/app_localizations_ar.dart';
import 'package:kinquest/l10n/app_localizations_en.dart';

void main() {
  group('official competition Token prizes', () {
    test('Daily winner receives more than runner-up', () {
      expect(CompetitionRewards.dailyWinnerTokens, 10);
      expect(CompetitionRewards.dailyRunnerUpTokens, 4);
      _expectDescending([
        CompetitionRewards.dailyWinnerTokens,
        CompetitionRewards.dailyRunnerUpTokens,
      ]);
    });

    test('Weekly prizes decrease with placement', () {
      expect(
        [
          CompetitionRewards.weeklyChampionTokens,
          CompetitionRewards.weeklyRunnerUpTokens,
          CompetitionRewards.weeklyThirdPlaceTokens,
        ],
        [50, 20, 10],
      );
      _expectDescending([
        CompetitionRewards.weeklyChampionTokens,
        CompetitionRewards.weeklyRunnerUpTokens,
        CompetitionRewards.weeklyThirdPlaceTokens,
      ]);
    });

    test('Monthly prizes decrease with placement', () {
      expect(
        [
          CompetitionRewards.monthlyChampionTokens,
          CompetitionRewards.monthlyRunnerUpTokens,
          CompetitionRewards.monthlySemifinalistTokens,
        ],
        [100, 50, 20],
      );
      _expectDescending([
        CompetitionRewards.monthlyChampionTokens,
        CompetitionRewards.monthlyRunnerUpTokens,
        CompetitionRewards.monthlySemifinalistTokens,
      ]);
    });

    test('championship round scoring is separate and unchanged', () {
      expect(
        [
          for (var placement = 1; placement <= 5; placement++)
            ChampionshipScoringService.pointsForPlacement(placement),
        ],
        [10, 7, 5, 3, 1],
      );
    });
  });

  for (final strings in <AppLocalizations>[
    AppLocalizationsEn(),
    AppLocalizationsAr(),
  ]) {
    test('${strings.localeName} prize copy uses Tokens, never RP', () {
      final summaries = [
        strings.dailyWinnerRewardSummary(10),
        strings.dailyRunnerUpRewardSummary(4),
        strings.championRewardSummary(50),
        strings.runnerUpRewardSummary(20),
        strings.thirdPlaceRewardSummary(10),
        strings.monthlyChampionRewardSummary(100),
        strings.runnerUpRewardSummary(50),
        strings.semifinalistRewardSummary(20),
        strings.dailyWinnerAnnouncement('Amr', 10),
        strings.weeklyWinnerAnnouncement('Amr', 50),
        strings.monthlyWinnerAnnouncement('Amr', 100),
        strings.tieRewardPendingDescription,
      ];
      for (final summary in summaries) {
        expect(summary, isNot(contains('Ranking Points')));
        expect(summary, isNot(contains('RP')));
        expect(summary, isNot(contains('نقطة ترتيب')));
        expect(summary, isNot(contains('نقاط ترتيب')));
        expect(summary, matches(RegExp(r'Tokens|رمز|رموز')));
      }
    });
  }
}

void _expectDescending(List<int> prizes) {
  expect(prizes.last, greaterThan(0));
  for (var index = 1; index < prizes.length; index++) {
    expect(prizes[index - 1], greaterThan(prizes[index]));
  }
}
