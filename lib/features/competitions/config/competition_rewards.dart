class CompetitionRewards {
  const CompetitionRewards._();

  // ============================================================
  // TOKENS
  //
  // Spendable Family Tokens for official competition prizes.
  // Higher placements always receive more. Quick Play never pays these.
  // ============================================================

  static const int dailyWinnerTokens = 10;
  static const int dailyRunnerUpTokens = 4;
  static const int weeklyChampionTokens = 50;
  static const int weeklyRunnerUpTokens = 20;
  static const int weeklyThirdPlaceTokens = 10;
  static const int monthlyChampionTokens = 100;
  static const int monthlyRunnerUpTokens = 50;
  static const int monthlySemifinalistTokens = 20;

  // ============================================================
  // WEEKLY CHAMPIONSHIP ROUND POINTS
  //
  // These exist only inside one Weekly Championship.
  // They are NOT Tokens.
  // They are NOT permanent Ranking Points.
  // ============================================================

  static const int weeklyRoundFirst = 10;
  static const int weeklyRoundSecond = 7;
  static const int weeklyRoundThird = 5;
  static const int weeklyRoundFourth = 3;
  static const int weeklyRoundParticipation = 1;
}
